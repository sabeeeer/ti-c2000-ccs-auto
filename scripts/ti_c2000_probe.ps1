#requires -Version 7.0
<#
ti_c2000_probe.ps1 -- how long to wait for a probe to come back, learned per project.

A probe that was just released does NOT return at a fixed time:

  * Windows re-enumerates the FTDI/USB device when the DSS process that owned it exits.
    Measured on XDS100v2 (2026-11-16): ~7 s before it reappears in PnP.
  * Reappearing in PnP is not the same as being usable - the driver needs roughly another
    ~10 s before it can be opened. Measuring the two separately matters, because a check
    that only looks at PnP passes too early and the very next open fails with NO_PROBE.
  * Different probes are different USB implementations (XDS100v2 = FTDI, XDS110 = CDC,
    XDS200 = its own driver), so their re-enumeration times differ by seconds. A number
    tuned on one probe is simply wrong on another.

Therefore the wait is learned, not hard-coded:

  first time    start at 5 s
  each failure  +5 s (and remember that value as a known-bad wait)
  on success    remember the wait that worked
  next time     start at (lastGood + lastBad) / 2 -- a bisection. A fast probe is not
                punished by a slow probe's number, and a slow probe does not pay the fast
                probe's optimism.

Why this exists: a fixed 12 s window produced "the probe went missing again" reports that
looked like hardware faults (power, cable) while the device was simply still enumerating.

Usage:
  . (Join-Path $PSScriptRoot 'ti_c2000_probe.ps1')
  $ok = Wait-ProbeUsable -ProjectPath $pr -ProbeCheck { <returns $true when usable> }
#>

function Get-ProbeWaitState {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $p = Join-Path (Join-Path $ProjectPath 'readout\.service') 'probe-wait.json'
    $r = [ordered]@{ path = $p; okMs = 0; failMs = 0; probe = '' }
    if (-not (Test-Path -LiteralPath $p)) { return $r }
    try {
        $j = Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json
        if ($null -ne $j.okMs) { $r.okMs = [int]$j.okMs }
        if ($null -ne $j.failMs) { $r.failMs = [int]$j.failMs }
        if ($null -ne $j.probe) { $r.probe = [string]$j.probe }
    } catch { }
    return $r
}

