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

# ---------------------------------------------------------------- 中文显示
# 现在的 Python（3.15 起）默认用 UTF-8 输出，而中文版 Windows 的 cmd 默认是 GBK，
# 于是每个汉字都被拆成两个乱码字符（"听听见见"这种）。
# 把控制台代码页改成 UTF-8 就好了。
# 记下原来的代码页，退出时还回去（.bat 里的中文是 GBK 存的，代码页变了它就乱码了）
$OrigCodePage = ((chcp) -replace '[^0-9]', '')
try { chcp 65001 > $null } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
# 让 Python 一定用 UTF-8 写日志（不管系统是什么语言）
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
# 打印一行中文，自己看一眼显示正不正常（还是乱码就是这个控制台代码页的问题）
Write-Host "  中文显示测试：听见（正常应该就是这行字）" -ForegroundColor DarkGray
try { [Console]::Out.Flush() } catch {}
function Say($t)  { Write-Host "==> $t" -ForegroundColor Cyan }
function Step($t) { Write-Host "    $t" -ForegroundColor DarkGray }
function Die($t)  { Write-Host "!! $t" -ForegroundColor Red; exit 1 }
function Quote-Arg([string]$a) { if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a } }
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
# 打印局域网地址的时候要用
$script:MtPort = $MtPort
$script:ClonePort = $ClonePort
$MtDevice    = if ($env:HEAR_MT_DEVICE)    { $env:HEAR_MT_DEVICE }    else { "GPU" }
$CloneDevice = if ($env:HEAR_CLONE_DEVICE) { $env:HEAR_CLONE_DEVICE } else { "GPU" }
$MtQuant   = if ($env:HEAR_MT_QUANT)   { $env:HEAR_MT_QUANT }   else { "Q4_K_M" }
$AsrModel  = if ($env:HEAR_ASR_MODEL)  { $env:HEAR_ASR_MODEL }  else { "small" }
# 识别方案：whisper / sensevoice / sensevoice+whisper
$AsrScheme = if ($env:HEAR_ASR_SCHEME) { $env:HEAR_ASR_SCHEME } else { "sensevoice+whisper" }
$SvDir     = Join-Path $ModelDir "sensevoice"
$Context   = if ($env:HEAR_CTX)        { $env:HEAR_CTX }        else { "4096" }
$HF        = if ($env:HF_ENDPOINT)     { $env:HF_ENDPOINT }     else { "https://huggingface.co" }

# ---------------------------------------------------------------- 用哪些模型
# 交互启动时选择校正、翻译和克隆档位，直接回车沿用上次的配置。
$CfgFile = Join-Path $ServerDir "hear_models.json"

# SenseVoice 默认先出原文。下面只选择电脑端的 Whisper 档位。
$AsrChoices = @(
    @{ key = "base";     size = "约 145 MB"; note = "校正快，适合性能较低的电脑" },
    @{ key = "small";    size = "约 480 MB"; note = "兼顾校正速度和准确度" },
    @{ key = "medium";   size = "约 1.5 GB"; note = "校正更细，耗时更长" },
    @{ key = "large-v3"; size = "约 3 GB";   note = "高精度，CPU 校正耗时较长" }
)
$senseEnabled = $env:HEAR_SENSEVOICE -notmatch '^(0|off|false|no)$'
$env:HEAR_SENSEVOICE = if ($senseEnabled) { "1" } else { "0" }
if (-not $senseEnabled -and -not $env:HEAR_ASR_SCHEME) { $AsrScheme = "whisper" }
# 文本翻译：腾讯的 Hy-MT2（GGUF，llama.cpp 跑）
$MtChoices = @(
    @{ key = "1.8b"; repo = "tencent/Hy-MT2-1.8B-GGUF";    stem = "Hy-MT2-1.8B";    size = "约 1.1 GB";  note = "快，日常够用" },
    @{ key = "7b";   repo = "tencent/Hy-MT2-7B-GGUF";      stem = "Hy-MT2-7B";      size = "约 4.4 GB";  note = "更准，内存要 8G 以上" },
    @{ key = "30b";  repo = "tencent/Hy-MT2-30B-A3B-GGUF"; stem = "Hy-MT2-30B-A3B"; size = "约 18 GB";   note = "30B 里只激活 3B，又快又好；内存要 24G 以上" }
)
# 声音克隆：Qwen3-TTS（GGUF，llama.cpp 跑）
$CloneChoices = @(
    @{ key = "0.6b"; repo = "Shlomo426/Qwen3-TTS-12Hz-0.6B-Base-GGUF"; model = "Qwen3-TTS-12Hz-0.6B-Base-Q4_K_M.gguf"; mmproj = "mmproj-Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf"; size = "约 0.6 GB"; note = "快" },
    @{ key = "1.7b"; repo = "ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF"; model = "Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf"; mmproj = "mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf"; size = "约 1.1 GB"; note = "更像原声（推荐）" }
)

function Read-Choice($prompt) {
    # 没交互（不是从窗口里跑的）就直接用默认值。
    # 交互运行时最多等 5 秒；超时沿用上次选择，避免启动脚本一直卡在菜单。
    $timeoutSeconds = 5
    if ($env:HEAR_INPUT_TIMEOUT_SECONDS -match '^\d+$') {
        $timeoutSeconds = [Math]::Max(1, [int]$env:HEAR_INPUT_TIMEOUT_SECONDS)
    }
    Write-Host "$prompt（${timeoutSeconds}秒后使用默认）" -NoNewline
    try { [Console]::Out.Flush() } catch {}
    try {
        if ([Console]::IsInputRedirected) { return "" }
        $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
        $buffer = ""
        while ([DateTime]::UtcNow -lt $deadline) {
            if (-not [Console]::KeyAvailable) {
                Start-Sleep -Milliseconds 50
                continue
            }
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) {
                Write-Host ""
                return $buffer.Trim()
            }
            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($buffer.Length -gt 0) {
                    $buffer = $buffer.Substring(0, $buffer.Length - 1)
                    Write-Host "`b `b" -NoNewline
                }
                continue
            }
            if ($key.KeyChar -match '^\d$') {
                $buffer += [string]$key.KeyChar
                Write-Host $key.KeyChar -NoNewline
            }
        }
        Write-Host "（超时，使用默认）"
        return ""
    } catch {
        return ""
    }
}

