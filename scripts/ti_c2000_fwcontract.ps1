#requires -Version 7.0
<#
ti_c2000_fwcontract.ps1 -- the firmware side of the contract, read from one file.

references\firmware-contract.json is the single source of truth for the ONLY firmware
symbols this skill knows by name: the identity constant, the heartbeat counters, the rate
counter and the frozen-buffer trio. They used to be hard-coded in twelve places and had
already drifted (FrozenValue was 'true' in one script and '1' in another; the heartbeat
candidate sets differed in both membership and order).

Everything else about the target - memory map, Flash base, section layout, probe model - is
discovered at run time, never assumed. That distinction is the point: a contract you can
audit (tools/audit_fw_contract.ps1) versus knowledge that must be guessed.

Fallbacks are built in so a missing or broken contract file degrades to the documented
defaults with a warning instead of taking every reader offline.
#>

$script:FwContractCache = $null
$script:FwContractWarned = $false

function Get-FwContractPaths {
    $root = Split-Path $PSScriptRoot -Parent
    return @(
        (Join-Path $root 'references\firmware-contract.json')
        (Join-Path $PSScriptRoot 'firmware-contract.json')
    )
}

<#
Get-FwContract -- the parsed contract, cached for this process.

Fields: identity.var, heartbeat.candidates (array), rate.{var,perSec,tolerancePct},
frozenBuffer.{array,flag,flagValue,seq}. The shape is fixed here even when the file is
missing, so callers never have to null-check a field.
#>
function Get-FwContract {
    param([switch]$Quiet)

    if ($script:FwContractCache) { return $script:FwContractCache }

    # documented defaults: what the file would say if it existed
    $default = [ordered]@{
        identity     = [ordered]@{ var = 'gFwId' }
        heartbeat    = [ordered]@{ candidates = @('gMsTick', 'usMainLoop', 'gRunMs') }
        rate         = [ordered]@{ var = 'gMsTick'; perSec = 1000; tolerancePct = 20 }
        frozenBuffer = [ordered]@{ array = 'gBuf'; flag = 'gBufFull'; flagValue = '1'; seq = 'gBufSeq' }
        source       = '(built-in defaults)'
    }

    $path = @(Get-FwContractPaths) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $path) {
        if (-not $script:FwContractWarned -and -not $Quiet) {
            Write-Output 'WARN    : references\firmware-contract.json is missing - using built-in firmware defaults'
            Write-Output ('WARN    : ' + ($default.identity.var) + ', ' + ($default.heartbeat.candidates -join ', ') + ' - create the file to make this explicit')
        }
        $script:FwContractWarned = $true
        $script:FwContractCache = $default
        return $script:FwContractCache
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        if (-not $script:FwContractWarned -and -not $Quiet) {
            Write-Output ('WARN    : ' + (Split-Path $path -Leaf) + ' is not valid JSON - using built-in firmware defaults')
            Write-Output ('WARN    : ' + $_.Exception.Message)
        }
        $script:FwContractWarned = $true
        $script:FwContractCache = $default
        return $script:FwContractCache
    }

    # merge over the defaults, so a partial file still yields a complete shape
    $c = [ordered]@{
        identity = [ordered]@{ var = $(if ($raw.identity.var) { [string]$raw.identity.var } else { $default.identity.var }) }
        heartbeat = [ordered]@{ candidates = @() }
        rate = [ordered]@{
            var          = $(if ($raw.rate.var) { [string]$raw.rate.var } else { $default.rate.var })
            perSec       = $(if ($raw.rate.perSec) { [double]$raw.rate.perSec } else { $default.rate.perSec })
            tolerancePct = $(if ($raw.rate.tolerancePct) { [double]$raw.rate.tolerancePct } else { $default.rate.tolerancePct })
        }
        frozenBuffer = [ordered]@{
            array      = $(if ($raw.frozenBuffer.array) { [string]$raw.frozenBuffer.array } else { $default.frozenBuffer.array })
            flag       = $(if ($raw.frozenBuffer.flag) { [string]$raw.frozenBuffer.flag } else { $default.frozenBuffer.flag })
            flagValue  = $(if ($null -ne $raw.frozenBuffer.flagValue) { [string]$raw.frozenBuffer.flagValue } else { $default.frozenBuffer.flagValue })
            seq        = $(if ($raw.frozenBuffer.seq) { [string]$raw.frozenBuffer.seq } else { $default.frozenBuffer.seq })
        }
        source = (Split-Path $path -Leaf)
    }

    $cands = @($raw.heartbeat.candidates | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $c.heartbeat.candidates = $(if ($cands.Count) { $cands } else { $default.heartbeat.candidates })

    $script:FwContractCache = $c
    return $script:FwContractCache
}

<# The heartbeat candidates as one comma-separated string, ready for -HeartbeatExpr. #>
function Get-FwHeartbeatExpr {
    param([switch]$Quiet)
    return ((Get-FwContract -Quiet:$Quiet).heartbeat.candidates -join ',')
}
