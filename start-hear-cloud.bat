@echo off
setlocal
title Hear Cloud
echo Starting Hear cloud service...
echo Checking service files. The first launch may download required files.
set "HEAR_LAUNCHER_FILE=%~f0"
set "HEAR_LAUNCHER_MODE=%~1"
set "HEAR_LAUNCHER_ARG=%~2"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:HEAR_LAUNCHER_FILE); $i=$s.LastIndexOf(':__HEAR_POWERSHELL__'); & ([scriptblock]::Create($s.Substring($i+20)))"
set "RC=%ERRORLEVEL%"
if /i not "%~1"=="--check" if /i not "%~1"=="--help" if /i not "%~1"=="--check-token" if not "%RC%"=="0" pause
exit /b %RC%

:__HEAR_POWERSHELL__
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $env:HEAR_LAUNCHER_FILE
$mode = $env:HEAR_LAUNCHER_MODE
$files = @('start-windows.ps1', 'hear_cloud.py', 'hear_http.py', 'hear_speaker.py', 'make_cert.py',
           'requirements.txt', 'test_api.py', 'test_contract.py',
           'hear_auth.py', 'hear_check_token.py', 'hear_token_store.py', 'hear_token_service.py',
           'hear_token_admin.html', 'hear_token_admin.js', 'hear_token_admin.css', 'test_token_auth.py')
$inCheckout = Test-Path -LiteralPath (Join-Path $here 'server\start-windows.ps1')
$root = if ($inCheckout) { $here } else { Join-Path $here 'Hear' }
$serverDir = Join-Path $root 'server'

function Test-ServerFiles($directory) {
    foreach ($name in $files) {
        if (-not (Test-Path -LiteralPath (Join-Path $directory $name) -PathType Leaf)) {
            return $false
        }
    }
    return $true
}

function Read-AccessMode {
    if ([Console]::IsInputRedirected) { return $true }

    Write-Host ''
    Write-Host '  服务访问口令（5 秒后默认启用，内网和公网都需要）' -ForegroundColor Cyan
    Write-Host '    1) 启用访问口令（默认）'
    Write-Host '    2) 仅本次关闭访问口令（选 2 后按 Enter 确认）'
    $requireToken = $true

    try {
        [Console]::Out.Flush()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($timer.Elapsed.TotalSeconds -lt 5) {
            if (-not [Console]::KeyAvailable) {
                Start-Sleep -Milliseconds 50
                continue
            }
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) { return $requireToken }
            if ($key.KeyChar -eq '2') {
                $requireToken = $false
                Write-Host '    按 Enter 确认仅本次关闭访问口令。' -ForegroundColor Yellow
            } elseif ($key.KeyChar -eq '1' -or $key.Key -eq [ConsoleKey]::Backspace) {
                $requireToken = $true
            }
        }
    } catch {
        # Some hosts do not provide a readable console. Use the secure default.
    }
    return $true
}

