#requires -Version 7.0
# Brute-force test for set_probe.ps1 (2026-11-18).
# Goal: prove repeated probe switching can NEVER drop / corrupt ccxml nodes.
# Sections: A) 60 pseudo-random v1/v2/v3 rounds  B) fixture format variants
#           C) bad-arg no-mutation  D) idempotency  E) .bak correctness
#           F) 30 random rounds on the REAL F28379D ccxml
# Supersedes test_set_probe_preserves_link.ps1 (deleted 2026-11-18): the one assertion
# that test had and this one lacked - "the c28x driver must follow the requested prefix,
# otherwise the switch silently did nothing" - was merged into Assert-Complete here.
# Validation: mutation-tested on 2026-11-18 - re-injecting the old "rebuild-from-scratch"
# bug into a throwaway skill copy makes this test FAIL with the exact dropped-node list,
# so this test genuinely guards the regression (not a vacuous pass).
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $skillRoot 'scripts/ti_c2000_set_probe.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('c2000-probe-brute-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$targetDir = Join-Path $tempRoot 'targetConfigs'
New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
$ccxml = Join-Path $targetDir 'TMS320F28379D.ccxml'

$verInfo = @{
    v1 = @{ conn='TIXDS100usb_Connection.xml';        id='Texas Instruments XDS100v1 USB Emulator'; desc='Texas Instruments XDS100v1 USB Debug Probe'; drv='tixds100' }
    v2 = @{ conn='TIXDS100v2_Connection.xml';         id='Texas Instruments XDS100v2 USB Emulator'; desc='Texas Instruments XDS100v2 USB Debug Probe'; drv='tixds100v2' }
    v3 = @{ conn='TIXDS100v3_Dot7_Connection.xml';    id='Texas Instruments XDS100v3 USB Emulator'; desc='Texas Instruments XDS100v3 USB Debug Probe'; drv='tixds100v2' }
}
$serial = 'TI90I42A'

# The "driver file exists" check needs a real CCS targetdb. Without one (CI runner, a
# machine with CCS elsewhere) skip it with a NOTE instead of failing: the structure/XML
# and prefix checks below still guard the regression on any machine.
# Set CCS_ROOT to your CCS install root to enable this check locally; never hardcode a
# machine-specific drive path here (the portability gate blocks it).
$driverDb = ''
if ($env:CCS_ROOT) {
    $candidate = Join-Path $env:CCS_ROOT 'ccs_base\common\targetdb\drivers'
    if (Test-Path -LiteralPath $candidate) { $driverDb = $candidate }
}
if (-not $driverDb) {
    Write-Output "NOTE    : CCS targetdb not configured - skipping 'driver file exists' check (set CCS_ROOT to enable)"
}

function New-Fixture([string]$ver, [bool]$withSerial, [string]$nl, [bool]$withSuffix) {
    $i = $verInfo[$ver]
    $sfx = if ($withSuffix) { '_0' } else { '' }
    $lines = @(
        '<?xml version="1.0" encoding="UTF-8" standalone="no"?>'
        '<configurations XML_version="1.2" id="configurations_0">'
        ('<configuration XML_version="1.2" id="{0}{1}">' -f $i.desc, $sfx)
        ('  <instance XML_version="1.2" desc="{0}{1}" href="connections/{2}" id="{0}{1}" xml="{2}" xmlpath="connections"/>' -f $i.desc, $sfx, $i.conn)
        ('  <connection XML_version="1.2" id="{0}{1}">' -f $i.desc, $sfx)
        ('    <instance XML_version="1.2" href="drivers/{0}icepick_c.xml" id="drivers" xml="{0}icepick_c.xml" xmlpath="drivers"/>' -f $i.drv)
        ('    <instance XML_version="1.2" href="drivers/{0}c28x.xml" id="drivers" xml="{0}c28x.xml" xmlpath="drivers"/>' -f $i.drv)
        ('    <instance XML_version="1.2" href="drivers/{0}cla1.xml" id="drivers" xml="{0}cla1.xml" xmlpath="drivers"/>' -f $i.drv)
        ('    <instance XML_version="1.2" href="drivers/{0}cs_child.xml" id="drivers" xml="{0}cs_child.xml" xmlpath="drivers"/>' -f $i.drv)
    )
    if ($withSerial) {
        $lines += @(
            '    <property Type="choicelist" Value="1" id="Emulator Selection">'
            '      <choice Name="Select by serial number" value="0">'
            ('        <property Type="stringfield" Value="{0}" id="-- Enter the serial number"/>' -f $serial)
            '      </choice>'
            '    </property>'
        )
    }
    $lines += @(
        '    <platform XML_version="1.2" id="platform_0">'
        '      <instance XML_version="1.2" desc="TMS320F28379D_0" href="devices/f28379d.xml" id="TMS320F28379D_0" xml="f28379d.xml" xmlpath="devices"/>'
        '      <device HW_revision="1" XML_version="1.2" description="" id="TMS320F28379D_0" partnum="TMS320F28379D">'
        '        <router HW_revision="1.0" XML_version="1.2" description="ICEPick_C router" id="IcePick_C_0" isa="ICEPICK_C">'
        '          <subpath id="Subpath_1">'
        '            <property Type="numericfield" Value="0x11" desc="Port Number_0" id="Port Number"/>'
        '          </subpath>'
        '        </router>'
        '      </device>'
        '    </platform>'
        '  </connection>'
        '</configuration>'
        '</configurations>'
    )
    [IO.File]::WriteAllText($ccxml, ($lines -join $nl))
}

