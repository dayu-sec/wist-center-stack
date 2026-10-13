# wist-center 现场态**声明** —— 只写 `${VAR}` 引用，**不含现场值**。
#
# 本文件是**模板**：由 tpl 机制渲染到 `identity/center/wist-center-pub.toml`
# （见 `sys/workflows/operators.gxl`）—— 与其它交付物同一套渲染；重渲 / 升级动不到现场，
# 因为值不在这里。真值在同目录的 `.env`（docker-compose 口径：`.env` 挨着本文件；**进程环境优先**）。
#
# 变量名用 gops 的系统变量名（`CENTER_PUBLIC_URL`），好让现场脚本「原样搬」。
# `${VAR}` 未定义且没给 `:-默认值` → 中心拒启（fail-closed）；这里给了默认值，避免「忘跑脚本」即拒启。
#
# ⚠ handlebars 只处理它自己的**双花括号**占位、不管 `${…}` —— 所以本模板里**不要**出现双花括号。

[server]
# 中心对外地址：用于生成网关初始化 URL，必须落在控制中心服务器证书的 SAN 内。
public_url = "${CENTER_PUBLIC_URL:-https://center.warpinsight.example}"
