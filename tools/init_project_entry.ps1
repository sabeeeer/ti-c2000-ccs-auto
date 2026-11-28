#requires -Version 7.0
<# Create the three AI entry files before an agent edits a CCS project. File-only. #>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProjectPath)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath (Join-Path $ProjectPath '.cproject'))) {
    Write-Output 'USAGE: NO_PROJECT'; Write-Output 'RESULT: FAIL'; exit 2
}
$project = (Get-Item -LiteralPath $ProjectPath).FullName
$body = @'
# TI C2000 / CCS project entry

This project uses `ti-c2000-ccs-auto`. Before changing code or reading target data:

1. Read the complete installed skill at `%USERPROFILE%\.codex\skills\ti-c2000-ccs-auto\SKILL.md` (Codex) or `%USERPROFILE%\.codebuddy\skills\ti-c2000-ccs-auto\SKILL.md` (CodeBuddy). Its source of truth is the CodeBuddy copy; synchronize copies with the skill's `tools\sync_platform_copies.ps1` after editing it.
2. Read this project's `.cproject`, `.ccxml`, linker `.cmd` and applicable project instructions. Select the device/probe reference, algorithm reference and debug-experience reference separately.
3. Run the installed skill's `scripts\check_project_entry.ps1 -ProjectPath <this project>`; proceed only on exit 0 and `RESULT: OK`. Use only scripts in that skill, never project-local DSS or copied skill scripts.
4. For data reads, use `-Mode ReadOnly`: zero builds, zero loads, retained live DSS session. Report the probe, connection, source image, RAM/Flash location (or UNKNOWN), firmware identity, application heartbeat and cumulative download count. Deliver any values actually read with a same-run `OK/FAIL` data verdict; location alone never blocks a read or download.
5. A download requires the user's explicit approval and `-ConfirmLoad`. Read data while the program runs; do not halt/reset/reconnect merely to read. Continuous runs require explicit user request, at least 5 seconds between load attempts and at least 400 ms between reads.
6. On an error, first use the skill's offline `scripts\ti_c2000_error.ps1 -Code <code>` and inspect `references\error-index.json` before retrying.
7. Maintain `BUILD_VERIFICATION.txt` in the project root: fill in Part 1 (system configuration: device/core, probe, compiler, clocks/carrier/sampling rate, peripherals/pins, active modules) when first onboarding or when system config changes; on every code/config/build change, append a brief entry to Part 2 (`date | what changed | why | verification result`), append-only without overwriting.

Every skill command must print `SKILL   : ti-c2000-ccs-auto@<version>`; trust success only when exit code is zero and `RESULT: OK` appears.
'@
$names = @('AGENTS.md','CODEBUDDY.md','CLAUDE.md')
foreach ($name in $names) {
    $path = Join-Path $project $name
    if (Test-Path -LiteralPath $path) {
        $old = [IO.File]::ReadAllText($path)
        if ($old -ne $body) {
            Write-Output 'FAILURE: ENTRY_EXISTS'; Write-Output 'RESULT: FAIL'
            Write-Output "REASON: $path has existing instructions; merge them manually, then copy the same content into all three entry files"
            exit 4
        }
    }
}
foreach ($name in $names) {
    $path = Join-Path $project $name
    if (-not (Test-Path -LiteralPath $path)) {
        [IO.File]::WriteAllText($path, $body, [Text.UTF8Encoding]::new($false))
        Write-Output "CREATED : $path"
    }
}
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ti_c2000_readmode.ps1')
$version = (Get-SkillIdentity).version
Write-Output "SKILL   : ti-c2000-ccs-auto@$version"
Write-Output 'RESULT: OK'
