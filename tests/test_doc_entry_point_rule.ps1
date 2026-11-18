#requires -Version 7.0
# Guards the 2026-11-18 documentation regression that cost an entire afternoon.
#
# SKILL.md and ram-and-linker.md used to instruct callers to build with
# "-EntryPoint code_start". Another conversation followed that literally, produced a
# 592810-byte image, and could never download it: the loader writes .text in 0x800
# pieces, the first block fails with -1041 + FTDI -150, and the core is left in a
# state where the next load reports "Target reset failed. Error: -1".
#
# Prose cannot protect itself, so this test fails if:
#   1. any document passes -EntryPoint code_start in a runnable build command, or
#   2. any line presents it affirmatively (add it / must pass it / fixed command),
#   3. SKILL.md stops stating the _c_int00 rule.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$problems = New-Object System.Collections.Generic.List[string]

$docs = New-Object System.Collections.Generic.List[string]
$docs.Add((Join-Path $root 'SKILL.md'))
$docs.Add((Join-Path $root 'AGENTS.md'))
$refDir = Join-Path $root 'references'
if (Test-Path -LiteralPath $refDir) {
    foreach ($f in (Get-ChildItem -LiteralPath $refDir -Recurse -File -Filter '*.md')) { $docs.Add($f.FullName) }
}

# Words that make a mention clearly negative / historical.
$negWords = @(
    'do not', 'DO NOT', 'never', 'NOT applied', 'refuse', 'wrong', 'was error',
    'xiang fan', 'bu yao', 'jue bu', 'jin zhi', 'cuo wu', 'xie fan', 'bu de', 'bu neng'
)
# Chinese equivalents, kept separate so this file stays parseable as plain ASCII above.
$negCjk = @([char]0x4E0D + [char]0x8981, [char]0x7EDD + [char]0x4E0D, [char]0x7981 + [char]0x6B62,
            [char]0x9519 + [char]0x8BEF, [char]0x5199 + [char]0x53CD, [char]0x4E0D + [char]0x5F97,
            [char]0x4E0D + [char]0x80FD, [char]0x5DF2 + [char]0x63A8 + [char]0x7FFB)

$affirmativePatterns = @('fixed command', 'must pass', 'add -EntryPoint', 'reproduces the old')

$negativeMentions = 0

foreach ($doc in $docs) {
    if (-not (Test-Path -LiteralPath $doc)) { continue }
    $text = [IO.File]::ReadAllText($doc)
    $leaf = Split-Path $doc -Leaf

    # Line-oriented checks: no regex over the whole document, which is what missed the
    # regression when this test was first written.
    $lines = $text.Split([char]10)
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if ($line.IndexOf('code_start', [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

        $isNegative = $false
        foreach ($w in $negWords) {
            if ($line.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $isNegative = $true; break }
        }
        if (-not $isNegative) {
            foreach ($w in $negCjk) {
                if ($line.IndexOf($w, [StringComparison]::Ordinal) -ge 0) { $isNegative = $true; break }
            }
        }
        if ($isNegative) { $negativeMentions++; continue }

        # Rule 1: a runnable build command carrying the switch.
        $isBuildCmd = ($line.IndexOf('ti_c2000_build.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0) -and
                      ($line.IndexOf('-EntryPoint', [StringComparison]::OrdinalIgnoreCase) -ge 0)
        if ($isBuildCmd) {
            $problems.Add(($leaf + ':' + ($i + 1) + ' runnable build command passes -EntryPoint code_start: ' + $line.Trim()))
            continue
        }

        # Rule 2: an affirmative mention is the regression.
        foreach ($p in $affirmativePatterns) {
            if ($line.IndexOf($p, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $problems.Add(($leaf + ':' + ($i + 1) + ' presents -EntryPoint code_start as a recipe: ' + $line.Trim()))
                break
            }
        }
    }
}

# Rule 3: SKILL.md must still state the real rule.
$skillPath = Join-Path $root 'SKILL.md'
if (Test-Path -LiteralPath $skillPath) {
    $skill = [IO.File]::ReadAllText($skillPath)
    if ($skill.IndexOf('_c_int00', [StringComparison]::Ordinal) -lt 0) {
        $problems.Add('SKILL.md no longer states that the entry point must be _c_int00')
    }
}

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Output ('VIOLATION: ' + $p) }
    Write-Output 'RESULT: FAIL'
    exit 1
}

Write-Output ('CHECK   : no document presents -EntryPoint code_start as a build recipe (' + $negativeMentions + ' negative mentions kept)')
Write-Output 'CHECK   : SKILL.md states the _c_int00 rule'
Write-Output 'RESULT: OK'
exit 0
