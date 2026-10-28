# wist-center-stack 待办

> 记录**已决策、尚未落地**的事项。每项结论先行，附代码依据，避免重复讨论。
> 组件仓（`wist-center` / `wist-gateway-stack` / `wist-gwlinkd`）的位置以仓名 + 路径标注。

---

## P1 · Git Proxy 启用双向证书（mTLS），独立域名 + 第二 IP 的 443

### 结论（2026-10-28 决策）

Git Proxy **不并入 center 的 443，也不做 path 合流**；公网暴露以**双向证书**为前提。
地址形态定为：**独立域名（`wp-git.<zone>`）+ 主机上的第二个公网 IP + 该 IP 的 443**
—— URL 里不带端口，且 mTLS / 真实 peer IP / 限流全部保持原样。

> 过渡态：第二个 EIP 落地前，沿用 `https://<API_WGC_DOMAIN>:18082/<repo>`，
> mTLS 与 allowlist 先上（安全性不变，只是 URL 带端口）。
>
> **已落地（2026-10-28）**：中心侧 mTLS 骨架已完成（模板开关 / CA-G 挂载 / 两个新变量 /
> 渲染脚本 `scripts/init-git-proxy-conf.sh`）。默认 `off`，行为不变；后续只剩网关侧改动与灰度。

### 为什么不合流到 443 / 不做 path 分流

不是 nginx 配置问题，而是 `wist-center` 的鉴权模型假设「TCP 对端就是网关本人」：

| 约束 | 依据 | 后果 |
|---|---|---|
| 网关身份只能来自 **TLS 层** | `wist-center/src/main.rs:275-278`（注释明确「客户端无法通过 HTTP 头伪造」）；`src/main.rs:303-323` 用 rustls 校 CA-G 链、从连接取叶子证书 DER | L7 终结 TLS 后 nginx **无法转呈第三方客户端证书** → 全部 401 `certificate_required`（`src/api/gateway_ops.rs:1140-1143`） |
| 限流按 **peer IP** 且显式忽略 XFF | `wist-center/src/api/rate_limit.rs:1-2`；限额为 **5 次失败 / 60s → 封 60s** | 任何前置（L7 或 SNI/L4）都会让全 fleet 共用一个桶：任一网关 5 次失败 → 整面被封 60s |
| 部分链路只靠 mTLS 保完整性 | `wist-center/src/api/gateway_ops.rs:2493`（「不显式给摘要就**没有任何内容校验**，只剩 mTLS」） | 终结 mTLS 即失去该保证 |

> 不经过前置代理（直接暴露 443 也一样）会保住**真实 peer IP** —— 限流、审计、
> `GIT_PROXY_ALLOW_CIDR` 都继续有效，这是任何前置方案都会破坏的。这是本条决策的主要理由。

### 地址与端口形态（已定）

```
wp-git.<zone>  → 第二 EIP → 辅助私网 IP（如 10.168.0.150） → git-proxy :443
center.<zone>  → 主 EIP   → 主私网 IP（如 10.168.0.149）   → center   :443
```

域名定为 **`wp-git`**（2026-10-28）：与仓库名（`wp-rules` / `wp-infra`）和变量前缀（`WP_GIT_*`）一致；
比 `git.` 更能说明它**只读、只有这两个仓库、`git-receive-pack` 返回 403**，避免运维误以为可 clone 全站或可推。

- **域名不解决端口**：一个 IP 的 443 只能有一个监听者。要 URL 无端口，必须是**第二个 IP**
  （或独立主机），不是第二个域名。
- **云上公网 IP 是 NAT**：容器要绑**私网 IP**；绑 EIP 会报 `bind: cannot assign requested address`。
- **`CENTER_API_BIND_IP` 必须从 `0.0.0.0` 钉成主私网 IP**，否则它占住所有私网 IP 的 443，
  git-proxy 起不来（这是最易漏、且报错最像 docker 问题的一条）。
- **证书复用**：同机共享同一张叶证书（私钥不出机器），`EXTRA_SANS` 增加 `wp-git.<zone>` 后重签即可；
  CA 不变，网关无感。
- **不要用通配符 `*.<zone>`**：通配符不带来任何收益（域名是固定两三个），却让一张私钥可冒充
  该 zone 下**任意**子域；日后若把 git 拆到独立主机，通配符私钥就得跨机复制（更糟）。
- ⚠️ **SAN 变化会重新生成私钥**（`scripts/ensure-center-server-cert.sh:64`）：
  center / web / git-proxy 三个容器挂的是同一个证书文件（`sys/docker-compose.yml:199-200, 226-227`），
  必须**一起滚动重启**，否则会有一段时间某容器用旧 key。

