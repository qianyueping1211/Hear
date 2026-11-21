@echo off
setlocal enabledelayedexpansion
title 听见 - 云端模型服务
cd /d "%~dp0"

REM 找到代码放在哪儿。两种摆法都支持：
REM   1) 这个 .bat 和 server 目录在一起（从仓库里直接双击运行）
REM   2) 这个 .bat 在外面，代码在它旁边的 Hear 目录里（平时用的那种）
if exist "%~dp0server\start-windows.ps1" (
    set "ROOT=%~dp0"
) else (
    set "ROOT=%~dp0Hear"
)

echo.
echo  ==========================================================
echo    听见 App  云端模型服务（Windows）
echo    识别 / 翻译 / 声音克隆 跑在这台电脑上
echo    手机 App 通过局域网调用（手机和电脑要连同一个 Wi-Fi）
echo  ==========================================================
echo.
echo    目录：%ROOT%
echo    需要磁盘空间约 4 GB（llama.cpp + 三个模型 + 识别模型）
echo    启动的时候会让你按类型选模型（识别 / 翻译 / 克隆），
echo    直接回车就是上次选的那个。
echo.

REM 先把手机要填的地址打印出来（不用等模型下完）
echo.
echo    手机 App 里「功能设置 → 模型管理 → 在线模型 → 通用服务地址」填下面这个：
powershell -NoProfile -Command ^
 "$c = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }; $a = Get-NetAdapter -ErrorAction SilentlyContinue; foreach ($x in $c) { $d = $a | Where-Object { $_.ifIndex -eq $x.InterfaceIndex } | Select-Object -First 1; if (-not $d) { continue }; if ($d.Name -match 'vEthernet|WSL|VMware|VirtualBox|Tailscale|Loopback|Tunnel|VPN|Hyper-V') { continue }; $k = '其它'; if ($d.NdisPhysicalMedium -eq 9 -or $d.NdisPhysicalMedium -eq 15) { $k = 'WLAN' } elseif ($d.NdisPhysicalMedium -eq 1 -or $d.InterfaceDescription -match 'Ethernet') { $k = '以太网' }; Write-Host ('      {0,-8} {1}   https://{2}:8000' -f $k, $d.Name, $x.IPAddress) }"
echo    先在电脑浏览器打开 http://127.0.0.1:8000/ 看服务有没有起来（要等下面 [4/4] 启动完）。
echo    想分清是服务的问题还是 App 的问题：跑 "%~dp0Hear\server\test_api.py" clone --wav 参考.wav --text "Hello"
echo    服务起来了，再用手机浏览器打开上面那个 https 地址：能打开就说明手机到电脑的网络是通的。
echo.

REM ==========================================================
REM  1. 检查 Python
REM ==========================================================
call :find_python
if not defined PY goto :no_python
echo [1/4] Python：%PYEXE%
goto :step2

:no_python
echo [1/4] 没找到能用的 Python。
echo.
echo       请到 https://www.python.org/downloads/windows/ 下载安装 Python 3.9 以上，
echo       安装第一页底部一定要勾上 "Add python.exe to PATH"，
echo       装完关掉这个窗口，重新双击本文件。
echo.
pause
exit /b 1

:find_python
set "PY="
set "PYEXE="
for /f "delims=" %%V in ('where python 2^>nul') do call :try_python "%%V"
if defined PY goto :eof
for /f "delims=" %%V in ('where py 2^>nul') do call :try_py "%%V"
goto :eof

:try_python
if defined PY goto :eof
echo %~1 | findstr /i "WindowsApps" >nul && goto :eof
"%~1" --version 2>&1 | findstr /C:"Python 3." >nul || goto :eof
set "PY=%~1"
set "PYEXE=%~1"
goto :eof

:try_py
if defined PY goto :eof
"%~1" -3 --version 2>&1 | findstr /C:"Python 3." >nul || goto :eof
set "PY=%~1 -3"
set "PYEXE=%~1"
goto :eof

