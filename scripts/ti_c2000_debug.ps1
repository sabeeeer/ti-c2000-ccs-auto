#requires -Version 7.0
# =====================================================================
# ti_c2000_debug.ps1
#   Execution workflow only: build / load / run with TI C2000 in CCS.
#   There is deliberately no read mode here. A separately started read
#   session cannot prove it is looking at the RAM image this script just
#   loaded; reading belongs to ti_c2000_run_read.ps1 / ti_c2000_read_dma.ps1,
#   which keep one DSS session from load to read.
#
#   - auto-detects the CCS installation (registry / C:\ti / %USERPROFILE%\ti)
#   - detects the XDS probe and fails fast & clearly when the board is absent
#   - load/run through loadti.bat
#
#   Usage:
#     ... ti_c2000_debug.ps1 -ProjectPath <proj> -Build -Run
#     ... ti_c2000_debug.ps1 -ProjectPath <proj> -Build -LoadOnly
#     ... -CcsRoot D:\path\to\ccs         force a CCS installation
#   Exit code: 0 OK | 1 failure | 2 environment/toolchain problem | 3 no probe
# =====================================================================
param(
    [string]$ProjectPath = "",
    [string]$CcsRoot     = "",
    [string]$Ccxml       = "",
    [string]$OutFile     = "",
    [switch]$Build,
    [switch]$AllowCompilerFallback,
    [switch]$Run,
    [switch]$LoadOnly,
    [switch]$ConfirmLoad,
    [switch]$ProbeCheckOnly,
    # With -ProbeCheckOnly: also let DSS open the probe (connect -> isConnected -> disconnect,
    # never loads). This is the only openability check that holds for EVERY probe type
    # (XDS100/110/200/560v2/on-board), because it uses the same code path a download does.
    [switch]$Deep,
    # Physical probe serial; empty = resolve from env / probe-serial.txt / xds100serial.
    [string]$ProbeSerial = '',
    [switch]$NoProbeCheck,
    [int]$TimeoutSec     = 180,
    [switch]$Quiet,
    [switch]$Background,
    [string]$LogFile     = "",
    [switch]$Detached
)
$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }
. (Join-Path $PSScriptRoot 'ti_c2000_readmode.ps1')
Out2 ('SKILL   : ti-c2000-ccs-auto@' + (Get-SkillIdentity).version)

# A stale caller may still pass -ReadOnly/-ReadVars/-ReadArray/-WaitFor. Under
# `pwsh -File` those do not fail binding; they land in $args. Say so explicitly
# instead of silently building or loading nothing.
if ($args.Count -gt 0) {
    Out2 'USAGE: UNKNOWN_ARGUMENT'
    Out2 'RESULT: FAIL'
    Out2 ('REASON: unrecognized argument(s): ' + ($args -join ' ') + ' - the read-only switches were removed; read with ti_c2000_run_read.ps1 or ti_c2000_read_dma.ps1')
    exit 2
}
# Reject incompatible arguments before a background process, build or loader
# can start. This script never reads values back.
if ($ProbeCheckOnly -and ($Build -or $AllowCompilerFallback -or $Run -or $LoadOnly -or $NoProbeCheck -or $ConfirmLoad)) {
    Out2 "USAGE: MODE_CONFLICT"
    Out2 "RESULT: FAIL"
    Out2 "REASON: -ProbeCheckOnly cannot build, access the target or skip the probe check"
    exit 2
}
if ($AllowCompilerFallback -and -not $Build) {
    Out2 "USAGE: MODE_CONFLICT"
    Out2 "RESULT: FAIL"
    Out2 "REASON: -AllowCompilerFallback only applies when -Build is specified"
    exit 2
}
if ($LoadOnly -and $Run) {
    Out2 "USAGE: MODE_CONFLICT"
    Out2 "RESULT: FAIL"
    Out2 "REASON: -LoadOnly cannot be combined with -Run"
    exit 2
} elseif (-not $Build -and -not $Run -and -not $LoadOnly -and -not $ProbeCheckOnly) {
    Out2 "USAGE: ACTION_REQUIRED"
    Out2 "RESULT: FAIL"
    Out2 "REASON: choose -Build, -Run, -LoadOnly or -ProbeCheckOnly; no implicit action"
    exit 2
}
if (($Run -or $LoadOnly) -and -not $ConfirmLoad) {
    Out2 'FAILURE: LOAD_NOT_CONFIRMED'; Out2 'RESULT: FAIL'
    Out2 'REASON: explicit loadti download requires -ConfirmLoad after user approval'; exit 4
}