# 本机 Token 管理服务（start-hear-token-admin.bat）的默认位置：数据和凭据在当前用户目录里
$tokenPort = if ($env:HEAR_TOKEN_SERVICE_PORT) { $env:HEAR_TOKEN_SERVICE_PORT.Trim() } else { '8443' }
$tokenGateway = if ($env:HEAR_GATEWAY_ID) { $env:HEAR_GATEWAY_ID.Trim() } else { 'hear-home' }
$tokenDb = Join-Path $env:LOCALAPPDATA 'Hear\token-data\hear-tokens.db'
$tokenCred = Join-Path $env:LOCALAPPDATA ('Hear\secrets\' + $tokenGateway + '.cred')

# 口令管理模式：HEAR_AUTH_MODE=managed，或已配置管理服务三项时默认进入。
# 用 start-hear-token-admin.bat 在本机设置过 Token 管理后，不用再配环境变量，默认直接进入管理模式。
# 网关凭据只通过 HEAR_GATEWAY_CREDENTIAL_FILE 指向的文件提供，这里只检查文件，不读取内容。
function Resolve-AuthMode {
    $names = @('HEAR_AUTH_API_URL', 'HEAR_GATEWAY_ID', 'HEAR_GATEWAY_CREDENTIAL_FILE')
    $present = @($names | Where-Object { [Environment]::GetEnvironmentVariable($_) })
    $requested = ([string]$env:HEAR_AUTH_MODE).Trim().ToLowerInvariant()
    if ($requested -eq '' -and $present.Count -eq 0 -and (Test-Path -LiteralPath $tokenCred -PathType Leaf)) {
        $env:HEAR_AUTH_API_URL = "http://127.0.0.1:$tokenPort"
        $env:HEAR_GATEWAY_ID = $tokenGateway
        $env:HEAR_GATEWAY_CREDENTIAL_FILE = $tokenCred
        $present = $names
    }
    if ($requested -eq '' -and $present.Count -gt 0) { $requested = 'managed' }
    if ($requested -eq '' -or $requested -eq 'legacy') { return 'legacy' }
    if ($requested -eq 'off') { return 'off' }
    if ($requested -ne 'managed') { throw "HEAR_AUTH_MODE 只能是 managed、legacy 或 off（现在是 $requested）" }
    $missing = @($names | Where-Object { -not [Environment]::GetEnvironmentVariable($_) })
    if ($missing.Count -gt 0) { throw ("口令管理模式配置不完整，缺少：" + ($missing -join '、')) }
    $url = $env:HEAR_AUTH_API_URL.Trim()
    if ($url -notmatch '^https://' -and $url -notmatch '^http://(127\.0\.0\.1|localhost|\[::1\])(:|/|$)') {
        throw 'HEAR_AUTH_API_URL 需要是 https:// 地址（只有本机地址可以用 http）'
    }
    $credential = $env:HEAR_GATEWAY_CREDENTIAL_FILE.Trim()
    if (-not (Test-Path -LiteralPath $credential -PathType Leaf)) { throw "网关凭据文件不存在：$credential" }
    if ((Get-Item -LiteralPath $credential).Length -lt 16) { throw "网关凭据文件内容为空或不完整：$credential" }
    if ($env:HEAR_AUTH_CA_FILE -and -not (Test-Path -LiteralPath $env:HEAR_AUTH_CA_FILE -PathType Leaf)) {
        throw "HEAR_AUTH_CA_FILE 指向的文件不存在：$($env:HEAR_AUTH_CA_FILE)"
    }
    return 'managed'
}

function Find-LauncherPython {
    $venv = Join-Path $serverDir '.venv\Scripts\python.exe'
    if (Test-Path -LiteralPath $venv) { return @($venv) }
    foreach ($candidate in @('python', 'python3')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command -and $command.Source -notlike '*WindowsApps*') { return @($command.Source) }
    }
    if (Get-Command 'py' -ErrorAction SilentlyContinue) { return @('py', '-3') }
    return @()
}

