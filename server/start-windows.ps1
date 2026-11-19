# 听见 App 的云端模型服务 —— Windows 上直接跑（能用上 Intel 核显和 NPU）
#
# 在哪里运行：仓库的根目录（就是有 README.md、server 文件夹的那一层）。
#   cd <仓库路径>
#   powershell -ExecutionPolicy Bypass -File server\start-windows.ps1
#
# 为什么不用 WSL2：WSL2 里访问不到 Intel 的 NPU（只有 N 卡的 CUDA 才行），
# 核显的 Vulkan 在 WSL2 里也不稳。原生跑在 Windows 上，NPU、核显、CPU 都能用。
#
# 三个模型各自选一个后端（用环境变量改）：
#   HEAR_MT_DEVICE     翻译   NPU / GPU / CPU   默认 GPU（核显，兼容性最好）
#   HEAR_CLONE_DEVICE  克隆   GPU / CPU         默认 GPU（OpenVINO 不支持多模态）
#   识别走 faster-whisper，只能用 CPU（int8）
#
# 前置条件：Python 3.9 以上（装的时候要勾上 “Add python.exe to PATH”）。
# 不需要 Visual Studio、不需要编译、不需要 WSL。

$ErrorActionPreference = "Stop"
$tempCloud = $null      # 临时服务进程（出错时要停掉）
$cloud = $null          # 正式服务进程
$ServerDir = $PSScriptRoot                                  # ...\Hear\server
$RepoRoot  = Split-Path -Parent $ServerDir                 # ...\Hear
$ModelDir  = Join-Path $ServerDir "models"
$BinDir    = Join-Path $ServerDir "bin"
$LlamaTag  = if ($env:HEAR_LLAMA_TAG) { $env:HEAR_LLAMA_TAG } else { "b12491" }
$Port      = if ($env:HEAR_PORT)        { $env:HEAR_PORT }        else { "8000" }
$MtPort    = if ($env:HEAR_MT_PORT)     { $env:HEAR_MT_PORT }     else { "8081" }
$ClonePort = if ($env:HEAR_CLONE_PORT)  { $env:HEAR_CLONE_PORT }  else { "8082" }
$MtDevice    = if ($env:HEAR_MT_DEVICE)    { $env:HEAR_MT_DEVICE }    else { "GPU" }
$CloneDevice = if ($env:HEAR_CLONE_DEVICE) { $env:HEAR_CLONE_DEVICE } else { "GPU" }
$MtQuant   = if ($env:HEAR_MT_QUANT)   { $env:HEAR_MT_QUANT }   else { "Q4_K_M" }
$AsrModel  = if ($env:HEAR_ASR_MODEL)  { $env:HEAR_ASR_MODEL }  else { "small" }
$Context   = if ($env:HEAR_CTX)        { $env:HEAR_CTX }        else { "4096" }
$HF        = if ($env:HF_ENDPOINT)     { $env:HF_ENDPOINT }     else { "https://huggingface.co" }

trap {
    # 出错了就把临时服务也停掉，别留下一个占着 8000 端口的孤儿
    if ($tempCloud -and -not $tempCloud.HasExited) {
        try { Stop-Process -Id $tempCloud.Id -Force } catch {}
    }
    if ($cloud -and -not $cloud.HasExited) {
        try { Stop-Process -Id $cloud.Id -Force } catch {}
    }
    Write-Host ""
    Write-Host "!! 出错了：$_" -ForegroundColor Red
    Write-Host "   网络问题的话换个网络/代理再跑一次就行，已经下好的东西不会重下。" -ForegroundColor Red
    Write-Host "   也可以设 `$env:HF_ENDPOINT='https://hf-mirror.com' 用国内镜像。" -ForegroundColor Red
    exit 1
}

function Say($t)  { Write-Host "==> $t" -ForegroundColor Cyan }
function Step($t) { Write-Host "    $t" -ForegroundColor DarkGray }
function Die($t)  { Write-Host "!! $t" -ForegroundColor Red; exit 1 }

