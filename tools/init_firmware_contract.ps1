#requires -Version 7.0
<#
init_firmware_contract.ps1 -- generate the firmware-side JUDGEMENT symbols this skill reads.

WHY THIS EXISTS
  gFwId / heartbeat / RAM proof / DMA frame symbols are DATA JUDGEMENTS: the skill
  reads them and decides "is this target really running, does this sample belong
  to this build". Before this tool, a new project had to copy them by hand from
  references/firmware-contract.json and historical cases; missing symbols silently
  degraded into MISSING/UNREADABLE - skipped and advancing=False. That is a judgement
  the user cannot see unless they know the contract by heart.

WHAT IT DOES
  Writes ti_c2000_contract.h / .c into the project with HEAVILY COMMENTED Chinese
  declarations so the next person knows why each symbol matters and where to ++ it.
  It NEVER rewrites existing source: if a symbol already exists anywhere in the
  project (excluding ti/ vendor code), that module is SKIPped. No -Force by design:
  silently overwriting an engineer's counter is worse than a refused generation.

WHAT IT DOES NOT DO
  - It does not touch main.c / ISR files. You must call the generated tick
    functions from your own 1 ms ISR and main loop (printed as NEXT steps).
  - It does not edit .cmd. The DATA_SECTION / CODE_SECTION names must exist in the
    linker command file; the tool warns when the requested section is not found.
  - It is NOT run by build/download. Invoke it explicitly once when creating a
    project, or when the firmware contract changes.

Exit code: 0 OK | 1 generation failed | 2 bad arguments / no CCS project
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    # Where the generated .h/.c go. Default: <project>\ti_c2000_contract
    [string]$SourceDir = '',
    # If none of these switches is given, all four modules are generated.
    [switch]$Identity,
    [switch]$Heartbeat,
    [switch]$RamProof,
    [switch]$DmaFrame,
    [int]$DmaRows = 512,
    [string]$DmaSection = 'ramgs1',
    [string]$DmaArrayA = 'gDmaFrameA',
    [string]$DmaArrayB = 'gDmaFrameB',
    # Override only if you really must; a reused FW_ID cannot prove build identity.
    [string]$FwId = '',
    [switch]$DryRun,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }

if (-not (Test-Path -LiteralPath (Join-Path $ProjectPath '.cproject'))) {
    Out2 'USAGE: NO_PROJECT'
    Out2 'RESULT: FAIL'
    Out2 ("REASON: no .cproject under {0}" -f $ProjectPath)
    exit 2
}
$project = (Get-Item -LiteralPath $ProjectPath).FullName

# --- module selection -------------------------------------------------------
$anyModule = $Identity -or $Heartbeat -or $RamProof -or $DmaFrame
$wantIdentity  = -not $anyModule -or $Identity
$wantHeartbeat = -not $anyModule -or $Heartbeat
$wantRamProof  = -not $anyModule -or $RamProof
$wantDmaFrame  = -not $anyModule -or $DmaFrame
if ($Identity)  { $wantIdentity  = $true }
if ($Heartbeat) { $wantHeartbeat = $true }
if ($RamProof)  { $wantRamProof  = $true }
if ($DmaFrame)  { $wantDmaFrame  = $true }
if (-not ($wantIdentity -or $wantHeartbeat -or $wantRamProof -or $wantDmaFrame)) {
    Out2 'USAGE: NOTHING_SELECTED'
    Out2 'RESULT: FAIL'
    Out2 'REASON: no firmware module selected'
    exit 2
}

# --- validate C identifiers and section name --------------------------------
$names = @()
if ($wantIdentity)  { $names += 'gFwId' }
if ($wantHeartbeat) { $names += @('gMsTick','usMainLoop','TiC2000_Heartbeat_IsrTick','TiC2000_Heartbeat_MainTick') }
if ($wantRamProof)  { $names += @('gRamProofTick','TiC2000_RamProofTick') }
if ($wantDmaFrame)  { $names += @($DmaArrayA,$DmaArrayB,'gDmaSeq','gDmaHalf','gDmaReady') }
foreach ($n in $names) {
    if ($n -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        Out2 'USAGE: BAD_IDENTIFIER'
        Out2 'RESULT: FAIL'
        Out2 ("REASON: '{0}' is not a valid C identifier" -f $n)
        exit 2
    }
}
if ($DmaSection -notmatch '^[A-Za-z_.][A-Za-z0-9_.]*$') {
    Out2 'USAGE: BAD_SECTION_NAME'
    Out2 'RESULT: FAIL'
    Out2 ("REASON: '{0}' is not a safe linker section name" -f $DmaSection)
    exit 2
}
if ($DmaRows -lt 1 -or $DmaRows -gt 65536) {
    Out2 'USAGE: BAD_DIMENSIONS'
    Out2 'RESULT: FAIL'
    Out2 ("REASON: DmaRows must be 1..65536, got {0}" -f $DmaRows)
    exit 2
}