# 管理服务在本机（http://127.0.0.1:端口）但还没运行时，在另一个最小化窗口里把它启动起来。
# 这个窗口独立于云端服务：关掉云端服务窗口不会停掉它。
function Start-LocalTokenService {
    if ($env:HEAR_AUTH_API_URL -notmatch '^http://127\.0\.0\.1:(\d+)/?$') { return }
    $port = $Matches[1]
    try {
        if ((Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/healthz" -TimeoutSec 2).StatusCode -eq 200) {
            Write-Host "Token 管理服务已在运行：http://127.0.0.1:$port/admin/" -ForegroundColor DarkGray
            return
        }
    } catch { }
    $service = Join-Path $serverDir 'hear_token_service.py'
    if (-not (Test-Path -LiteralPath $tokenDb) -or -not (Test-Path -LiteralPath $service)) {
        Write-Warning '本机 Token 管理服务还没设置：先双击 start-hear-token-admin.bat。'
        return
    }
    $python = @(Find-LauncherPython)
    if ($python.Count -eq 0) { throw 'Python 3 was not found.' }
    $arguments = @()
    if ($python.Count -gt 1) { $arguments += $python[1..($python.Count - 1)] }
    $arguments += @($service, '--db', $tokenDb, 'serve', '--host', '127.0.0.1', '--port', $port)
    # Windows PowerShell 5 不会给带空格的参数加引号，这里逐个加上
    $quoted = $arguments | ForEach-Object { '"' + $_ + '"' }
    $env:PYTHONUTF8 = '1'
    Start-Process -FilePath $python[0] -ArgumentList $quoted -WindowStyle Minimized | Out-Null
    Write-Host "已在另一个窗口启动 Token 管理服务：http://127.0.0.1:$port/admin/" -ForegroundColor Cyan
}

function Update-ServerFiles {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $stage = Join-Path $tempRoot ('hear-launcher-' + [guid]::NewGuid().ToString('N'))
    $archive = Join-Path $stage 'hear.zip'
    $backup = Join-Path $stage 'backup'
    New-Item -ItemType Directory -Path $stage, $backup | Out-Null
    $installed = [System.Collections.Generic.List[string]]::new()
    try {
        $ref = if ($env:HEAR_SERVER_REF) { $env:HEAR_SERVER_REF.Trim() } else { 'main' }
        if ($ref -eq 'main') { $snapshot = 'refs/heads/main' }
        elseif ($ref -match '^v[0-9]+\.[0-9]+\.[0-9]+$') { $snapshot = "refs/tags/$ref" }
        elseif ($ref -match '^[0-9a-f]{40}$') { $snapshot = $ref }
        else { throw 'HEAR_SERVER_REF must be main, a release tag such as v0.4.73, or a full commit SHA.' }
        $url = "https://codeload.github.com/qianyueping1211/Hear/zip/$snapshot"
        Write-Host 'Downloading the Hear server source snapshot...'
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive -TimeoutSec 45
        Expand-Archive -LiteralPath $archive -DestinationPath $stage
        $package = Get-ChildItem -LiteralPath $stage -Directory | Where-Object { $_.Name -like 'Hear-*' } | Select-Object -First 1
        if (-not $package) { throw 'The source snapshot has no Hear directory.' }
        $source = Join-Path $package.FullName 'server'
        if (-not (Test-ServerFiles $source)) { throw 'The downloaded server snapshot is incomplete.' }
        New-Item -ItemType Directory -Path $serverDir -Force | Out-Null
        foreach ($name in $files) {
            $target = Join-Path $serverDir $name
            if (Test-Path -LiteralPath $target) {
                Copy-Item -LiteralPath $target -Destination (Join-Path $backup $name)
            }
            $installed.Add($name)
            Copy-Item -LiteralPath (Join-Path $source $name) -Destination $target -Force
        }
        $env:HEAR_SERVER_REVISION = $ref
    } catch {
        foreach ($name in $installed) {
            $old = Join-Path $backup $name
            $target = Join-Path $serverDir $name
            if (Test-Path -LiteralPath $old) {
                Copy-Item -LiteralPath $old -Destination $target -Force
            } elseif (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target
            }
        }
        throw
    } finally {
        $resolved = [IO.Path]::GetFullPath($stage)
        if ((Split-Path -Parent $resolved).TrimEnd('\') -eq $tempRoot.TrimEnd('\') -and
            (Split-Path -Leaf $resolved) -match '^hear-launcher-[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    if ($mode -eq '--help') {
        Write-Host 'Hear Cloud for Windows'
        Write-Host 'SenseVoice produces the first transcript; Whisper applies corrections.'
        Write-Host 'The startup menu selects Whisper base / small / medium / large-v3. Press Enter for small on first launch.'
        Write-Host 'Connect the phone app to this cloud service; Whisper is managed on the computer.'
        Write-Host 'Both LAN and internet access require a token by default. The startup choice times out after 5 seconds.'
        Write-Host 'start-hear-cloud.bat --check    Check required server files'
        Write-Host 'start-hear-cloud.bat --check-token [https://host:port]    Check the gateway and one access token (hidden input).'
        Write-Host '    Exit codes: 0 valid, 2 network/TLS, 3 missing/invalid, 4 not started, 5 expired, 6 revoked, 7 auth unavailable.'
        Write-Host 'start-hear-cloud.bat --cloudflare-local-http    Allow authenticated HTTP only from a local Tunnel connector.'
        Write-Host 'Managed tokens: run start-hear-token-admin.bat once; this launcher then uses them automatically.'
        Write-Host 'Remote token service: set HEAR_AUTH_MODE=managed, HEAR_AUTH_API_URL, HEAR_GATEWAY_ID, HEAR_GATEWAY_CREDENTIAL_FILE.'
        Write-Host 'HEAR_SERVER_REF accepts main, a release tag, or a full commit SHA.'
        exit 0
    }
    if ($mode -eq '--check') {
        if (-not (Test-ServerFiles $serverDir)) { throw "Incomplete server folder: $serverDir" }
        Write-Host 'Hear server files OK'
        exit 0
    }
    if ($mode -eq '--check-token') {
        $checker = Join-Path $serverDir 'hear_check_token.py'
        if (-not (Test-Path -LiteralPath $checker) -and -not $inCheckout) { Update-ServerFiles }
        if (-not (Test-Path -LiteralPath $checker)) { throw "Missing $checker" }
        # 函数返回的数组会被展开，这里重新收成数组
        $python = @(Find-LauncherPython)
        if ($python.Count -eq 0) { throw 'Python 3 was not found.' }
        $env:PYTHONUTF8 = '1'
        $pythonArgs = @()
        if ($python.Count -gt 1) { $pythonArgs += $python[1..($python.Count - 1)] }
        $pythonArgs += $checker
        # 只把地址放进参数；口令由检查程序隐藏输入读取
        if ($env:HEAR_LAUNCHER_ARG) { $pythonArgs += $env:HEAR_LAUNCHER_ARG }
        & $python[0] @pythonArgs
        exit $LASTEXITCODE
    }
    if (-not $inCheckout) {
        try { Update-ServerFiles }
        catch {
            if (-not (Test-ServerFiles $serverDir)) { throw }
            Write-Warning "Update unavailable. Using the installed server files. $($_.Exception.Message)"
        }
    }
    if (-not (Test-ServerFiles $serverDir)) { throw "Incomplete server folder: $serverDir" }
    $loopbackHttp = $mode -eq '--cloudflare-local-http'
    if ($loopbackHttp) {
        $env:HEAR_ALLOW_LOOPBACK_HTTP = '1'
        Write-Host '已启用 Cloudflare 本机 HTTP 回源。' -ForegroundColor Cyan
    }
    $authMode = Resolve-AuthMode
    if ($authMode -eq 'managed') {
        # 管理模式只认后台签发的 Token：不显示关闭口令的选项，也不使用 access-token.txt
        $env:HEAR_AUTH_MODE = 'managed'
        $env:HEAR_REQUIRE_TOKEN = '0'
        Write-Host "口令管理模式：网关 $($env:HEAR_GATEWAY_ID)，管理服务 $($env:HEAR_AUTH_API_URL)" -ForegroundColor Cyan
        Start-LocalTokenService
        Write-Host '  口令清单加载完成前，推理请求会被拒绝（503）。' -ForegroundColor DarkGray
    } elseif ($authMode -eq 'off') {
        $env:HEAR_AUTH_MODE = 'off'
        $env:HEAR_REQUIRE_TOKEN = '0'
        if ($loopbackHttp) { throw '启用本机 HTTP 回源时，必须同时启用访问口令' }
        Write-Host 'HEAR_AUTH_MODE=off：本次启动不校验访问口令。' -ForegroundColor Yellow
    } elseif ($loopbackHttp -or (Read-AccessMode)) {
        $env:HEAR_AUTH_MODE = 'legacy'
        $env:HEAR_REQUIRE_TOKEN = '1'
        Write-Host '访问口令已启用。' -ForegroundColor Cyan
    } else {
        $env:HEAR_AUTH_MODE = 'legacy'
        $env:HEAR_REQUIRE_TOKEN = '0'
        Write-Host '本次启动已关闭访问口令。' -ForegroundColor Yellow
    }
    $script = Join-Path $serverDir 'start-windows.ps1'
    # Read the UTF-8 source explicitly for Windows PowerShell 5, without rewriting the checkout.
    $source = [IO.File]::ReadAllText($script, [Text.Encoding]::UTF8)
    Set-Location -LiteralPath $root
    # Load from a UTF-8 BOM script so its PSScriptRoot stays the server directory.
    $launcher = Join-Path $serverDir ('.hear-start-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        [IO.File]::WriteAllText($launcher, $source, [Text.UTF8Encoding]::new($true))
        & powershell -NoProfile -ExecutionPolicy Bypass -File $launcher
        exit $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $launcher -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "Hear server launch failed. $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
