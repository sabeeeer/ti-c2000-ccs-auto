#requires -Version 7.0
<#
check_project_entry.ps1 -- "does this project follow the skill, or does it follow a
stale copy of it?"

Two failures this catches, both invisible until someone runs the wrong script:
  1. a copy of a skill script inside the project  -> the copy wins at run time, so the
     interlocks, the four ReadOnly proofs and the load counter are all bypassed
  2. no AI entry document in the directory the tool opens, or one that still points at
     a deleted copy -> a new session has nothing telling it that the skill exists

It never touches the target and never runs a build: file names and file contents only.

Usage:
  pwsh -NoProfile -File check_project_entry.ps1 -ProjectPath <CCS project folder>

Exit code: 0 clean | 1 violations found | 2 bad arguments
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    # how many levels above the CCS project folder to look for the entry documents
    [int]$EntrySearchDepth = 0,
    # 0 = do not look at the run log. N > 0 requires the newest entry in
    # readout\skill-runs.jsonl to be at most N minutes old and to come from this skill,
    # i.e. proof that the last operation actually went through the skill.
    [int]$MaxRunAgeMinutes = 0,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }
. (Join-Path $PSScriptRoot 'ti_c2000_readmode.ps1')

if (-not (Test-Path -LiteralPath $ProjectPath)) {
    Out2 'USAGE: NO_PROJECT'
    Out2 'RESULT: FAIL'
    Out2 ("REASON: '{0}' does not exist" -f $ProjectPath)
    exit 2
}
$root = (Get-Item -LiteralPath $ProjectPath).FullName

# files that only ever exist because someone copied skill logic into a project
$copyNamePattern = '^ti_c2000_.*\.(ps1|js)$'
$copyExact = @('verify_on_target.ps1', 'dss_load_run_read.js', 'run_hold.js')
# a document naming one of these is steering the next session at a dead endpoint
$deadNames = @('verify_on_target.ps1', 'dss_load_run_read.js', 'ti_c2000_runlog.ps1', 'run_hold.js')
# every entry document must name this, otherwise it is not about this skill
$skillToken = 'ti-c2000-ccs-auto'

$violations = New-Object System.Collections.Generic.List[string]
$notes = New-Object System.Collections.Generic.List[string]

# ---------- 0. 工程改动留痕（BUILD_VERIFICATION.txt）--------------------------
# 工程 AGENTS.md 的硬性规则⑤要求每次改动追加一条，此前完全依赖 AI 自觉。
# 2026-11-18 实测：同一工程两个会话，一个写了 5 条、另一个 0 条 —— 靠自觉不可靠。
# 这里改成机械保证：不存在就当场创建（带表头），存在就报告行数与最后写入时间。
$chgLog = Join-Path $root 'BUILD_VERIFICATION.txt'
if (-not (Test-Path -LiteralPath $chgLog)) {
    $head = @(
        '# 工程记录与改动留痕（BUILD_VERIFICATION.txt）',
        '',
        ('> 首次创建：{0}，由 check_project_entry.ps1 生成' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        '> 规则：第一部分记录系统配置（首次接入时填写，配置变更时同步更新）；第二部分每次修改程序/配置/构建参数时在末尾追加一条（只追加不覆盖）。',
        '',
        '# 第一部分 · 系统配置说明',
        '',
        '- 目标器件 / 核：<待填写，如 TMS320F28335 / C28xx>',
        '- 探针与 ccxml：<待填写，如 XDS100v2 / targetConfigs/TMS320F28335.ccxml>',
        '- 编译器与构建配置：<待填写，如 ti-cgt-c2000_15.12.1.LTS / Debug>',
        '- 系统时钟 / 载波 / 采样频率：<待填写，如 150 MHz / 10 kHz / 10 kHz>',
        '- 关键外设与引脚分配：<待填写，如 EPWM1~3 / ADCINA0~A5 / GPIO52~55>',
        '- 核心模块与运行模式：<待填写，如 开环/闭环、主要模块清单>',
        '',
        '---',
        '',
        '# 第二部分 · 改动留痕',
        '',
        '格式：日期 | 改了什么 | 为什么 | 验证结果（编译/上板/未上板）。只追加，不覆盖。',
        '（build.ps1 / service.ps1 成功时会自动追加 build / load 记录。）',
        '--------------------------------------------------------------------------------'
    ) -join "`r`n"
    try {
        [IO.File]::WriteAllText($chgLog, $head + "`r`n", (New-Object Text.UTF8Encoding($false)))
        $notes.Add('created BUILD_VERIFICATION.txt (project change log) - append one entry per change')
    } catch {
        $violations.Add(('cannot create BUILD_VERIFICATION.txt: {0}' -f $_.Exception.Message))
    }
} else {
    $nLines = @([IO.File]::ReadAllLines($chgLog)).Count
    $notes.Add(('BUILD_VERIFICATION.txt: {0} lines, last write {1}' -f $nLines, (Get-Item -LiteralPath $chgLog).LastWriteTime.ToString('MM-dd HH:mm')))
}

# ---------- 1. copies of skill scripts inside the project ------------------------
$copies = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include *.ps1, *.js -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\\.git\\' } |
    Where-Object { $_.Name -match $copyNamePattern -or $copyExact -contains $_.Name })
