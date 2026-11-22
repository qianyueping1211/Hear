@echo off
setlocal
title Hear Cloud
echo Starting Hear cloud service...
echo Checking service files. The first launch may download required files.
set "HEAR_LAUNCHER_FILE=%~f0"
set "HEAR_LAUNCHER_MODE=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:HEAR_LAUNCHER_FILE); $i=$s.LastIndexOf(':__HEAR_POWERSHELL__'); & ([scriptblock]::Create($s.Substring($i+20)))"
set "RC=%ERRORLEVEL%"
if /i not "%~1"=="--check" if /i not "%~1"=="--help" if not "%RC%"=="0" pause
exit /b %RC%

:__HEAR_POWERSHELL__
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $env:HEAR_LAUNCHER_FILE
$mode = $env:HEAR_LAUNCHER_MODE
$files = @('start-windows.ps1', 'hear_cloud.py', 'hear_http.py', 'hear_speaker.py', 'make_cert.py',
           'requirements.txt', 'test_api.py', 'test_contract.py')
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
        Write-Host 'start-hear-cloud.bat --cloudflare-local-http    Allow authenticated HTTP only from a local Tunnel connector.'
        Write-Host 'HEAR_SERVER_REF accepts main, a release tag, or a full commit SHA.'
        exit 0
    }
    if ($mode -eq '--check') {
        if (-not (Test-ServerFiles $serverDir)) { throw "Incomplete server folder: $serverDir" }
        Write-Host 'Hear server files OK'
        exit 0
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
    if ($loopbackHttp -or (Read-AccessMode)) {
        $env:HEAR_REQUIRE_TOKEN = '1'
        Write-Host '访问口令已启用。' -ForegroundColor Cyan
    } else {
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