### 部署前置（必须先核实）

- [ ] 实例规格支持第二个 IP / 第二个 EIP（多 ENI，或「辅助私网 IP + EIP」，以控制台/工单为准）
- [ ] 辅助私网 IP 已在网卡上：`ip addr show | rg '<辅助私网 IP>'`（不在网卡上，docker 一定绑不上）
- [ ] DNS：`wp-git.<zone>` → 第二 EIP（可用 `dig +short` 验证）
- [ ] 安全组放行第二 IP 的 443（腾讯云安全组是实例级，通常已放行）
- [ ] EIP 的带宽/计费确认（按 EIP 单独计费）

### 上线验证

```sh
# 1) SAN 覆盖新域名（CA 不发，只看叶）
openssl s_client -connect wp-git.<zone>:443 -servername wp-git.<zone> </dev/null \
  | openssl x509 -noout -ext subjectAltName
# 2) URL 无端口可达；mTLS 开启后，不带客户端证书应被拒（400/403 才是对）
curl -s -o /dev/null -w '%{http_code}\n' \
  'https://wp-git.<zone>/dy-sec/jingang-cust/wist/wp-rules/info/refs?service=git-upload-pack'
# 3) 网关侧：确认拿到的是新地址、且能带证书拉取（gwlinkd/诊断脚本）
```

### 中心侧落地清单

- [x] `sys/configs/git-proxy/nginx.conf.tpl`：`{{{git_proxy_client_ca}}}` 占位 + access log 带
      `verify=$ssl_client_verify`（`optional` 灰度靠它算覆盖率）
- [x] `sys/docker-compose.yml`（`git-proxy.volumes`）：只读挂 `gateway-client-ca.pem`（**不挂私钥**）
- [x] `sys/setting/vars.yml`：`GIT_PROXY_CLIENT_CERT_VERIFY`（`off|optional|on`，默认 `off`）、
      `GIT_PROXY_DOMAIN`（默认空 = 沿用 `API_WGC_DOMAIN`）
- [x] 渲染脚本：`scripts/init-git-proxy-conf.sh`（补上了缺失的 `git-proxy.value.json` 生成，
      见下方「顺带发现」）；已接入 `sys/workflows/operators.gxl` localize 流程
- [x] `scripts/init-center.sh`：`GIT_PROXY_DOMAIN` 自动进叶证书 **SAN**（非空且与已有域名不同时追加；
      幂等重签、CA 不动）—— 否则网关校 `wp-git.*` 主机名会失败
- [ ] 撤销链路：`ssl_crl` 生成 + 重渲染 + reload（否则删网关后**最长 30 天空窗**）
- [ ] 监控：证书剩余天数 + `verify=FAILED` 计数
- [ ] 文档：设计文档 `wist-design/.../warpstation-rule-publishing.md` §5.2.1 / R17（README 已更新）

### 双域名形态（本机已验通，不依赖 443）

本机用「两个域名 + 各自端口」复现了最终形态（443 留到 alpha 上验）：

```
center.dev.wist.lab :3100   → center（网关面，mTLS）
wp-git.dev.wist.lab :18082  → git-proxy（只读 smart HTTP + 可选双向证书）
```

- [x] 叶证书 SAN 覆盖两者：`wgc / center / wp-git / localhost / 127.0.0.1`
- [x] 网关栈新增 `GIT_PROXY_DOMAIN` + `extra_hosts`（容器内把 `wp-git.*` 指回宿主网关）
      —— 落在 `wist-gateway-stack` 仓，**需上游合并**，本机只改了 dev checkout
- [x] 验证：容器（与 wparse 同网络）用 Center CA 校验证书拉 `info/refs` → 200；
      非白名单 → 404；带网关客户端证书 → 日志 `verify=SUCCESS`
- [ ] 网关侧把客户端证书交给 git（见下）后切 `on`
- [ ] 第二 IP + 443（见下节）

### 第二 IP 现场值（EIP 到手后再改，中心侧代码已就绪）

**不新增变量**：双 IP 靠既有的 `CENTER_API_BIND_IP` / `CENTER_API_HOST_PORT` 与
`GIT_PROXY_BIND_IP` / `GIT_PROXY_HOST_PORT` 两对；`GIT_PROXY_DOMAIN` 单独一个。

- [x] localize 阶段的**双 IP 守卫**：同端口且绑定地址重叠（相同或任一 `0.0.0.0`）→ `init-git-proxy-conf.sh`
      直接报错并给出两种出路（不用等 `compose up` 的 `EADDRINUSE`）