function Get-ProbeConfigKey {
    param([Parameter(Mandatory)][string]$ProjectPath, [string]$Ccxml = '')
    if ($Ccxml -and (Test-Path -LiteralPath $Ccxml)) {
        return ((Get-Item -LiteralPath $Ccxml).FullName + ':' + (Get-FileHash -LiteralPath $Ccxml -Algorithm SHA256).Hash)
    }
    $dir = Join-Path $ProjectPath 'targetConfigs'
    if (-not (Test-Path -LiteralPath $dir)) { return '' }
    return (@(Get-ChildItem -LiteralPath $dir -Filter '*.ccxml' -File | Sort-Object Name |
        ForEach-Object { $_.Name + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join ';')
}

function Save-ProbeWaitState {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [int]$OkMs = 0,
        [int]$FailMs = 0,
        [string]$Probe = ''
    )
    $st = Get-ProbeWaitState -ProjectPath $ProjectPath
    $dir = Split-Path $st.path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $obj = [ordered]@{
        okMs      = $OkMs
        failMs    = $FailMs
        probe     = $(if ($Probe) { $Probe } else { $st.probe })
        updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $obj | ConvertTo-Json | Set-Content -LiteralPath $st.path -Encoding utf8
}

# Windows enumeration and DSS driver access are separate observations. This second
# record learns the elapsed Stop -> verified DSS connection interval for the selected
# target configuration. It is deliberately never updated by a PnP-only check.
function Get-ProbeDriverState {
    param([Parameter(Mandatory)][string]$ProjectPath, [string]$Ccxml = '')
    $path = Join-Path (Join-Path $ProjectPath 'readout\.service') 'probe-driver-wait.json'
    $key = Get-ProbeConfigKey -ProjectPath $ProjectPath -Ccxml $Ccxml
    $s = [ordered]@{ path=$path; probe=$key; stoppedAtMs=0L; badMs=0; goodMs=0 }
    if (Test-Path -LiteralPath $path) {
        try {
            $old = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
            if ([string]$old.probe -eq $key) {
                $s.stoppedAtMs = [long]$old.stoppedAtMs
                $s.badMs = [int]$old.badMs
                $s.goodMs = [int]$old.goodMs
            }
        } catch { }
    }
    return $s
}
function Save-ProbeDriverState {
    param([Parameter(Mandatory)]$State)
    $dir = Split-Path $State.path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [ordered]@{ probe=$State.probe; stoppedAtMs=$State.stoppedAtMs; badMs=$State.badMs; goodMs=$State.goodMs } |
        ConvertTo-Json | Set-Content -LiteralPath $State.path -Encoding utf8
}
function Mark-ProbeReleased {
    param([Parameter(Mandatory)][string]$ProjectPath, [string]$Ccxml = '')
    $s = Get-ProbeDriverState -ProjectPath $ProjectPath -Ccxml $Ccxml
    $s.stoppedAtMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Save-ProbeDriverState $s
}
function Get-ProbeDriverElapsedMs {
    param([Parameter(Mandatory)]$State)
    if ($State.stoppedAtMs -le 0) { return -1 }
    return [int]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $State.stoppedAtMs)
}
function Get-ProbeDriverTargetMs {
    param([Parameter(Mandatory)]$State)
    if ($State.goodMs -gt $State.badMs) { return [int](($State.goodMs + $State.badMs) / 2) }
    if ($State.badMs -gt 0) { return [int]($State.badMs + 5000) }
    return 0
}
function Wait-ProbeDriverGap {
    param([Parameter(Mandatory)][string]$ProjectPath, [string]$Ccxml = '', [switch]$Quiet)
    $s = Get-ProbeDriverState -ProjectPath $ProjectPath -Ccxml $Ccxml
    $elapsed = Get-ProbeDriverElapsedMs $s
    if ($elapsed -lt 0 -or $elapsed -gt 90000) { return }
    $target = [Math]::Min(90000, (Get-ProbeDriverTargetMs $s))
    $wait = [Math]::Max(0, $target - $elapsed)
    if ($wait -gt 0) {
        if (-not $Quiet) { Write-Host ('PROBE   : DSS access delay {0:N1} s (Stop-to-connect target {1:N1} s; bad={2} ms good={3} ms)' -f ($wait/1000.0),($target/1000.0),$s.badMs,$s.goodMs) }
        Start-Sleep -Milliseconds $wait
    }
}
function Mark-ProbeDriverFailure {
    param([Parameter(Mandatory)][string]$ProjectPath, [string]$Ccxml = '')
    $s = Get-ProbeDriverState -ProjectPath $ProjectPath -Ccxml $Ccxml
    $elapsed = Get-ProbeDriverElapsedMs $s
    if ($elapsed -lt 0 -or $elapsed -gt 90000) { return }
    $s.badMs = [Math]::Max($s.badMs, [Math]::Max(1, $elapsed))
    if ($s.goodMs -le $s.badMs) { $s.goodMs = 0 }
    Save-ProbeDriverState $s
}
function Mark-ProbeDriverSuccess {
    param([Parameter(Mandatory)][string]$ProjectPath, [string]$Ccxml = '')
    $s = Get-ProbeDriverState -ProjectPath $ProjectPath -Ccxml $Ccxml
    $elapsed = Get-ProbeDriverElapsedMs $s
    if ($elapsed -lt 0 -or $elapsed -gt 90000) { return }
    if ($elapsed -gt $s.badMs -and ($s.goodMs -eq 0 -or $elapsed -lt $s.goodMs)) { $s.goodMs = $elapsed }
    Save-ProbeDriverState $s
}

<#
Wait-ProbeUsable -- check immediately, then wait and retry until the callback succeeds
or the budget runs out. Its result is only as strong as -ProbeCheck: the current
-ProbeCheckOnly callback checks Windows enumeration, while DSS verifies target access
later with connect and isConnected. Do not call a PnP result "openable".
#>
# =============================================================================
# Probe identity resolution -- keeps the project .ccxml FREE of a hard-coded serial.
#
# Why: writing "TI90I42A" into the project's .ccxml ties the project to one physical
# probe. Any other probe then fails with PROBE_SERIAL_MISMATCH, and the usual reaction
# is to edit the project file again (or blame the hardware). Instead the project file
# may stay portable ("Only one XDS100", or another probe's serial) and this function
# resolves it at run time against the probe that is actually attached:
#
#   serial source priority:
#     1. -Serial <value>                       explicit, always wins
#     2. $env:TI_C2000_PROBE_SERIAL            per-machine / CI override
#     3. <project>\targetConfigs\probe-serial.txt   one serial per line, '#' comments
#     4. xds100serial -l output                the only trustworthy physical identity
#     5. the serial already in .ccxml          last resort (unverified)
#
#   decision:
#     ccxml already pins the same serial   -> use the project file untouched
#     ccxml pins a different serial        -> temp copy with the serial replaced
#     ccxml uses "Only one XDS100"         -> temp copy that pins the discovered serial
#                                             (ghost instances make "Only one" unsafe)
#     serial cannot be read                -> use the project file, mark SerialUnknown
#
# The temp copy is a MINIMAL edit of the original text (no rebuild, so the <device>
# node, ICEPick_C router, Subpath and every driver survive), is [xml]-parsed and
# re-checked before it is written, and lands next to the session for inspection.
# =============================================================================
# Serial discovery across probe models. Every vendor exposes a different utility, so this
# never assumes one. Sources, in the order they are tried:
#   XDS100 (FTDI)  -> <CCS>\ccs_base\common\uscif\xds100serial.exe -l
#                      "0403/a6d0  XDS100v1/v2  TI90I42A  Texas Instruments Inc.XDS100 Ver 2.0"
#   XDS110 (CDC)   -> <CCS>\ccs_base\common\uscif\xds110\xdsdfu.exe -e
#                      per TI's XDS110 page (emu_xds110.html): 'xdsdfu -e' enumerates and
#                      prints Serial Num; 8-char printable ASCII, no commas. Firmware/DFU
#                      states are visible here too (VID 0x1cbe / PID 0x00ff = ROM DFU).
#   XDS200         -> no serial utility in the emupack; falls through to PnP / DSS.
#   anything else  -> PnP InstanceId, and ultimately the model-independent DSS test.
# Parsing is deliberately loose (any 'Serial Num|Number|S/N' shape, 4..32 chars) because
# the exact wording differs between emupack versions.
function Get-AttachedProbeSerials {
    param([string]$CcsPath = '', [string]$Xds100Tool = '')
    $rows = @()

    # --- XDS100 family (FTDI) ---
    if ($Xds100Tool -and (Test-Path -LiteralPath $Xds100Tool)) {
        try {
            foreach ($line in @(& $Xds100Tool -l 2>$null)) {
                $m = [regex]::Match([string]$line, '^\s*[0-9a-fA-F]{4}/[0-9a-fA-F]{4}\s+(\S+)\s+(\S+)\s+')
                if ($m.Success) {
                    $rows += [pscustomobject]@{ Model = $m.Groups[1].Value; Serial = $m.Groups[2].Value; Raw = ([string]$line).Trim() }
                }
            }
        } catch { }
    }

    # --- XDS110 family (CDC) ---
    if ($CcsPath) {
        $dfu = Join-Path $CcsPath 'ccs_base\common\uscif\xds110\xdsdfu.exe'
        if (Test-Path -LiteralPath $dfu) {
            try {
                foreach ($line in @(& $dfu -e 2>$null | ForEach-Object { [string]$_ })) {
                    $m = [regex]::Match($line, '(?i)(?:serial\s*(?:num(?:ber)?)?|s/n)\s*[:=]?\s*([A-Za-z0-9_-]{4,32})')
                    if (-not $m.Success) { continue }
                    $sn = $m.Groups[1].Value
                    # 00000000 is the ROM-DFU placeholder, not a real probe identity.
                    if ($sn -eq '00000000') { continue }
                    if (@($rows | Where-Object { $_.Serial -eq $sn }).Count -gt 0) { continue }
                    $rows += [pscustomobject]@{ Model = 'XDS110'; Serial = $sn; Raw = $line.Trim() }
                }
            } catch { }
        }
    }
    return @($rows)
}

function Get-ConfiguredProbeSerial {
    param([string]$CcxmlText)
    $r = [pscustomobject]@{ Pinned = $false; Serial = ''; Tag = '' }
    if (-not $CcxmlText) { return $r }
    $tag = [regex]::Match($CcxmlText, '<property\b[^>]*id="Emulator Selection"[^>]*>')
    if ($tag.Success) {
        $r.Tag = $tag.Value
        $v = [regex]::Match($tag.Value, '\bValue="([^"]*)"')
        if ($v.Success -and $v.Groups[1].Value -eq '1') { $r.Pinned = $true }
    }
    $s = [regex]::Match($CcxmlText, 'Value="([^"]*)"\s+id="-- Enter the serial number"')
    if ($s.Success) { $r.Serial = $s.Groups[1].Value }
    return $r
}

function Resolve-ProbeTargetConfig {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$Ccxml,
        [string]$Serial = '',
        [string]$WorkDir = '',
        [string]$Xds100Tool = '',
        [string]$CcsPath = ''
    )
    $result = [pscustomobject]@{
        Path         = $Ccxml
        Source       = 'project'
        Serial       = ''
        SerialSource = 'none'
        Note         = ''
        Changed      = $false
    }
    if (-not (Test-Path -LiteralPath $Ccxml)) { return $result }
    $text = ''
    try { $text = [IO.File]::ReadAllText($Ccxml) } catch { return $result }
    $cfg = Get-ConfiguredProbeSerial -CcxmlText $text

    # ---- 1) which serial do we believe? ----
    $useSerial = ''
    $src = 'none'
    if ($Serial) { $useSerial = $Serial.Trim(); $src = 'param' }
    if (-not $useSerial -and $env:TI_C2000_PROBE_SERIAL) { $useSerial = $env:TI_C2000_PROBE_SERIAL.Trim(); $src = 'env' }
    if (-not $useSerial) {
        $f = Join-Path $ProjectPath 'targetConfigs\probe-serial.txt'
        if (Test-Path -LiteralPath $f) {
            $lines = @(Get-Content -LiteralPath $f | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
            if ($lines.Count -gt 0) { $useSerial = $lines[0]; $src = 'file' }
        }
    }
    if (-not $useSerial) {
        $attached = @(Get-AttachedProbeSerials -Xds100Tool $Xds100Tool -CcsPath $CcsPath)
        if ($attached.Count -eq 1) { $useSerial = $attached[0].Serial; $src = 'discovered' }
        elseif ($attached.Count -gt 1) {
            # Several probes attached and nothing said which one: prefer the one the
            # project already pins, otherwise refuse to guess.
            $match = @($attached | Where-Object { $_.Serial -eq $cfg.Serial })
            if ($match.Count -eq 1) { $useSerial = $match[0].Serial; $src = 'discovered' }
            else { $result.Note = ('{0} probes attached ({1}) and none selected - pass -Serial or set TI_C2000_PROBE_SERIAL' -f $attached.Count, (($attached | ForEach-Object { $_.Serial }) -join ', ')); return $result }
        }
    }
    if (-not $useSerial) {
        # Nothing readable (session holds the FDII handle, or no probe). Keep the project file.
        $result.Serial = $cfg.Serial
        $result.SerialSource = 'ccxml'
        $result.Note = 'attached probe serial not readable now; project .ccxml used as-is'
        return $result
    }
    $result.Serial = $useSerial
    $result.SerialSource = $src

    # ---- 2) is the project file already correct? ----
    if ($cfg.Pinned -and $cfg.Serial -eq $useSerial) {
        $result.Note = ('project .ccxml already pins {0}' -f $useSerial)
        return $result
    }

    # ---- 3) minimal edit: pin the discovered serial without touching any other node ----
    $newText = $text
    if ($text -match 'id="-- Enter the serial number"') {
        $newText = [regex]::Replace($newText, '(<property[^>]*id="-- Enter the serial number"[^>]*/>)', {
            param($m) [regex]::Replace($m.Value, 'Value="[^"]*"', ('Value="{0}"' -f $useSerial))
        })
        if ($newText -notmatch 'id="Emulator Selection"[\s\S]{0,400}?Value="1"') {
            $newText = [regex]::Replace($newText, '(<property\b[^>]*id="Emulator Selection"[^>]*>)', {
                param($m) [regex]::Replace($m.Value, '\bValue="[^"]*"', 'Value="1"')
            })
        }
    } else {
        $nl = "`r`n"
        $block = '            <property Type="choicelist" Value="1" id="Emulator Selection">' + $nl +
                 '                <choice Name="Select by serial number" value="0">' + $nl +
                 ('                    <property Type="stringfield" Value="{0}" id="-- Enter the serial number"/>' -f $useSerial) + $nl +
                 '                </choice>' + $nl +
                 '            </property>' + $nl
        $idx = $newText.IndexOf('<platform')
        if ($idx -lt 0) { $result.Note = 'ccxml has no <platform>; cannot insert the serial block'; return $result }
        $lineStart = $newText.LastIndexOf("`n", [Math]::Max(0, $idx - 1))
        if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart += 1 }
        $newText = $newText.Substring(0, $lineStart) + $block + $newText.Substring($lineStart)
    }

    # ---- 4) self-check BEFORE writing: serial correct, node counts unchanged, valid XML ----
    try { [void][xml]$newText } catch { $result.Note = 'generated ccxml is not valid XML; keeping the project file'; return $result }
    if ($newText -notmatch [regex]::Escape($useSerial)) { $result.Note = 'generated ccxml does not contain the serial; keeping the project file'; return $result }
    $drvOld = ([regex]::Matches($text, 'xmlpath="drivers"')).Count
    $drvNew = ([regex]::Matches($newText, 'xmlpath="drivers"')).Count
    if ($drvOld -ne $drvNew) { $result.Note = ('driver node count would change ({0}->{1}); keeping the project file' -f $drvOld, $drvNew); return $result }
    if (($text -match 'partnum=') -and ($newText -notmatch 'partnum=')) { $result.Note = '<device> node would be lost; keeping the project file'; return $result }

    if (-not $WorkDir) { $WorkDir = Join-Path $ProjectPath 'readout\.service' }
    if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    $outPath = Join-Path $WorkDir ('resolved-' + ($useSerial -replace '[^A-Za-z0-9_-]', '_') + '.ccxml')
    [IO.File]::WriteAllText($outPath, $newText)

    $result.Path = $outPath
    $result.Source = 'temp'
    $result.Changed = $true
    $result.Note = ('project .ccxml left untouched; resolved copy pins {0} (from {1})' -f $useSerial, $src)
    return $result
}

