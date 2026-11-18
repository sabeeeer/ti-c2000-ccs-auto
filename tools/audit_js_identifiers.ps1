#requires -Version 7.0
<#
audit_js_identifiers.ps1 -- find ALL_CAPS identifiers used in a DSS template but never
defined in it.

Why this exists: a DSS template is JavaScript embedded in a PowerShell here-string. A typo
or a leftover reference (WARMUP, used by ti_c2000_read_continuous.ps1 after the boot sequence moved
to ti_c2000_dss_boot.js) compiles silently in PowerShell and only fails inside Rhino, on the
board, before a single byte is read. That is the most expensive class of bug in this skill.

How it decides:
  * takes the JS region of each template (the @' ... '@ or @" ... "@ here-string);
  * collects what the block defines: `var X`, `function X`, `function f(X)`, and
    `X = $(...)` / `X = $var` (PowerShell interpolation writes the value into a JS variable);
  * collects ALL_CAPS references outside string literals, skipping JS built-ins;
  * reports every reference with no definition.

-SelfTest plants the exact bug and fails if it is not reported, and also fails if the
detector complains about clean code. A detector that has never fired proves nothing.

    pwsh -NoProfile -File tools/audit_js_identifiers.ps1
    pwsh -NoProfile -File tools/audit_js_identifiers.ps1 -Scripts <dir>
    pwsh -NoProfile -File tools/audit_js_identifiers.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [string]$Scripts = '',
    [switch]$SelfTest,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }

$jsKeywords = @('NUMBER', 'STRING', 'BOOLEAN', 'OBJECT', 'FUNCTION', 'ARRAY', 'MATH', 'TRUE', 'FALSE', 'NAN', 'INFINITY')

# here-string open / close, accepting both quote styles. Written as two -match tests so no
# nested quoting is needed: "@'\s*$" and '@"\s*$' are each a single literal.
function Test-HereStringOpen([string]$line) {
    if ($line -match "@'\s*$") { return $true }
    if ($line -match '@"\s*$') { return $true }
    return $false
}
function Test-HereStringClose([string]$line) {
    if ($line -match "^\s*'@\s*$") { return $true }
    if ($line -match '^\s*"@\s*$') { return $true }
    return $false
}

function Get-UndefinedConstants {
    param([Parameter(Mandatory)][string]$Directory)

    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($f in (Get-ChildItem -LiteralPath $Directory -Filter *.ps1 -File)) {
        $lines = [IO.File]::ReadAllLines($f.FullName)
        $inJs = $false; $jsLines = @(); $startLine = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $l = $lines[$i]
            if (-not $inJs -and (Test-HereStringOpen $l)) { $inJs = $true; $jsLines = @(); $startLine = $i + 1; continue }
            if ($inJs -and (Test-HereStringClose $l)) {
                $inJs = $false
                $js = ($jsLines -join "`n")
                if (-not $js.Trim()) { continue }

                $defined = @()
                foreach ($m in [regex]::Matches($js, '\bvar\s+([A-Za-z_]\w*)')) { $defined += $m.Groups[1].Value }
                foreach ($m in [regex]::Matches($js, '\bfunction\s+([A-Za-z_]\w*)')) { $defined += $m.Groups[1].Value }
                foreach ($m in [regex]::Matches($js, '\b([A-Za-z_]\w*)\s*=\s*\$\(')) { $defined += $m.Groups[1].Value }
                foreach ($m in [regex]::Matches($js, '\b([A-Za-z_]\w*)\s*=\s*\$\w')) { $defined += $m.Groups[1].Value }
                foreach ($m in [regex]::Matches($js, '\bfunction\s+\w+\s*\(([^)]*)\)')) {
                    foreach ($p in ($m.Groups[1].Value -split ',')) {
                        $n = $p.Trim()
                        if ($n) { $defined += $n }
                    }
                }

                # Strip comments FIRST: a comment is prose ("NOT connected", "// DSS:
                # connected", "the NEXT session") and its capitalised words are not
                # identifiers. Stripping strings first would let an apostrophe inside a
                # comment ("don't") open a bogus string literal and swallow the code after
                # it.
                $code = [regex]::Replace($js, '(?m)//.*$', '')
                $code = [regex]::Replace($code, '/\*[\s\S]*?\*/', '')
                $noStrings = [regex]::Replace($code, '"(?:[^"\\]|\\.)*"', '""')
                $noStrings = [regex]::Replace($noStrings, "'(?:[^'\\]|\\.)*'", "''")
                $refs = [regex]::Matches($noStrings, '(?<![\w$."''])([A-Z][A-Z0-9_]{2,})\b') |
                    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
                foreach ($r in $refs) {
                    if ($jsKeywords -contains $r) { continue }
                    if ($defined -contains $r) { continue }
                    $problems.Add(('{0} (JS block from line {1}): uses {2} but never defines it' -f $f.Name, $startLine, $r))
                }
                continue
            }
            if ($inJs) { $jsLines += $l }
        }
    }
    return $problems
}

