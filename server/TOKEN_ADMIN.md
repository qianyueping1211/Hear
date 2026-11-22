# 听见 Token 管理服务与网关托管鉴权

本文是《听见 Token 管理服务与 BAT 接入规范》的实现说明，内容包括：启动和备份、网关接入、测试数据生成、接口地址与权限，以及验收对照。接口契约见同目录的 [`hear-token-api.openapi.yaml`](hear-token-api.openapi.yaml)（OpenAPI 3.1）。

所有组件只依赖 Python 标准库（Python 3.9 以上）。只有 `gen-cert` 子命令额外需要 `cryptography`；网关的 venv 里已经装了它。

## 1. 组成

| 文件 | 作用 |
| --- | --- |
| `hear_token_service.py` | 管理服务：浏览器后台 `/admin/`、管理 API `/admin/api/v1`、网关清单 `/internal/v1`，以及命令行工具 |
| `hear_token_store.py` | SQLite 存储、迁移和业务规则。签发、改期、撤销、停用和删除都与网关修订号在同一事务内提交 |
| `hear_token_admin.html/.js/.css` | 管理后台页面。使用严格 CSP，不含内联脚本，用户数据一律按纯文本写入页面 |
| `hear_auth.py` | 网关端：拉取清单、在内存中校验，每 30 秒刷新一次；超过 60 秒未同步成功则返回 503 |
| `hear_http.py` / `hear_cloud.py` | 推理接口接入同一套鉴权，新增 `/v1/auth/check`，`/health` 增加 `auth_mode` 和 `auth_ready` |
| `hear_check_token.py` | `start-hear-cloud.bat --check-token` 背后的检查程序 |
| `test_token_auth.py` | 端到端自测，覆盖 116 项，CI 中运行 |

## 2. 地址与权限

| 接口 | Base URL | 凭据 | 能做什么 | 不能做什么 |
| --- | --- | --- | --- | --- |
| 管理后台 | `https://<管理服务>:8443/admin/` | 管理员用户名和密码（会话 Cookie） | 浏览器管理 | — |
| 管理 API | `https://<管理服务>:8443/admin/api/v1` | 会话 Cookie；写操作另需 `X-CSRF-Token` 且同源 | `admin` 角色可读写，`viewer` 角色只读 | 网关凭据和用户 Token 都会得到 401 |
| 网关清单 | `https://<管理服务>:8443/internal/v1/gateways/{gateway_id}/token-snapshot` | `Authorization: Bearer hear_gw_...` | 只能读取本网关的清单 | 读取其他网关的清单返回 403；用户 Token 返回 401；不能操作用户 |
| 网关健康 | `https://hear.yueping1211.asia/health`，或内网 `https://<Windows IP>:8000/health` | 无 | 查看连通、模型和口令服务状态 | — |
| 口令检查 | 同上，路径为 `/v1/auth/check` | `X-Hear-Token: hear_ut_...` | 检查这串口令在该网关上的状态 | 不调用模型 |
| 推理接口 | 同上，路径为 `/v1/asr` 等 | `X-Hear-Token` | App 现有的协议不变 | 明文 HTTP 返回 403（显式开启的本机 Cloudflare 回源除外） |

管理服务和内部 API 只应通过 VPN、专用内网或独立的管理入口访问，不要和 App 的公网入口共用同一个反向代理路由。网关 ID 由管理员在登记网关时指定，例如 `hear-home`。

## 3. 启动管理服务

管理服务可以和网关装在同一台 Windows 电脑上，也可以单独部署。以下命令在 `server` 目录下执行，Windows 上把 `python3` 换成 `python`。

```powershell
# 1) 创建数据库，默认位置是 server\token-data\hear-tokens.db，可用 --db 或 HEAR_TOKEN_DB 改
python hear_token_service.py init

# 2) 创建管理员。密码至少 12 位，输入不回显。再建一个只读账号可加 --role viewer
python hear_token_service.py create-admin --username admin

# 3) 生成管理服务证书。--host 写网关访问管理服务时使用的地址
python hear_token_service.py gen-cert --cert token-data\svc-cert.pem --key token-data\svc-key.pem --host 127.0.0.1 --host 10.8.0.1

# 4) 登记网关。凭据写入一个新文件，只生成这一次
python hear_token_service.py create-gateway --id hear-home --name 家里 --credential-out C:\HearSecrets\hear-home.cred

# 5) 启动
python hear_token_service.py serve --host 10.8.0.1 --port 8443 --tls-cert token-data\svc-cert.pem --tls-key token-data\svc-key.pem
```