# 列出网卡（WLAN / 以太网）各自的 IP，让用户挑一个填到手机里。
# 不能随便取第一个：VPN、虚拟网卡、WSL 的地址都可能出现，手机连不上。
function Show-LanInfo($port) {
    $all = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" }
    $ifaces = Get-NetAdapter -ErrorAction SilentlyContinue
    $choices = @()
    foreach ($a in $all) {
        $ad = $ifaces | Where-Object { $_.ifIndex -eq $a.InterfaceIndex } | Select-Object -First 1
        if (-not $ad) { continue }
        # 虚拟网卡（VPN、WSL、Hyper-V、VMware 等）不要
        if ($ad.Name -match "vEthernet|WSL|VMware|VirtualBox|Tailscale|Loopback|Tunnel|VPN|Hyper-V") { continue }
        # NdisPhysicalMedium: 1 = 802.3（以太网），9 / 15 = 无线（802.11）
        $kind = "其它"
        if ($ad.NdisPhysicalMedium -eq 9 -or $ad.NdisPhysicalMedium -eq 15) { $kind = "WLAN" }
        elseif ($ad.NdisPhysicalMedium -eq 1 -or $ad.InterfaceDescription -match "Ethernet|以太网") { $kind = "以太网" }
        $choices += [PSCustomObject]@{ Kind = $kind; Name = $ad.Name; IP = $a.IPAddress }
    }
    Write-Host ""
    Say "云端服务监听 0.0.0.0:$port"
    Write-Host ""
    if ($choices.Count -eq 0) {
        Write-Host "  没有找到可用的局域网 IP。" -ForegroundColor Yellow
        Write-Host "  请确认电脑已经连上 Wi-Fi 或插了网线，然后重新运行本文件。" -ForegroundColor Yellow
    }
    else {
        Write-Host "  手机 App 里「功能设置 → 模型管理 → 在线模型 → 通用服务地址」填：" -ForegroundColor Green
        Write-Host ""
        $i = 1
        foreach ($c in $choices) {
            Write-Host ("      {0}. {1,-8} {2}   http://{3}:{4}" -f $i, $c.Kind, $c.Name, $c.IP, $port) -ForegroundColor Green
            $i++
        }
        Write-Host ""
        Write-Host "  （手机和电脑要连同一个 Wi-Fi）" -ForegroundColor DarkGray
    }
    Write-Host ""
}


Say "仓库目录：$RepoRoot"
Say "模型目录：$ModelDir"

# 上一次没关窗口的话，8000 端口还被占着，先提醒一下
$busy0 = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($busy0) {
    Write-Host "    （端口 $Port 已经被占着，可能是上次的服务还在跑；下面会处理）" -ForegroundColor DarkGray
}
New-Item -ItemType Directory -Force -Path $ModelDir, $BinDir | Out-Null

# 先把手机要填的地址打印出来，不用等模型下完
Show-LanInfo $Port

# ---------------------------------------------------------------- 下载解压
# 网络不通的时候换别的办法再来一遍，不要一失败就整个退出。
# $urls 可以给多个（第一个是主地址，后面是备用）
function Get-File($urls, $out) {
    if (Test-Path $out) { Step "已有 $(Split-Path $out -Leaf)"; return $out }
    if ($urls -is [string]) { $urls = @($urls) }
    $name = Split-Path $out -Leaf
    $i = 0
    foreach ($url in $urls) {
        $i++
        if ($i -eq 1) { Say "下载 $name" } else { Say "下载 $name（第 $i 次，换个地址试试）" }
        & curl.exe -fL --connect-timeout 20 --retry 3 --retry-delay 3 -o "$out.part" $url
        if ($LASTEXITCODE -eq 0) {
            Move-Item "$out.part" $out
            return $out
        }
        Remove-Item "$out.part" -ErrorAction SilentlyContinue
        Step "这个地址不行：$url"
    }
    throw "下载失败：$name（试了 $i 个地址都不行）"
}
function Expand-Zip($zip, $dest) {
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Expand-Archive -Path $zip -DestinationPath $dest -Force
}
function Find-Exe($name, $keyword) {
    $all = Get-ChildItem -Path $BinDir -Filter $name -Recurse -ErrorAction SilentlyContinue
    if ($keyword) {
        $f = $all | Where-Object { $_.DirectoryName -like "*$keyword*" } | Select-Object -First 1
    } else {
        $f = $all | Select-Object -First 1
    }
    if ($f) { return $f.FullName }
    return $null
}
# 不同后端的 llama-server.exe 在不同目录里（官方压缩包解压后是平铺的，一个后端一个目录）
function Server-For($backend) {
    switch ($backend) {
        "NPU" { return (Find-Exe "llama-server.exe" "win-openvino") }
        "GPU" { return (Find-Exe "llama-server.exe" "win-vulkan") }
        default { return (Find-Exe "llama-server.exe" "win-cpu-x64") }
    }
}

