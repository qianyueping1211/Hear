# 听见 App 的云端模型服务 —— Windows 上直接跑（能用上 Intel 核显和 NPU）
#
#   powershell -ExecutionPolicy Bypass -File server\start-windows.ps1
#
# 为什么不用 WSL2：WSL2 里访问不到 Intel 的 NPU（只有 N 卡的 CUDA 才行），
# 核显的 Vulkan 在 WSL2 里也不稳。原生跑在 Windows 上，NPU、核显、CPU 都能用。
#
# 三个模型各自选一个后端（可以用环境变量改）：
#   HEAR_MT_DEVICE     翻译   NPU / GPU / CPU   默认 GPU（核显，兼容性最好）
#   HEAR_CLONE_DEVICE  克隆   GPU / CPU         默认 GPU（OpenVINO 不支持多模态）
#   识别走 faster-whisper，只能用 CPU（int8）

$ErrorActionPreference = "Stop"
$ServerDir = $PSScriptRoot
$Root      = Split-Path -Parent $ServerDir
$ModelDir  = Join-Path $ServerDir "models"
$BinDir    = Join-Path $ServerDir "bin"
$LlamaTag  = if ($env:HEAR_LLAMA_TAG) { $env:HEAR_LLAMA_TAG } else { "b12491" }
$Port      = if ($env:HEAR_PORT)     { $env:HEAR_PORT }     else { "8000" }
$MtPort    = if ($env:HEAR_MT_PORT)  { $env:HEAR_MT_PORT }  else { "8081" }
$ClonePort = if ($env:HEAR_CLONE_PORT) { $env:HEAR_CLONE_PORT } else { "8082" }
$MtDevice    = if ($env:HEAR_MT_DEVICE)    { $env:HEAR_MT_DEVICE }    else { "GPU" }
$CloneDevice = if ($env:HEAR_CLONE_DEVICE) { $env:HEAR_CLONE_DEVICE } else { "GPU" }
$MtQuant   = if ($env:HEAR_MT_QUANT) { $env:HEAR_MT_QUANT } else { "Q4_K_M" }
$AsrModel  = if ($env:HEAR_ASR_MODEL) { $env:HEAR_ASR_MODEL } else { "small" }
$Context   = if ($env:HEAR_CTX) { $env:HEAR_CTX } else { "4096" }

function Say($t) { Write-Host "==> $t" -ForegroundColor Cyan }
function Step($t) { Write-Host "    $t" -ForegroundColor DarkGray }

New-Item -ItemType Directory -Force -Path $ModelDir, $BinDir | Out-Null

# ---------------------------------------------------------------- 下载解压
function Get-File($url, $out) {
    if (Test-Path $out) { Step "已有 $(Split-Path $out -Leaf)"; return $out }
    Say "下载 $(Split-Path $out -Leaf)"
    & curl.exe -fL --retry 5 --retry-delay 3 -o "$out.part" $url
    if ($LASTEXITCODE -ne 0) { throw "下载失败：$url" }
    Move-Item "$out.part" $out
    return $out
}
function Expand-Zip($zip, $dest) {
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Expand-Archive -Path $zip -DestinationPath $dest -Force
}
function Find-Exe($name, $keyword) {
    $all = Get-ChildItem -Path $BinDir -Filter $name -Recurse -ErrorAction SilentlyContinue
    if ($keyword) {
        $f = $all | Where-Object { $_.FullName -like "*$keyword*" } | Select-Object -First 1
    } else {
        $f = $all | Select-Object -First 1
    }
    if ($f) { return $f.FullName }
    return $null
}
# 不同后端的 llama-server.exe 在不同目录里，按目录名挑
function Server-For($backend) {
    switch ($backend) {
        "NPU" { return (Find-Exe "llama-server.exe" "openvino") }
        "GPU" { return (Find-Exe "llama-server.exe" "vulkan") }
        default { return (Find-Exe "llama-server.exe" "cpu") }
    }
}

# ---------------------------------------------------------------- llama.cpp
$base = "https://github.com/ggml-org/llama.cpp/releases/download/$LlamaTag"
$needOv   = ($MtDevice -eq "NPU")
$needVulk = ($MtDevice -eq "GPU" -or $CloneDevice -eq "GPU")

