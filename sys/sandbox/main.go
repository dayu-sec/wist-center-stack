// wist-sandbox —— WarpStation 沙盒的 runner / client 兼容层。
//
// 同一个二进制两个角色：
//   - `/usr/local/bin/wist-sandbox run`      → runner（station-sandbox 容器，无网络、无密钥）
//   - 以 `wparse` / `wpgen` / `wproj` 调用  → client（WarpStation 容器里 /app/toolchain/ 下的包装）
//
// WarpStation 只认 `/app/toolchain/{wparse,wpgen,wproj}` 这三个路径；client 把 argv 原样通过
// Unix socket 发给 runner，runner 在沙盒容器里执行真实二进制，并把 stdout/stderr/exit code 回传。
// 这样用户可控的规则/OML 永远不会在持有 CNB token / proxy token / DB 凭据的主容器里执行。
//
// 协议：4 字节大端长度 + JSON 帧（见 frame）。stdout/stderr/stdin 用 base64 承载，避免非 UTF-8
// 被 JSON 编码替换。client 断开时 runner 立即杀掉整个进程组（兼容 WarpStation 的 start_kill）。
package main

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	defaultSocketPath = "/run/sandbox/control.sock"
	defaultSandboxRoot = "/app/tmp/sandbox"
	maxFrameBytes      = 8 << 20
	maxArgs            = 128
	maxArgBytes        = 8 << 10
	maxConcurrent      = 2
	streamChunk        = 32 << 10
)

var allowedCommands = map[string]bool{
	"wparse": true,
	"wpgen":  true,
	"wproj":  true,
}

type request struct {
	Cmd  string   `json:"cmd"`
	Args []string `json:"args"`
	Cwd  string   `json:"cwd"`
}

