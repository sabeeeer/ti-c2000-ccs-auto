#requires -Version 7.0
<#
audit_fw_contract.ps1 -- every script must agree with references\firmware-contract.json.

Why this exists: the firmware symbols this skill knows by name were hard-coded in twelve
places and had already drifted when this audit was written (2026-11-15):

  * FrozenValue was 'true' in ti_c2000_live_read.ps1 and '1' in ti_c2000_read_dma.ps1;
  * the heartbeat candidate list appeared four times in three different sets/orders.

A contract spread over twelve copies is not a contract. This audit makes the file the only
source of truth.

Why it parses with the AST instead of scanning text: the first version scanned lines and
reported five problems, four of which were prose - a comment that quoted
"-HeartbeatVars gMsTick,usMainLoop" and two continuation lines inside block comments. A
detector that cries wolf on comments gets switched off, so this version reads only what the
parser says is a parameter default value.

Exit 0 when every script agrees, 1 on drift, 2 when the contract file is missing.

    pwsh -NoProfile -File tools/audit_fw_contract.ps1
    pwsh -NoProfile -File tools/audit_fw_contract.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [string]$SkillRoot = '',
    [switch]$SelfTest,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
function Out2($m) { Write-Output $m }
function Info2($m) { if (-not $Quiet) { Write-Output $m } }

if (-not $SkillRoot) { $SkillRoot = Split-Path $PSScriptRoot -Parent }
$contractPath = Join-Path $SkillRoot 'references\firmware-contract.json'
$scriptsDir = Join-Path $SkillRoot 'scripts'

# "true" and "1" are the same statement in C; a flag may surface either way.
function Normalise-Flag([string]$v) {
    $t = ([string]$v).Trim().ToLower()
    if ($t -eq 'true' -or $t -eq '1') { return 'T' }
    if ($t -eq 'false' -or $t -eq '0') { return 'F' }
    return $t
}

# Turn a param default AST into the strings it denotes (a scalar gives one; an array gives
# its elements). Anything computed at run time is returned as an empty list and ignored: the
# audit only judges literal defaults, which is exactly the kind that drifts.
function Get-DefaultStrings {
    param($Ast)
    $out = @()
    if ($null -eq $Ast) { return ,$out }
    if ($Ast -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return ,@([string]$Ast.Value) }
    if ($Ast -is [System.Management.Automation.Language.ArrayExpressionAst]) {
        foreach ($e in $Ast.SubExpression.Statements) {
            foreach ($el in $e.PipelineElements) {
                if ($el -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    $x = $el.Expression
                    if ($x -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $out += [string]$x.Value }
                    elseif ($x -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                        foreach ($a in $x.Elements) {
                            if ($a -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $out += [string]$a.Value }
                        }
                    }
                }
            }
        }
    }
    return ,$out
}

function Get-ContractProblems {
    param([string]$ContractFile, [string]$Scripts)

    $problems = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $ContractFile)) {
        $problems.Add("the firmware contract file is missing: $ContractFile")
        return ,$problems
    }
    try {
        $c = Get-Content -LiteralPath $ContractFile -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        $problems.Add("the firmware contract file is not valid JSON: $($_.Exception.Message)")
        return ,$problems
    }

    $idVar = [string]$c.identity.var
    $hbCands = @($c.heartbeat.candidates | ForEach-Object { [string]$_ })
    $hbKey = (($hbCands | Sort-Object) -join ',')
    $rateVar = [string]$c.rate.var
    $flagVar = [string]$c.frozenBuffer.flag
    $flagWant = Normalise-Flag $c.frozenBuffer.flagValue
    $seqVar = [string]$c.frozenBuffer.seq
    $arrayVar = [string]$c.frozenBuffer.array
    $contractNames = @(@($idVar, $rateVar, $flagVar, $seqVar, $arrayVar) + $hbCands | Where-Object { $_ } | Sort-Object -Unique)

    foreach ($f in (Get-ChildItem -LiteralPath $Scripts -Filter *.ps1 -File)) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        if (-not $ast.ParamBlock) { continue }

        foreach ($p in $ast.ParamBlock.Parameters) {
            $name = $p.Name.VariablePath.UserPath
            $vals = Get-DefaultStrings $p.DefaultValue
            if ($vals.Count -eq 0) { continue }
            $where = '{0}:{1}' -f $f.Name, $p.Extent.StartLineNumber

            # 1. a heartbeat candidate list must be exactly the contract's set
            $hbInDefault = @($hbCands | Where-Object { $v = $_; @($vals | Where-Object { $_ -match ('\b' + [regex]::Escape($v) + '\b') }).Count -gt 0 })
            if ($hbInDefault.Count -gt 0) {
                $joined = ($vals -join ',')
                $present = @($hbCands | Where-Object { $joined -match ('\b' + [regex]::Escape($_) + '\b') })
                $presentKey = (($present | Sort-Object) -join ',')
                if ($presentKey -ne $hbKey) {
                    $problems.Add(('{0}: -{1} lists heartbeat candidates [{2}] but the contract says [{3}]' -f $where, $name, ($present -join ','), ($hbCands -join ',')))
                }
            }

            # 2. a frozen-state value must mean the same thing as the contract's
            if ($name -eq 'FrozenValue') {
                $got = Normalise-Flag $vals[0]
                if ($got -ne $flagWant) {
                    $problems.Add(('{0}: -FrozenValue defaults to ''{1}'' but the contract says ''{2}''' -f $where, $vals[0], $c.frozenBuffer.flagValue))
                }
            }

            # 3. any firmware-looking literal in a default must be a contract symbol
            foreach ($v in $vals) {
                foreach ($m in [regex]::Matches($v, '\b((?:g|us)[A-Z]\w*)\b')) {
                    $sym = $m.Groups[1].Value
                    if ($contractNames -notcontains $sym) {
                        $problems.Add(('{0}: -{1} defaults to firmware symbol ''{2}'' which is not in the contract' -f $where, $name, $sym))
                    }
                }
            }
        }
    }
    return ,$problems
}