if (-not (Find-Exe "llama-server.exe" "")) {
    $want = @()
    if ($needOv)   { $want += "llama-$LlamaTag-bin-win-openvino-*.zip" }
    if ($needVulk) { $want += "llama-$LlamaTag-bin-win-vulkan-x64.zip" }
    $want += "llama-$LlamaTag-bin-win-cpu-x64.zip"
    foreach ($pattern in $want) {
        $name = $pattern -replace '\*', ""
        if ($pattern.Contains("*")) {
            # OpenVINO 的文件名里带运行库版本号，先问一下 GitHub
            $rel = & curl.exe -sSL "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$LlamaTag" |
                   ConvertFrom-Json
            $asset = $rel.assets | Where-Object { $_.name -like $pattern } | Select-Object -First 1
            if (-not $asset) { Step "这个发行版没有 $pattern，跳过"; continue }
            $name = $asset.name
            $url  = $asset.browser_download_url
        } else {
            $url = "$base/$name"
        }
        $zip = Join-Path $BinDir $name
        Get-File $url $zip | Out-Null
        Say "解压 $name"
        Expand-Zip $zip (Join-Path $BinDir ([IO.Path]::GetFileNameWithoutExtension($name)))
    }
}
if (-not (Find-Exe "llama-server.exe" "")) { throw "没找到 llama-server.exe" }

# ---------------------------------------------------------------- OpenVINO 运行库（NPU 要）
if ($needOv) {
    $ovDir = Join-Path $BinDir "openvino"
    if (-not (Test-Path (Join-Path $ovDir "runtime"))) {
        Say "找 OpenVINO 运行库（Intel 官网）"
        $page = (Invoke-WebRequest -UseBasicParsing "https://docs.openvino.ai/2026/get-started/install-openvino/install-openvino-archive-windows.html").Content
        $m = [regex]::Match($page, 'https://storage\.openvinotoolkit\.org[^"]*x86_64\.zip')
        if (-not $m.Success) { throw "没找到 OpenVINO 的下载地址" }
        $zip = Get-File $m.Value (Join-Path $BinDir "openvino.zip")
        Say "解压 OpenVINO 运行库"
        Expand-Zip $zip $ovDir
    }
    $ovBin = Get-ChildItem -Path $ovDir -Filter "openvino_intel_npu_plugin.dll" -Recurse | Select-Object -First 1
    if ($ovBin) {
        $env:PATH = $ovBin.DirectoryName + ";" + $env:PATH
        Step "OpenVINO 运行库：$($ovBin.DirectoryName)"
    } else {
        Say "警告：没找到 NPU 插件，翻译模型改用核显"
        $MtDevice = "GPU"
    }
}

# ---------------------------------------------------------------- 模型
function Get-Model($repo, $file) {
    $out = Join-Path $ModelDir $file
    if (Test-Path $out) { Step "已有 $file"; return $out }
    Say "下载 $file"
    & curl.exe -fL --retry 5 --retry-delay 3 -o "$out.part" "https://huggingface.co/$repo/resolve/main/$file"
    if ($LASTEXITCODE -ne 0) { throw "模型下载失败：$file" }
    Move-Item "$out.part" $out
    return $out
}
Get-Model "tencent/Hy-MT2-1.8B-GGUF" "Hy-MT2-1.8B-$MtQuant.gguf" | Out-Null
Get-Model "Shlomo426/Qwen3-TTS-12Hz-0.6B-Base-GGUF" "Qwen3-TTS-12Hz-0.6B-Base-Q4_K_M.gguf" | Out-Null
Get-Model "Shlomo426/Qwen3-TTS-12Hz-0.6B-Base-GGUF" "mmproj-Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf" | Out-Null

# ---------------------------------------------------------------- Python（识别模型）
$py = "python"
if (Test-Path (Join-Path $ServerDir ".venv\Scripts\python.exe")) {
    $py = Join-Path $ServerDir ".venv\Scripts\python.exe"
} elseif (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Say "装 faster-whisper（识别模型用）"
    & py -3 -m venv (Join-Path $ServerDir ".venv")
    $py = Join-Path $ServerDir ".venv\Scripts\python.exe"
    & $py -m pip install --upgrade pip
    & $py -m pip install -r (Join-Path $ServerDir "requirements.txt")
}
if (-not (Test-Path (Join-Path $ServerDir ".venv\Scripts\python.exe"))) {
    & $py -m pip install -r (Join-Path $ServerDir "requirements.txt")
}

