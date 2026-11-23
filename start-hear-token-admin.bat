@echo off
setlocal
title Hear Token Admin
set "HEAR_LAUNCHER_FILE=%~f0"
set "HEAR_LAUNCHER_MODE=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:HEAR_LAUNCHER_FILE); $i=$s.LastIndexOf(':__HEAR_POWERSHELL__'); & ([scriptblock]::Create($s.Substring($i+20)))"
set "RC=%ERRORLEVEL%"
if /i not "%~1"=="--help" if not "%RC%"=="0" pause
exit /b %RC%

:__HEAR_POWERSHELL__
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$env:PYTHONUTF8 = '1'
$here = Split-Path -Parent $env:HEAR_LAUNCHER_FILE
$mode = $env:HEAR_LAUNCHER_MODE
$inCheckout = Test-Path -LiteralPath (Join-Path $here 'server\start-windows.ps1')
$root = if ($inCheckout) { $here } else { Join-Path $here 'Hear' }
$serverDir = Join-Path $root 'server'
$service = Join-Path $serverDir 'hear_token_service.py'

# 数据和凭据放在当前 Windows 用户自己的目录里：更新服务文件时不会被覆盖
$dataDir = Join-Path $env:LOCALAPPDATA 'Hear'
$db = Join-Path $dataDir 'token-data\hear-tokens.db'
$secretDir = Join-Path $dataDir 'secrets'
$gatewayId = if ($env:HEAR_GATEWAY_ID) { $env:HEAR_GATEWAY_ID.Trim() } else { 'hear-home' }
$credFile = Join-Path $secretDir "$gatewayId.cred"
$port = if ($env:HEAR_TOKEN_SERVICE_PORT) { $env:HEAR_TOKEN_SERVICE_PORT.Trim() } else { '8443' }
if ($port -notmatch '^\d+$' -or [int]$port -lt 1 -or [int]$port -gt 65535) {
    throw "HEAR_TOKEN_SERVICE_PORT 必须是 1~65535 的纯数字端口（当前值：$port）"
}
$adminUrl = "http://127.0.0.1:$port/admin/"
$taskName = 'Hear Token Admin'

function Say($text) { Write-Host $text -ForegroundColor Cyan }
function Note($text) { Write-Host "  $text" -ForegroundColor DarkGray }

function Find-Python {
    $bundled = Join-Path $serverDir 'runtime\python.exe'
    if (Test-Path -LiteralPath $bundled) { return @($bundled) }
    $venv = Join-Path $serverDir '.venv\Scripts\python.exe'
    if (Test-Path -LiteralPath $venv) { return @($venv) }
    foreach ($candidate in @('python', 'python3')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command -and $command.Source -notlike '*WindowsApps*') { return @($command.Source) }
    }
    if (Get-Command 'py' -ErrorAction SilentlyContinue) { return @('py', '-3') }
    return @()
}

$python = @(Find-Python)

function Invoke-Service {
    # 调用 hear_token_service.py；数据库固定用当前用户目录里的那一份
    $pythonArgs = @()
    if ($python.Count -gt 1) { $pythonArgs += $python[1..($python.Count - 1)] }
    $pythonArgs += @($service, '--db', $db) + $args
    # 输出直接显示在窗口里，不混进函数返回值；函数只返回退出码
    & $python[0] @pythonArgs | Out-Host
    return $LASTEXITCODE
}

function Test-ServiceRunning {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/healthz" -TimeoutSec 2
        return $response.StatusCode -eq 200
    } catch { return $false }
}

function Protect-PrivateDir($path) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $grant = if ($sid) { "*$($sid):(OI)(CI)F" } else { "$($env:USERNAME):(OI)(CI)F" }
    & icacls.exe $path /inheritance:r /grant:r $grant | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Note "提示：设置目录访问权限未成功（$path），请确认当前用户拥有所有权"
    }
}

function Protect-SecretDir {
    Protect-PrivateDir $secretDir
    Protect-PrivateDir (Join-Path $dataDir 'token-data')
    Protect-PrivateDir (Join-Path $dataDir 'backups')
}

function Initialize-Admin {
    New-Item -ItemType Directory -Path (Split-Path -Parent $db) -Force | Out-Null
    $firstRun = -not (Test-Path -LiteralPath $db)
    if ((Invoke-Service 'init') -ne 0) { throw '数据库初始化失败' }
    if ($firstRun) {
        Write-Host ''
        Say '第一次使用：先创建管理后台的登录账号'
        Note '用户名固定为 admin；密码至少 12 位，输入时不显示，需要输入两次。'
        $created = $false
        for ($i = 0; $i -lt 3 -and -not $created; $i++) {
            $created = (Invoke-Service 'create-admin' '--username' 'admin') -eq 0
            if (-not $created) { Write-Host '  没有创建成功，请重新输入。' -ForegroundColor Yellow }
        }
        if (-not $created) {
            # 连同 -wal / -shm 一起删，下次重新开始
            Remove-Item -Path "$db*" -ErrorAction SilentlyContinue
            throw '管理员账号没有创建成功，请重新运行本文件'
        }
    }
    if (-not (Test-Path -LiteralPath $credFile)) {
        Protect-SecretDir
        Say "登记网关 $gatewayId，并生成网关凭据"
        if ((Invoke-Service 'create-gateway' '--id' $gatewayId '--name' '本机网关' '--credential-out' $credFile) -ne 0) {
            # 网关以前登记过、但凭据文件不见了：换一份新凭据
            if ((Invoke-Service 'rotate-gateway-credential' '--id' $gatewayId '--credential-out' $credFile) -ne 0) {
                throw '网关凭据生成失败'
            }
        }
        Note "凭据文件：$credFile（只有当前 Windows 用户能读）"
    }
}