# ---------------------------------------------------------------- Python（识别模型）
function Find-Python {
    $venv = Join-Path $ServerDir ".venv\Scripts\python.exe"
    if (Test-Path $venv) { return $venv }
    foreach ($cand in @("python", "python3", "py")) {
        $cmd = Get-Command $cand -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        # 微软商店的假 python（会弹商店窗口）跳过
        if ($cmd.Source -like "*WindowsApps*") { continue }
        try {
            $v = (& $cand --version 2>&1) -join " "
            if ($v -match "Python 3\.") { return $cand }
        } catch {}
    }
    return $null
}
$py = Find-Python
if (-not $py) {
    Die "没找到 Python。请到 https://www.python.org/downloads/windows/ 装 Python 3.9 以上（安装时勾上 Add python.exe to PATH），装完重开 PowerShell 再跑。"
}
# ---------------------------------------------------------------- 先起个临时服务
# hear_cloud.py 只用标准库就能跑（识别模型是懒加载的），
# 所以先用系统 Python 把它起起来，几秒钟后就能在手机浏览器上测网络了，
# 不用等 llama.cpp 和几个 G 的模型下完。
$cloudScript = Join-Path $ServerDir "hear_cloud.py"
$tempCloud = $null
$py0 = Find-Python
if ($py0) {
    $env:HEAR_PORT = $Port
    $env:HEAR_MT_URL = "http://127.0.0.1:$MtPort"
    $env:HEAR_CLONE_URL = "http://127.0.0.1:$ClonePort"
    $env:HEAR_ASR_MODEL = $AsrModel
    try {
        $tempCloud = Start-Process -FilePath $py0 -ArgumentList "`"$cloudScript`"" `
                        -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $ServerDir "cloud.log") `
                        -RedirectStandardError (Join-Path $ServerDir "cloud.log.err")
        Start-Sleep -Seconds 2
        Say "临时服务已启动（端口 $Port），现在就能在手机浏览器上测网络"
        Write-Host "    电脑浏览器： http://127.0.0.1:$Port/" -ForegroundColor Cyan
        Write-Host "    手机浏览器：下面这些地址，随便挑一个能打开的" -ForegroundColor Cyan
        Show-LanInfo $Port
        Write-Host "  （模型还在下，下完之后会自动换成完整的服务）" -ForegroundColor DarkGray
        Write-Host ""
    } catch {
        Step "临时服务没起来（不影响后面）"
    }
}

# ---------------------------------------------------------------- llama.cpp
$needOv   = ($MtDevice -eq "NPU")
$needVulk = ($MtDevice -eq "GPU" -or $CloneDevice -eq "GPU")

if (-not (Find-Exe "llama-server.exe" "")) {
    $want = @()
    if ($needOv)   { $want += "llama-$LlamaTag-bin-win-openvino-*.zip" }
    if ($needVulk) { $want += "llama-$LlamaTag-bin-win-vulkan-x64.zip" }
    $want += "llama-$LlamaTag-bin-win-cpu-x64.zip"
    foreach ($pattern in $want) {
        $url = $null
        if ($pattern.Contains("*")) {
            # OpenVINO 那个文件名里带运行库版本号，先问 GitHub 要准确的链接
            try {
                $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$LlamaTag" -UseBasicParsing -Headers @{ "User-Agent" = "hear-cloud" }
            } catch {
                $rel = & curl.exe -sSL "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$LlamaTag" | ConvertFrom-Json
            }
            $asset = $rel.assets | Where-Object { $_.name -like $pattern } | Select-Object -First 1
            if (-not $asset) { Step "这个发行版里没有 $pattern，跳过"; continue }
            $url  = $asset.browser_download_url
            $name = $asset.name
        } else {
            $name = $pattern
            $url  = "https://github.com/ggml-org/llama.cpp/releases/download/$LlamaTag/$name"
        }
        $zip = Join-Path $BinDir $name
        # GitHub 打不开的话换代理再试
        $mirrors = @($url)
        if ($url -like "https://github.com/*") {
            $mirrors += ($url -replace "^https://github.com", "https://gh-proxy.com")
            $mirrors += ($url -replace "^https://github.com", "https://ghproxy.net")
        }
        Get-File $mirrors $zip | Out-Null
        Say "解压 $name"
        Expand-Zip $zip (Join-Path $BinDir ([IO.Path]::GetFileNameWithoutExtension($name)))
    }
}
if (-not (Find-Exe "llama-server.exe" "")) { Die "没找到 llama-server.exe" }

Say "Python：$py"

# venv 是一个"文件夹"，不是 python.exe 的路径（之前写错，venv 建到了 python.exe 上，
# 结果 python.exe 根本不存在）
$venvDir = Join-Path $ServerDir ".venv"
$venvPy  = Join-Path $venvDir "Scripts\python.exe"
if (-not (Test-Path $venvPy)) {
    Say "建虚拟环境并装 faster-whisper（识别模型用）"
    if (Test-Path $venvDir) { Remove-Item -Recurse -Force $venvDir -ErrorAction SilentlyContinue }
    & $py -m venv $venvDir
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $venvPy)) {
        Say "建虚拟环境失败，退回用系统 Python（可能要管理员权限）"
        $venvPy = $py
    }
}
if (-not (Test-Path $venvPy)) { Die "找不到可用的 Python" }
& $venvPy -m pip install --upgrade pip --quiet
if ($LASTEXITCODE -ne 0) { Say "pip 升级失败，先用现有的 pip 继续" }
& $venvPy -m pip install -r (Join-Path $ServerDir "requirements.txt") --quiet
if ($LASTEXITCODE -ne 0) {
    Say "faster-whisper 没装上，语音识别会不可用（翻译和克隆不受影响）"
    Step "手动装：& `"$venvPy`" -m pip install -r requirements.txt"
}