# ---------- 0. detached mode ----------
# A big application may need minutes before its registers settle; an IDE/agent
# command timeout would kill such a run. -Background relaunches this script
# detached, writes everything to a log and returns immediately.
if ($Background -and -not $Detached) {
    $log = if ($LogFile) { $LogFile } else { Join-Path $env:TEMP ("ti_c2000_debug_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss')) }
    $errLog = "$log.err.txt"
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        if ($k -eq 'Background' -or $k -eq 'LogFile') { continue }
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $argList += "-$k" } }
        else { $argList += "-$k"; $argList += "`"$v`"" }
    }
    $argList += '-Detached'
    # ★一律用 PowerShell 7 引擎：本脚本首行是 #requires -Version 7.0，
    #   所以 $PSHOME 就是 PS7 安装目录 ——用它启动后台实例，绝不退回 Windows PowerShell 5.1
    #   （退回 5.1 时子脚本会因为自己的 #requires 直接失败：ScriptRequiresUnmatchedPSVersion）。
    $pwshExe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }   # 兜底走 PATH
    Start-Process -FilePath $pwshExe -ArgumentList $argList -WindowStyle Hidden `
                  -RedirectStandardOutput $log -RedirectStandardError $errLog | Out-Null
    Out2 "BACKGROUND: started detached, log = $log"
    Out2 "HINT    : poll with   Select-String -Path '$log' -Pattern 'RESULT|^VAR |ready|BACKGROUND'"
    exit 0
}

# ---------- locate project ----------
if (-not $ProjectPath) {
    $d = Get-Item -LiteralPath (Get-Location).Path
    while ($d) {
        if (Test-Path (Join-Path $d.FullName '.cproject')) { $ProjectPath = $d.FullName; break }
        $d = $d.Parent
    }
}
if (-not $ProjectPath -or -not (Test-Path -LiteralPath $ProjectPath -PathType Container) -or
    -not (Test-Path -LiteralPath (Join-Path $ProjectPath '.cproject') -PathType Leaf)) {
    Out2 "USAGE: NO_PROJECT"
    Out2 "RESULT: FAIL"; Out2 "REASON: project (.cproject) not found"; exit 2
}
$ProjectPath = (Get-Item -LiteralPath $ProjectPath).FullName
$projName = Split-Path $ProjectPath -Leaf
if (Test-Path (Join-Path $ProjectPath '.project')) {
    try {
        [xml]$prj = Get-Content -LiteralPath (Join-Path $ProjectPath '.project') -Raw
        if ($prj.projectDescription.name) { $projName = $prj.projectDescription.name }
    } catch { }
}
Info2 "PROJECT : $ProjectPath"

# ---------- 1. detect CCS installations (newest first) ----------
function Get-CcsRoots {
    $list = New-Object System.Collections.ArrayList
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Texas Instruments' -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($p.Version -and $p.Location) {
            $loc = ([string]$p.Location).TrimEnd('\')
            foreach ($cand in @((Join-Path $loc 'ccs'), (Join-Path $loc ("ccs" + ($p.Version -split '\.')[0])))) {
                if (Test-Path (Join-Path $cand 'ccs_base')) {
                    [void]$list.Add([pscustomobject]@{ Path = (Get-Item -LiteralPath $cand).FullName; Version = [string]$p.Version })
                    break
                }
            }
        }
    }
    foreach ($g in @("$env:USERPROFILE\ti\ccs*", 'C:\ti\ccsv*', 'C:\ti\ccs*')) {
        foreach ($cand in @(Get-Item -Path $g -ErrorAction SilentlyContinue)) {
            if ((Test-Path (Join-Path $cand.FullName 'ccs_base')) -and $cand.Name -notmatch '^ccs_base') {
                if (-not ($list | Where-Object { $_.Path -eq $cand.FullName })) {
                    $ver = '6.0'; if ($cand.Name -match 'ccs(\d+)') { $ver = $Matches[1] + '.0' }
                    [void]$list.Add([pscustomobject]@{ Path = $cand.FullName; Version = $ver })
                }
            }
        }
    }
    return @($list | Sort-Object { [double](($_.Version -split '[^\d]')[0]) } -Descending)
}
$roots = @()
if ($CcsRoot -and (Test-Path (Join-Path $CcsRoot 'ccs_base'))) {
    $roots = @([pscustomobject]@{ Path = (Get-Item -LiteralPath $CcsRoot).FullName; Version = 'forced' })
} else {
    $roots = Get-CcsRoots
}
if ($roots.Count -eq 0) { Out2 "FAILURE: ENV_NO_CCS"; Out2 "RESULT: FAIL"; Out2 "REASON: no CCS installation found"; exit 1 }
$ccs = $roots[0]
Info2 "CCS     : $($ccs.Path)  (v$($ccs.Version))"

# Probe library: serial resolution (model independent) + the DSS openability test.
. (Join-Path $PSScriptRoot 'ti_c2000_probe.ps1')