- [x] README 补「双 IP（可选）」小节（四个变量的对照表 + 绑私网 IP 的坑）
- [ ] `GIT_PROXY_BIND_IP` = **辅助私网 IP**（不是 EIP）；`GIT_PROXY_HOST_PORT` = `443`
- [ ] `CENTER_API_BIND_IP` = 主私网 IP（不能是 `0.0.0.0`，否则抢 443）
- [ ] `GIT_PROXY_DOMAIN` = `wp-git.<zone>`；网关侧两个 `WPARSE_PROJECT_*_REPO` 改成无端口地址

### 网关侧落地清单（仓：`wist-gateway-stack`）

- [x] 从 `identity/gwlinkd/credential.json` 投影证书：`scripts/init-wparse-admin.sh` 写
      `data-plane-run/.run/git-client.{crt,key}.host`（0600）；`wparse-run-init` 复制进命名卷
      `/data/.run/git-client.{crt,key}`（0600，属主 wparse）
- [x] **已随 gateway-stack `0.6.0-alpha` 发布（2026-10-28）**：网关侧只认域名，不认 IP ——
      `extra_hosts: <域名>:host-gateway`（单机）/ 真实 DNS（多机），values 里不出现 IP、端口。
      所以换 IP、换 EIP、上第二 IP **都不需要改网关**（一个值管 1000 个网关）。
      同时加了「`GIT_PROXY_DOMAIN` / `CENTER_API_DOMAIN` vs 实际访问主机名」一致性告警。
- [x] 顺带改名（**破坏性**）：`CENTER_DOMAIN` → **`CENTER_API_DOMAIN`**（与 center-stack 的
      `CENTER_API_*` 成对）；旧键仍在而新键为空时 localize 直接失败。
- [ ] **卡点：wparse 侧还不支持把客户端证书交给 libgit2** —— 见下

#### 卡点：wparse 不支持 git 客户端证书（2026-10-28 实测）

结论：**已证实“配置无效”，未证实“永远不支持”**。实测事实：

| 事实 | 依据 |
|---|---|
| wparse 用 **libgit2**（静态链接），容器内无 git 二进制 | `libgit2-sys-0.18.8+1.9.7`；`command -v git` 为空 |
| `GIT_SSL_CERT` / `GIT_SSL_KEY`（git CLI 专属）天然无效 | 同上 |
| gitconfig 三条路都不生效：`GIT_CONFIG_GLOBAL`、`$HOME/.gitconfig`、`$XDG_CONFIG_HOME/git/config` | **探针**：把 `sslCAInfo` 写成不存在的文件，拉取照常成功（`verify=NONE`） |
| 二进制里的 `ssl_cert` / `client_cert` 均来自 librdkafka / openssl-probe，不是 git 层 | `grep -a` 上下文均为 `rd_kafka_*` |

→ 结论：wparse 自己接管了 remote 的 TLS 参数，**客户端证书需要上游支持**（历史原因：在这个需求出现前，
Git Proxy 根本没有客户端认证，设计里写的就是 TODO）。

**向上游提的能力要求**（已在 `wp-labs/warp-parse` 提 issue：
https://github.com/wp-labs/warp-parse/issues/371 —— 任选其一）：
- `[project_remote]`（或 models/infra 子表）支持 `ssl_cert` / `ssl_key` / `ssl_ca` 路径；或
- 构造 libgit2 remote 时读 `http.sslCert` / `http.sslKey`（即尊重 gitconfig）；或
- 支持约定环境变量（容器友好，不需改配置结构）。

**在 wparse 支持前**：`GIT_PROXY_CLIENT_CERT_VERIFY` 只能停在 `optional`（`on` 会让网关拉不到仓库），
真正的来源限制靠 `GIT_PROXY_ALLOW_CIDR` + 不公网暴露。

#### 有用的旁证（验证手段，以后别再重查）

- **触发 wparse 远端同步**：`POST /admin/v1/reloads/model`，body
  `{"group":"models|infra","version":"<x>","update":true}`（缺 `update=true` 会被拒）；
  token 在 `data-plane-run/.run/admin_api.token.host`。
- **观测是否带证书**：git-proxy access log 的 `verify=` 字段（`docker exec ... cat /var/log/nginx/access.log`）。

### 灰度顺序（避免一开就全挂）

```
off  →  optional（只记录 $ssl_client_verify，不拦）→ 观测 100% SUCCESS  →  on + CRL
```

### 已确认

- CA-G 已存在：`scripts/init-center.sh:119-126`（`identity/center/gateway-client-ca.{pem,key.pem}`）
- 网关已有 per-gateway 客户端证书：`identity/gwlinkd/credential.json`
  （`certificate` + `private_key_pem`，URI SAN = `gateway_id`，有效期约 30 天）