# ---------------------------------------------------------------- 云端服务（先起）
# 模型还要下十几分钟，先把 8000 端口的服务起起来：
# 这样手机马上就能连上来测试网络了（翻译和克隆要等模型下完才可用）。
$env:HEAR_PORT = $Port
$env:HEAR_MT_URL = "http://127.0.0.1:$MtPort"
$env:HEAR_CLONE_URL = "http://127.0.0.1:$ClonePort"
$env:HEAR_ASR_MODEL = $AsrModel
$cloudScript = Join-Path $ServerDir "hear_cloud.py"
# 端口上可能还留着上一次跑的临时服务，先把它停掉再起正式的
# （正式的服务用 venv 里的 Python，带 faster-whisper）
$busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($busy) {
    foreach ($c in $busy) {
        $owner = (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue)
        if ($owner -and $owner.ProcessName -match "python") {
            Step "停掉占着端口 $Port 的旧服务"
            try { Stop-Process -Id $c.OwningProcess -Force } catch {}
        }
    }
    Start-Sleep -Seconds 1
}
if ($tempCloud -and -not $tempCloud.HasExited) {
    try { Stop-Process -Id $tempCloud.Id -Force } catch {}
}
$cloud = Start-Process -FilePath $venvPy -ArgumentList "`"$cloudScript`"" `
            -PassThru -NoNewWindow
Start-Sleep -Seconds 3
Say "云端服务已启动（端口 $Port），模型还在准备中"
Write-Host "    电脑浏览器打开 http://127.0.0.1:$Port/ 看看服务在不在" -ForegroundColor Cyan
Write-Host "    手机浏览器打开下面打印的地址，能打开就说明手机到电脑是通的" -ForegroundColor Cyan
Show-LanInfo $Port