REM ==========================================================
REM  2. 拿到代码（GitHub 不通就换代理）
REM ==========================================================
:step2
if exist "%ROOT%\server\start-windows.ps1" goto :have_code
if exist "%ROOT%" rmdir /s /q "%ROOT%" >nul 2>&1
echo [2/4] 下载代码...
set "CODEDONE="
for %%U in (
    "https://github.com/qianyueping1211/Hear/archive/refs/heads/main.zip"
    "https://gh-proxy.com/https://github.com/qianyueping1211/Hear/archive/refs/heads/main.zip"
    "https://ghproxy.net/https://github.com/qianyueping1211/Hear/archive/refs/heads/main.zip"
) do (
    if not defined CODEDONE (
        curl -fL --connect-timeout 20 --retry 3 --retry-delay 3 -o "hear-main.zip" %%U
        if not errorlevel 1 set "CODEDONE=1"
    )
)
if not defined CODEDONE (
    echo       代码下载失败，GitHub 和两个代理都不行。
    echo       换个网络/代理再运行本文件，或者手动把仓库 zip 下载下来解压成 Hear 文件夹。
    pause
    exit /b 1
)
powershell -NoProfile -Command "Expand-Archive -Path '%~dp0hear-main.zip' -DestinationPath '%~dp0' -Force" >nul 2>&1
del "hear-main.zip" >nul 2>&1
if exist "Hear-main" ren "Hear-main" "Hear" >nul 2>&1
if not exist "%ROOT%\server\start-windows.ps1" (
    echo       解压失败。把 hear-main.zip 手动解压成 Hear 文件夹，再运行本文件。
    pause
    exit /b 1
)
:have_code
echo [2/4] 代码就绪：%~dp0Hear

REM 已经下过的代码，把 server 里的文件更新一下（不然改了 bug 还是旧的）
echo       更新服务文件...
call :refresh "start-windows.ps1"
call :refresh "hear_cloud.py"
call :refresh "make_cert.py"
call :refresh "requirements.txt"
call :refresh "test_api.py"
call :refresh "test_contract.py"

REM ==========================================================
REM  3. 让 PowerShell 5 正确读中文（脚本存成带 BOM 的 UTF-8）
REM ==========================================================
powershell -NoProfile -Command ^
 "$p='%ROOT%\server\start-windows.ps1'; if (Test-Path $p) { $c=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8); [IO.File]::WriteAllText($p,$c,(New-Object Text.UTF8Encoding $true)) }" >nul 2>&1

REM ==========================================================
REM  3.5 证书：App 只走 https，证书必须先生成好
REM ==========================================================
set "VPY=%ROOT%\server\.venv\Scripts\python.exe"
if exist "%VPY%" (
    "%VPY%" -m pip install cryptography --quiet >nul 2>&1
    if exist "%ROOT%\server\make_cert.py" (
        REM 每次都跑一次：换了网络、IP 变了的话，脚本自己会重新生成证书
        echo       检查自签证书...
        "%VPY%" "%ROOT%\server\make_cert.py"
        if errorlevel 1 (
            echo       证书生成失败，装一下 cryptography 再跑一次本文件：
            echo         "%VPY%" -m pip install cryptography
        )
    )
)

REM ==========================================================
REM  4. 下载源：国内直连不上就换镜像
REM ==========================================================
curl -sI --max-time 15 "https://huggingface.co" >nul 2>&1
if errorlevel 1 (
    set "HF_ENDPOINT=https://hf-mirror.com"
    echo [3/4] huggingface.co 连不上，改用国内镜像 hf-mirror.com
) else (
    set "HF_ENDPOINT=https://huggingface.co"
    echo [3/4] 下载源：huggingface.co
)

REM ==========================================================
REM  5. 起服务
REM ==========================================================
echo [4/4] 启动服务（第一次要下 llama.cpp 和三个模型，大概十几分钟）...
echo       （服务会先起来，几秒钟后就能在手机浏览器上测网络，不用等模型下完）
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\server\start-windows.ps1"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
    echo 服务没能正常启动（退出码 %RC%）。
    echo   翻译日志：%~dp0Hear\server\mt.log
    echo   克隆日志：%~dp0Hear\server\clone.log
) else (
    echo 服务已停止。
)
echo.
echo 按任意键关闭这个窗口。
pause >nul
exit /b 0

REM ==========================================================
REM  更新 server 里的一个文件（GitHub 不通就换代理）
REM ==========================================================
:refresh
set "OK="
for %%U in (
    "https://raw.githubusercontent.com/qianyueping1211/Hear/main/server/%~1"
    "https://gh-proxy.com/https://raw.githubusercontent.com/qianyueping1211/Hear/main/server/%~1"
    "https://ghproxy.net/https://raw.githubusercontent.com/qianyueping1211/Hear/main/server/%~1"
) do (
    if "!OK!"=="" (
        curl -fL --connect-timeout 15 --retry 2 -o "%ROOT%\server\%~1.new" %%U >nul 2>&1
        if not errorlevel 1 set "OK=1"
    )
)
if "!OK!"=="" (
    del "%ROOT%\server\%~1.new" >nul 2>&1
    echo       %~1 更新失败，还是用原来那份
) else (
    move /y "%ROOT%\server\%~1.new" "%ROOT%\server\%~1" >nul 2>&1
)
goto :eof