if ($copies.Count -gt 0) {
    foreach ($c in $copies) {
        $rel = $c.FullName.Substring($root.Length).TrimStart('\')
        $violations.Add(('skill script copy in the project: {0}' -f $rel))
    }
} else {
    $notes.Add('no skill script copies inside the project')
}

# ---------- 2. an entry document the opening tool will actually read ------------
# Walk every level instead of stopping at the first one that has any entry file: the CCS
# project folder usually holds its own CODEBUDDY.md, while the folder an AI tool opens
# (and therefore reads AGENTS.md from) is one level above. Stopping early is exactly how
# "the document exists but nobody reads it" happens.
$entryNames = @('AGENTS.md', 'CODEBUDDY.md', 'CLAUDE.md')
$rootEntries = @($entryNames | ForEach-Object { Join-Path $root $_ })
$missingRoot = @($rootEntries | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missingRoot.Count -gt 0) {
    # 自动触发（2026-11-18 用户要求）：调用 skill 就该产生可验证的事件，
    # 而不是等某个 AI 记得去跑 tools\init_project_entry.ps1。
    # 该工具只在缺失时写入，已有内容一律 SKIP 或 REFUSE，不会覆盖手写规则。
    $skillRootForInit = Split-Path $PSScriptRoot -Parent
    $initTool = Join-Path $skillRootForInit 'tools\init_project_entry.ps1'
    if (Test-Path -LiteralPath $initTool) {
        $initOut = @(& $initTool -ProjectPath $root 2>&1)
        foreach ($line in $initOut) {
            if ([string]$line -match 'CREATED|SKIP|REFUSE|EXISTS') { $notes.Add('init: ' + ([string]$line).Trim()) }
        }
        $missingRoot = @($rootEntries | Where-Object { -not (Test-Path -LiteralPath $_) })
    }
    if ($missingRoot.Count -gt 0) {
        $violations.Add(('project root is missing AI entry file(s): ' + (($missingRoot | ForEach-Object { Split-Path -Leaf $_ }) -join ', ') + '; run tools/init_project_entry.ps1 or merge existing instructions'))
    } else {
        $notes.Add('auto-created the missing AI entry file(s) via init_project_entry.ps1')
    }
} else {
    $entryTexts = @($rootEntries | ForEach-Object { [IO.File]::ReadAllText($_) })
    if (@($entryTexts | Sort-Object -Unique).Count -ne 1) {
        $violations.Add('project root AGENTS.md / CODEBUDDY.md / CLAUDE.md differ; AI tools would follow different rules')
    }
}
$dir = $root
$found = @()
for ($i = 0; $i -le $EntrySearchDepth -and $dir; $i++) {
    $hit = @($entryNames | ForEach-Object { Join-Path $dir $_ } | Where-Object { Test-Path -LiteralPath $_ })
    if ($hit.Count -gt 0) { $found += [pscustomobject]@{ dir = $dir; files = $hit } }
    $parent = Split-Path -Parent $dir
    if (-not $parent -or $parent -eq $dir) { break }
    $dir = $parent
}

if ($found.Count -eq 0) {
    $violations.Add(('no AI entry document (AGENTS.md / CODEBUDDY.md / CLAUDE.md) in {0} or up to {1} levels above' -f $root, $EntrySearchDepth))
} else {
    foreach ($layer in $found) { $notes.Add(('entry documents in {0}' -f $layer.dir)) }
    $hasAgents = $false
    foreach ($layer in $found) {
        foreach ($f in $layer.files) {
            $name = Split-Path -Leaf $f
            if ($name -eq 'AGENTS.md') { $hasAgents = $true }
            $label = Join-Path $layer.dir $name
            $text = ''
            try { $text = [IO.File]::ReadAllText($f) } catch {
                $violations.Add(('unreadable entry document: {0}' -f $label))
                continue
            }
            if ($text -notmatch [regex]::Escape($skillToken)) {
                $violations.Add(('{0} does not mention {1}, so it does not point at the skill' -f $label, $skillToken))
            }
            # line by line: naming a deleted copy is only wrong when the line is telling
            # someone to run it. "do not use X" / "X was deleted" is the fix, not the fault.
            $lineno = 0
            foreach ($line in ($text -split "`r?`n")) {
                $lineno++
                $named = @($deadNames | Where-Object { $line -match [regex]::Escape($_) })
                if ($named.Count -eq 0) { continue }
                if ($line -match '删除|删掉|已删|不要|禁止|不许|改用|换成|deleted|removed|do not|don''t|never|instead of') { continue }
                $violations.Add(('{0}:{1} still names the deleted copy {2} as something to run - rewrite that line to call the skill' -f $label, $lineno, ($named -join ', ')))
            }
        }
    }
    # Codex and other tools read AGENTS.md; CodeBuddy reads CODEBUDDY.md. A project that
    # only ships the CodeBuddy file silently loses every non-CodeBuddy tool.
    if (-not $hasAgents) {
        $violations.Add('AGENTS.md is missing in every level searched - Codex / generic tools would open this project with no entry document at all')
    }
}

# ---------- 3. proof that the last operation came from this skill ----------------
# Documents ask; the run log proves. Every entry point stamps readout\skill-runs.jsonl
# with its script, this skill's directory and the content version, so "the last thing
# that touched this project really was the skill" becomes a fact that can be checked.
if ($MaxRunAgeMinutes -gt 0) {
    $log = Join-Path $root 'readout\skill-runs.jsonl'
    $skillRoot = Split-Path $PSScriptRoot -Parent
    if (-not (Test-Path -LiteralPath $log)) {
        $violations.Add(('no skill run recorded in {0} - nothing in this project has gone through the skill yet' -f $log))
    } else {
        $last = $null
        try {
            $last = @(Get-Content -LiteralPath $log -Encoding utf8 | Where-Object { $_.Trim() } | Select-Object -Last 1)[0] | ConvertFrom-Json
        } catch { }
        if (-not $last) {
            $violations.Add('readout\skill-runs.jsonl exists but the last line is unreadable')
        } elseif ([string]$last.version -ne (Get-SkillIdentity).version) {
            $violations.Add(('the newest run used skill version {0}, current installed version is {1}' -f $last.version,(Get-SkillIdentity).version))
        } else {
            $age = $null
            try { $age = ((Get-Date) - [datetime]::ParseExact([string]$last.at, 'yyyy-MM-dd HH:mm:ss', $null)).TotalMinutes } catch { }
            if ($null -eq $age) {
                $violations.Add(('the newest skill run has an unreadable timestamp: {0}' -f $last.at))
            } elseif ($age -gt $MaxRunAgeMinutes) {
                $violations.Add(('the newest skill run is {0:N0} min old (limit {1}) - start one from the skill before trusting this project' -f $age, $MaxRunAgeMinutes))
            } elseif (([string]$last.skill).TrimEnd('\') -ne $skillRoot.TrimEnd('\')) {
                $violations.Add(('the newest run came from another skill copy ({0}), not from {1}' -f $last.skill, $skillRoot))
            } else {
                $notes.Add(('last skill run: {0} by {1} ({2}), skill@ {3}' -f $last.at, $last.script, $last.mode, $last.version))
            }
        }
    }
}

# ---------- report ---------------------------------------------------------------
Info2 ('PROJECT : ' + $root)
$skillVersion = (Get-SkillIdentity).version
Out2 ('SKILL   : ti-c2000-ccs-auto@' + $skillVersion)
foreach ($n in $notes) { Info2 ('CHECK   : ' + $n) }
if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Out2 ('VIOLATION: ' + $v) }
    Out2 'RESULT: FAIL'
    Out2 ('REASON: {0} violation(s) - the project would not run through the skill' -f $violations.Count)
    Out2 'HINT    : delete the copies; keep AGENTS.md + CODEBUDDY.md + CLAUDE.md identical and pointing at the skill'
    exit 1
}
Out2 ('CHECK   : {0} entry document(s), 0 copies' -f $found.files.Count)
Out2 'RESULT: OK'
exit 0