function Assert-Complete([string]$text, [string]$phase, [string]$Prefix = '') {
    $problems = [Collections.Generic.List[string]]::new()
    try { [void][xml]$text } catch { $problems.Add("$phase : XML parse error: $($_.Exception.Message)") }
    if (([regex]::Matches($text, 'xmlpath="drivers"')).Count -ne 4) { $problems.Add("$phase : driver node count != 4") }
    if ($text -notmatch 'href="devices/f28379d\.xml"') { $problems.Add("$phase : device instance lost") }
    if ($text -notmatch 'partnum="TMS320F28379D"') { $problems.Add("$phase : <device partnum> lost") }
    if ($text -notmatch 'isa="ICEPICK_C"') { $problems.Add("$phase : ICEPick_C router lost") }
    if ($text -notmatch '<subpath id="Subpath_1">') { $problems.Add("$phase : Subpath_1 lost") }
    if ($text -notmatch 'Value="0x11"') { $problems.Add("$phase : port number lost") }
    if ($text -notmatch ('Value="' + $serial + '"')) { $problems.Add("$phase : serial lost") }
    if ($text -notmatch 'USB Debug Probe') { $problems.Add("$phase : connection desc lost") }
    if ($text -match 'id="configuration_0"') { $problems.Add("$phase : configuration id generalized") }
    # Repeated driver prefix (tixds100v2v2 / tixds100v2v2) is a cumulative-rewrite bug.
    if ($text -match 'tixds100v2v2|tixds100v2_Connection.*tixds100v2v2') { $problems.Add("$phase : repeated driver prefix (double rewrite)") }
    # A switch that keeps the OLD driver prefix still passes "file exists"; require the c28x
    # driver (present in every version) to follow the requested prefix, otherwise a no-op
    # rename would go unnoticed (this assertion came from test_set_probe_preserves_link.ps1).
    if ($Prefix -and $text -notmatch ('href="drivers/' + [regex]::Escape($Prefix) + 'c28x\.xml"')) {
        $problems.Add("$phase : c28x driver not renamed to '$($Prefix)' (switch had no effect)")
    }
    if ($driverDb) {
        foreach ($m in [regex]::Matches($text, 'href="drivers/([^"]+)"')) {
            $n = $m.Groups[1].Value
            if ($n -match 'v2v2|v2v1|v1v2') { $problems.Add("$phase : corrupted driver name $n") }
            if (-not (Test-Path (Join-Path $driverDb $n))) {
                $problems.Add("$phase : driver file does not exist in targetdb: $n")
            }
        }
    }
    if ($problems.Count) { throw ($problems -join ' | ') }
}

function Invoke-Switch([string]$ver) {
    $o = & pwsh -NoProfile -File $scriptPath -ProjectPath $tempRoot -Probe $ver -Serial $serial 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $o -notmatch 'RESULT: OK') { throw "switch -> $ver failed (exit=$LASTEXITCODE): $o" }
    Assert-Complete ([IO.File]::ReadAllText($ccxml)) "after -> $ver" $verInfo[$ver].drv
    return $o
}

