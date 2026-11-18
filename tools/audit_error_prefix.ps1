#requires -Version 7.0
<#
audit_error_prefix.ps1 -- every error code must use the prefix that matches its exit code.

Two kinds of failure, two very different meanings:

  USAGE: <CODE>   exit 2   the COMMAND is wrong (missing/conflicting arguments).
                              Nothing was measured; nothing can be trusted or distrusted yet.
  FAILURE: <CODE>   exit 1/3/4
                              the WORK is wrong: build failed (1), probe/board refused (3),
                              data does not prove what it claims (4).

Why this matters: mixing them makes a missing parameter look like a validation that
refused to download. Measured 2026-11-16 - "-CorePattern was empty so five CPUs matched"
printed FAILURE: AMBIGUOUS_CORE and read as a judgement about the board.

There are no FAILURE + exit 2 exceptions. Installation and probe errors use exit 1/3/4.

Usage:
  pwsh -NoProfile -File tools/audit_error_prefix.ps1
  pwsh -NoProfile -File tools/audit_error_prefix.ps1 -SelfTest

Exit code: 0 consistent (or self-test passed) | 1 drift found / self-test failed
#>
[CmdletBinding()]
param(
    [string]$SkillRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
function Out2($m) { Write-Output $m }

function Test-Dir([string]$scripts) {
    $issues = @()
    Get-ChildItem $scripts -Filter *.ps1 -ErrorAction SilentlyContinue | Where-Object Name -ne 'audit_error_prefix.ps1' | ForEach-Object {
        $name = $_.Name
        $ls = [IO.File]::ReadAllLines($_.FullName)
        for ($i = 0; $i -lt $ls.Count; $i++) {
            $line = $ls[$i]
            $code = $null
            $kind = $null
            if ($line -match '(?:Out2|Write-Output)\s+[''"]USAGE: ([A-Z_]+)') { $code = $Matches[1]; $kind = 'USAGE' }
            elseif ($line -match '(?:Out2|Write-Output)\s+[''"]FAILURE: ([A-Z_]+)') { $code = $Matches[1]; $kind = 'FAILURE' }
            if (-not $code) { continue }

            $ex = $null
            for ($j = $i; $j -lt [Math]::Min($i + 12, $ls.Count); $j++) {
                if ($ls[$j] -match '\bexit (\d+)') { $ex = [int]$Matches[1]; break }
            }

            if ($kind -eq 'USAGE' -and $ex -ne 2) {
                $issues += ('{0}:{1}  USAGE {2} with exit={3}; a wrong command must exit 2' -f $name, ($i + 1), $code, $ex)
            }
            if ($kind -eq 'FAILURE' -and $ex -eq 2) {
                $issues += ('{0}:{1}  FAILURE {2} with exit 2; use USAGE + 2 or FAILURE + 1/3/4' -f $name, ($i + 1), $code)
            }
        }
    }
    return $issues
}

if ($SelfTest) {
    # A detector that has never fired is not a detector. Plant one of each kind of drift and
    # require both to be reported; also plant correct code and require silence about it.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('c2000-prefix-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $enc = New-Object Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText((Join-Path $tmp 'bad1.ps1'), @'
if ($x) {
    Out2 'USAGE: SOME_ARG'
    exit 4
}
'@, $enc)
        [IO.File]::WriteAllText((Join-Path $tmp 'bad2.ps1'), @'
if ($y) {
    Out2 'FAILURE: SOME_VALIDATION'
    exit 2
}
'@, $enc)
        [IO.File]::WriteAllText((Join-Path $tmp 'good.ps1'), @'
if ($z) {
    Out2 'USAGE: NEED_THING'
    exit 2
}
if ($w) {
    Out2 'FAILURE: DATA_NOT_TRUSTWORTHY'
    exit 4
}
'@, $enc)

        $found = @(Test-Dir $tmp)
        $bad1 = @($found | Where-Object { $_ -match 'bad1\.ps1' }).Count
        $bad2 = @($found | Where-Object { $_ -match 'bad2\.ps1' }).Count
        $good = @($found | Where-Object { $_ -match 'good\.ps1' }).Count

        if ($bad1 -ne 1 -or $bad2 -ne 1 -or $good -ne 0) {
            Out2 'FAILURE: AUDIT_SELFTEST_FAILED'
            Out2 ('REASON: planted drift was not reported as expected (bad1={0}/1, bad2={1}/1, good-false-positives={2}/0)' -f $bad1, $bad2, $good)
            Out2 'RESULT: FAIL'
            exit 1
        }
        Out2 '自检通过：两类漂移都被抓到，正确写法零误报'
        Out2 'RESULT: OK'
        exit 0
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$scripts = Join-Path $SkillRoot 'scripts'
if (-not (Test-Path -LiteralPath $scripts)) {
    Out2 'FAILURE: NO_SCRIPTS_DIR'
    Out2 ('REASON: ' + $scripts + ' not found')
    Out2 'RESULT: FAIL'
    exit 1
}

$problems = @((Test-Dir $scripts); (Test-Dir (Join-Path $SkillRoot 'tools'))) | Where-Object { $_ }
if ($problems.Count -gt 0) {
    Out2 'FAILURE: ERROR_PREFIX_MISMATCH'
    foreach ($p in $problems) { Out2 ('  ' + $p) }
    Out2 'REASON: a code uses the prefix of the other class; a wrong command must be USAGE + exit 2'
    Out2 'RESULT: FAIL'
    exit 1
}
Out2 '分类一致：USAGE<->exit 2，FAILURE<->exit 1/3/4'
Out2 'RESULT: OK'
exit 0
