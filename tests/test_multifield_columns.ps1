#requires -Version 7.0
# 结构体数组（多字段）读法的契约测试——离线，不需要板卡和 CCS。
#
# 背景（2026-11-18 实测，commit 1491c4f）：
#   gCtrlFrozen 是 CtrlLog_t{Uint16 ia; Uint16 dac;}[1000]，共 2000 字。
#   正确用法 -Rows 1000 -Columns 2 -> anchor SKIPPED（多字段）、count 是结构判据、RESULT: OK。
#   错误用法 -Rows 2000 -Columns 1 -> anchor FAILED（结构体 evaluate 不了）-> DATA_UNRELIABLE。
#   代码修好了，但当时 SKILL.md 和 references 没同步，下一个 AI 照抄示例就会重犯。
#
# 这个测试锁死三件事：
#   1. live_read.ps1 里仍存在 "Columns -gt 1 -> SKIPPED" 的分支（谁删了它这里就红）
#   2. SKILL.md 的读数组示例带 -Columns，并写明 Rows 是元素数
#   3. single-session-read.md 有结构体数组小节和正确/错误输出对照
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$bad = New-Object System.Collections.Generic.List[string]
$checks = 0

function Read-Text([string]$rel) {
    $p = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $p)) { throw "missing file: $rel" }
    return [IO.File]::ReadAllText($p)
}

function Check([string]$label, [bool]$ok, [string]$detail) {
    $script:checks++
    if (-not $ok) { $bad.Add(('{0}: {1}' -f $label, $detail)) }
}

try {
    # ---------- 1. 代码分支仍存在 ----------
    $live = Read-Text 'scripts/ti_c2000_live_read.ps1'
    Check 'live_read: multi-field anchor branch' `
        ($live -match 'if\s*\(\s*\$Columns\s*-gt\s*1\s*\)') `
        'the "Columns > 1" branch disappeared; multi-field arrays would fail the anchor again'
    Check 'live_read: SKIPPED wording' `
        ($live -match 'CHECK anchor : SKIPPED') `
        'multi-field arrays must print "CHECK anchor : SKIPPED", not FAILED'
    Check 'live_read: multi-column CSV header' `
        ($live -match "'c\{0\}'") `
        'CSV must be index,c1..cN for multi-field arrays'
    Check 'live_read: LAYOUT line' `
        ($live -match 'LAYOUT\s+:') `
        'a LAYOUT line must tell the caller each row is one struct element'

    # ---------- 2. SKILL.md 主入口示例 ----------
    $skill = Read-Text 'SKILL.md'
    Check 'SKILL.md: read example carries -Columns' `
        ($skill -match '-Columns\s*<字段数>') `
        'the main read_continuous example must show -Columns <字段数>'
    Check 'SKILL.md: says Rows is element count' `
        ($skill -match '`-Rows` 是元素个数') `
        'SKILL.md must state that -Rows is the element count, not the word count'
    Check 'SKILL.md: struct example 1000 x 2' `
        ($skill -match 'gCtrlFrozen\[1000\].*\|\s*\*\*1000\*\*.*\|\s*\*\*2\*\*') `
        'SKILL.md must give the concrete CtrlLog_t[1000] -> Rows 1000 / Columns 2 mapping'
    Check 'SKILL.md: no stale anchor sentence' `
        ($skill -notmatch '首元素 evaluate 与 readData 一致\s*$') `
        'the old sentence promising an anchor compare must be qualified for multi-field arrays'

    # ---------- 3. 读模式文档 ----------
    $ref = Read-Text 'references/single-session-read.md'
    Check 'single-session-read: struct section' `
        ($ref -match '结构体数组（多字段）') `
        'missing the "struct array: Rows/Columns" section'
    Check 'single-session-read: correct output sample' `
        ($ref -match 'CHECK anchor : SKIPPED') `
        'the document must show the SKIPPED output as the correct result'
    Check 'single-session-read: the wrong-usage trap' `
        ($ref -match 'could not be evaluated') `
        'the document must name the wrong usage (Rows=words, Columns default) and its symptom'

    # ---------- 4. 关键字面一致性：主入口不能只有单列示例 ----------
    $singleOnly = @([regex]::Matches($skill, '-ArrayName\s+\S+\s+-Rows\s+\d+\s+-Mode') | ForEach-Object { $_.Value })
    Check 'SKILL.md: no read_continuous example without -Columns' `
        ($singleOnly.Count -eq 0) `
        ('these examples omit -Columns: ' + ($singleOnly -join ' ; '))
}
catch {
    $bad.Add(('exception: ' + $_.Exception.Message))
}

if ($bad.Count -gt 0) {
    foreach ($b in $bad) { Write-Host ('FAILED  ' + $b) }
    Write-Host ('RESULT: FAIL ({0} checks, {1} failed)' -f $checks, $bad.Count)
    exit 1
}

Write-Host ('PASS    {0} checks: code branch + SKILL.md + single-session-read.md stay in sync' -f $checks)
Write-Host 'RESULT: OK'
exit 0
