# Windows 部署清单

在 Windows 上把「听见」的云端服务（模型跑在电脑上，手机连过来）装起来、
跑起来、验证能用，按这份清单走。踩过的坑都写在下面了。

## 一、部署步骤

1. 装 Python 3.9 以上。安装时**勾上 `Add python.exe to PATH`**（不勾的话脚本找不到 Python）。
2. 把仓库放本地（比如 `D:\Documents\Learn\GitHub\Hear`），或者直接跑一键启动的
   `start-hear-cloud.bat`（它会把代码、证书、服务都准备好）。
3. 双击 `start-hear-cloud.bat`。第一次运行会问三个问题（用哪些模型），
   选完记在 `server\hear_models.json` 里，以后启动不再问。
4. 第一次要下载模型（几 GB），网络慢的话脚本会自动换国内镜像
   （`HF_ENDPOINT=https://hf-mirror.com`），下过的不会重下。
5. 服务起来后，窗口会打印局域网地址。手机浏览器先打开那个地址验证一下，
   能打开就说明手机到电脑这条路是通的。

## 二、启动时按类型选模型

脚本启动时会问三个问题，分别对应三种模型。选完写进
`server\hear_models.json`，下次启动直接用；想改就再跑一次：

```
powershell -ExecutionPolicy Bypass -File server\start-windows.ps1 -Choose
```

| 类型 | 可选 | 大小 | 说明 |
|---|---|---|---|
| 语音识别（Whisper） | tiny / base / **small** / medium / large-v3 | 75 MB ~ 3 GB | CPU 上跑。`small` 是速度和准确度的平衡点；`large-v3` 最准但 CPU 上偏慢，有独显会快很多 |
| 文本翻译（Hy-MT2） | **1.8b** / 7b / 30b | 1.1 GB ~ 18 GB | `1.8b` 快；`7b` 更准（内存 8G 以上）；`30b` 是混合专家，30B 里只激活 3B，**又大又快又好**，内存要 24G 以上 |
| 声音克隆（Qwen3-TTS） | 0.6b / **1.7b** | 0.6 GB ~ 1.1 GB | `1.7b` 更像原声，推荐 |

带粗体的是推荐值，直接回车就选它。

环境变量仍然可以覆盖菜单的选择（`HEAR_ASR_MODEL` / `HEAR_MT_QUANT` /
`HEAR_MT_DEVICE` / `HEAR_CLONE_DEVICE` / `HEAR_CTX` / `HEAR_PORT` 等），
详见 `server/start-windows.ps1` 开头的说明。

选完以后，App 的「功能设置 → 模型管理 → 在线模型」里能看到电脑上现在跑的是
哪个模型（状态后面会跟着模型名，比如「正常（Hy-MT2-7B-Q4_K_M.gguf）」）。

## 三、注意事项

1. **手机和电脑要在同一个网络**。手机浏览器先打开脚本打印的那个地址，
   打不开就是网络问题，不是 App 的问题。
2. **iOS 的「本地网络」权限**。App 要访问局域网里的电脑，iOS 会单独问一次：
   设置 → 隐私与安全性 → 本地网络 → 打开「听见」。不给的话浏览器能开、App 连不上。
3. **只填局域网地址，别填 127.0.0.1**。127.0.0.1 在手机上指的是手机自己。
4. **虚拟网卡的地址不能用**。VPN（Tailscale / Cloudflare WARP）、WSL、
   VMware、Hyper-V 的网卡地址手机连不上，脚本已经过滤掉了，只显示 WLAN / 以太网。
5. **换网络或开了 VPN 之后，证书要重签**。证书里写的是生成那一刻的 IP，
   地址变了手机会直接拒绝。脚本启动时会自己检查并重新生成，一般不用手动管；
   万一没自动重签，重跑一次 `start-hear-cloud.bat` 就行。
6. **防火墙**：手机连不上 8000 / 8081 / 8082，八成是 Windows 防火墙拦了入站。
   用管理员 PowerShell 执行脚本打印出来的那一行即可（脚本在管理员身份下会自动建好规则）。
7. **不要开两个窗口跑服务**。上一个窗口没关干净时，端口上会残留旧的
   llama-server，症状是「克隆声音是乱的而且特别慢」。脚本启动时会自己清理
   8000 / 8081 / 8082 三个端口，真要手动清理就先关掉所有旧窗口。
8. **关闭服务就是关掉那个窗口**。窗口一关，模型服务就停了。
9. **模型要现下现用**：第一次启动要下载几 GB 的模型，期间服务已经起来了，
   但翻译和克隆要等模型下完才可用（`/health` 里会写「加载中」）。
10. **日志**：`server\cloud.log`（总服务）、`server\mt.log`（翻译）、
    `server\clone.log`（克隆）。用别的编辑器看中文乱码的话，
    先在那个编辑器里把编码设成 UTF-8。

## 四、已知问题和处理方案