# ---------------------------------------------------------------- 起服务
$mtServer    = Server-For $MtDevice
$cloneServer = Server-For $CloneDevice
if (-not $mtServer)    { throw "没找到 $MtDevice 后端的 llama-server.exe" }
if (-not $cloneServer) { $cloneServer = Server-For "CPU" }
if (-not $cloneServer) { throw "没找到 llama-server.exe" }
$procs = @()
function Stop-All { foreach ($p in $procs) { try { Stop-Process -Id $p.Id -Force } catch {} } }
try { Stop-All } finally { }

$mtArgs = @("-m", (Join-Path $ModelDir "Hy-MT2-1.8B-$MtQuant.gguf"),
             "--host", "127.0.0.1", "--port", $MtPort, "-c", $Context, "--no-warmup")
if ($MtDevice -eq "NPU") {
    # OpenVINO 后端：NPU 只支持无状态执行，-np 只能是 1，-c 要明确给
    $env:GGML_OPENVINO_DEVICE = "NPU"
    $env:GGML_OPENVINO_CACHE_DIR = Join-Path $BinDir "ov_cache"
    $mtArgs += "-np", "1"
} elseif ($MtDevice -eq "GPU") {
    # 核显：Vulkan 后端，兼容性最好，什么架构都能跑
    $mtArgs += "--device", "Vulkan"
}

Say "起翻译模型（Hy-MT2，后端 $MtDevice，端口 $MtPort）"
$mtLog = Join-Path $ServerDir "mt.log"
$mt = Start-Process -FilePath $mtServer -ArgumentList $mtArgs -PassThru -NoNewWindow `
        -RedirectStandardOutput $mtLog -RedirectStandardError "$mtLog.err"
$procs += $mt

$cloneArgs = @("-m", (Join-Path $ModelDir "Qwen3-TTS-12Hz-0.6B-Base-Q4_K_M.gguf"),
                "--mmproj", (Join-Path $ModelDir "mmproj-Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf"),
                "--host", "127.0.0.1", "--port", $ClonePort, "-c", $Context, "--no-warmup")
if ($CloneDevice -eq "GPU") { $cloneArgs += "--device", "Vulkan" }

Say "起声音克隆模型（Qwen3-TTS，后端 $CloneDevice，端口 $ClonePort）"
$cloneLog = Join-Path $ServerDir "clone.log"
$clone = Start-Process -FilePath $cloneServer -ArgumentList $cloneArgs -PassThru -NoNewWindow `
            -RedirectStandardOutput $cloneLog -RedirectStandardError "$cloneLog.err"
$procs += $clone

function Wait-Health($url, $name) {
    for ($i = 0; $i -lt 120; $i++) {
        try { if ((Invoke-WebRequest -UseBasicParsing "$url/health" -TimeoutSec 3).StatusCode -eq 200) { Say "$name 好了"; return } }
        catch {}
        Start-Sleep -Seconds 2
    }
    Say "$name 两分钟内没就绪，先往下走（看 $name 对应的 log）"
}
Wait-Health "http://127.0.0.1:$MtPort" "翻译模型"
Wait-Health "http://127.0.0.1:$ClonePort" "声音克隆模型"

$env:HEAR_PORT = $Port
$env:HEAR_MT_URL = "http://127.0.0.1:$MtPort"
$env:HEAR_CLONE_URL = "http://127.0.0.1:$ClonePort"
$env:HEAR_ASR_MODEL = $AsrModel

$ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
       Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
       Select-Object -First 1).IPAddress
Write-Host ""
Say "云端服务监听 0.0.0.0:$Port"
Write-Host ""
Write-Host "  手机 App 里「功能设置 → 模型管理 → 在线模型」填：" -ForegroundColor Green
Write-Host "      http://$ip`:$Port" -ForegroundColor Green
Write-Host ""
Write-Host "  防火墙放行（管理员 PowerShell 执行一次）："
Write-Host "      New-NetFirewallRule -DisplayName `"Hear Cloud`" -Direction Inbound -LocalPort $Port,$MtPort,$ClonePort -Protocol TCP -Action Allow"
Write-Host ""

& $py (Join-Path $ServerDir "hear_cloud.py")