- 服务监听非本机地址时必须启用 HTTPS。如果前面有可信的 HTTPS 反向代理，改用 `--allow-plain-http --secure-cookie --allowed-origin https://admin.example.com`，并且只允许代理访问这个端口。
- 浏览器打开 `https://10.8.0.1:8443/admin/` 登录。自签证书第一次访问时需要在浏览器里确认。
- 需要常驻运行时，用「任务计划程序」新建一个开机启动的任务，执行上面的 `serve` 命令，起始目录设为 `server`。
- 其他命令：`reset-password --username admin`（重置密码，同时注销该管理员的所有会话）、`rotate-gateway-credential --id hear-home --credential-out <新文件>`（轮换网关凭据）、`list-gateways`（查看各网关的修订号和清单请求计数）。

## 4. Windows 网关接入

**第一步：放好凭据文件，收紧权限。** 凭据文件只存放凭据本身，脚本和命令行里只出现它的路径。

```powershell
icacls C:\HearSecrets\hear-home.cred /inheritance:r /grant:r "$($env:USERNAME):R"
```

**第二步：设置环境变量。** 写入当前用户的环境变量，然后重新打开窗口。

```powershell
setx HEAR_AUTH_MODE managed
setx HEAR_AUTH_API_URL https://10.8.0.1:8443
setx HEAR_GATEWAY_ID hear-home
setx HEAR_GATEWAY_CREDENTIAL_FILE C:\HearSecrets\hear-home.cred
# 管理服务用的是自签证书时，让网关信任它：
setx HEAR_AUTH_CA_FILE C:\HearSecrets\svc-cert.pem
```

**第三步：照常双击 `start-hear-cloud.bat`。** 管理模式下的行为如下：

- 三项配置全部存在时，即使没有设置 `HEAR_AUTH_MODE`，也默认进入管理模式。缺少任何一项、凭据文件不存在或地址不是 HTTPS，都会明确报错并停止启动。
- 管理模式不显示“关闭访问口令”的 5 秒菜单，也不读取 `access-token.txt`。`HEAR_AUTH_MODE=legacy` 时，仍是原来的单口令方式和 5 秒默认选择。
- 网关启动后自己拉取一次清单。启动脚本轮询本机 `/health`，等到 `auth_ready=true` 才报告口令服务就绪；模型就绪单独显示。
- 管理服务连不上或凭据被拒时，网关照常运行但保持未就绪，所有推理请求返回 `503 AUTH_SERVICE_UNAVAILABLE`，并每 5 秒自动重试，不会退回到无口令状态。
- 运行中超过 60 秒没有同步成功，同样返回 503；同步恢复后自动继续校验。
- `--cloudflare-local-http` 在管理模式下也可以使用。明文 HTTP 只接受真实 TCP 来源为 `127.0.0.1` 或 `::1` 的连接，并且仍然要求有效的 Token。

**迁移顺序：** 先在后台给每个用户签发新 Token，让用户在 App 的「访问口令」栏里替换，然后再配置管理模式并重启网关。

## 5. 手动检查：`--check-token`

```bat
start-hear-cloud.bat --check-token
start-hear-cloud.bat --check-token https://hear.yueping1211.asia
```

程序先请求 `/health`，显示网络连通、模型就绪和口令服务状态；再用隐藏输入读取口令，调用 `/v1/auth/check`。口令不进入命令参数、不回显，也不写日志。检查内网自签地址时，会自动信任本机网关的根证书 `server\certs\root.pem`；也可以用 `HEAR_CHECK_CA_FILE` 指定其他证书。

| 退出码 | 含义 |
| --- | --- |
| 0 | 口令有效 |
| 2 | 网络或 TLS 不可达。提示会区分找不到域名、连不上端口、证书错误和连接超时 |
| 3 | 缺少口令或口令无效 |
| 4 | 尚未生效（显示生效时间） |
| 5 | 已到期（显示到期时间） |
| 6 | 已撤销（显示失效时间） |
| 7 | 鉴权服务未就绪（503）、目标未接入托管鉴权（404）或接口不兼容 |

## 6. 测试数据与独立验收

生成一个测试用户和 5 个 Token，分别处于可用、未生效、2 分钟后到期、已到期和已撤销状态。Token 原文只写进一个新建的受保护文件：

```powershell
python hear_token_service.py seed-test-data --gateway hear-home --out C:\HearSecrets\seed-tokens.json
```

验收完成后，删除这个文件，并在后台删除测试用户。真实凭据请通过独立渠道发放。

PowerShell 示例：先用隐藏输入安全地载入测试口令，再请求接口。

```powershell
$secure = Read-Host "测试口令" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $env:HEAR_TEST_USER_TOKEN = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

$uri = "https://hear.yueping1211.asia/v1/auth/check"
Invoke-RestMethod -Uri $uri -Headers @{ "X-Hear-Token" = $env:HEAR_TEST_USER_TOKEN }

# PowerShell 7 也想看 401/503 的错误体时：
Invoke-RestMethod -Uri $uri -Headers @{ "X-Hear-Token" = $env:HEAR_TEST_USER_TOKEN } -SkipHttpErrorCheck -StatusCodeVariable code
$code

Remove-Item Env:HEAR_TEST_USER_TOKEN
```