# 设置过本机 Token 管理后，start-hear-cloud.bat 会自动进入管理模式；这两个开关只用来临时切回或恢复
function Enable-Managed {
    if (-not (Test-Path -LiteralPath $credFile)) { throw '还没有网关凭据：请先直接双击本文件完成第一次设置' }
    [Environment]::SetEnvironmentVariable('HEAR_AUTH_MODE', $null, 'User')
    Say '已恢复 Token 管理模式。关掉云端服务窗口，重新双击 start-hear-cloud.bat 生效。'
}

function Disable-Managed {
    [Environment]::SetEnvironmentVariable('HEAR_AUTH_MODE', 'legacy', 'User')
    Say '已切回旧的单口令方式。关掉云端服务窗口，重新双击 start-hear-cloud.bat 生效。'
}

function Start-Admin($openBrowser) {
    if (Test-ServiceRunning) {
        Say "管理服务已经在运行：$adminUrl"
        if ($openBrowser) { Start-Process $adminUrl }
        return 0
    }
    $firstSetup = -not (Test-Path -LiteralPath $credFile)
    Initialize-Admin
    Write-Host ''
    if ($firstSetup) {
        Say '设置完成。以后双击 start-hear-cloud.bat 会自动使用 Token 管理，并顺带启动本管理服务。'
        Note '在后台签发 Token 后，把口令填进 App 的「访问口令」。'
    }
    Say "管理后台地址：$adminUrl"
    Note '只能在这台电脑上打开。关闭本窗口 = 停止管理服务（超过 60 秒后 App 请求会被拒绝）。'
    if ($openBrowser) {
        # 等服务起来再打开浏览器
        Start-Process powershell -WindowStyle Hidden -ArgumentList @('-NoProfile', '-Command',
            "Start-Sleep -Seconds 2; Start-Process '$adminUrl'")
    }
    return (Invoke-Service 'serve' '--host' '127.0.0.1' '--port' $port)
}

try {
    if ($mode -eq '--help') {
        Write-Host 'Hear Token Admin'
        Write-Host '  start-hear-token-admin.bat                  Set up on first run, start the admin service and open the browser'
        Write-Host '  start-hear-token-admin.bat --disable-managed Temporarily switch the cloud gateway back to the legacy shared token'
        Write-Host '  start-hear-token-admin.bat --enable-managed  Undo --disable-managed'
        Write-Host '  start-hear-token-admin.bat --backup         Back up the token database'
        Write-Host '  start-hear-token-admin.bat --autostart-on   Start the admin service when this Windows user signs in'
        Write-Host '  start-hear-token-admin.bat --autostart-off  Remove the sign-in task'
        Write-Host "Admin page: http://127.0.0.1:<port>/admin/ (default port 8443, HEAR_TOKEN_SERVICE_PORT)"
        exit 0
    }
    if (-not (Test-Path -LiteralPath $service)) {
        throw "找不到 $service：请先双击一次 start-hear-cloud.bat，让它下载最新的服务文件"
    }
    if ($python.Count -eq 0) { throw '没找到 Python 3：请先双击一次 start-hear-cloud.bat 完成安装' }

    switch ($mode) {
        '--enable-managed' { Enable-Managed; exit 0 }
        '--disable-managed' { Disable-Managed; exit 0 }
        '--backup' {
            $backupDir = Join-Path $dataDir 'backups'
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            $target = Join-Path $backupDir ('hear-tokens-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.db')
            exit (Invoke-Service 'backup' '--out' $target)
        }
        '--autostart-on' {
            $action = New-ScheduledTaskAction -Execute 'cmd.exe' `
                -Argument ('/c ""' + $env:HEAR_LAUNCHER_FILE + '" --autostart-run"')
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$($env:USERDOMAIN)\$($env:USERNAME)"
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Force | Out-Null
            Say '已设置：登录 Windows 后自动启动管理服务（会打开一个服务窗口）。'
            exit 0
        }
        '--autostart-off' {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Say '已取消登录后自动启动。'
            exit 0
        }
        '--autostart-run' { exit (Start-Admin $false) }
        default {
            $code = Start-Admin $true
            exit $code
        }
    }
} catch {
    Write-Host "Hear Token Admin failed. $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