# -----------------------------------------------------------------------------
# Probe inventory: three independent facts, never merged into one boolean.
#   L1 PnP enumeration      - is anything plugged in at all
#   L2 FTDI driver can open - xds100serial -l; PnP enumeration is NOT driver access
#   L3 physical serial      - the only trustworthy identity (PnP DeviceID has one
#                             extra trailing char: ...TI90I42AB -> TI90I42A)
# 2026-11-18: L1 passed (COM11 + Debug + Aux all OK) while L2 failed ("No XDS100
# emulators were found") and DSS opened a ghost instance -> Error -151. A check that
# only looked at L1 reported OK for a full afternoon of failed downloads.
# -----------------------------------------------------------------------------
$script:ProbeInventory = $null
function Get-ProbeInventory {
    if ($script:ProbeInventory) { return $script:ProbeInventory }
    $probePatterns = 'XDS|Texas Instruments.*(Debug|Emulat|Probe)|Debug Probe|Spectrum Digital|Blackhawk|SEGGER|J-Link|ICDI'
    # 幽灵实例（Present=False / Status=Unknown）**只有 Get-PnpDevice 看得到**；
    # Get-CimInstance Win32_PnPEntity 只返回当前存在的设备，所以用它永远数不出幽灵
    # （2026-11-18 实测：CIM 返回 3 条，Get-PnpDevice 返回 12 条 = 3 OK + 9 Unknown）。
    # 而"有幽灵 + ccxml 默认 Only one"正是 -151 的成因，必须能数出来。
    $all = @()
    $usedPnp = $false
    try {
        $all = @(Get-PnpDevice -ErrorAction Stop 2>$null | Where-Object { $_.FriendlyName -match $probePatterns })
        $usedPnp = $true
    } catch {
        $all = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop 2>$null | Where-Object { $_.Name -match $probePatterns })
    }

    $isReal = {
        param($d)
        if ($d.PSObject.Properties['Status']) { return ($d.Status -eq 'OK') }
        return (($null -eq $d.ConfigManagerErrorCode -or $d.ConfigManagerErrorCode -eq 0) -and
                (-not $d.PSObject.Properties['Present'] -or $d.Present))
    }
    $usable = @($all | Where-Object { & $isReal $_ })
    $ghosts = @($all | Where-Object { -not (& $isReal $_) })

    $serialOk = $false
    $serialLines = @()
    $xdsTool = Join-Path $ccs.Path 'ccs_base\common\uscif\xds100serial.exe'
    if (Test-Path -LiteralPath $xdsTool) {
        $rows = @(& $xdsTool -l 2>$null | Where-Object { $_ -match '^[0-9a-fA-F]{4}/[0-9a-fA-F]{4}\s+XDS100' })
        if ($rows.Count -gt 0) { $serialOk = $true; $serialLines = @($rows | ForEach-Object { $_.Trim() }) }
    }

    $script:ProbeInventory = [pscustomobject]@{
        All         = @($all)
        Usable      = @($usable)
        Ghosts      = @($ghosts)
        SerialOk    = $serialOk
        SerialLines = @($serialLines)
        SerialTool    = (Test-Path -LiteralPath $xdsTool)
    }
    return $script:ProbeInventory
}

# Backwards-compatible thin wrapper: callers that only need "is something there".
function Get-ConnectedProbes {
    $inv = Get-ProbeInventory
    $found = @($inv.Usable)
    if ($found.Count -eq 0 -and $inv.SerialOk) {
        $found = @($inv.SerialLines | ForEach-Object { [pscustomobject]@{ Name = $_ } })
    }
    return @($found)
}

function Test-LiveServiceSession([string]$proj) {
    $stateFile = Join-Path $proj 'readout\.service\state.json'
    if (-not (Test-Path -LiteralPath $stateFile)) { return $false }
    try {
        $st = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        if ($st.pid -and (Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue)) { return $true }
    } catch { }
    return $false
}

function Stop-NoProbe {
    Out2 "PROBE   : [1/5] Windows 枚举 : 0 个可用设备"
    Out2 "FAILURE: NO_PROBE"
    Out2 "RESULT: FAIL"
    Out2 "REASON: no JTAG probe enumerated by Windows (checked: XDS*, Spectrum Digital, Blackhawk, SEGGER, Debug Probe)"
    Out2 "HINT    : this is the ONE case where the hardware really is absent - connect the probe"
    Out2 "          and the board, then ask the operator before retrying"
    exit 3
}