# --- detect symbols already owned by the project ----------------------------
$skipDirs = @((Join-Path $project 'ti'), (Join-Path $project '.git'), (Join-Path $project 'Debug'))
if (-not $SourceDir) { $SourceDir = Join-Path $project 'ti_c2000_contract' }
$genDir = [IO.Path]::GetFullPath($SourceDir)
$sourceFiles = @(Get-ChildItem -LiteralPath $project -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $fp = $_.FullName
        $_.Extension -in @('.c','.h','.cpp','.hpp') -and
        -not ($skipDirs | Where-Object { $fp.StartsWith(($_ + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase) })
    }
)
$existing = @{}
foreach ($f in $sourceFiles) {
    $text = [IO.File]::ReadAllText($f.FullName)
    foreach ($n in $names) {
        if (-not $existing.ContainsKey($n) -and $text -match ('\b' + [regex]::Escape($n) + '\b')) {
            $existing[$n] = $f.FullName.Substring($project.Length).TrimStart('\')
        }
    }
}
function Module-State([string[]]$moduleNames) {
    $hits = @($moduleNames | Where-Object { $existing.ContainsKey($_) })
    if ($hits.Count) { return @{ skip = $true; reason = (($hits | ForEach-Object { '{0} in {1}' -f $_, $existing[$_] }) -join '; ') } }
    return @{ skip = $false; reason = '' }
}
$stId  = Module-State @('gFwId')
$stHb  = Module-State @('gMsTick','usMainLoop','TiC2000_Heartbeat_IsrTick','TiC2000_Heartbeat_MainTick')
$stRam = Module-State @('gRamProofTick','TiC2000_RamProofTick')
$stDma = Module-State @($DmaArrayA,$DmaArrayB,'gDmaSeq','gDmaHalf','gDmaReady')

# --- linker section sanity (warning only, never silently pass) --------------
$sectionFound = $false
foreach ($cmd in (Get-ChildItem -LiteralPath $project -Recurse -File -Filter *.cmd -ErrorAction SilentlyContinue)) {
    if ([IO.File]::ReadAllText($cmd.FullName) -match ('\b' + [regex]::Escape($DmaSection) + '\b')) { $sectionFound = $true; break }
}

# --- unique FW_ID (never reuse: a repeated ID cannot prove build identity) --
if (-not $FwId) {
    $b = [guid]::NewGuid().ToByteArray()
    $v = [BitConverter]::ToUInt32($b, 0) -bor 0x80000000UL
    $FwId = ('0x{0:X8}UL' -f $v)
} elseif ($FwId -notmatch '^0x[0-9A-Fa-f]{1,8}UL$') {
    Out2 'USAGE: BAD_FW_ID'
    Out2 'RESULT: FAIL'
    Out2 ("REASON: FwId must look like 0x00010001UL, got '{0}'" -f $FwId)
    exit 2
}

$stamp = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
$h = New-Object System.Collections.Generic.List[string]
$c = New-Object System.Collections.Generic.List[string]

$h.Add('/* ============================================================================')
$h.Add(' * ti-c2000-ccs-auto - 固件判据契约（DATA JUDGEMENTS，自动生成）')
$h.Add(' * 生成时间 : ' + $stamp)
$h.Add(' * 生成工具 : tools/init_firmware_contract.ps1')
$h.Add(' * 权威定义 : 已安装 skill 的 references/firmware-contract.json')
$h.Add(' *')
$h.Add(' * 【这些不是业务数据，是判据】skill 靠它们回答三个问题：')
$h.Add(' *   1. 目标真的在跑吗？            -> 心跳（gMsTick / usMainLoop）')
$h.Add(' *   2. 这份采样属于哪一次构建？    -> gFwId')
$h.Add(' *   3. 这个 ping-pong 帧完整吗？   -> gDmaSeq / bank 选择器')
$h.Add(' * skill 只【读取】这些符号，永远不会替你创建。符号缺失或不再增长时，')
$h.Add(' * 只会标注 MISSING / advancing=False，绝不会凭空捏造一个值。')
$h.Add(' * 因此：变量名、volatile、++ 的位置、唯一写者，任何一项做错，')
$h.Add(' * 所有的数据判据就都失去意义。这是本文件存在的唯一理由。')
$h.Add(' * ========================================================================== */')
$h.Add('#ifndef TI_C2000_CONTRACT_H')
$h.Add('#define TI_C2000_CONTRACT_H')
$h.Add('')

$c.Add('/* 由 tools/init_firmware_contract.ps1 生成。为什么需要这些符号，见头文件注释。')
$c.Add(' * 可以改这里的初值，但不要改变量名，也不要去掉 volatile。 */')
$c.Add('#include "ti_c2000_contract.h"')
$c.Add('')

$next = New-Object System.Collections.Generic.List[string]

if ($wantIdentity -and -not $stId.skip) {
    $h.Add('/* ---- 1. 构建身份（数据判据）--------------------------------------------')
    $h.Add(' * 每次构建必须取不同值！skill 在下载时记下它，之后每次读数都比对；')
    $h.Add(' * 不一致就把这次采样标成 DATA_UNRELIABLE。')
    $h.Add(' * 复用旧 ID 会让判据失效——即使 .out 的 SHA256 恰好对得上也不算证明。 */')
    $h.Add('extern volatile unsigned long gFwId;')
    $h.Add('')
    $c.Add('volatile unsigned long gFwId = ' + $FwId + ';')
    $c.Add('')
    $next.Add('gFwId is ' + $FwId + ' - regenerate this tool for each new release (or bump it by hand).')
} elseif ($wantIdentity) { Info2 ('SKIP   : identity - ' + $stId.reason) }

if ($wantHeartbeat -and -not $stHb.skip) {
    $h.Add('/* ---- 2. 心跳（活性判据）------------------------------------------------')
    $h.Add(' * 任意一个在涨，就证明程序真的在执行。skill 判的是【在涨 advancing】，')
    $h.Add(' * 不是【声明了 declared】：只定义不 ++ 的静态变量 = 没有心跳。')
    $h.Add(' * 两个计数器比一个好：gMsTick 在涨而 usMainLoop 不动 = 中断还活着、主循环卡死。')
    $h.Add(' * 注意：这是判据，不是业务变量，不要在别处改写它们。 */')
    $h.Add('extern volatile unsigned long gMsTick;    /* 在 1 ms 定时中断里 ++ */')
    $h.Add('extern volatile unsigned long usMainLoop; /* 在 for(;;) 主循环里 ++ */')
    $h.Add('')
    $h.Add('/* 调用点各一行，不要把 ++ 同时塞进两个函数： */')
    $h.Add('void TiC2000_Heartbeat_IsrTick(void);  /* 每个 1 ms ISR 调一次 */')
    $h.Add('void TiC2000_Heartbeat_MainTick(void); /* 主循环每圈调一次 */')
    $h.Add('')
    $c.Add('volatile unsigned long gMsTick = 0UL;')
    $c.Add('volatile unsigned long usMainLoop = 0UL;')
    $c.Add('')
    $c.Add('void TiC2000_Heartbeat_IsrTick(void)  { ++gMsTick; }')
    $c.Add('void TiC2000_Heartbeat_MainTick(void) { ++usMainLoop; }')
    $c.Add('')
    $next.Add('Call TiC2000_Heartbeat_IsrTick() in your 1 ms ISR and TiC2000_Heartbeat_MainTick() in for(;;).')
} elseif ($wantHeartbeat) { Info2 ('SKIP   : heartbeat - ' + $stHb.reason) }

if ($wantRamProof -and -not $stRam.skip) {
    $h.Add('/* ---- 3. RAM 运行自证（来源标注，绝不扣留数据）-------------------------')
    $h.Add(' * 只有 TiC2000_RamProofTick() 可以写 gRamProofTick（唯一写者）。')
    $h.Add(' * skill 在下载时钉住 .out/.map，之后检查本函数和计数器是否落在 RAM 段、')
    $h.Add(' * 计数器是否在涨。证据不足只标 UNKNOWN / advancing=False，')
    $h.Add(' * 数据照给——位置从来不是数据判据。')
    $h.Add(' * 【必须】在 .cmd 里把 .TI.ramfunc 的运行地址映射到 RAM，否则自证无效。 */')
    $h.Add('extern volatile unsigned long gRamProofTick;')
    $h.Add('void TiC2000_RamProofTick(void); /* 每 1-10 ms 调一次；FUNC_CANNOT_INLINE 保住独立符号 */')
    $h.Add('')
    $c.Add('volatile unsigned long gRamProofTick = 0UL;')
    $c.Add('')
    $c.Add('#pragma CODE_SECTION(TiC2000_RamProofTick, ".TI.ramfunc")')
    $c.Add('#pragma FUNC_CANNOT_INLINE(TiC2000_RamProofTick)')
    $c.Add('void TiC2000_RamProofTick(void) { ++gRamProofTick; }')
    $c.Add('')
    $next.Add('Call TiC2000_RamProofTick() every 1-10 ms; map .TI.ramfunc RUN to RAM in .cmd.')
    if (-not $sectionFound) {
        Info2 ('NOTE   : .TI.ramfunc was not found in any .cmd - add a RAM RUN mapping or proof stays UNKNOWN')
    }
} elseif ($wantRamProof) { Info2 ('SKIP   : ramProof - ' + $stRam.reason) }

if ($wantDmaFrame -and -not $stDma.skip) {
    $h.Add('/* ---- 4. 连续录波判据（-FrozenBufferReady 用）---------------------------')
    $h.Add(' * gDmaSeq   : 只有整帧写完后才 ++（唯一写者）。')
    $h.Add(' * 连续录波：控制 ISR 每拍存一组，存满置 gDmaReady，之后停止写入。')
    $h.Add(' * DSS 的 ARRAY 按静态符号地址取值，读的是静态数组，传输多久都不会变。')
    $h.Add(' * 数组大小先算：点数 = f_ctrl x T，字数 = 点数 x 变量数；超过 4096 字要合并 RAMGS。')
    $h.Add(' * gDmaReady : 冻结读模式的完成标志（置 1）。')
    $h.Add(' * 发布顺序必须是：写满 bank -> 置 gDmaHalf -> ++gDmaSeq，绝不能颠倒。')
    $h.Add(' * gDmaHalf : 选块标志——读侧无法自己判断哪块缓冲最新，只能靠 gDmaSeq/gDmaHalf 定 bank。')
    $h.Add(' * 两块数组必须是真实 RAM 段里的静态符号；段名在 .cmd 里不存在时，')
    $h.Add(' * 链接器不报错但会把数组随手放到别处（实测踩过，BuffB 全 0）。 */')
    $h.Add(('extern volatile unsigned int {0}[{1}];' -f $DmaArrayA, $DmaRows))
    $h.Add(('extern volatile unsigned int {0}[{1}];' -f $DmaArrayB, $DmaRows))
    $h.Add('extern volatile unsigned long gDmaSeq;')
    $h.Add('extern volatile unsigned int  gDmaHalf;')
    $h.Add('extern volatile unsigned int  gDmaReady;')
    $h.Add('')
    $c.Add(('#pragma DATA_SECTION({0}, "{1}")' -f $DmaArrayA, $DmaSection))
    $c.Add(('volatile unsigned int {0}[{1}];' -f $DmaArrayA, $DmaRows))
    $c.Add(('#pragma DATA_SECTION({0}, "{1}")' -f $DmaArrayB, $DmaSection))
    $c.Add(('volatile unsigned int {0}[{1}];' -f $DmaArrayB, $DmaRows))
    $c.Add('')
    $c.Add('volatile unsigned long gDmaSeq = 0UL;')
    $c.Add('volatile unsigned int  gDmaHalf = 0U;')
    $c.Add('volatile unsigned int  gDmaReady = 0U;')
    $c.Add('')
    $next.Add(('DMA: publish bank via {0}/{1}, ++gDmaSeq after the full frame; DATA_SECTION "{2}" must exist in .cmd.' -f $DmaArrayA, $DmaArrayB, $DmaSection))
    if (-not $sectionFound) {
        Out2 'FAILURE: DMA_SECTION_MISSING'
        Out2 'RESULT: FAIL'
        Out2 ("REASON: section '{0}' not found in any .cmd under {1}" -f $DmaSection, $project)
        Out2 'HINT  : pass -DmaSection <name that exists in your .cmd> (check the MAP file), or add the section first'
        exit 1
    }
} elseif ($wantDmaFrame) { Info2 ('SKIP   : dmaFrame - ' + $stDma.reason) }

$h.Add('#endif /* TI_C2000_CONTRACT_H */')

# --- write or report --------------------------------------------------------
$headerPath = Join-Path $genDir 'ti_c2000_contract.h'
$sourcePath = Join-Path $genDir 'ti_c2000_contract.c'
$anyGenerated = (-not $stId.skip -and $wantIdentity) -or (-not $stHb.skip -and $wantHeartbeat) -or `
                (-not $stRam.skip -and $wantRamProof) -or (-not $stDma.skip -and $wantDmaFrame)

if ($DryRun) {
    Info2 ('DRYRUN : header -> ' + $headerPath)
    Info2 ('DRYRUN : source -> ' + $sourcePath)
} elseif ($anyGenerated) {
    if (-not (Test-Path -LiteralPath $genDir)) { New-Item -ItemType Directory -Force -Path $genDir | Out-Null }
    $enc = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($headerPath, (($h -join "`n") + "`n"), $enc)
    [IO.File]::WriteAllText($sourcePath, (($c -join "`n") + "`n"), $enc)
    Out2 ('CREATED: ' + $headerPath)
    Out2 ('CREATED: ' + $sourcePath)
} else {
    Info2 'CREATED: nothing (all requested modules already exist in the project)'
}

# skill identity is mandatory on every skill command (entry, run and tools)
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ti_c2000_readmode.ps1')
$version = (Get-SkillIdentity).version
Out2 ('SKILL   : ti-c2000-ccs-auto@' + $version)
foreach ($n in $next) { Info2 ('NEXT   : ' + $n) }
Out2 'RESULT: OK'
exit 0
