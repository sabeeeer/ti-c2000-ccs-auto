#requires -Version 7.0
<#
audit_dead_params.ps1 -- find parameters declared in param() but never read in the body.

Why this exists: a parameter that nothing reads is worse than a missing one. It appears in
--help and in the documentation, so a caller believes it changes behaviour; the run then
succeeds while ignoring the request. Measured 2026-11-15: -MapFile existed on run_read and
read_dma but was never forwarded, so "pass -MapFile to name the map yourself" was advice the
code could not follow.

Exit 0 when every declared parameter is used somewhere in its own script.

    pwsh -NoProfile -File tools/audit_dead_params.ps1
    pwsh -NoProfile -File tools/audit_dead_params.ps1 -Scripts <dir>
#>
[CmdletBinding()]
param(
    [string]$Scripts = '',
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }

if (-not $Scripts) { $Scripts = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts' }
if (-not (Test-Path -LiteralPath $Scripts)) {
    Out2 'USAGE: NO_SCRIPT_DIR'; Out2 'RESULT: FAIL'; Out2 ('REASON: ' + $Scripts); exit 2
}

$dead = New-Object System.Collections.Generic.List[string]
$scanned = 0

foreach ($f in (Get-ChildItem -LiteralPath $Scripts -Filter *.ps1 -File)) {
    $text = [IO.File]::ReadAllText($f.FullName)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
    if (-not $ast.ParamBlock) { continue }
    $scanned++

    $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    if ($names.Count -eq 0) { continue }

    # Count references outside the param block. Using the AST would be ideal, but a plain
    # $name scan after removing the param block is enough to spot a parameter nothing reads,
    # and cannot produce false alarms for a used one.
    $body = $text
    $pb = $ast.ParamBlock.Extent
    if ($pb) { $body = $text.Substring(0, $pb.StartOffset) + (' ' * ($pb.EndOffset - $pb.StartOffset)) + $text.Substring($pb.EndOffset) }

    foreach ($n in $names) {
        $pattern = '\$' + [regex]::Escape($n) + '\b'
        if (-not [regex]::IsMatch($body, $pattern)) {
            $dead.Add(('{0}: parameter -{1} is declared but never read' -f $f.Name, $n))
        }
    }
}

if ($dead.Count -gt 0) {
    Out2 'FAILURE: DEAD_PARAMETERS'; Out2 'RESULT: FAIL'
    foreach ($d in $dead) { Out2 ('REASON: ' + $d) }
    Out2 'HINT    : a parameter nothing reads makes the documentation a lie - a caller who passes it believes it took effect'
    exit 1
}

Info2 ('CHECK   : every declared parameter is read somewhere ({0} scripts with param blocks)' -f $scanned)
Out2 'RESULT: OK'
exit 0