type frame struct {
	Type    string `json:"type"`
	Data    string `json:"data,omitempty"`
	Code    *int   `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
	Signal  string `json:"signal,omitempty"`
}

func main() {
	base := filepath.Base(os.Args[0])
	switch {
	case base == "wist-sandbox" || strings.HasPrefix(base, "wist-sandbox"):
		if len(os.Args) > 1 && os.Args[1] == "run" {
			runServer()
			return
		}
		fmt.Fprintln(os.Stderr, "usage: wist-sandbox run")
		os.Exit(2)
	case allowedCommands[base]:
		runClient(base)
	default:
		fmt.Fprintf(os.Stderr, "wist-sandbox: unknown invocation %q\n", base)
		os.Exit(2)
	}
}

func envOr(key, def string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return def
}

// ── runner ─────────────────────────────────────────────────────────────────

func runServer() {
	sockPath := envOr("SANDBOX_SOCKET", defaultSocketPath)
	if err := os.MkdirAll(filepath.Dir(sockPath), 0o750); err != nil {
		fmt.Fprintf(os.Stderr, "sandbox: mkdir socket dir: %v\n", err)
		os.Exit(1)
	}
	_ = os.Remove(sockPath)
	listener, err := net.Listen("unix", sockPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "sandbox: listen %s: %v\n", sockPath, err)
		os.Exit(1)
	}
	if err := os.Chmod(sockPath, 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "sandbox: chmod socket: %v\n", err)
	}

	sem := make(chan struct{}, maxConcurrent)
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-stop
		_ = listener.Close()
		os.Exit(0)
	}()

	fmt.Fprintf(os.Stderr, "sandbox: runner listening on %s (root=%s, max=%d)\n",
		sockPath, envOr("SANDBOX_ROOT", defaultSandboxRoot), maxConcurrent)
	for {
		conn, err := listener.Accept()
		if err != nil {
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				continue
			}
			return
		}
		select {
		case sem <- struct{}{}:
			go func() {
				defer func() { <-sem }()
				handle(conn)
			}()
		default:
			_ = writeFrame(conn, frame{Type: "error", Message: "sandbox busy: too many concurrent tasks"})
			_ = conn.Close()
		}
	}
}

func handle(conn net.Conn) {
	defer conn.Close()

	var writeMu sync.Mutex
	send := func(f frame) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		return writeFrame(conn, f)
	}

	raw, err := readFrame(conn)
	if err != nil {
		return
	}
	var req request
	if err := json.Unmarshal(raw, &req); err != nil {
		_ = send(frame{Type: "error", Message: "invalid request: " + err.Error()})
		return
	}
	if err := validateRequest(&req); err != nil {
		_ = send(frame{Type: "error", Message: err.Error()})
		return
	}

	cmd := exec.Command(filepath.Join("/usr/local/bin", req.Cmd), req.Args...)
	cmd.Dir = req.Cwd
	cmd.Env = minimalEnv()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = send(frame{Type: "error", Message: "stdout pipe: " + err.Error()})
		return
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		_ = send(frame{Type: "error", Message: "stderr pipe: " + err.Error()})
		return
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		_ = send(frame{Type: "error", Message: "stdin pipe: " + err.Error()})
		return
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var stdinMu sync.Mutex
	go func() {
		// 唯一的读循环：stdin / signal；连接断开 = 客户端消失。
		for {
			raw, err := readFrame(conn)
			if err != nil {
				cancel()
				return
			}
			var f frame
			if err := json.Unmarshal(raw, &f); err != nil {
				continue
			}
			switch f.Type {
			case "stdin":
				data, err := base64.StdEncoding.DecodeString(f.Data)
				if err != nil {
					continue
				}
				stdinMu.Lock()
				_, _ = stdin.Write(data)
				stdinMu.Unlock()
			case "stdin_close":
				stdinMu.Lock()
				_ = stdin.Close()
				stdinMu.Unlock()
			case "signal":
				if sig, ok := parseSignal(f.Signal); ok && cmd.Process != nil {
					_ = syscall.Kill(-cmd.Process.Pid, sig)
					if sig == syscall.SIGKILL {
						cancel()
					}
				}
			}
		}
	}()

	if err := cmd.Start(); err != nil {
		_ = send(frame{Type: "error", Message: "start: " + err.Error()})
		return
	}

	go streamPipe(stdout, "stdout", send)
	go streamPipe(stderr, "stderr", send)

	wait := make(chan error, 1)
	go func() { wait <- cmd.Wait() }()

	select {
	case <-ctx.Done():
		// client 断开或显式 KILL：不留孤儿进程组。
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-wait
		return
	case err := <-wait:
		cancel()
		code := exitCode(err)
		_ = send(frame{Type: "exit", Code: &code})
	}
}

func validateRequest(req *request) error {
	if !allowedCommands[req.Cmd] {
		return fmt.Errorf("command not allowed: %q", req.Cmd)
	}
	if len(req.Args) > maxArgs {
		return fmt.Errorf("too many args: %d", len(req.Args))
	}
	for _, arg := range req.Args {
		if len(arg) > maxArgBytes {
			return fmt.Errorf("arg too long: %d bytes", len(arg))
		}
		if strings.ContainsRune(arg, 0) {
			return errors.New("arg contains NUL")
		}
	}
	if strings.TrimSpace(req.Cwd) == "" {
		return errors.New("cwd is required")
	}

	root, err := filepath.EvalSymlinks(envOr("SANDBOX_ROOT", defaultSandboxRoot))
	if err != nil {
		return fmt.Errorf("sandbox root unavailable: %w", err)
	}
	abs, err := filepath.Abs(req.Cwd)
	if err != nil {
		return fmt.Errorf("cwd: %w", err)
	}
	real, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return fmt.Errorf("cwd not found: %w", err)
	}
	if real != root && !strings.HasPrefix(real, root+string(os.PathSeparator)) {
		return fmt.Errorf("cwd escapes sandbox root: %s", real)
	}
	info, err := os.Stat(real)
	if err != nil || !info.IsDir() {
		return fmt.Errorf("cwd is not a directory: %s", real)
	}
	req.Cwd = real
	return nil
}

func minimalEnv() []string {
	env := []string{
		"PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
		"HOME=/tmp",
		"TMPDIR=/tmp",
		"LANG=C.UTF-8",
		"LC_ALL=C.UTF-8",
	}
	// 只透传时区：WarpStation 的任务日志依赖它，其它业务环境变量一律不继承。
	if tz := strings.TrimSpace(os.Getenv("TZ")); tz != "" && len(tz) <= 64 {
		env = append(env, "TZ="+tz)
	}
	return env
}

func streamPipe(reader io.Reader, kind string, send func(frame) error) {
	buf := make([]byte, streamChunk)
	for {
		n, err := reader.Read(buf)
		if n > 0 {
			_ = send(frame{Type: kind, Data: base64.StdEncoding.EncodeToString(buf[:n])})
		}
		if err != nil {
			return
		}
	}
}

func parseSignal(name string) (syscall.Signal, bool) {
	switch strings.ToUpper(strings.TrimPrefix(strings.TrimSpace(name), "SIG")) {
	case "TERM":
		return syscall.SIGTERM, true
	case "INT":
		return syscall.SIGINT, true
	case "HUP":
		return syscall.SIGHUP, true
	case "QUIT":
		return syscall.SIGQUIT, true
	case "KILL":
		return syscall.SIGKILL, true
	default:
		return 0, false
	}
}

func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		if status, ok := exitErr.Sys().(syscall.WaitStatus); ok {
			if status.Signaled() {
				return 128 + int(status.Signal())
			}
			return status.ExitStatus()
		}
	}
	return 1
}

// ── client ─────────────────────────────────────────────────────────────────

func runClient(command string) {
	sockPath := envOr("SANDBOX_SOCKET", defaultSocketPath)
	cwd, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: getwd: %v\n", command, err)
		os.Exit(1)
	}
	conn, err := net.DialTimeout("unix", sockPath, 3*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: sandbox runner unavailable (%s): %v\n", command, sockPath, err)
		os.Exit(111)
	}
	defer conn.Close()

	var writeMu sync.Mutex
	send := func(f frame) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		return writeFrame(conn, f)
	}

	writeMu.Lock()
	err = writeFrame(conn, request{Cmd: command, Args: os.Args[1:], Cwd: cwd})
	writeMu.Unlock()
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: send request: %v\n", command, err)
		os.Exit(1)
	}

	go func() {
		buf := make([]byte, streamChunk)
		for {
			n, err := os.Stdin.Read(buf)
			if n > 0 {
				if send(frame{Type: "stdin", Data: base64.StdEncoding.EncodeToString(buf[:n])}) != nil {
					return
				}
			}
			if err != nil {
				_ = send(frame{Type: "stdin_close"})
				return
			}
		}
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGQUIT)
	go func() {
		for sig := range sigCh {
			_ = send(frame{Type: "signal", Signal: signalName(sig)})
		}
	}()

	for {
		raw, err := readFrame(conn)
		if err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				fmt.Fprintf(os.Stderr, "%s: sandbox runner closed the connection\n", command)
			} else {
				fmt.Fprintf(os.Stderr, "%s: read result: %v\n", command, err)
			}
			os.Exit(1)
		}
		var f frame
		if err := json.Unmarshal(raw, &f); err != nil {
			fmt.Fprintf(os.Stderr, "%s: bad result frame: %v\n", command, err)
			os.Exit(1)
		}
		switch f.Type {
		case "stdout", "stderr", "result":
			data, err := base64.StdEncoding.DecodeString(f.Data)
			if err != nil {
				continue
			}
			if f.Type == "stderr" {
				_, _ = os.Stderr.Write(data)
			} else {
				_, _ = os.Stdout.Write(data)
			}
		case "exit":
			if f.Code == nil {
				os.Exit(0)
			}
			os.Exit(*f.Code)
		case "error":
			fmt.Fprintf(os.Stderr, "%s: %s\n", command, f.Message)
			os.Exit(1)
		}
	}
}


func signalName(sig os.Signal) string {
	switch sig {
	case syscall.SIGTERM:
		return "TERM"
	case syscall.SIGINT:
		return "INT"
	case syscall.SIGHUP:
		return "HUP"
	case syscall.SIGQUIT:
		return "QUIT"
	default:
		return ""
	}
}

// ── framing ────────────────────────────────────────────────────────────────

func readFrame(r io.Reader) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, err
	}
	size := binary.BigEndian.Uint32(header[:])
	if size == 0 || size > maxFrameBytes {
		return nil, fmt.Errorf("invalid frame size: %d", size)
	}
	payload := make([]byte, size)
	if _, err := io.ReadFull(r, payload); err != nil {
		return nil, err
	}
	return payload, nil
}

func writeFrame(w io.Writer, value any) error {
	payload, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(payload) > maxFrameBytes {
		return fmt.Errorf("frame too large: %d", len(payload))
	}
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(payload)))
	if _, err := w.Write(header[:]); err != nil {
		return err
	}
	_, err = w.Write(payload)
	return err
}