- center 的网关面（3100）已经用这套 mTLS，Git Proxy 只是把同一套接上去

### 待确认

1. **wparse 的 git 后端**：entrypoint 使用 `GIT_SSL_CAINFO`（只有 git CLI 认，libgit2 不读），
   推断为 git CLI → `GIT_SSL_CERT`/`GIT_SSL_KEY` 可直接用。需在镜像里确认（`command -v git` / 无 libgit2 链接）
2. **第二 EIP 的成本与规格上限**（同机多 IP 是否可行）；拿不到就退回过渡态 `:18082`
3. ~~域名命名~~ → **已定 `wp-git.<zone>`**（见「地址与端口形态」）
4. **撤销策略**：CRL（每次撤销要重渲染 + reload）还是短有效期（如 7 天，靠轮换收敛）
5. **网关网段**：是否同时开 `GIT_PROXY_ALLOW_CIDR` 做纵深
6. **授权粒度**：当前语义是「任何**已入网**网关可读这两个仓库」。若将来按客户拆仓，
   需用 `map $ssl_client_s_dn`（URI SAN 的 `gateway_id`）做仓库级授权（对应 R15）

---

## P2 · Git Proxy 上游凭据收口（CNB token 不落公网主机）

- **现状**：CNB 读 token 明文在渲染后的 `configs/git-proxy/nginx.conf`（600，只读挂载）。
  mTLS 保护的是入口，保护不了落盘凭据；同机还跑着 R18 登记的无鉴权 WarpStation。
- **方案**：Git Proxy 改为**服务中心本地镜像**（`configs/station/gitea/wparse__{models,infra}`，
  见 `wist-design/.../warpstation-rule-publishing.md` §4.1/§6）；发布后 `git fetch --prune --tags` 同步。
  token 只留在发布侧，公网端点不再持有任何上游凭据。
- [ ] 评估 `git http-backend`（smart HTTP）vs `update-server-info` + 静态 `root`（dumb，仓库小、实现最简）
- [ ] 镜像同步挂到发布流程收尾（幂等；失败要可见）

## P3 · 版本标识改为不可变（回退字节级一致）

- **问题**：tag 可移动/删除重建，「回退到 vX」不保证字节一致
- [ ] 发布时记录 `tag → commit sha`，网关按 sha 固定
      （`project_remote_state.json` 已有 `revision` 字段，正好复用）

---

## 已否决（记录以免重复讨论）

| 方案 | 否决理由 |
|---|---|
| Git Proxy 并进 center 的 443（path 分流） | 需改 center 的信任模型（`trust_proxy_from` + 验 `X-Client-Cert` + 限流 key 改造 + 禁止外部伪造），安全不变量被替换；为两个只读仓库付这个代价不划算 |
| 同机 SNI / L4 分流占 443 | mTLS 能保住，但后端 peer 变成 `127.0.0.1` → 限流并桶（需 PROXY protocol，center 目前不支持） |
| 拆独立主机托管 Git Proxy | 只解决端口争用，却新增故障域 + 密钥分发 + 一套运维；在本规模下不划算。**同机第二 IP + 443** 可以零副作用拿到同样效果（见 P1「地址与端口形态」），所以不走这一条 |
| 用通配符 `*.<zone>` 做证书 | 域名空间固定，通配符无收益；却把私钥可冒充的范围从「几个已知主机名」放大到整个 zone，并阻碍日后拆分主机 |
| 在网关 values 里写 Git Proxy 的 IP（如 `GIT_PROXY_RESOLVE_IP`） | IP 属于**中心侧拓扑**，写进客户端等于「换 IP / 换 EIP 要改 1000 个网关」，域名带来的好处当场归零。单机用 `host-gateway` 映射、多机用真实 DNS，两种形态都只需要域名 |

---

## 顺带发现（待修）

- [x] ~~**0.5.5 的 localize 流程没有生成 `configs/git-proxy/git-proxy.value.json` 的脚本**~~
      → 已修：新增 `scripts/init-git-proxy-conf.sh`，接入 `operators.gxl` localize 流程；
      本地已跑通（`gops sys localize` 15/15 ok，二次运行幂等）
- [ ] **设计文档白名单正则过期**：`warpstation-rule-publishing.md` §5.2 写的是
      `^/dy-sec/jingang-cust/(wp-rules|wp-infra)\.git/...`，缺中间的 `/wist/`；
      实际渲染值是 `.../jingang-cust/wist/wp-rules...`。照文档手配 nginx 会 404
