@echo off
setlocal
chcp 65001 >nul
title 听见云端服务
echo 听见云端服务正在启动，请稍候...
echo 正在检查并准备服务文件，首次启动可能需要下载。
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

function Update-ServerFiles {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $stage = Join-Path $tempRoot ('hear-launcher-' + [guid]::NewGuid().ToString('N'))
    $archive = Join-Path $stage 'hear.zip'
    $backup = Join-Path $stage 'backup'
    New-Item -ItemType Directory -Path $stage, $backup | Out-Null
    $installed = [System.Collections.Generic.List[string]]::new()
    try {
        $url = 'https://codeload.github.com/qianyueping1211/Hear/zip/refs/heads/main'
        Write-Host 'Downloading the Hear server source snapshot...'
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive -TimeoutSec 45
        Expand-Archive -LiteralPath $archive -DestinationPath $stage
        $source = Join-Path $stage 'Hear-main\server'
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
        Write-Host '听见 Windows 云端服务'
        Write-Host 'SenseVoice 默认先出原文，Whisper 随后校正。'
        Write-Host '启动菜单可选择 Whisper 校正档位：base / small / medium / large-v3。首次直接回车用 small。'
        Write-Host '在手机上连接云端服务即可，校正档位在电脑上管理。'
        Write-Host 'start-hear-cloud.bat --check    检查启动所需文件'
        exit 0
    }
    if ($mode -eq '--check') {
        if (-not (Test-ServerFiles $serverDir)) { throw "Incomplete server folder: $serverDir" }
        Write-Host "Hear server files OK: $serverDir"
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
