#requires -Version 7.0
# 守住 SKILL.md 的「硬约束 ② 改动前影响评估」不被删除或稀释。
#
# 背景（2026-11-19 用户要求）：
#   改 skill 必须先评估：改的是哪一层、谁依赖、会不会挖坑、三件套是否同步、验证到什么程度。
#   上板不作强制要求，但**没上板必须写明"未上板"**，不许暗示已验证。
#
# 这个测试只做文本契约检查：不连板、不改任何东西、不参与任何门禁。
# 规则被删掉或措辞被稀释时它会变红 —— 提醒下一个 AI，而不是拦截操作。
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$bad = New-Object System.Collections.Generic.List[string]
$checks = 0

function Check([string]$label, [bool]$ok, [string]$detail) {
    $script:checks++
    if (-not $ok) { $bad.Add(('{0}: {1}' -f $label, $detail)) }
}

try {
    $p = Join-Path $root 'SKILL.md'
    if (-not (Test-Path -LiteralPath $p)) { throw 'SKILL.md missing' }
    $skill = [IO.File]::ReadAllText($p)

    Check 'rule 2 exists' `
        ($skill -match '###\s*②\s*改动前必须做影响评估') `
        'the "hard rule 2: impact assessment" heading is gone'

    foreach ($q in @('改动落在哪一层', '谁依赖它', '会不会挖坑', '同步三件套', '验证到什么程度')) {
        Check ('five questions: ' + $q) `
            ($skill -match [regex]::Escape($q)) `
            ('the question "' + $q + '" disappeared from the table')
    }

    Check 'not-on-board wording exists' `
        ($skill -match '未上板') `
        'the phrase "未上板" is gone; changes could silently claim verification'

    Check 'no mandatory on-board gate' `
        ($skill -notmatch '\*\*必须上板\*\*') `
        'the rule became a hard on-board requirement again; user asked for "label honestly", not "must be on board"'

    Check 'delivery format has four fields' `
        ($skill -match '改动：' -and $skill -match '影响：' -and $skill -match '验证：' -and $skill -match '遗留：') `
        'the four-field delivery template is incomplete'

    Check 'rule is visible to the user, not silent' `
        ($skill -match '评估必须写进回复里') `
        'the "print the assessment into the reply" clause is gone; the rule becomes invisible'

    Check 'contract test is referenced from the rule' `
        ($skill -match 'test_skill_change_rule\.ps1') `
        'the rule no longer points at this test'

    Check 'rule does not become a gate' `
        ($skill -match '不挂 hooks' -and $skill -match '不产生\s*`exit`\s*非零') `
        'the rule must stay advisory: no hooks, no non-zero exit'
}
catch {
    $bad.Add(('exception: ' + $_.Exception.Message))
}

if ($bad.Count -gt 0) {
    foreach ($b in $bad) { Write-Host ('FAILED  ' + $b) }
    Write-Host ('RESULT: FAIL ({0} checks, {1} failed)' -f $checks, $bad.Count)
    exit 1
}

Write-Host ('PASS    {0} checks: hard rule 2 (impact assessment) is present and still advisory' -f $checks)
Write-Host 'RESULT: OK'
exit 0