# A hardware run with -Build must stop here if its probe is absent. The
# compiler must not be invoked first and an agent must not retry until the
# operator confirms the physical connection. Build-only remains hardware-free.
if ($ProbeCheckOnly -or ($Build -and ($Run -or $LoadOnly) -and -not $NoProbeCheck)) {
    $preCcxml = $Ccxml
    if (-not $preCcxml) {
        $candidate = Get-ChildItem -Path (Join-Path $ProjectPath 'targetConfigs') -Filter '*.ccxml' -ErrorAction SilentlyContinue |
                     Select-Object -First 1
        if ($candidate) { $preCcxml = $candidate.FullName }
    }
    if (-not $preCcxml -or -not (Test-Path -LiteralPath $preCcxml)) {
        Out2 "USAGE: NO_CCXML"
        Out2 "RESULT: FAIL"
        Out2 "REASON: no .ccxml target configuration found - pass -Ccxml <file>"
        exit 2
    }
    $preIsSim = $false
    try {
        [xml]$preConfig = Get-Content -LiteralPath $preCcxml -Raw
        $preEmu = $preConfig.SelectSingleNode('//configuration/instance[@desc]')
        if ($preEmu -and [string]$preEmu.desc -match 'simulator|tisim') { $preIsSim = $true }
    } catch { }
    if ($preIsSim) {
        Info2 "PROBE   : skipped (simulator target)"
    } else {
        $preProbes = @(Get-ConnectedProbes)
        if ($preProbes.Count -eq 0) { Stop-NoProbe }
        foreach ($item in $preProbes) { Info2 ("PROBE   : {0}" -f $item.Name) }

        # ===== 分层探针自检（5 层判据）=========================================
        # 判定顺序固定为「软件层 -> 硬件层」：只有软件层全部排除后才允许建议动硬件。
        # 2026-11-18 的教训：只查 L1(PnP) 就报 OK，而真因在 L4(ccxml 选了幽灵实例)，
        # 结果把一整个下午浪费在"拔线/改 BOOT"上。
        $inv = Get-ProbeInventory
        $sessionAlive = Test-LiveServiceSession -proj $ProjectPath
        $usableCount = @($inv.Usable).Count
        $ghostCount  = @($inv.Ghosts).Count

        Out2 ''
        Out2 'PROBE   : === 探针自检（5 层判据）==='

        # --- L1 Windows 枚举：只回答"插没插" ---
        Out2 ('PROBE   : [1/5] Windows 枚举 : {0} 个可用设备 / {1} 个幽灵(Unknown 或 Present=False)' -f $usableCount, $ghostCount)
        if ($usableCount -eq 0 -and -not $inv.SerialOk) { Stop-NoProbe }

        # --- L2 句柄占用 / 串号可读性 -------------------------------------------
        # 2026-11-18 控制实验（同一块板、同一分钟）：
        #   A) DSS 会话运行中（LOAD #108 正常跑）-> xds100serial -l 报
        #      "No XDS100 emulators were found"
        #   B) 停会话 3 秒后 -> 立刻读到 0403/a6d0 XDS100v1/v2 TI90I42A
        # 结论：该工具的成败只反映"FTDI 句柄有没有被占用"，**不能**用来判定探针好坏。
        # 所以这里不再输出 FAIL，只报告事实；真正的可用性判据是 [4b] 的 DSS 试连。
        $staleProcs = @(Get-Process -Name dss,java -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
        if ($staleProcs.Count -gt 0) {
            Out2 ('PROBE   : [2/5] 残留 DSS/Java : {0} 个（pid {1}）—— 这些进程可能仍占着 FTDI 句柄' -f $staleProcs.Count, ($staleProcs -join ','))
        } else {
            Out2 'PROBE   : [2/5] 残留 DSS/Java : 无'
        }
        if ($inv.SerialOk) {
            Out2 'PROBE   : [2/5] 串号可读性    : OK（xds100serial 已打开探针）'
        } elseif ($sessionAlive) {
            Out2 'PROBE   : [2/5] 串号可读性    : SKIP（活跃会话占着句柄，属正常，不是故障）'
        } elseif ($staleProcs.Count -gt 0) {
            Out2 'PROBE   : [2/5] 串号可读性    : 被残留进程占用（先清理它们，不要动硬件）'
        } else {
            Out2 'PROBE   : [2/5] 串号可读性    : 读不到（这本身不足以判定探针坏，见 [4b]）'
        }

        # --- L3 实物串号：唯一可信身份 ---
        if ($inv.SerialOk) {
            foreach ($line in $inv.SerialLines) { Out2 ('PROBE   : [3/5] 实物串号     : ' + $line) }
        } elseif ($sessionAlive) {
            Out2 'PROBE   : [3/5] 实物串号     : 未知（会话占用；-Stop 后可读）'
        } else {
            Out2 'PROBE   : [3/5] 实物串号     : 读不到'
        }

        # --- L4 ccxml 选择：按串号还是默认 Only one ---
        $preText = ''
        try { $preText = [System.IO.File]::ReadAllText($preCcxml) } catch { }
        $selValue = ''
        $cfgSerial = ''
        if ($preText) {
            # CCS 的写入顺序不固定（<property Type="choicelist" Value="1" id="Emulator Selection">），
            # 先取标签再取 Value，避免属性顺序变化导致解析失败（踩过）。
            $mSelTag = [regex]::Match($preText, '<property\b[^>]*id="Emulator Selection"[^>]*>')
            if ($mSelTag.Success) {
                $mSelVal = [regex]::Match($mSelTag.Value, '\bValue="([^"]*)"')
                if ($mSelVal.Success) { $selValue = $mSelVal.Groups[1].Value }
            }
            $mSer = [regex]::Match($preText, 'Value="([^"]*)"\s+id="-- Enter the serial number"')
            if ($mSer.Success) { $cfgSerial = $mSer.Groups[1].Value }
        }
        $pinnedFlag = ($selValue -eq '1' -and $cfgSerial)
        $serialBlob = (@($inv.SerialLines) -join ' ')
        # 从 xds100serial 行里取出串号（形如 "0403/a6d0  XDS100v1/v2  TI90I42A  ..."）
        $attachedSerials = @()
        foreach ($line in @($inv.SerialLines)) {
            $mS = [regex]::Match([string]$line, '^\s*[0-9a-fA-F]{4}/[0-9a-fA-F]{4}\s+(\S+)\s+(\S+)\s+')
            if ($mS.Success) { $attachedSerials += $mS.Groups[2].Value }
        }
        # 运行时能自动确定的串号：只有一块 -> 就它；多块但 ccxml 已指定其中一块 -> 用它。
        $autoSerial = ''
        if ($attachedSerials.Count -eq 1) { $autoSerial = $attachedSerials[0] }
        elseif ($attachedSerials.Count -gt 1 -and $pinnedFlag -and ($attachedSerials -contains $cfgSerial)) { $autoSerial = $cfgSerial }

        # 只报告事实。串号不是 skill 的依赖项：ccxml 原样交给 DSS，除非调用方显式给了
        # -ProbeSerial / TI_C2000_PROBE_SERIAL / targetConfigs\probe-serial.txt。
        if ($pinnedFlag -and $autoSerial -eq $cfgSerial) {
            Out2 ('PROBE   : [4/5] ccxml 选择   : 按串号 {0}（与实物一致）' -f $cfgSerial)
        } elseif ($pinnedFlag -and $autoSerial) {
            Out2 ('PROBE   : [4/5] ccxml 选择   : 按串号 {0}，实物是 {1}' -f $cfgSerial, $autoSerial)
            Out2 'PROBE   :                     -> 默认仍按 ccxml 原样使用；要改用实物串号请显式传 -ProbeSerial'
        } elseif ($pinnedFlag) {
            Out2 ('PROBE   : [4/5] ccxml 选择   : 按串号 {0}（实物串号此刻读不到）' -f $cfgSerial)
        } elseif ($autoSerial) {
            Out2 'PROBE   : [4/5] ccxml 选择   : 默认 "Only one XDS100"（没有 pin 串号）'
        } else {
            Out2 'PROBE   : [4/5] ccxml 选择   : 默认 "Only one XDS100"（实物串号不可读）'
        }
        # 不依赖串号的根治建议：清掉幽灵，让"自动选择"本身可用。
        if ($ghostCount -gt 0 -and -not $pinnedFlag) {
            Out2 ('PROBE   : [4/5] 建议         : {0} 个幽灵实例；若遇到 -215/连不上，用管理员运行' -f $ghostCount)
            Out2 'PROBE   :                    tools\clean_ghost_probes.ps1 -Confirm（清掉它们，而不是填串号）'
        }

        # --- 4b) 可选：让 DSS 自己打开一次（型号无关的最终判据）--------------------
        # xds100serial 只认识 XDS100；XDS110/XDS200/XDS560v2 没有对应的串号工具，
        # dbgjtag 又要 CCS 生成的 .dat 而不是 .ccxml。唯一对所有型号都成立的是
        # "DSS 能不能打开它"——这正是下载用的同一条代码路径。-Deep 才跑（几秒）。
        $deepFail = ''
        if ($Deep) {
            $xdsToolDeep = Join-Path $ccs.Path 'ccs_base\common\uscif\xds100serial.exe'
            $resolvedDeep = Resolve-ProbeTargetConfig -ProjectPath $ProjectPath -Ccxml $preCcxml -Serial $ProbeSerial `
                -WorkDir (Join-Path $ProjectPath 'readout\.service') -CcsPath $ccs.Path -Xds100Tool $xdsToolDeep
            $dssBat = Join-Path $ccs.Path 'ccs_base\scripting\bin\dss.bat'
            $probeTest = Test-ProbeOpenableByDss -Ccxml $resolvedDeep.Path -DssBat $dssBat -ProjectPath $ProjectPath -CorePattern $CorePattern
            if ($probeTest.Skipped) {
                Out2 ('PROBE   : [4b]  DSS 试连   : SKIP（{0}）' -f $probeTest.Detail)
            } elseif ($probeTest.Ok) {
                Out2 ('PROBE   : [4b]  DSS 试连   : OK（{0}）' -f $probeTest.Detail)
            } else {
                Out2 ('PROBE   : [4b]  DSS 试连   : FAIL（{0}）' -f $probeTest.Detail)
                if ($probeTest.Log) { Out2 ('PROBE   :                    log: {0}' -f $probeTest.Log) }
                $deepFail = 'PROBE_DSS_CONNECT_FAILED'
            }
        }

        # --- L5 判定：只保留两条站得住的失败条件 --------------------------------
        # 已删除的两个旧判据（2026-11-18 控制实验反证）：
        #   a) "xds100serial 读不到 → PROBE_DRIVER_UNUSABLE"
        #      反证：会话运行中(LOAD #108)它就报找不到，停会话 3 秒后立刻找到。
        #      该工具的成败与能否下载无关，拿它判探针坏会误伤。
        #   b) "有幽灵 + 默认 Only one → PROBE_SELECTION_AMBIGUOUS"
        #      反证：幽灵是 Present=False（物理不存在），DSS 打开的是在场设备，
        #      打不开一个不存在的设备这件事本身不成立，因此不构成歧义。
        # 留下的判据必须是"要么有硬证据、要么能自动恢复"。
        $fail = ''
        if ($deepFail) {
            $fail = $deepFail
        } elseif ($attachedSerials.Count -gt 1 -and -not $autoSerial) {
            # 真的有多块实物探针同时在场，且 ccxml 没指定其中任何一块：确实猜不出来。
            $fail = 'PROBE_SELECTION_AMBIGUOUS'
        }

        switch ($fail) {
            'PROBE_DSS_CONNECT_FAILED' {
                Out2 'PROBE   : [5/5] 结论         : DSS 自己都打不开探针（这就是下载用的同一条路径）'
                Out2 'FAILURE: PROBE_DSS_CONNECT_FAILED'
                Out2 'RESULT: FAIL'
                Out2 'REASON: DSS connect 未通过（型号无关的最终判据，见 probe-openable.log）'
                Out2 'FIX     : 1) 先看上面 [4/5]：ccxml 是否指向实物串号（配置错比硬件坏常见得多）'
                Out2 'FIX     : 2) 换一个 USB 口 / 换线，重跑 -ProbeCheckOnly -Deep'
                Out2 'FIX     : 3) 两者都排除后才怀疑探针本体或目标板供电'
                Out2 'NOTE    : 不要改 BOOT 引脚——BOOT 只决定目标从哪里启动，与探针能否打开无关'
                exit 3
            }
            'PROBE_SELECTION_AMBIGUOUS' {
                Out2 'PROBE   : [5/5] 结论         : 有 {0} 块实物探针在场，无法确定用哪一块 —— 不要动硬件' -f $attachedSerials.Count
                Out2 'FAILURE: PROBE_SELECTION_AMBIGUOUS'
                Out2 'RESULT: FAIL'
                Out2 ('REASON: 检测到 {0} 块实物探针（{1}），ccxml 没有指定其中任何一块' -f $attachedSerials.Count, ($attachedSerials -join ', '))
                Out2 'FIX     : 三选一显式指定 —— -ProbeSerial <串号> / $env:TI_C2000_PROBE_SERIAL /'
                Out2 '          targetConfigs\probe-serial.txt（每行一个串号）'
                Out2 'FIX     : 不要拔线、不要改 BOOT；这只是"选哪一块"，不是探针故障'
                Out2 'FIX     : 不要拔线、不要改 BOOT；改完重跑本检查'
                exit 3
            }
            default {
                if ($sessionAlive -and -not $inv.SerialOk) {
                    Out2 ('PROBE   : [5/5] 结论         : 会话占用中，链路由该会话负责；串号核对跳过（{0}）—— 不要动硬件' -f $cfgSerial)
                } elseif ($pinnedFlag -and $autoSerial -eq $cfgSerial) {
                    Out2 ('PROBE   : [5/5] 结论         : 软件层全部通过（ccxml 串号 {0} 与实物一致）—— 不要动硬件' -f $cfgSerial)
                } elseif ($autoSerial) {
                    Out2 ('PROBE   : [5/5] 结论         : 软件层通过；-Start 时会把实物串号 {0} 写进 ccxml —— 不要动硬件' -f $autoSerial)
                } else {
                    Out2 'PROBE   : [5/5] 结论         : 软件层通过（串号此刻不可读；-Start 时读不到就原样用 ccxml）—— 不要动硬件'
                }
            }
        }
    }
    if ($ProbeCheckOnly) {
        Out2 "RESULT: OK"
        exit 0
    }
}

# ---------- 2. optional build (same toolchain family) ----------
if ($Build) {
    Info2 "STEP    : build"
    $buildScript = Join-Path $PSScriptRoot 'ti_c2000_build.ps1'
    $bargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $buildScript, '-ProjectPath', $ProjectPath, '-KeepLaunches')
    if ($CcsRoot) { $bargs += @('-CcsRoot', $CcsRoot) }
    if ($AllowCompilerFallback) { $bargs += '-AllowCompilerFallback' }
    if ($Run -or $LoadOnly) { $bargs += '-Stage' }
    # ★引擎统一：用 PowerShell 7（pwsh）跑子脚本，绝不退回 Windows PowerShell 5.1
    #   （退回 5.1 时 ti_c2000_build.ps1 会因自身 #requires -Version 7.0 直接失败）
    $pwshExe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }   # 兜底走 PATH
    $bout = & $pwshExe @bargs 2>&1
    $bcode = $LASTEXITCODE
    # one RESULT line per invocation: the build reports BUILD, not RESULT
    if (-not $Quiet) { $bout | Where-Object { [string]$_ -notmatch '^RESULT:' } | Select-Object -Last 12 | ForEach-Object { Out2 $_ } }
    if ($bcode -eq 0) { Info2 'BUILD   : OK' }
    if ($bcode -ne 0 -or -not @($bout | Where-Object { $_ -match '^RESULT: OK\s*$' }).Count) {
        $bfail = @($bout | Where-Object { $_ -match '^FAILURE: ' }) | Select-Object -First 1
        if (-not $bfail) { $bfail = 'FAILURE: BUILD_FAILED' }
        Out2 $bfail
        Out2 "RESULT: FAIL"
        Out2 "REASON: build failed - debugger step aborted (see the build script output / its build.log)"
        exit 1
    }
    if (-not $Run -and -not $LoadOnly) {
        Out2 "NOTE    : build completed; no download or run requested"
        Out2 "RESULT: OK"
        exit 0
    }
}

# ---------- 3. resolve .out / .ccxml / tools ----------
if (-not $OutFile) { $OutFile = Join-Path $ProjectPath "Debug\$projName.out" }
if (-not (Test-Path -LiteralPath $OutFile)) {
    Out2 "FAILURE: NO_OUT_FILE"
    Out2 "RESULT: FAIL"; Out2 "REASON: $OutFile not found - run the build first (add -Build)"; exit 4
}
if ($Run -or $LoadOnly) {
    . (Join-Path $PSScriptRoot 'ti_c2000_readmode.ps1')
    Assert-SelectedOutFresh -ProjectPath $ProjectPath -OutFile $OutFile
}
if (-not $Ccxml) {
    $c = Get-ChildItem -Path (Join-Path $ProjectPath 'targetConfigs') -Filter '*.ccxml' -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($c) { $Ccxml = $c.FullName }
}
if (-not $Ccxml -or -not (Test-Path -LiteralPath $Ccxml)) {
    Out2 "USAGE: NO_CCXML"
    Out2 "RESULT: FAIL"; Out2 "REASON: no .ccxml target configuration found - pass -Ccxml <file>"; exit 2
}
# what device / emulator does this target configuration ask for?
$ccxmlEmu = ''; $ccxmlDev = ''; $isSim = $false
try {
    [xml]$cc = Get-Content -LiteralPath $Ccxml -Raw
    $n = $cc.SelectSingleNode("//configuration/instance[@desc]")
    if ($n) { $ccxmlEmu = [string]$n.desc }
    $n = $cc.SelectSingleNode("//platform/instance[@id]")
    if ($n) { $ccxmlDev = [string]$n.id }
} catch { }
if (-not $ccxmlEmu) { $ccxmlEmu = '<unknown>' }
if (-not $ccxmlDev) { $ccxmlDev = '<unknown>' }
if ($ccxmlEmu -match 'simulator|tisim') { $isSim = $true }
Info2 "TARGET  : $ccxmlDev  via  $ccxmlEmu$(if ($isSim) { '  [simulator]' })"

$loadti = Join-Path $ccs.Path 'ccs_base\scripting\examples\loadti\loadti.bat'
if (-not (Test-Path $loadti)) {
    foreach ($r in $roots) {
        $c = Join-Path $r.Path 'ccs_base\scripting\examples\loadti\loadti.bat'
        if (Test-Path $c) { $loadti = $c; break }
    }
}
if (-not (Test-Path -LiteralPath $loadti)) {
    Out2 "FAILURE: ENV_NO_LOADTI"; Out2 "RESULT: FAIL"; Out2 "REASON: loadti.bat not found under any CCS installation"; exit 1
}
Info2 "OUTCARD : $OutFile"
Info2 "CCXML   : $Ccxml"
Info2 "LOADTI  : $loadti"

# ---------- 4. probe / GUI pre-flight ----------
$probe = @()
if (-not $isSim -and -not $NoProbeCheck) {
    $probe = @(Get-ConnectedProbes)
}
if ($isSim) {
    Info2 "PROBE   : skipped (simulator target, no hardware needed)"
    $probe = @([pscustomobject]@{ Name = 'TI simulator' })
} elseif ($NoProbeCheck) {
    Info2 "PROBE   : check skipped by -NoProbeCheck"
} elseif ($probe.Count -eq 0) {
    Stop-NoProbe
} else {
    foreach ($p in $probe) { Info2 ("PROBE   : {0}" -f $p.Name) }
}
if (@(Get-Process ccstudio, ccstudio64, eclipsec -ErrorAction SilentlyContinue).Count -gt 0) {
    Info2 "WARN    : CCS GUI is running - close any active debug session if the JTAG turns out to be busy"
}

# ---------- 5. loadti path ----------
# -Build alone returned above, and ACTION_REQUIRED covers "no action at all".
# Reaching this point without an explicit download request must never turn
# into an implicit load (that used to download and halt the target silently).
if (-not $LoadOnly -and -not $Run) {
    Out2 "USAGE: ACTION_REQUIRED"
    Out2 "RESULT: FAIL"
    Out2 "REASON: no download requested; add -Run or -LoadOnly, or use -Build alone"
    exit 2
}
$ltArgs = @("-c=$Ccxml")
if ($LoadOnly) { $ltArgs += '-l' }
else           { $ltArgs += @('-r', '-a') }
$ltArgs += "-t=$($TimeoutSec * 1000)"
$ltArgs += $OutFile
Info2 ("STEP    : loadti {0}" -f ($ltArgs -join ' '))
# PowerShell 7 can throw StandardOutputEncoding before a .bat starts. Use
# cmd.exe through ProcessStartInfo so paths containing spaces retain cmd's
# required quoting; PowerShell's native argument re-quoting is bypassed.
function Quote-CmdArgument([string]$value) {
    if ($value -match '["%\r\n]') { throw "unsupported character in loadti path or argument" }
    return '"' + $value + '"'
}
. (Join-Path $PSScriptRoot 'ti_c2000_readmode.ps1')
Wait-MinLoadGap -ProjectPath $ProjectPath
try {
    $command = (Quote-CmdArgument $loadti) + ' ' + (($ltArgs | ForEach-Object { Quote-CmdArgument $_ }) -join ' ')
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
    $start.Arguments = '/d /v:off /s /c "' + $command + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $waitMs = [int][Math]::Min(2147483647L, ([long]$TimeoutSec * 1000L + 30000L))
    $expired = -not $process.WaitForExit($waitMs)
    if ($expired) { $process.Kill($true); $process.WaitForExit() }
    $out = @((($stdout.GetAwaiter().GetResult() + "`n" + $stderr.GetAwaiter().GetResult()) -split '\r?\n') |
             Where-Object { $_ -ne '' })
    $code = $process.ExitCode
    $process.Dispose()
} catch {
    Out2 "FAILURE: LOADTI_LAUNCH_ERROR"
    Out2 "RESULT: FAIL"
    Out2 "REASON: loadti could not be started: $($_.Exception.Message)"
    exit 1
} finally {
    Mark-LoadAttemptEnd -ProjectPath $ProjectPath
}
if (-not $Quiet) { $out | Select-Object -Last 25 | ForEach-Object { Out2 $_ } }
$bad    = @($out | Where-Object { $_ -match 'error|failed|cannot|aborted' })
$ldDone = @($out | Where-Object { $_ -match '\bDone\b' })
$runSeen = @($out | Where-Object { $_ -match '^Target running\.\.\.' })
if ($expired -or $code -ne 0 -or $bad.Count -gt 0 -or $ldDone.Count -eq 0 -or ($Run -and $runSeen.Count -eq 0)) {
    if ($expired) {
        Out2 "FAILURE: LOADTI_TIMEOUT"
        Out2 "REASON: loadti exceeded its $TimeoutSec s target timeout"
    } elseif ($code -ne 0 -or $bad.Count -gt 0) {
        Out2 "FAILURE: LOADTI_ERROR"
        Out2 "REASON: loadti exited with code $code or reported an error"
        $bad | Select-Object -First 3 | ForEach-Object { Out2 ("    " + $_) }
    } else {
        Out2 "FAILURE: LOADTI_INCOMPLETE"
        Out2 "REASON: loadti exited without the required Done and Target running markers"
    }
    Out2 "RESULT: FAIL"
    exit 1
}
# every successful loadti writes the image to the target: count it, so "LOAD #N"
# in any later read tells the whole story of how many times this project was flashed
try {
    . (Join-Path $PSScriptRoot 'ti_c2000_loadcount.ps1')
    $sha = ''
    if (Test-Path -LiteralPath $OutFile) { $sha = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash }
    $rec = Add-LoadRecord -ProjectPath $ProjectPath -Mode 'Explicit' -Out $OutFile -Sha256 $sha
    Info2 ("LOAD    : #{0} (download number {0} for this project)" -f $rec.count)
} catch { }

if ($LoadOnly) { Out2 "NOTE    : program loaded and halted (no run requested)" }
elseif ($Run)  { Out2 "NOTE    : program started on target (async run)" }
Out2 "NOTE    : no values were read here; use ti_c2000_run_read.ps1 for a same-session read"
Out2 "RESULT: OK"
exit 0