# =============================================================================
# Probe-agnostic openability test: ask DSS itself, with a connect-but-never-load
# session. This is the only check that is true for EVERY probe type (XDS100 FTDI,
# XDS110 CDC, XDS200, XDS560v2, on-board XDS110 on LaunchPad, ...), because it uses
# exactly the same code path a real download uses.
#
# Why not a tool-specific serial utility:
#   * xds100serial.exe  only knows XDS100 (no xds110serial/xds200serial exists)
#   * dbgjtag.exe       is generic but needs a CCS-generated board data file (.dat),
#                       not the project .ccxml, so it cannot be used offline here
#   * PnP enumeration   says nothing about whether the driver can open the device
# DSS is the common denominator. Cost: a few seconds, so it is opt-in (-Deep).
# =============================================================================
function Test-ProbeOpenableByDss {
    param(
        [Parameter(Mandatory)][string]$Ccxml,
        [Parameter(Mandatory)][string]$DssBat,
        [Parameter(Mandatory)][string]$ProjectPath,
        [string]$WorkDir = '',
        [int]$TimeoutSec = 60,
        [string]$CorePattern = ''
    )
    $r = [pscustomobject]@{ Ok = $false; Skipped = $false; Detail = ''; Log = '' }
    if (-not (Test-Path -LiteralPath $Ccxml)) { $r.Detail = 'ccxml not found'; return $r }
    if (-not (Test-Path -LiteralPath $DssBat)) { $r.Detail = 'dss.bat not found'; return $r }

    # A live session owns the probe: opening a second DSS target would fight it.
    $stateFile = Join-Path $ProjectPath 'readout\.service\state.json'
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $st = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            if ($st.pid -and (Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue)) {
                $r.Ok = $true; $r.Skipped = $true; $r.Detail = 'a live DSS session already holds the probe'
                return $r
            }
        } catch { }
    }

    if (-not $WorkDir) { $WorkDir = Join-Path $ProjectPath 'readout\.service' }
    if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    $js = Join-Path $WorkDir 'probe-openable.js'
    $log = Join-Path $WorkDir 'probe-openable.log'
    $ccxmlJs = (Get-Item -LiteralPath $Ccxml).FullName.Replace('\', '/')

    $jsText = @'
// Probe-agnostic openability probe: connect, verify, disconnect. Never loads, never halts a running app.
importPackage(Packages.com.ti.debug.engine.scripting);
importPackage(Packages.com.ti.ccstudio.scripting.environment);
var env = ScriptingEnvironment.instance();
try { env.setScriptTimeout(0); } catch (e) { }
var server = env.getServer("DebugServer.1");
server.setConfig("__CCXML__");
var cpus = server.getListOfCPUs();
var target = "";
var pattern = "__CORE__";
for (var i = 0; i < cpus.length; i++) {
    var n = "" + cpus[i];
    if (pattern) { if (new RegExp(pattern).test(n)) { target = n; break; } }
    else if (n.indexOf("C28xx") >= 0) { target = n; break; }
}
if (!target) {
    var all = [];
    for (var k = 0; k < cpus.length; k++) { all.push("" + cpus[k]); }
    print("PROBE_OPENABLE 0 NO_TARGET_CORE [" + all.join(" | ") + "]");
} else {
    var s = null;
    try {
        s = server.openSession(target);
        s.target.connect();
        var up = false;
        try { up = s.target.isConnected(true); } catch (e1) { up = false; }
        if (up) {
            try { s.target.isHalted(); } catch (e2) { up = false; }
        }
        if (up) { print("PROBE_OPENABLE 1 " + s.getCPUName()); }
        else { print("PROBE_OPENABLE 0 CONNECT_NOT_VERIFIED"); }
        try { s.target.disconnect(); } catch (e3) { }
    } catch (e) {
        print("PROBE_OPENABLE 0 " + e);
    }
    try { if (s) { s.terminate(); } } catch (e4) { }
}
'@
    $jsText = $jsText.Replace('__CCXML__', $ccxmlJs).Replace('__CORE__', $CorePattern)
    [IO.File]::WriteAllText($js, $jsText)
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }

    $cmdLine = '/d /s /c ""' + $DssBat + '" "' + $js + '" > "' + $log + '" 2>&1"'
    $p = $null
    try {
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdLine -PassThru -WindowStyle Hidden -ErrorAction Stop
    } catch { $r.Detail = 'could not start DSS: ' + $_.Exception.Message; return $r }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    if (-not $p.HasExited) {
        try { & cmd.exe /d /c "taskkill /PID $($p.Id) /T /F" 2>&1 | Out-Null } catch { }
        $r.Detail = ('DSS did not finish within {0} s' -f $TimeoutSec)
        if (Test-Path -LiteralPath $log) { $r.Log = $log }
        return $r
    }

    $text = ''
    if (Test-Path -LiteralPath $log) { try { $text = [IO.File]::ReadAllText($log) } catch { } }
    $r.Log = $log
    $m = [regex]::Match($text, 'PROBE_OPENABLE\s+([01])\s*(.*)')
    if ($m.Success) {
        $r.Ok = ($m.Groups[1].Value -eq '1')
        $r.Detail = $m.Groups[2].Value.Trim()
    } else {
        $r.Detail = 'DSS produced no PROBE_OPENABLE line (see log)'
    }
    return $r
}