| 现象 | 真正的原因 | 怎么办 |
|---|---|---|
| 窗口里的中文全是乱码（每个汉字变两个怪字符） | 现在的 Python（3.15 起）默认 UTF-8 输出，中文版 Windows 的 cmd 默认 GBK | 脚本已经把代码页改成 65001 并设了 `PYTHONUTF8=1`；还乱码就用「Windows PowerShell」而不是 cmd 打开 |
| 找不到 Python / 提示装 Python | 装的时候没勾 `Add python.exe to PATH`，或者装的是微软商店的假 python | 重装 Python 并勾上 PATH；脚本已经会跳过商店版的 `python.exe` |
| 提示 `python.exe 根本不存在` | 以前 `python -m venv` 把 venv 建到了 python.exe 这个文件上 | 已修：venv 建成目录，解释器在 `venv\Scripts\python.exe`；脚本发现建坏了会自动重建 |
| 手机连不上，浏览器打开也 400 `Bad request version` | https 的 TLS 握手打到了只认 http 的解析器，说明服务没证书 | 跑一次 `python server\make_cert.py` 生成证书，再重启服务（脚本会自动做） |
| 手机浏览器能打开，App 说「服务地址不可用，请确认」 | iOS 的本地网络权限没给 | 设置 → 隐私与安全性 → 本地网络 → 打开「听见」 |
| App 报 `TLS 握手失败 / UNEXPECTED_EOF` | 证书里没有当前这个 IP（换了网络、开了 WARP 的 100.96.x.x），系统不认自签证书 | 重跑 `start-hear-cloud.bat`，证书会按现在所有网卡的地址重新生成；App 现在也会放行你自己填的地址 |
| 服务端刷 `POST /v1/clone/reference → 500 UnicodeDecodeError` | 电脑上跑的还是老版本服务：老服务没有 `/v1/clone/reference` 这个路径，手机的 wav 落到 `/v1/clone`，被当成 JSON 解析就炸了 | 重跑 `start-hear-cloud.bat`（它会自动把 `hear_cloud.py` 更新成最新的）；新版本会返回 400 说清楚，不再抛堆栈 |
| 克隆出来的声音是乱的，而且特别慢（同一句直连快、走总服务慢十倍） | 上一个窗口没关干净，127.0.0.1:8082 上还留着旧的 llama-server。Windows 上绑具体地址的套接字优先于绑 0.0.0.0 的，总服务走回环连到旧实例、手机走局域网连到新实例，两边对不上 | 关掉所有旧窗口重开；脚本启动时会自动清掉 8000/8081/8082。`/health` 里会报出后端跑的是哪个模型，可以对一下 |
| 服务起来没几秒就自己退了 | 端口被上一次残留的进程占着 | 脚本会自动清理端口；还不行就查 `server\cloud.log.err` |
| 翻译/克隆模型起不来（mt.log / clone.log 有报错） | 显卡驱动不支持 llama-server 用的后端 | 脚本会自动退回 CPU 跑；想指定就设 `HEAR_MT_DEVICE=CPU`、`HEAR_CLONE_DEVICE=CPU` |
| NPU（OpenVINO）跑不起来 | OpenVINO 的 NPU 只支持无状态执行 | 脚本已经自动带上 `-np 1` 和明确的 `-c`；还是不行就用 CPU |
| 识别（faster-whisper）不可用，其它两个正常 | pip 装 faster-whisper 失败 | 手动装：`server\.venv\Scripts\python.exe -m pip install -r server\requirements.txt` |
| 下载模型很慢或中断 | huggingface.co 在国内不稳定 | 脚本会自动换 `hf-mirror.com`；也可以自己设 `$env:HF_ENDPOINT='https://hf-mirror.com'`。已经下好的不会重下 |
| 翻译偶尔卡住不动 | 上下文太长 | 调小 `HEAR_CTX`（默认 4096） |
| 手机提示「网络中断」/ App 报 -1009 | 手机到电脑这条路断了（Wi-Fi 抖了、电脑换了网络、服务重启） | App 会自动重试三次；还不行就检查电脑上的服务是不是还开着、手机和电脑是不是还在同一个网络 |
| 服务在跑但 App 说「这个接口要的是 JSON」 | 请求打到了不匹配的接口（老服务没有新路径） | 更新服务：重跑 `start-hear-cloud.bat` |
| 声音克隆一直转圈不出声 | 电脑上模型还在加载，或者参考音频没传过去 | 看 `server\clone.log`；App 的日志里会写「声音克隆服务不可用」，这时会退回系统声音朗读，不会卡住 |

## 五、部署完成后的自检（三步）

1. **电脑浏览器打开 `https://127.0.0.1:8000/`** —— 能打开说明服务在跑，
   页面里三个模型的状态应该都是「就绪」。
2. **手机浏览器打开脚本打印的那个局域网地址**（比如 `https://192.168.1.5:8000/`）——
   能打开说明手机到电脑是通的。打不开就是防火墙或网络问题，见上面注意事项 4、6。
3. **App 里填同一个地址** —— 「功能设置 → 模型管理 → 在线模型 → 通用服务地址」，
   填完状态应该变成「正常（模型名）」。不正常就看 App 的日志
   （App 里能看日志页），再对照上面的表处理。

三个模型也可以分别填地址（8081 只有翻译、8082 只有克隆），
在「在线模型 → 语音识别 / 文本翻译 / 声音克隆 → 配置」里单独设。