# ---------------------------------------------------------------- self test -----
if ($SelfTest) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('fwc-' + [guid]::NewGuid().ToString('N'))
    $sub = Join-Path $dir 'scripts'
    New-Item -ItemType Directory -Force -Path $sub, (Join-Path $dir 'references') | Out-Null
    try {
        [IO.File]::WriteAllText((Join-Path $dir 'references\firmware-contract.json'), @'
{ "version": 1,
  "identity": { "var": "gFwId" },
  "heartbeat": { "candidates": ["gMsTick", "usMainLoop"] },
  "rate": { "var": "gMsTick", "perSec": 1000, "tolerancePct": 20 },
  "frozenBuffer": { "array": "gBuf", "flag": "gBufFull", "flagValue": "1", "seq": "gBufSeq" } }
'@, (New-Object Text.UTF8Encoding($false)))

        # compliant, and noisy on purpose: the comment quotes the wrong list, the block
        # comment mentions another, and neither may be reported
        [IO.File]::WriteAllText((Join-Path $sub 'good.ps1'), @'
<#
Example: -HeartbeatExpr gMsTick,gRunMs  (prose, must be ignored)
#>
param(
    [string]$FrozenFlag = 'gBufFull',
    [string]$FrozenValue = '1',
    [string]$HeartbeatExpr = 'gMsTick,usMainLoop',
    [string[]]$HeartbeatVars = @('gMsTick', 'usMainLoop')
)
# gMsTick and gRunMs style counters in a trailing comment
'@, (New-Object Text.UTF8Encoding($false)))

        # drifts in all three ways. FrozenValue uses '0': true and 1 are the same statement
        # in C and the audit normalises them, so only a genuinely different value is drift.
        [IO.File]::WriteAllText((Join-Path $sub 'bad.ps1'), @'
param(
    [string]$FrozenValue = '0',
    [string]$HeartbeatExpr = 'gMsTick',
    [string]$FwIdVar = 'gSomeOtherId'
)
'@, (New-Object Text.UTF8Encoding($false)))

        $found = Get-ContractProblems -ContractFile (Join-Path $dir 'references\firmware-contract.json') -Scripts $sub
        $text = ($found -join "`n")

        $miss = @()
        if ($text -notmatch 'FrozenValue') { $miss += 'FrozenValue drift' }
        if ($text -notmatch 'heartbeat candidates') { $miss += 'heartbeat set drift' }
        if ($text -notmatch 'gSomeOtherId') { $miss += 'symbol outside the contract' }
        $noise = @($found | Where-Object { $_ -match 'good\.ps1' })

        if ($miss.Count -gt 0) {
            Out2 'FAILURE: AUDIT_DETECTOR_BLIND'; Out2 'RESULT: FAIL'
            Out2 ('REASON: planted drift not reported: ' + ($miss -join ', '))
            Out2 ('FOUND: ' + $text)
            exit 1
        }
        if ($noise.Count -gt 0) {
            Out2 'FAILURE: AUDIT_DETECTOR_NOISY'; Out2 'RESULT: FAIL'
            Out2 ('REASON: a compliant script was flagged (comments are not defaults): ' + ($noise -join '; '))
            exit 1
        }
        Out2 'CHECK   : detector catches all three drift kinds and ignores comments'
        Out2 'RESULT: OK'
        exit 0
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------- audit -----
if (-not (Test-Path -LiteralPath $contractPath)) {
    Out2 'FAILURE: FW_CONTRACT_MISSING'; Out2 'RESULT: FAIL'
    Out2 ('REASON: ' + $contractPath)
    Out2 'HINT    : the contract is the only place firmware symbols may be named; without it every script invents its own'
    exit 2
}

$problems = Get-ContractProblems -ContractFile $contractPath -Scripts $scriptsDir
if ($problems.Count -gt 0) {
    Out2 'FAILURE: FW_CONTRACT_DRIFT'; Out2 'RESULT: FAIL'
    foreach ($p in $problems) { Out2 ('REASON: ' + $p) }
    Out2 'HINT    : change references\firmware-contract.json first, then make the scripts agree - not the other way round'
    exit 1
}

$c = Get-Content -LiteralPath $contractPath -Raw -Encoding utf8 | ConvertFrom-Json
Info2 ('CHECK   : every script agrees with the firmware contract ({0})' -f (Split-Path $contractPath -Leaf))
Info2 ('          identity {0} | heartbeat {1} | rate {2}@{3}/s | frozen {4}={5} seq {6}' -f `
        $c.identity.var, (($c.heartbeat.candidates) -join ','), $c.rate.var, $c.rate.perSec, $c.frozenBuffer.flag, $c.frozenBuffer.flagValue, $c.frozenBuffer.seq)
Out2 'RESULT: OK'
exit 0