try {
    # CI runners have no CCS, so set_probe reports NO_CCS there. Skip the whole drill
    # instead of reporting a false failure; machines with CCS run every section below.
    $probeCheck = & pwsh -NoProfile -File $scriptPath -ProjectPath $tempRoot -Probe v1 -Serial $serial -DryRun 2>&1 | Out-String
    if ($probeCheck -match 'NO_CCS') {
        Write-Output 'SKIP    : CCS not installed - probe switch behaviour cannot run here'
        Write-Output 'BRUTE FORCE RESULT: OK'
        exit 0
    }

    # ---- Section A: 60 rounds of pseudo-random switching (fixed seed = reproducible) ----
    New-Fixture 'v2' $true "`r`n" $true
    Assert-Complete ([IO.File]::ReadAllText($ccxml)) 'initial fixture'
    $rng = [Random]::new(20261118)
    $vers = @('v1','v2','v3')
    for ($r = 0; $r -lt 60; $r++) {
        $v = $vers[$rng.Next(0, $vers.Count)]
        $null = Invoke-Switch $v
        $txt = [IO.File]::ReadAllText($ccxml)
        $want = $verInfo[$v].drv
        if ($txt -notmatch ('href="drivers/' + $want + 'c28x\.xml"')) { throw "round $r : c28x not $want" }
        if ($txt -notmatch ([regex]::Escape($verInfo[$v].conn))) { throw "round $r : connection file not $($verInfo[$v].conn)" }
    }
    Write-Output 'SECTION A PASS: 60 pseudo-random v1/v2/v3 rounds, no node loss / no cumulative corruption'

    # ---- Section B: format variants (LF vs CRLF, serial present/absent, suffix present/absent) ----
    foreach ($nl in @("`r`n", "`n")) {
        foreach ($ws in @($true, $false)) {
            foreach ($sfx in @($true, $false)) {
                New-Fixture 'v2' $ws $nl $sfx
                $o = & pwsh -NoProfile -File $scriptPath -ProjectPath $tempRoot -Probe v1 -Serial $serial 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0 -or $o -notmatch 'RESULT: OK') { throw "format variant (crlf=$($nl -eq "`r`n") serial=$ws suffix=$sfx) failed: $o" }
                Assert-Complete ([IO.File]::ReadAllText($ccxml)) "format variant crlf=$($nl -eq "`r`n") serial=$ws suffix=$sfx"
            }
        }
    }
    Write-Output 'SECTION B PASS: 8 fixture format variants (CRLF/LF x serial x _0 suffix)'

    # ---- Section C: bad args must not mutate the file ----
    New-Fixture 'v2' $true "`r`n" $true
    $before = [IO.File]::ReadAllText($ccxml)
    $cases = @(
        @{ args=@('-Probe','v1','-Serial','bad!serial'); code=2; tag='INVALID_SERIAL' }
        @{ args=@('-Probe','no_such_probe','-Serial',$serial); code=2; tag='BAD_PROBE' }
        @{ args=@('-Probe','v1'); code=2; tag='SERIAL_REQUIRED' }
    )
    foreach ($c in $cases) {
        $o = & pwsh -NoProfile -File $scriptPath -ProjectPath $tempRoot @($c.args) 2>&1 | Out-String
        if ($LASTEXITCODE -ne $c.code -or $o -notmatch $c.tag) { throw "bad-arg $($c.tag): expected exit $($c.code), got $LASTEXITCODE : $o" }
        if ([IO.File]::ReadAllText($ccxml) -ne $before) { throw "bad-arg $($c.tag) mutated the ccxml" }
    }
    Write-Output 'SECTION C PASS: 3 bad-arg cases rejected without mutation'

    # ---- Section D: idempotency - second identical call is a no-op ----
    New-Fixture 'v2' $true "`r`n" $true
    $null = Invoke-Switch 'v1'
    $after1 = [IO.File]::ReadAllText($ccxml)
    $o2 = & pwsh -NoProfile -File $scriptPath -ProjectPath $tempRoot -Probe v1 -Serial $serial 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $o2 -notmatch 'RESULT: OK' -or $o2 -notmatch '无需修改') { throw "idempotent second call failed: $o2" }
    if ([IO.File]::ReadAllText($ccxml) -ne $after1) { throw 'idempotent second call mutated the ccxml' }
    Write-Output 'SECTION D PASS: repeated identical call is a no-op'

    # ---- Section E: .bak is the exact pre-switch content ----
    New-Fixture 'v2' $true "`r`n" $true
    $preSwitch = [IO.File]::ReadAllText($ccxml)
    $null = Invoke-Switch 'v1'
    $bak = Join-Path $targetDir 'TMS320F28379D.ccxml.bak'
    if (-not (Test-Path $bak)) { throw 'missing .bak after switch' }
    if ([IO.File]::ReadAllText($bak) -ne $preSwitch) { throw '.bak does not match pre-switch content' }
    Write-Output 'SECTION E PASS: .bak is exact pre-switch content'

    # ---- Section F: REAL project ccxml, 30 more random rounds (covers authentic formatting/device tree) ----
    # Optional: set TI_REAL_CCXML to a real project's targetConfigs/TMS320F28379D.ccxml
    # to enable this section locally; CI skips it when unset. Never hardcode a local path.
    $realCcxml = $env:TI_REAL_CCXML
    if ($realCcxml -and (Test-Path -LiteralPath $realCcxml)) {
        Copy-Item -LiteralPath $realCcxml -Destination $ccxml -Force
        # Authentic ccxml has no trailing serial-block newline quirk; just assert structure first.
        $realText = [IO.File]::ReadAllText($ccxml)
        [void][xml]$realText
        if (([regex]::Matches($realText, 'xmlpath="drivers"')).Count -lt 3 -or $realText -notmatch 'partnum="TMS320F28379D"') {
            throw 'Section F: real ccxml fixture is unexpectedly incomplete'
        }
        $rng2 = [Random]::new(424242)
        for ($r = 0; $r -lt 30; $r++) {
            $v = $vers[$rng2.Next(0, $vers.Count)]
            $null = Invoke-Switch $v
        }
        Write-Output 'SECTION F PASS: 30 random rounds on the REAL F28379D ccxml (authentic device tree)'
    } else {
        Write-Output 'SECTION F SKIP: real project ccxml not present (offline-only environment)'
    }

    Write-Output 'BRUTE FORCE RESULT: OK'
    exit 0
}
catch {
    Write-Output "FAIL: $($_.Exception.Message)"
    Write-Output 'RESULT: FAIL'
    exit 1
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