# ---------------------------------------------------------------- 模型
function Get-Model($repo, $file) {
    $out = Join-Path $ModelDir $file
    if (Test-Path $out) { Step "已有 $file"; return $out }
    # 主地址 + 国内镜像 + 另一个镜像：哪个通用哪个
    $mirrors = @(
        "$HF/$repo/resolve/main/$file",
        "https://hf-mirror.com/$repo/resolve/main/$file"
    )
    if ($HF -ne "https://huggingface.co") {
        $mirrors += "https://huggingface.co/$repo/resolve/main/$file"
    }
    Get-File $mirrors $out | Out-Null
    return $out
}
Get-Model "tencent/Hy-MT2-1.8B-GGUF" "Hy-MT2-1.8B-$MtQuant.gguf" | Out-Null
Get-Model "Shlomo426/Qwen3-TTS-12Hz-0.6B-Base-GGUF" "Qwen3-TTS-12Hz-0.6B-Base-Q4_K_M.gguf" | Out-Null
Get-Model "Shlomo426/Qwen3-TTS-12Hz-0.6B-Base-GGUF" "mmproj-Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf" | Out-Null

# ---------------------------------------------------------------- 起服务
$mtServer    = Server-For $MtDevice
$cloneServer = Server-For $CloneDevice
if (-not $mtServer)    { Die "没找到 $MtDevice 后端的 llama-server.exe" }
if (-not $cloneServer) { $cloneServer = Server-For "CPU" }
if (-not $cloneServer) { Die "没找到 llama-server.exe" }
$procs = @()

# 监听 0.0.0.0（不是 127.0.0.1），这样手机才能直接连 8081 / 8082
$mtArgs = @("-m", (Join-Path $ModelDir "Hy-MT2-1.8B-$MtQuant.gguf"),
             "--host", "0.0.0.0", "--port", $MtPort, "-c", $Context, "--no-warmup")
if ($MtDevice -eq "NPU") {
    # OpenVINO 后端：NPU 只支持无状态执行，-np 只能是 1，-c 必须明确给
    $env:GGML_OPENVINO_DEVICE = "NPU"
    $env:GGML_OPENVINO_CACHE_DIR = Join-Path $BinDir "ov_cache"
    $mtArgs += "-np", "1"
} elseif ($MtDevice -eq "GPU") {
    $mtArgs += "--device", "Vulkan"
}

Say "起翻译模型（Hy-MT2，后端 $MtDevice，端口 $MtPort）"
$mtLog = Join-Path $ServerDir "mt.log"
$mt = Start-Process -FilePath $mtServer -ArgumentList $mtArgs -PassThru -NoNewWindow `
        -RedirectStandardOutput $mtLog -RedirectStandardError "$mtLog.err"
$procs += $mt

$cloneArgs = @("-m", (Join-Path $ModelDir "Qwen3-TTS-12Hz-0.6B-Base-Q4_K_M.gguf"),
                "--mmproj", (Join-Path $ModelDir "mmproj-Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf"),
                "--host", "0.0.0.0", "--port", $ClonePort, "-c", $Context, "--no-warmup")
if ($CloneDevice -eq "GPU") { $cloneArgs += "--device", "Vulkan" }

Say "起声音克隆模型（Qwen3-TTS，后端 $CloneDevice，端口 $ClonePort）"
$cloneLog = Join-Path $ServerDir "clone.log"
$clone = Start-Process -FilePath $cloneServer -ArgumentList $cloneArgs -PassThru -NoNewWindow `
            -RedirectStandardOutput $cloneLog -RedirectStandardError "$cloneLog.err"
$procs += $clone

function Wait-Health($url, $name, $logName, $proc) {
    # 模型大的时候要加载一会儿，给足 10 分钟
    for ($i = 0; $i -lt 300; $i++) {
        try { if ((Invoke-WebRequest -UseBasicParsing "$url/health" -TimeoutSec 3).StatusCode -eq 200) { Say "$name 好了"; return $true } }
        catch {}
        # 进程自己退出了就别等了，直接看日志
        if ($proc -and $proc.HasExited) {
            Say "$name 进程退出了（退出码 $($proc.ExitCode)），下面是日志最后几行："
            Show-LogTail $logName
            return $false
        }
        Start-Sleep -Seconds 2
    }
    Say "$name 十分钟内没就绪，看看 $logName"
    Show-LogTail $logName
    return $false
}