# ---------------------------------------------------------------- self test -----
if ($SelfTest) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('jsid-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        $broken = @(
            '$js = @"'
            'var A = 1;'
            'var B = A + NOT_DEFINED_ANYWHERE;'
            'function useC(v) { return v + ALSO_MISSING; }'
            'var C = "QUOTED_IS_FINE";'
            '"@'
        ) -join "`r`n"
        $good = @(
            '$js = @'''
            'var A = 1;'
            'var B = A + 2;'
            'function useC(v) { return v + A; }'
            'var D = $(powerShellValue);'
            "'@"
        ) -join "`r`n"
        [IO.File]::WriteAllText((Join-Path $dir 'broken.ps1'), $broken, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $dir 'good.ps1'), $good, (New-Object Text.UTF8Encoding($false)))

        $found = Get-UndefinedConstants -Directory $dir
        $miss1 = -not @($found | Where-Object { $_ -match 'NOT_DEFINED_ANYWHERE' }).Count
        $miss2 = -not @($found | Where-Object { $_ -match 'ALSO_MISSING' }).Count
        $noise = @($found | Where-Object { $_ -match 'QUOTED_IS_FINE|good\.ps1' })

        if ($miss1 -or $miss2) {
            Out2 'FAILURE: AUDIT_DETECTOR_BLIND'; Out2 'RESULT: FAIL'
            Out2 ('REASON: planted undefined constants were not reported (found: ' + (($found | ForEach-Object { $_ }) -join '; ') + ')')
            exit 1
        }
        if ($noise.Count -gt 0) {
            Out2 'FAILURE: AUDIT_DETECTOR_NOISY'; Out2 'RESULT: FAIL'
            Out2 ('REASON: ' + ($noise -join '; '))
            exit 1
        }
        Out2 'CHECK   : detector fires on planted bugs and stays quiet on clean code'
        Out2 'RESULT: OK'
        exit 0
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------- audit -----
if (-not $Scripts) { $Scripts = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts' }
if (-not (Test-Path -LiteralPath $Scripts)) {
    Out2 'USAGE: NO_SCRIPT_DIR'; Out2 'RESULT: FAIL'; Out2 ('REASON: ' + $Scripts); exit 2
}

$problems = Get-UndefinedConstants -Directory $Scripts
if ($problems.Count -gt 0) {
    Out2 'FAILURE: JS_UNDEFINED_IDENTIFIER'; Out2 'RESULT: FAIL'
    foreach ($p in $problems) { Out2 ('REASON: ' + $p) }
    Out2 'HINT    : a DSS template is JavaScript inside a here-string; PowerShell cannot see this - only Rhino can, on the board'
    exit 1
}
Info2 ('CHECK   : every DSS template defines the constants it references ({0} files scanned)' -f (Get-ChildItem -LiteralPath $Scripts -Filter *.ps1 -File).Count)
Out2 'RESULT: OK'
exit 0