开发者自测：在仓库根目录运行 `python3 server/test_token_auth.py`。它会在临时目录里启动管理服务、托管模式网关和替身识别服务，跑完所有场景。测试用环境变量 `HEAR_AUTH_REFRESH_SECONDS` 和 `HEAR_AUTH_MAX_STALENESS_SECONDS` 缩短了同步间隔；生产环境不要设置这两项，保持默认的 30 秒和 60 秒。

## 7. 备份与恢复

```powershell
# 在线一致性备份，服务运行中也可以执行
python hear_token_service.py backup --out D:\Backup\hear-tokens-20270115.db
```

恢复步骤：

1. 停止管理服务。
2. 用备份文件替换 `token-data\hear-tokens.db`，同时删除旁边的 `-wal` 和 `-shm` 文件。
3. 启动管理服务。

修订号每次提升都取「原值 + 1」和「当前 Unix 秒数」中较大的那个，管理服务每次启动时也会提升一次。所以从旧备份恢复并启动服务后，修订号仍然会高于网关内存里已有的值，不会被网关当作“修订号回退”拒绝。恢复后请核对备份时间点之后的变更，必要时重新撤销或签发。

备份文件里有 Token 摘要、管理员密码哈希和网关凭据摘要，请按敏感数据保管。

## 8. 日志与安全要点

- 用户 Token 原文只在签发成功的 201 响应里出现一次。数据库、审计、清单、列表和日志里只有 SHA-256 摘要、末 6 位和元数据。网关凭据在库里也只存摘要。
- 管理服务的访问日志只记录方法、路径、状态码、耗时和 `request_id`，不记录请求头和请求体。网关的鉴权失败日志只记录接口、错误码和 `request_id`。
- 管理 API 和网关的所有 JSON 响应都带 `Cache-Control: no-store`。清单接口带 `ETag`，只有内容没变时才返回 304。
- 管理员登录：同一来源加同一用户名 15 分钟内失败 5 次，锁定 15 分钟。会话 8 小时后过期，1 小时没有操作也会过期。
- 8081 和 8082 端口仍然只监听本机，不受这次改动影响。

## 9. 验收标准对照（规范 §6）

| 场景 | 实现与自测项（`test_token_auth.py`） |
| --- | --- |
| 增删改用户，签发多个 Token | 后台和 API 走同一套接口。“issuing returns 201 and the raw token once”“token lists never contain raw tokens” |
| 起止时间与时区 | 开始时间包含、结束时间不包含。“the same instant written in different time zones is stored identically”“the end time is exclusive”“the start time is inclusive” |
| 自然到期后重启 Windows | 清单保留 90 天内失效的记录，网关重启后仍能给出 `TOKEN_EXPIRED`。“natural expiry is computed without a scheduled job”“--check-token exits 5” |
| 停用、删除用户或撤销单个 Token | 同一事务内撤销并提升修订号，下一轮同步后网关拒绝。“disabling a user revokes its tokens in the same transaction”“re-enabling a user does not restore old tokens” |
| 修改有效时间或签发新 Token | “moving starts_at earlier takes effect after a sync”“a new token works after the next sync without restarting Windows” |
| 管理服务断开 | “a cold start without the service refuses inference (503)”“over the staleness window without sync, inference returns 503”“verification resumes automatically” |
| 网关离线、口令到期、模型加载中 | `--check-token` 分别返回退出码 2、5，并单独显示模型就绪状态；错误口令返回 3，仅凭 `/health` 成功不能判为有效 |
| 同一 Token 连续请求 | 后台「网关」页和 `list-gateways` 显示清单请求计数。“80 checks/inferences cause only the scheduled snapshot requests” |
| 公网与内网 | 两边是同一套规则。空口令、错误口令和明文 HTTP 推理都会被拒绝，见对应的 401 和 403 测试项 |
| 凭据隔离 | “a user token cannot read the snapshot”“another gateway's credential cannot read this snapshot”“the gateway credential cannot use the admin API”“…logs never contain raw tokens” |

## 10. 已知限制

- 网关不回写 Token 的最近使用时间。规范把这一项列为可选，且要求鉴权路径不写数据库，所以这一版没有做。
- 用 `HEAR_SERVER_REF` 指定的早于本版的发行版标签，缺少上面列出的新文件，启动器会提示快照不完整。请使用 `main`，或包含本功能的版本。
- App 的「测试连接」按钮仍然只请求 `/health`。想让它直接显示到期原因，需要另外做一次 App 改动，接入 `/v1/auth/check`。