function Read-Pick($title, $choices, $defaultKey) {
    Write-Host ""
    Write-Host "  $title" -ForegroundColor Cyan
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $c = $choices[$i]
        $mark = ""
        if ($c.key -eq $defaultKey) { $mark = "（推荐）" }
        Write-Host ("    {0}) {1,-9} {2,-10} {3} {4}" -f ($i + 1), $c.key, $c.size, $c.note, $mark) -ForegroundColor Gray
    }
    $ans = Read-Choice "  选哪个（直接回车 = $defaultKey）"
    $pick = $null
    if ($ans -ne "") {
        $n = 0
        if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $choices.Count) {
            $pick = $choices[$n - 1]
        } else {
            Write-Host "    没看懂，按推荐的来" -ForegroundColor DarkGray
        }
    }
    if (-not $pick) {
        $pick = $choices | Where-Object { $_.key -eq $defaultKey } | Select-Object -First 1
    }
    return $pick
}

function Load-Choice {
    if (-not (Test-Path $CfgFile)) { return $null }
    try { return (Get-Content $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# 每次启动都问一次：直接回车就是上次的选择。
# 后台（非交互）跑的时候不问，直接用上次的选择，免得卡在那儿等输入。
$scriptArgs = $args
$cfg = Load-Choice
$wantMenu = [Environment]::UserInteractive
if (-not $wantMenu) { Step "非交互运行：用上次选的模型" }

function Pick-Key($choices, $key, $fallback) {
    # 上次选的那个还在列表里就用它，不在了就用推荐的
    if ($key) {
        $hit = $choices | Where-Object { $_.key -eq $key } | Select-Object -First 1
        if ($hit) { return $hit.key }
    }
    return $fallback
}

if ($wantMenu) {
    Write-Host ""
    if ($cfg) {
        Write-Host "  按类型选一下这次要用哪些模型（直接回车 = 上次的选择）" -ForegroundColor Cyan
    } else {
        Write-Host "  第一次启动：先按类型选一下要用哪些模型（选完会记住）" -ForegroundColor Cyan
    }
    try { [Console]::Out.Flush() } catch {}
    $defAsr   = Pick-Key $AsrChoices   ($(if ($cfg) { $cfg.asr }   else { "" })) "small"
    $defMt    = Pick-Key $MtChoices    ($(if ($cfg) { $cfg.mt }    else { "" })) "1.8b"
    $defClone = Pick-Key $CloneChoices ($(if ($cfg) { $cfg.clone } else { "" })) "1.7b"
    $asrTitle = if (-not $senseEnabled -or $AsrScheme -eq "whisper") {
        "语音识别：选择 Whisper 档位"
    } else {
        "云端语音识别：SenseVoice 默认先出原文，选择 Whisper 校正档位"
    }
    $pickAsr   = Read-Pick $asrTitle $AsrChoices $defAsr
    $pickMt    = Read-Pick "文本翻译（Hy-MT2）"          $MtChoices    $defMt
    $pickClone = Read-Pick "声音克隆（Qwen3-TTS）"       $CloneChoices $defClone
    $cfg = @{ asr = $pickAsr.key; mt = $pickMt.key; clone = $pickClone.key }
    try {
        ($cfg | ConvertTo-Json) | Set-Content -Path $CfgFile -Encoding UTF8
    } catch {
        Step "模型选择记不下来（$CfgFile 写不了），这次用刚才选的"
    }
}
if (-not $cfg) { $cfg = @{ asr = "small"; mt = "1.8b"; clone = "1.7b" } }

# 翻译模型：不同大小用的量化不一样（30B 只有 Q4_K_M / Q8_0）
$mtChoice = $MtChoices  | Where-Object { $_.key -eq $cfg.mt }  | Select-Object -First 1
if (-not $mtChoice) { $mtChoice = $MtChoices[0] }
if ($mtChoice.key -eq "30b" -and @("Q4_K_M", "Q8_0") -notcontains $MtQuant) {
    Step "30B 模型没有 $MtQuant 这个量化版本，改用 Q4_K_M"
    $MtQuant = "Q4_K_M"
}
$MtRepo = $mtChoice.repo
$MtFile = "$($mtChoice.stem)-$MtQuant.gguf"

# 声音克隆模型
$cloneChoice = $CloneChoices | Where-Object { $_.key -eq $cfg.clone } | Select-Object -First 1
if (-not $cloneChoice) { $cloneChoice = $CloneChoices[0] }
$CloneRepo      = $cloneChoice.repo
$CloneModelFile = $cloneChoice.model
$CloneMmprojFile = $cloneChoice.mmproj

# 识别模型：环境变量优先（HEAR_ASR_MODEL），否则用刚才选的
if (-not $env:HEAR_ASR_MODEL) { $AsrModel = Pick-Key $AsrChoices $cfg.asr "small" }

trap {
    # 出错了就把临时服务也停掉，别留下一个占着 8000 端口的孤儿
    if ($tempCloud -and -not $tempCloud.HasExited) {
        try { Stop-HearOwnedProcess $tempCloud } catch {}
    }
    if ($cloud -and -not $cloud.HasExited) {
        try { Stop-HearOwnedProcess $cloud } catch {}
    }
    try { if ($OrigCodePage) { chcp $OrigCodePage > $null } } catch {}
    Write-Host ""
    Write-Host "!! 出错了：$_" -ForegroundColor Red
    Write-Host "   网络问题的话换个网络/代理再跑一次就行，已经下好的东西不会重下。" -ForegroundColor Red
    Write-Host "   也可以设 `$env:HF_ENDPOINT='https://hf-mirror.com' 用国内镜像。" -ForegroundColor Red
    exit 1
}

# Only stop instances recorded by this installation. PID alone can be reused.
$ProcessLedger = Join-Path $ServerDir ".hear-processes.json"
$OwnedProcesses = @{}
try {
    foreach ($entry in @(Get-Content -LiteralPath $ProcessLedger -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json)) {
        # v0.4.66 及更早版本偶尔会把 PowerShell 集合包装成
        # {"value":[...],"Count":...}。读取时也接受这种旧格式。
        $candidates = @($entry)
        if ($entry -and $entry.PSObject.Properties['value']) {
            $candidates += @($entry.value)
        }
        foreach ($candidate in $candidates) {
            if ($candidate -and $candidate.Id) {
                $OwnedProcesses[[string]$candidate.Id] = $candidate
            }
        }
    }
} catch { }

function Get-HearProcessIdentity($Process) {
    $startTicks = $null
    try { $startTicks = [string]$Process.StartTime.ToUniversalTime().Ticks } catch { return $null }
    $exe = ""
    $commandLine = ""
    try {
        $proc = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $Process.Id) -ErrorAction Stop
        if ($proc.ExecutablePath) { $exe = $proc.ExecutablePath }
        if ($proc.CommandLine) { $commandLine = $proc.CommandLine }
    } catch {}
    return [pscustomobject]@{
        Id = $Process.Id
        StartTicks = $startTicks
        Executable = $exe
        CommandLine = $commandLine
    }
}

function Record-HearProcess($Process) {
    $identity = Get-HearProcessIdentity $Process
    if (-not $identity) { return }
    $OwnedProcesses[[string]$identity.Id] = $identity
    $tempLedger = "$ProcessLedger.new"
    try {
        $records = [System.Collections.Generic.List[object]]::new()
        foreach ($record in $OwnedProcesses.Values) {
            if ($record -and $record.Id) { $records.Add($record) }
        }
        ConvertTo-Json -InputObject $records.ToArray() -Depth 5 -Compress |
            Set-Content -LiteralPath $tempLedger -Encoding UTF8
        Move-Item -LiteralPath $tempLedger -Destination $ProcessLedger -Force
    } catch {
        Write-Warning "Hear process ownership could not be saved."
    }
}

function Get-HearOwnershipRootId($Process) {
    $current = $Process
    for ($depth = 0; $depth -lt 12 -and $current; $depth++) {
        $currentId = [string]$current.Id
        $currentTicks = ""
        try { $currentTicks = [string]$current.StartTime.ToUniversalTime().Ticks } catch {}

        $before = $OwnedProcesses[$currentId]
        if ($before -and $currentTicks -and [string]$before.StartTicks -eq $currentTicks) {
            if ($before.Executable -and $current.Path -and $before.Executable -ne $current.Path) { return $null }
            if ($before.CommandLine -and $current.CommandLine -and $before.CommandLine -cne $current.CommandLine) { return $null }
            return $currentId
        }

        $parentId = $null
        try {
            $cim = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $current.Id) -ErrorAction Stop
            if ($cim.ParentProcessId) { $parentId = [string]$cim.ParentProcessId }
        } catch {}
        if (-not $parentId -or $parentId -eq $currentId) { break }

        $parentRecord = $OwnedProcesses[$parentId]
        if ($parentRecord -and $currentTicks) {
            # Windows 的 venv python.exe 会再启动一个解释器子进程。
            # 即使父进程已经先退出，只要子进程创建时间晚于记录中的父进程，
            # 仍可确认它是这次 Hear 启动产生的进程树。
            try {
                if ([Int64]$currentTicks -ge [Int64]$parentRecord.StartTicks) { return $parentId }
            } catch {}
        }
        $current = Get-Process -Id ([int]$parentId) -ErrorAction SilentlyContinue
    }
    return $null
}

function Stop-HearProcessTreeById($ProcessId) {
    if (-not $ProcessId) { return }
    try { & taskkill.exe /PID ([string]$ProcessId) /T /F 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 300
    if (Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue) {
        try { Stop-Process -Id ([int]$ProcessId) -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Stop-HearOwnedProcess($Process) {
    if (-not $Process) { return }
    $rootId = Get-HearOwnershipRootId $Process
    if ($rootId) { Stop-HearProcessTreeById $rootId }
    if (Get-Process -Id $Process.Id -ErrorAction SilentlyContinue) {
        Stop-HearProcessTreeById $Process.Id
    }
}

# 云端服务依赖的模块缺一个就起不来。旧版 start-hear-cloud.bat 的下载清单里没有新模块，
# 会出现"hear_cloud.py 是新的、hear_auth.py 不存在"的情况，这里提前说清楚。
$missingModules = @(@("hear_cloud.py", "hear_auth.py", "hear_http.py", "hear_speaker.py") |
    Where-Object { -not (Test-Path -LiteralPath (Join-Path $ServerDir $_)) })
if ($missingModules.Count -gt 0) {
    Write-Host "!! server 文件夹里缺少：$($missingModules -join '、')" -ForegroundColor Red
    Write-Host "   多半是用了旧版 start-hear-cloud.bat。请从仓库根目录拿最新的 start-hear-cloud.bat 替换旧的，" -ForegroundColor Red
    Write-Host "   或者在仓库目录执行 git pull，然后再启动一次。" -ForegroundColor Red
    exit 1
}

# 让所有服务子进程成为同一个 Windows Job 的成员。BAT 窗口被关闭、
# PowerShell 被强制结束时，系统会关闭 Job 句柄并连带结束整棵进程树。
if (-not ("Hear.KillJob" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace Hear {
    public static class KillJob {
        [StructLayout(LayoutKind.Sequential)]
        struct IO_COUNTERS {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr CreateJobObject(IntPtr security, string name);

        [DllImport("kernel32.dll")]
        static extern bool SetInformationJobObject(
            IntPtr job, int infoClass, IntPtr info, uint length);

        [DllImport("kernel32.dll")]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        public static IntPtr CreateKillOnClose() {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) return IntPtr.Zero;
            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = 0x2000;
            int length = Marshal.SizeOf(info);
            IntPtr buffer = Marshal.AllocHGlobal(length);
            try {
                Marshal.StructureToPtr(info, buffer, false);
                if (!SetInformationJobObject(job, 9, buffer, (uint)length)) return IntPtr.Zero;
                return job;
            } finally {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public static bool Attach(IntPtr job, IntPtr process) {
            return job != IntPtr.Zero && AssignProcessToJobObject(job, process);
        }
    }
}
"@
}
$HearJob = [Hear.KillJob]::CreateKillOnClose()
function Add-ProcessToHearJob($Process) {
    if (-not $Process -or -not $HearJob) { return }
    try {
        $Process.Refresh()
        if ($Process.HasExited) { return }
        if (-not [Hear.KillJob]::Attach($HearJob, $Process.Handle)) {
            Write-Warning "Hear 进程没有加入自动清理组，退出窗口后可能需要手动结束。"
        }
    } catch {
        Write-Warning "Hear 进程自动清理组设置失败：$($_.Exception.Message)"
    }
}

# 列出网卡（WLAN / 以太网）各自的 IP，让用户挑一个填到手机里。
# 不能随便取第一个：VPN、虚拟网卡、WSL 的地址都可能出现，手机连不上。
# 模型端口（8081 / 8082）默认只让本机访问：
# 手机是通过总服务（8000）用这两个后端的，没必要把它们暴露到局域网。
# 确实需要直连（比如想在别的机器上单独调模型）时，
# 设环境变量 HEAR_OPEN_MODEL_PORTS=1 再启动。
$OpenModelPorts = ($env:HEAR_OPEN_MODEL_PORTS -eq "1")
# 防火墙的网络类型：默认只放行「专用网络」。
# 家里的 Wi-Fi 如果被 Windows 标成「公用网络」，手机就连不上——
# 那就把网络类型改成「专用网络」，或者设 HEAR_FIREWALL_PROFILE=Any。
$FirewallProfile = if ($env:HEAR_FIREWALL_PROFILE) { $env:HEAR_FIREWALL_PROFILE } else { "Private" }

function Ensure-FirewallRule($ports) {
    # 防火墙：手机连不上 8000，多半是 Windows 防火墙拦了入站。
    # 管理员权限的话直接建好规则；不是管理员就把命令打印出来（复制到管理员 PowerShell 里跑一次就行）。
    $isAdmin = $false
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $isAdmin = $false }

    $ruleName = "Hear Cloud"
    if ($isAdmin) {
        try {
            Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
                Remove-NetFirewallRule -ErrorAction SilentlyContinue
            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound `
                -LocalPort $ports -Protocol TCP -Action Allow -Profile $FirewallProfile | Out-Null
            Write-Host "  防火墙已放行 $($ports -join ', ')（网络类型：$FirewallProfile）" -ForegroundColor Green
            # 公用网络下手机可能连不上：说清楚怎么改
            try {
                $pub = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue |
                         Where-Object { $_.NetworkCategory -eq "Public" })
                if ($pub.Count -gt 0) {
                    Write-Host "  注意：现在有网卡被 Windows 标成「公用网络」，手机可能连不上。" -ForegroundColor Yellow
                    Write-Host "        改成「专用网络」：设置 → 网络和 Internet → Wi-Fi → 属性 → 网络配置文件 → 专用" -ForegroundColor Yellow
                    Write-Host "        （确实要用公用网络的话，设 HEAR_FIREWALL_PROFILE=Any 再启动）" -ForegroundColor DarkGray
                }
            } catch {}
            return
        } catch {
            Write-Host "  防火墙规则没建成：$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    Write-Host "  防火墙放行：用【管理员】PowerShell 执行一次下面这行就行" -ForegroundColor Yellow
    Write-Host "      New-NetFirewallRule -DisplayName `"Hear Cloud`" -Direction Inbound -LocalPort $($ports -join ',') -Protocol TCP -Action Allow -Profile $FirewallProfile" -ForegroundColor Yellow
    Write-Host ""
}


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
            Write-Host ("      {0}. {1,-8} {2}   https://{3}:{4}" -f $i, $c.Kind, $c.Name, $c.IP, $port) -ForegroundColor Green
            $i++
        }
        Write-Host ""
        Write-Host "  三个模型用同一个通用服务地址就行（它会自己转发给翻译 / 克隆）：" -ForegroundColor DarkGray
        Write-Host "      通用服务地址 = 上面的 https://电脑IP:8000" -ForegroundColor DarkGray
        Write-Host "      （只填电脑IP:8000 也行，App 会自己补上 https://）" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  想单独连某个模型服务（一般不用，直接走 HTTP）：" -ForegroundColor DarkGray
        foreach ($c in $choices) {
            Write-Host ("      http://{0}:{1}  翻译模型      http://{0}:{2}  克隆模型" -f $c.IP, $script:MtPort, $script:ClonePort) -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "  （手机和电脑要连同一个 Wi-Fi）" -ForegroundColor DarkGray
    }
    Write-Host ""
}


Say "仓库目录：$RepoRoot"
Say "模型目录：$ModelDir"

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

# 问 llama-server 有哪些显卡设备可用。
# 它的 --device 要写它自己报出来的名字（"Vulkan0"、"CUDA0" 这种），
# 写 "Vulkan" 它不认，会直接报 "invalid device: Vulkan" 然后退出。
function Get-GpuDevice($exe) {
    if (-not $exe) { return $null }
    $out = ""
    $old = $ErrorActionPreference
    try {
        # llama-server 往 stderr 写东西时 PowerShell 会当成错误，
        # 这里临时改成 Continue，不然会被 $ErrorActionPreference = Stop 打断
        $ErrorActionPreference = "Continue"
        $out = (& $exe --list-devices 2>&1 | Out-String)
    } catch {
        $out = ""
    } finally {
        $ErrorActionPreference = $old
    }
    $names = @()
    foreach ($line in ($out -split "`r?`n")) {
        # 设备行长这样："  Vulkan0: NVIDIA GeForce RTX 4090 (24564 MiB, ...)"
        if ($line -match '^\s*((?:Vulkan|CUDA|ROCm|HIP|SYCL|OpenCL|Metal)\d*):') { $names += $Matches[1] }
    }
    $names = @($names | Where-Object { $_ -ne "CPU" -and $_ -ne "" })
    if ($names.Count -eq 0) { return $null }
    # 优先 Vulkan（N 卡 / AMD / Intel 都能用），其次 CUDA
    $v = $names | Where-Object { $_ -like "Vulkan*" } | Select-Object -First 1
    if ($v) { return $v }
    $c = $names | Where-Object { $_ -like "CUDA*" } | Select-Object -First 1
    if ($c) { return $c }
    return ($names | Select-Object -First 1)
}

# ---------------------------------------------------------------- Python（识别模型）
function Find-Python {
    $bundled = Join-Path $ServerDir "runtime\python.exe"
    if (Test-Path -LiteralPath $bundled) { return $bundled }
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

function Clear-HearPorts {
    foreach ($p in @($Port, $MtPort, $ClonePort)) {
        $busy = @(Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)
        if ($busy.Count -eq 0) { continue }

        $owners = @($busy | ForEach-Object { [int]$_.OwningProcess } | Sort-Object -Unique)
        foreach ($ownerId in $owners) {
            $owner = Get-Process -Id $ownerId -ErrorAction SilentlyContinue
            if (-not $owner) { continue }

            $rootId = Get-HearOwnershipRootId $owner
            if ($rootId) {
                Step "停止上次未退出的 Hear 服务（监听 PID $ownerId，进程树 PID $rootId）"
                Stop-HearOwnedProcess $owner
                continue
            }

            $details = $null
            try {
                $details = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $ownerId) -ErrorAction Stop
            } catch {}
            Write-Host ""
            Write-Host "!! 端口 $p 被其他程序占着：$($owner.ProcessName)（PID $ownerId）" -ForegroundColor Yellow
            if ($details -and $details.ExecutablePath) {
                Write-Host "   程序：$($details.ExecutablePath)" -ForegroundColor Yellow
            }
            if ($details -and $details.CommandLine) {
                Write-Host "   命令：$($details.CommandLine)" -ForegroundColor DarkGray
            }
            Write-Host "   这不是本工程记录的 Hear 进程，脚本不会误杀它。" -ForegroundColor Yellow
            Write-Host "   可以关闭该程序后重试，或换端口运行：" -ForegroundColor Yellow
            Write-Host "   set HEAR_PORT=8010 && set HEAR_MT_PORT=8091 && set HEAR_CLONE_PORT=8092" -ForegroundColor Yellow
            throw "端口 $p 被其他程序占用"
        }

        for ($i = 0; $i -lt 30; $i++) {
            if (-not (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 200
        }
        if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) {
            throw "端口 $p 仍被占用，未能结束旧 Hear 进程"
        }
    }
}

# ---------------------------------------------------------------- Cloudflare Tunnel
# cloudflared 把公网 HTTPS 转成本机的 http://127.0.0.1:8000 回源时，网关看到的是明文 HTTP，
# 带口令的推理会被拒（HTTPS_REQUIRED）。检测到本机在跑 cloudflared、并且口令校验是开着的，
# 就只放行"来自本机 127.0.0.1 / ::1 的明文连接"，口令照样要校验；局域网明文仍然拒绝。
# 不想要的话设 HEAR_ALLOW_LOOPBACK_HTTP=0。
if (-not $env:HEAR_ALLOW_LOOPBACK_HTTP -and
    ($env:HEAR_AUTH_MODE -eq "managed" -or $env:HEAR_REQUIRE_TOKEN -eq "1") -and
    (Get-Process -Name cloudflared -ErrorAction SilentlyContinue)) {
    $env:HEAR_ALLOW_LOOPBACK_HTTP = "1"
    Say "检测到 cloudflared：允许 Tunnel 从本机用 HTTP 回源（仍然校验口令）"
}

# ---------------------------------------------------------------- 先起个临时服务
# hear_cloud.py 只用标准库就能跑（识别模型是懒加载的），
# 所以先用系统 Python 把它起起来，几秒钟后就能在手机浏览器上测网络了，
# 不用等 llama.cpp 和几个 G 的模型下完。
Clear-HearPorts
$cloudScript = Join-Path $ServerDir "hear_cloud.py"
$tempCloud = $null
$py0 = Find-Python
if ($py0) {
    $env:HEAR_PORT = $Port
    $env:HEAR_MT_URL = "http://127.0.0.1:$MtPort"
    $env:HEAR_CLONE_URL = "http://127.0.0.1:$ClonePort"
    $env:HEAR_ASR_MODEL = $AsrModel
$env:HEAR_ASR_SCHEME = $AsrScheme
$env:HEAR_SENSEVOICE_DIR = $SvDir
    try {
        $tempCloud = Start-Process -FilePath $py0 -ArgumentList "`"$cloudScript`"" `
                        -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $ServerDir "cloud.log") `
                        -RedirectStandardError (Join-Path $ServerDir "cloud.log.err")
        Add-ProcessToHearJob $tempCloud
        Record-HearProcess $tempCloud
        Start-Sleep -Seconds 2
        Say "临时服务已启动（端口 $Port），现在就能在手机浏览器上测网络"
        Write-Host "    电脑浏览器： https://127.0.0.1:$Port/" -ForegroundColor Cyan
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

# 缺哪个补哪个：
# 之前是"只要找到一个 llama-server.exe 就不下了"，所以先跑过 CPU 模式的话，
# 后面想用显卡也永远没有 Vulkan 那个版本。
$want = @()
if ($needVulk -and -not (Find-Exe "llama-server.exe" "win-vulkan")) {
    $want += "llama-$LlamaTag-bin-win-vulkan-x64.zip"
}
if ($needOv -and -not (Find-Exe "llama-server.exe" "win-openvino")) {
    $want += "llama-$LlamaTag-bin-win-openvino-*.zip"
}
if (-not (Find-Exe "llama-server.exe" "win-cpu")) {
    $want += "llama-$LlamaTag-bin-win-cpu-x64.zip"
}
if ($want.Count -gt 0) {
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
        # GitHub 打不开的话换代理再试（保留完整原始 URL）
        $mirrors = @($url)
        if ($url -like "https://github.com/*") {
            $mirrors += "https://gh-proxy.com/$url"
            $mirrors += "https://ghproxy.net/$url"
        }
        Get-File $mirrors $zip | Out-Null
        Say "解压 $name"
        Expand-Zip $zip (Join-Path $BinDir ([IO.Path]::GetFileNameWithoutExtension($name)))
    }
}
if (-not (Find-Exe "llama-server.exe" "")) { Die "没找到 llama-server.exe" }

$bundledPy = Join-Path $ServerDir "runtime\python.exe"
if (Test-Path -LiteralPath $bundledPy) {
    $venvPy = $bundledPy
    Say "使用安装包内置 Python 运行时（已预装 faster-whisper / sherpa-onnx / cryptography）"
} else {
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
    $reqFile = Join-Path $ServerDir "requirements.txt"
    $reqStamp = Join-Path $venvDir ".requirements.sha256"
    $reqHash = ""
    if (Test-Path -LiteralPath $reqFile) {
        try { $reqHash = (Get-FileHash -LiteralPath $reqFile -Algorithm SHA256).Hash } catch { $reqHash = "" }
    }
    $savedHash = if (Test-Path -LiteralPath $reqStamp) {
        (Get-Content -LiteralPath $reqStamp -Raw -ErrorAction SilentlyContinue).Trim()
    } else { "" }
    if ($reqHash -and $savedHash -eq $reqHash) {
        Step "Python 依赖未变化，跳过 pip 安装（离线也能秒起）"
    } else {
        & $venvPy -m pip install --upgrade pip --quiet
        if ($LASTEXITCODE -ne 0) { Say "pip 升级失败，先用现有的 pip 继续" }
        & $venvPy -m pip install -r $reqFile --quiet
        if ($LASTEXITCODE -ne 0) {
            Say "faster-whisper 没装上，语音识别会不可用（翻译和克隆不受影响）"
            Step "手动装：& `"$venvPy`" -m pip install -r requirements.txt"
        } elseif ($reqHash -and (Test-Path -LiteralPath $venvDir)) {
            Set-Content -LiteralPath $reqStamp -Value $reqHash -Encoding ASCII -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------- 云端服务（先起）
# 模型还要下十几分钟，先把 8000 端口的服务起起来：
# 这样手机马上就能连上来测试网络了（翻译和克隆要等模型下完才可用）。
$env:HEAR_PORT = $Port
$env:HEAR_MT_URL = "http://127.0.0.1:$MtPort"
$env:HEAR_CLONE_URL = "http://127.0.0.1:$ClonePort"
$env:HEAR_ASR_MODEL = $AsrModel
$cloudScript = Join-Path $ServerDir "hear_cloud.py"
# 正式服务启动前再清一次：临时服务是 venv 之前的 Python，
# 正式服务必须由 venv Python 接管 8000。三个端口都检查，
# 避免旧翻译 / 克隆服务留在 8081 / 8082 上接通错误的实例。
Clear-HearPorts
if ($tempCloud -and -not $tempCloud.HasExited) {
    try { Stop-HearOwnedProcess $tempCloud } catch {}
}
# 自签证书：App 只走 https，没有证书手机就连不上，
# 所以这一步要看得见，失败了要马上说清楚（私钥只留在本机，不进仓库）
# 证书：服务启动时如果没有会自己生成一份（hear_cloud.py 里 ensure_cert），
# 这里只是提前生成，好让用户早点看到结果。
$certFile = Join-Path $ServerDir "certs\cert.pem"
$certScript = Join-Path $ServerDir "make_cert.py"
if (-not (Test-Path $certFile)) {
    Write-Host ""
    Say "生成自签证书（手机要用 https 连）"
    if (Test-Path $certScript) {
        & $venvPy $certScript
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $certFile)) {
            Write-Host ""
            Write-Host "!! 证书没生成成，手机（App 只走 https）就连不上" -ForegroundColor Red
            Write-Host "   原因多半是缺 cryptography 这个包，手动装一次：& `"$venvPy`" -m pip install cryptography" -ForegroundColor Red
            Write-Host "   装完再跑一次本文件就行。" -ForegroundColor Red
            Write-Host ""
        }
    } else {
        Step "没有 make_cert.py，服务启动时会自己生成证书"
    }
} else {
    Step "已有证书 certs\cert.pem"
}

function Get-HearHealth {
    try {
        $json = & curl.exe -s -k --max-time 5 "https://127.0.0.1:$Port/health"
        if ($LASTEXITCODE -eq 0 -and $json) { return ($json | ConvertFrom-Json) }
    } catch { }
    return $null
}

# 口令管理模式：网关自己拉取口令清单，这里只轮询本机 /health，等 auth_ready=true。
# 清单没加载好时网关照常运行，但所有推理请求都返回 503（不会退回无口令）。
function Wait-AuthReady($seconds) {
    if ($env:HEAR_AUTH_MODE -ne "managed") { return $true }
    Say "等待口令清单加载（网关 $($env:HEAR_GATEWAY_ID)）"
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $cloud.Refresh()
        if ($cloud.HasExited) {
            Die "云端服务退出了（退出码 $($cloud.ExitCode)）：多半是口令管理配置不对，看上面的报错"
        }
        $h = Get-HearHealth
        if ($h -and $h.auth_mode -eq "managed" -and $h.auth_ready -eq $true) {
            Say "口令服务已就绪：只接受管理后台签发的 Token"
            return $true
        }
        Start-Sleep -Seconds 1
    }
    Write-Host "!! 口令服务 $seconds 秒内没有就绪：网关已启动，但推理请求会返回 503，直到清单同步成功。" -ForegroundColor Red
    Write-Host "   检查 HEAR_AUTH_API_URL（$($env:HEAR_AUTH_API_URL)）能否访问、网关凭据是否正确；网关每 5 秒自动重试。" -ForegroundColor Red
    return $false
}

$cloud = Start-Process -FilePath $venvPy -ArgumentList "`"$cloudScript`"" `
            -PassThru -NoNewWindow
Add-ProcessToHearJob $cloud
Record-HearProcess $cloud
Start-Sleep -Seconds 3
$cloud.Refresh()
if ($cloud.HasExited) {
    Die "云端服务刚启动就退出了（退出码 $($cloud.ExitCode)），原因看上面的报错"
}
Say "云端服务已启动（端口 $Port），模型还在准备中"
Write-Host "    电脑浏览器打开 https://127.0.0.1:$Port/ 看看服务在不在（自签证书，浏览器会提示不安全，点继续就行）" -ForegroundColor Cyan
Write-Host "    手机浏览器打开下面打印的地址，能打开就说明手机到电脑是通的" -ForegroundColor Cyan
Show-LanInfo $Port
[void](Wait-AuthReady 45)

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
# SenseVoice（云端识别的"快"方案用；约 230 MB）
if ($env:HEAR_SENSEVOICE -eq "0") {
    Step "已通过 HEAR_SENSEVOICE 关闭 SenseVoice"
}
elseif (-not (Test-Path (Join-Path $SvDir "model.int8.onnx")) -or
        -not (Test-Path (Join-Path $SvDir "tokens.txt"))) {
    Say "下载 SenseVoice 模型（云端识别的快速方案）"
    New-Item -ItemType Directory -Force -Path $SvDir | Out-Null
    $svRepo = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
    Get-Model $svRepo "model.int8.onnx" | Out-Null
    Get-Model $svRepo "tokens.txt" | Out-Null
    # Get-Model 存到 ModelDir 根目录，挪到 sensevoice 子目录去
    foreach ($n in @("model.int8.onnx", "tokens.txt")) {
        $src = Join-Path $ModelDir $n
        if (Test-Path $src) { Move-Item $src (Join-Path $SvDir $n) -Force }
    }
}
else { Step "已有 SenseVoice 模型" }

$speakerName = "3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"
$speakerFile = Join-Path $ModelDir $speakerName
if (-not (Test-Path -LiteralPath $speakerFile -PathType Leaf)) {
    $speakerDownload = Join-Path $ModelDir "$speakerName.unverified"
    $speakerURL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/$speakerName"
    try {
        Say "准备实时翻译的说话人区分模型（约 28 MB）"
        Get-File $speakerURL $speakerDownload | Out-Null
        $speakerHash = "e6af4d4c444f3dab01d991bb9b7d5af98eb979e329f6c8880a19d5553561ed25"
        if ((Get-FileHash -LiteralPath $speakerDownload -Algorithm SHA256).Hash -ne $speakerHash) {
            throw "下载文件校验失败"
        }
        Move-Item -LiteralPath $speakerDownload -Destination $speakerFile -Force
    } catch {
        Step "暂时无法安装说话人区分模型，实时识别和翻译仍可用"
    } finally {
        Remove-Item -LiteralPath $speakerDownload -ErrorAction SilentlyContinue
    }
}

Say "下载翻译模型（$MtRepo / $MtFile）"
Get-Model $MtRepo $MtFile | Out-Null
Say "下载声音克隆模型（$CloneRepo / $CloneModelFile）"
Get-Model $CloneRepo $CloneModelFile | Out-Null
Get-Model $CloneRepo $CloneMmprojFile | Out-Null

# ---------------------------------------------------------------- 起服务
# 先问清楚这个 llama-server 认得的显卡设备名（"Vulkan0"、"CUDA0"……）
$gpuDevice = $null
$gpuServer = $null
if ($MtDevice -eq "GPU" -or $CloneDevice -eq "GPU") {
    # 候选：Vulkan 版本（兼容性最好），还有本机已经有的 CUDA 版本
    foreach ($cand in @((Server-For "GPU"), (Find-Exe "llama-server.exe" "win-cuda"))) {
        if (-not $cand) { continue }
        $d = Get-GpuDevice $cand
        if ($d) { $gpuDevice = $d; $gpuServer = $cand; break }
    }
    if ($gpuDevice) {
        Say "GPU 设备：$gpuDevice"
    } else {
        Step "llama-server 没认到显卡设备（显卡驱动不支持 Vulkan？），这次用 CPU"
        Write-Host "      N 卡也可以试试：装好 CUDA 驱动后再跑一次" -ForegroundColor DarkGray
    }
}
# 没认到显卡就老实用 CPU，别再传 --device 让它报错退出
if ($MtDevice    -eq "GPU" -and -not $gpuDevice) { $MtDevice    = "CPU" }
if ($CloneDevice -eq "GPU" -and -not $gpuDevice) { $CloneDevice = "CPU" }

$mtServer    = if ($MtDevice    -eq "GPU") { $gpuServer } else { Server-For $MtDevice }
$cloneServer = if ($CloneDevice -eq "GPU") { $gpuServer } else { Server-For $CloneDevice }
if (-not $mtServer)    { $mtServer = Server-For "CPU"; $MtDevice = "CPU" }
if (-not $mtServer)    { Die "没找到 llama-server.exe" }
if (-not $cloneServer) { $cloneServer = Server-For "CPU" }
if (-not $cloneServer) { Die "没找到 llama-server.exe" }
$procs = @()

# 模型端口默认只监听 127.0.0.1：手机是通过总服务（$Port）用这两个后端的，
# 把模型端口暴露到局域网没有好处（谁都能来连）。
# 确实需要直连时设 HEAR_OPEN_MODEL_PORTS=1。
$ModelHost = if ($OpenModelPorts) { "0.0.0.0" } else { "127.0.0.1" }
$mtArgs = @("-m", (Quote-Arg (Join-Path $ModelDir $MtFile)),
             "--host", $ModelHost, "--port", $MtPort, "-c", $Context, "--no-warmup")
if ($MtDevice -eq "NPU") {
    # OpenVINO 后端：NPU 只支持无状态执行，-np 只能是 1，-c 必须明确给
    $env:GGML_OPENVINO_DEVICE = "NPU"
    $env:GGML_OPENVINO_CACHE_DIR = Join-Path $BinDir "ov_cache"
    $mtArgs += "-np", "1"
} elseif ($MtDevice -eq "GPU") {
    # 设备名要用 llama-server 自己报的那个（"Vulkan0" 这种）
    $mtArgs += "--device", $gpuDevice
}

Say "起翻译模型（$MtFile，后端 $MtDevice，端口 $MtPort）"
$mtLog = Join-Path $ServerDir "mt.log"
$mt = Start-Process -FilePath $mtServer -ArgumentList $mtArgs -PassThru -NoNewWindow `
        -RedirectStandardOutput $mtLog -RedirectStandardError "$mtLog.err"
$procs += $mt
Add-ProcessToHearJob $mt
Record-HearProcess $mt
$cloneArgs = @("-m", (Quote-Arg (Join-Path $ModelDir $CloneModelFile)),
                "--mmproj", (Quote-Arg (Join-Path $ModelDir $CloneMmprojFile)),
                "--host", $ModelHost, "--port", $ClonePort, "-c", $Context, "--no-warmup")
if ($CloneDevice -eq "GPU") { $cloneArgs += "--device", $gpuDevice }

Say "起声音克隆模型（$CloneModelFile，后端 $CloneDevice，端口 $ClonePort）"
$cloneLog = Join-Path $ServerDir "clone.log"
$clone = Start-Process -FilePath $cloneServer -ArgumentList $cloneArgs -PassThru -NoNewWindow `
            -RedirectStandardOutput $cloneLog -RedirectStandardError "$cloneLog.err"
$procs += $clone
Add-ProcessToHearJob $clone
Record-HearProcess $clone
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
    try { Stop-HearOwnedProcess $mt } catch {}
    Start-Sleep -Seconds 2
    $cpuMt = Server-For "CPU"
    if ($cpuMt) {
        $cpuArgs = @("-m", (Quote-Arg (Join-Path $ModelDir $MtFile)),
                     "--host", $ModelHost, "--port", $MtPort, "-c", $Context, "--no-warmup")
        $mt = Start-Process -FilePath $cpuMt -ArgumentList $cpuArgs -PassThru -NoNewWindow `
                -RedirectStandardOutput $mtLog -RedirectStandardError "$mtLog.err"
        $procs += $mt
        Add-ProcessToHearJob $mt
        Record-HearProcess $mt
        $mtOk = Wait-Health "http://127.0.0.1:$MtPort" "翻译模型（CPU）" "mt.log" $mt
    }
}
$cloneOk = Wait-Health "http://127.0.0.1:$ClonePort" "声音克隆模型" "clone.log" $clone
if (-not $cloneOk -and $CloneDevice -ne "CPU") {
    Say "$CloneDevice 后端没起来，改用 CPU 跑声音克隆模型"
    try { Stop-HearOwnedProcess $clone } catch {}
    Start-Sleep -Seconds 2
    $cpuClone = Server-For "CPU"
    if ($cpuClone) {
        $cpuArgs = @("-m", (Quote-Arg (Join-Path $ModelDir $CloneModelFile)),
                     "--mmproj", (Quote-Arg (Join-Path $ModelDir $CloneMmprojFile)),
                     "--host", $ModelHost, "--port", $ClonePort, "-c", $Context, "--no-warmup")
        $clone = Start-Process -FilePath $cpuClone -ArgumentList $cpuArgs -PassThru -NoNewWindow `
                -RedirectStandardOutput $cloneLog -RedirectStandardError "$cloneLog.err"
        $procs += $clone
        Add-ProcessToHearJob $clone
        Record-HearProcess $clone
        $cloneOk = Wait-Health "http://127.0.0.1:$ClonePort" "声音克隆模型（CPU）" "clone.log" $clone
    }
}

$env:HEAR_PORT = $Port
$env:HEAR_MT_URL = "http://127.0.0.1:$MtPort"
$env:HEAR_CLONE_URL = "http://127.0.0.1:$ClonePort"
$env:HEAR_ASR_MODEL = $AsrModel

Show-LanInfo $Port
Write-Host ""
# 防火墙只放行总服务端口：模型端口只在本机用，不需要暴露到局域网
if ($OpenModelPorts) {
    Ensure-FirewallRule @($Port, $MtPort, $ClonePort)
    Write-Host "  （按你的要求，模型端口也开放了）" -ForegroundColor DarkGray
} else {
    Ensure-FirewallRule @($Port)
    Write-Host "  模型端口（$MtPort / $ClonePort）只在这台电脑上用，手机是通过 $Port 访问它们的。" -ForegroundColor DarkGray
    Write-Host "  确实需要直连的话，设 HEAR_OPEN_MODEL_PORTS=1 再启动。" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "  关掉这个窗口就等于关掉服务。"
Write-Host "  （日志文件是 UTF-8 编码，换个窗口看中文乱码的话先执行 chcp 65001）" -ForegroundColor DarkGray
Write-Host ""

# 问总服务要真实状态：三个接口到底哪几个能用（不能一口咬定"都能用"）
$asrTxt = "未知"; $mtTxt = "未知"; $cloneTxt = "未知"
$authModeNow = $null; $authReadyNow = $false
try {
    $json = & curl.exe -s -k --max-time 15 "https://127.0.0.1:$Port/health"
    if ($json) {
        $o = $json | ConvertFrom-Json
        if ($o.asr)   { $asrTxt   = "$($o.asr)" }
        if ($o.mt)    { $mtTxt    = "$($o.mt)" }
        if ($o.clone) { $cloneTxt = "$($o.clone)" }
        # 新服务直接给布尔值（不用去猜文字）
        if ($null -ne $o.asr_ready)   { $asrOk       = [bool]$o.asr_ready }
        if ($null -ne $o.mt_ready)    { $mtOkNow     = [bool]$o.mt_ready }
        if ($null -ne $o.clone_ready) { $cloneOkNow  = [bool]$o.clone_ready }
        if ($null -ne $o.auth_mode)   { $authModeNow = "$($o.auth_mode)"; $authReadyNow = [bool]$o.auth_ready }
    }
} catch { }
# 老服务没有布尔字段，才退回看文字（"外部服务连不上"不能算就绪）
if (-not $asrOk) {
    $asrOk = $asrTxt.StartsWith("就绪") -or ($asrTxt.StartsWith("外部服务") -and -not $asrTxt.Contains("连不上"))
}
if (-not $mtOkNow)    { $mtOkNow    = $mtTxt.StartsWith("就绪") }
if (-not $cloneOkNow) { $cloneOkNow = $cloneTxt.StartsWith("就绪") }
if ($asrOk -and $mtOkNow -and $cloneOkNow) {
    Write-Host "  模型都准备好了：识别 / 翻译 / 克隆三个接口现在都能用。" -ForegroundColor Green
} else {
    Write-Host "  还没全部准备好（下面写着每一项现在的状态）：" -ForegroundColor Yellow
    Write-Host "    识别：$asrTxt" -ForegroundColor DarkGray
    Write-Host "    翻译：$mtTxt" -ForegroundColor DarkGray
    Write-Host "    克隆：$cloneTxt" -ForegroundColor DarkGray
    Write-Host "    识别模型第一次要现下（几百 MB），下完自己就好了，不用重跑。" -ForegroundColor DarkGray
    Write-Host "    翻译/克隆起不来的话看 server\mt.log 和 server\clone.log。" -ForegroundColor DarkGray
}
if ($authModeNow -eq "managed") {
    if ($authReadyNow) {
        Write-Host "  口令服务：管理模式已就绪（网关 $($env:HEAR_GATEWAY_ID)）。" -ForegroundColor Green
    } else {
        Write-Host "  口令服务：管理模式未就绪，推理请求会返回 503；同步恢复后自动可用。" -ForegroundColor Red
    }
    Write-Host "    检查某个口令：start-hear-cloud.bat --check-token" -ForegroundColor DarkGray
} elseif ($authModeNow -eq "legacy") {
    Write-Host "  访问口令：旧的单口令方式（certs\access-token.txt）。" -ForegroundColor DarkGray
} elseif ($authModeNow -eq "off") {
    Write-Host "  访问口令：本次未启用。" -ForegroundColor Yellow
}
Write-Host ""

# 在服务运行期间保持 UTF-8 代码页避免中文日志乱码，仅在退出前还原原代码页（.bat 后续用 GBK）
try {
    if ($cloud) {
        if ($cloud.HasExited) {
            Write-Host "!! 云端服务退出了（退出码 $($cloud.ExitCode)），原因看上面的红色报错。" -ForegroundColor Red
            # 退出码非 0，BAT 窗口才会停住等你看报错，不会一闪就关
            exit 1
        }
        else {
            Wait-Process -Id $cloud.Id
            $cloud.Refresh()
            if ($cloud.ExitCode -ne 0) {
                Write-Host "!! 云端服务退出了（退出码 $($cloud.ExitCode)），原因看上面的红色报错。" -ForegroundColor Red
                exit 1
            }
        }
    }
} finally {
    try { if ($OrigCodePage) { chcp $OrigCodePage > $null } } catch {}
}
