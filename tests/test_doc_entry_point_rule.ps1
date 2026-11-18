#requires -Version 7.0
# Guards the entry-point rule from BOTH directions, because this rule has been written
# wrong twice already:
#
#   2026-11-15  "never pass -EntryPoint"        <- wrong conclusion from a swallowed argument
#   2026-11-18  "never pass code_start, must be _c_int00"  <- wrong again, same root cause
#
# What is actually true (see ti_c2000_build.ps1 comments):
#   * the entry symbol must FOLLOW .cproject linkerID.ENTRY_POINT (code_start here)
#   * it must be passed as the LONG form --entry_point=<sym>; the short form
#     "-e <sym>" is swallowed after -z ... --reread_libs, so the .out keeps _c_int00
#     while the log claims otherwise -> loadProgram starts the CPU at unwritten .text
#     -> bus hog -> first write 0x8000 fails with -1041 + FTDI -150
#   * the link must be verified against the .map afterwards (ENTRY_POINT_NOT_APPLIED)
#
# So this test enforces:
#   1. build.ps1 uses the long form and never the short form
#   2. build.ps1 verifies the result in the map
#   3. documents describe the long form + map check
#   4. documents do NOT claim "must be _c_int00" / "never pass code_start"
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$problems = New-Object System.Collections.Generic.List[string]

# ---- 1/2) code rules -------------------------------------------------------
$buildPath = Join-Path $root 'scripts\ti_c2000_build.ps1'
$build = [IO.File]::ReadAllText($buildPath)

if ($build.IndexOf('--entry_point=', [StringComparison]::Ordinal) -lt 0) {
    $problems.Add('build.ps1 no longer passes the entry point as --entry_point=<sym> (long form)')
}
if ($build -match "@\(\s*'-e'\s*,\s*\$EntryPoint\s*\)") {
    $problems.Add('build.ps1 is back to the short form -e <sym>, which is swallowed by cl2000')
}
if ($build.IndexOf('ENTRY_POINT_NOT_APPLIED', [StringComparison]::Ordinal) -lt 0) {
    $problems.Add('build.ps1 no longer verifies the entry point against the .map (ENTRY_POINT_NOT_APPLIED)')
}
if ($build.IndexOf('linkerID.ENTRY_POINT', [StringComparison]::Ordinal) -lt 0) {
    $problems.Add('build.ps1 no longer reads linkerID.ENTRY_POINT from .cproject')
}

# service.ps1 must judge "conflicts with .cproject", not "differs from _c_int00".
$svcPath = Join-Path $root 'scripts\ti_c2000_service.ps1'
$svc = [IO.File]::ReadAllText($svcPath)
if ($svc.IndexOf('$declaredEntrySym', [StringComparison]::Ordinal) -lt 0) {
    $problems.Add('service.ps1 no longer compares the map entry against the .cproject declaration')
}

# ---- 3/4) document rules ---------------------------------------------------
$docs = New-Object System.Collections.Generic.List[string]
$docs.Add((Join-Path $root 'SKILL.md'))
$refDir = Join-Path $root 'references'
if (Test-Path -LiteralPath $refDir) {
    foreach ($f in (Get-ChildItem -LiteralPath $refDir -Recurse -File -Filter '*.md')) {
        if ($f.Name -eq 'test_doc_entry_point_rule.md') { continue }
        $docs.Add($f.FullName)
    }
}

# Phrases that encode the WRONG conclusion. They may only appear inside an explicit
# "this was wrong / 已被推翻 / 历史坑" context, so check the same line for a marker.
$wrongPhrases = @(
    'must be _c_int00',
    'must not pass',
    'never pass',
    '_c_int00 only',
    'only _c_int00'
)
$cjkWrong = @(
    ([string]([char]0x7EDD + [char]0x4E0D + [char]0x80FD + [char]0x4F20)),   # 绝不能传
    ([string]([char]0x5FC5 + [char]0x987B + [char]0x662F))                    # 必须是
)
$retractMarkers = @(
    'wrong', 'was wrong', 'overturned', 'retracted', 'WRONG',
    ([string]([char]0x5DF2 + [char]0x88AB + [char]0x63A8 + [char]0x7FFB)),    # 已被推翻
    ([string]([char]0x9519 + [char]0x8BEF)),                                  # 错误
    ([string]([char]0x5199 + [char]0x53CD)),                                  # 写反
    ([string]([char]0x5386 + [char]0x53F2 + [char]0x5751)),                   # 历史坑
    ([string]([char]0x5E9F + [char]0x8BDD))                                   # 废话
)

$mentionsLongForm = 0
foreach ($doc in $docs) {
    if (-not (Test-Path -LiteralPath $doc)) { continue }
    $text = [IO.File]::ReadAllText($doc)
    $leaf = Split-Path $doc -Leaf
    if ($text.IndexOf('--entry_point=', [StringComparison]::Ordinal) -ge 0) { $mentionsLongForm++ }

    $lines = $text.Split([char]10)
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if ($line.IndexOf('code_start', [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
            $line.IndexOf('_c_int00', [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

        # A retraction marker may sit on the previous line (e.g. "**历史坑**：" then a
        # quoted old rule), so look at the current line plus the one before it.
        $ctx = $line
        if ($i -gt 0) { $ctx = $lines[$i - 1] + $line }
        $hasRetract = $false
        foreach ($m in $retractMarkers) {
            if ($ctx.IndexOf($m, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hasRetract = $true; break }
        }
        if ($hasRetract) { continue }

        foreach ($w in $wrongPhrases) {
            if ($line.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $problems.Add(($leaf + ':' + ($i + 1) + ' states the retracted rule: ' + $line.Trim()))
                break
            }
        }
        foreach ($w in $cjkWrong) {
            if ($line.IndexOf($w, [StringComparison]::Ordinal) -ge 0) {
                $problems.Add(($leaf + ':' + ($i + 1) + ' states the retracted rule: ' + $line.Trim()))
                break
            }
        }
    }
}

if ($mentionsLongForm -lt 2) {
    $problems.Add(('documents rarely mention the long form --entry_point= ({0} file(s)); the rule needs to be visible' -f $mentionsLongForm))
}

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Output ('VIOLATION: ' + $p) }
    Write-Output 'RESULT: FAIL'
    exit 1
}

Write-Output 'CHECK   : build.ps1 uses --entry_point=<sym> (long form), no short -e'
Write-Output 'CHECK   : build.ps1 verifies the entry point in the .map (ENTRY_POINT_NOT_APPLIED)'
Write-Output 'CHECK   : service.ps1 compares against the .cproject declaration, not against _c_int00'
Write-Output ('CHECK   : no document states the retracted rule ({0} file(s) document the long form)' -f $mentionsLongForm)
Write-Output 'RESULT: OK'
exit 0