function Show-LogTail($logName) {
    # 直接把日志最后几行打出来，省得再去翻文件
    $lp = Join-Path $ServerDir $logName
    foreach ($f in @($lp, "$lp.err")) {
        if (Test-Path $f) {
            Write-Host "    ---- $(Split-Path $f -Leaf) 最后几行 ----" -ForegroundColor DarkGray
            Get-Content $f -Tail 15 -ErrorAction SilentlyContinue |
                ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
    }
}
$mtOk = Wait-Health "http://127.0.0.1:$MtPort" "翻译模型" "mt.log" $mt
if (-not $mtOk -and $MtDevice -ne "CPU") {
    # 核显 / NPU 起不来（驱动、OpenVINO、显存都不够），退回 CPU 也能用，只是慢一点
    Say "$MtDevice 后端没起来，改用 CPU 跑翻译模型"
    try { Stop-Process -Id $mt.Id -Force -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 2
    $cpuMt = Server-For "CPU"
    if ($cpuMt) {
        $cpuArgs = @("-m", (Join-Path $ModelDir "Hy-MT2-1.8B-$MtQuant.gguf"),
                     "--host", "0.0.0.0", "--port", $MtPort, "-c", $Context, "--no-warmup")
        $mt = Start-Process -FilePath $cpuMt -ArgumentList $cpuArgs -PassThru -NoNewWindow `
                -RedirectStandardOutput $mtLog -RedirectStandardError "$mtLog.err"
        $procs += $mt
        Wait-Health "http://127.0.0.1:$MtPort" "翻译模型（CPU）" "mt.log" $mt | Out-Null
    }
}
$cloneOk = Wait-Health "http://127.0.0.1:$ClonePort" "声音克隆模型" "clone.log" $clone
if (-not $cloneOk -and $CloneDevice -ne "CPU") {
    Say "$CloneDevice 后端没起来，改用 CPU 跑声音克隆模型"
    try { Stop-Process -Id $clone.Id -Force -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 2
    $cpuClone = Server-For "CPU"
    if ($cpuClone) {
        $cpuArgs = @("-m", (Join-Path $ModelDir "Qwen3-TTS-12Hz-0.6B-Base-Q4_K_M.gguf"),
                     "--mmproj", (Join-Path $ModelDir "mmproj-Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf"),
                     "--host", "0.0.0.0", "--port", $ClonePort, "-c", $Context, "--no-warmup")
        $clone = Start-Process -FilePath $cpuClone -ArgumentList $cpuArgs -PassThru -NoNewWindow `
                -RedirectStandardOutput $cloneLog -RedirectStandardError "$cloneLog.err"
        $procs += $clone
        Wait-Health "http://127.0.0.1:$ClonePort" "声音克隆模型（CPU）" "clone.log" $clone | Out-Null
    }
}

$env:HEAR_PORT = $Port
$env:HEAR_MT_URL = "http://127.0.0.1:$MtPort"
$env:HEAR_CLONE_URL = "http://127.0.0.1:$ClonePort"
$env:HEAR_ASR_MODEL = $AsrModel

Show-LanInfo $Port
Write-Host ""
Write-Host "  防火墙放行（用管理员 PowerShell 执行一次）："
Write-Host "      New-NetFirewallRule -DisplayName `"Hear Cloud`" -Direction Inbound -LocalPort $Port,$MtPort,$ClonePort -Protocol TCP -Action Allow"
Write-Host ""
Write-Host "  关掉这个窗口就等于关掉服务。"
Write-Host ""

Write-Host "  模型都准备好了，识别 / 翻译 / 克隆三个接口现在都能用。" -ForegroundColor Green
Write-Host ""

if ($cloud) {
    if ($cloud.HasExited) {
        Say "云端服务退出了（退出码 $($cloud.ExitCode)），看看上面的报错"
    }
    else {
        Wait-Process -Id $cloud.Id
    }
}