function Wait-ProbeUsable {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][scriptblock]$ProbeCheck,
        [string]$Ccxml = '',
        [int]$MaxSeconds = 90,
        [switch]$Quiet
    )
    $st = Get-ProbeWaitState -ProjectPath $ProjectPath
    $probeKey = Get-ProbeConfigKey -ProjectPath $ProjectPath -Ccxml $Ccxml
    if ($probeKey -and $st.probe -ne $probeKey) {
        $st.okMs = 0; $st.failMs = 0; $st.probe = $probeKey
    }
    $step = 5000
    $started = Get-Date
    $deadline = $started.AddSeconds($MaxSeconds)

    # A probe that is already present must not pay the recovery delay on every read.
    # This check is also the zero-ms lower bound for a new recovery episode.
    if (& $ProbeCheck) { return $true }
    $lastFailedMs = [int]$st.failMs

    # Bisection start: halfway between the smallest wait that has worked and the smallest
    # that has failed. With no failure recorded yet, trust the last good value; with no
    # history at all, begin at one step.
    if ($st.okMs -gt 0 -and $st.failMs -ge 0 -and $st.failMs -lt $st.okMs) {
        $nextAtMs = [int](($st.okMs + $st.failMs) / 2)
    } elseif ($st.okMs -gt 0) { $nextAtMs = $st.okMs }
    else { $nextAtMs = $step }
    if ($nextAtMs -lt 1000) { $nextAtMs = 1000 }

    while ((Get-Date) -lt $deadline) {
        $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
        $remainingMs = [int]($deadline - (Get-Date)).TotalMilliseconds
        if ($remainingMs -le 0) { break }
        $wait = [Math]::Min([Math]::Max(0, $nextAtMs - $elapsedMs), $remainingMs)
        if (-not $Quiet) {
            $src = if ($st.okMs -gt 0 -and $st.failMs -gt 0) { 'bisect' } elseif ($st.okMs -gt 0) { 'learned' } else { 'first run' }
            Write-Host ('PROBE   : waiting {0:N1} s ({1}); history ok={2} ms, fail={3} ms' -f ($wait / 1000.0), $src, $st.okMs, $st.failMs)
        }
        if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
        $total = [int]((Get-Date) - $started).TotalMilliseconds
        if (& $ProbeCheck) {
            if (-not $Quiet) { Write-Host ('PROBE   : check passed after {0:N1} s total' -f ($total / 1000.0)) }
            Save-ProbeWaitState -ProjectPath $ProjectPath -OkMs $total -FailMs $lastFailedMs -Probe $probeKey
            return $true
        }
        # Store elapsed recovery time, not the last sleep duration. A failed 5 s check
        # followed by a successful 10 s sleep means readiness at 15 s, not 10 s.
        $lastFailedMs = $total
        $st.failMs = $total
        $nextAtMs = $total + $step
    }
    Save-ProbeWaitState -ProjectPath $ProjectPath -OkMs $st.okMs -FailMs $lastFailedMs -Probe $probeKey
    if (-not $Quiet) {
        Write-Host ('PROBE   : still not usable after {0:N0} s; recorded fail={1} ms for the next attempt' -f $MaxSeconds, $st.failMs)
    }
    return $false
}
