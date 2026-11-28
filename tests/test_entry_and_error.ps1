#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('c2000-entry-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture '.cproject'),'<project/>')
    $init = Join-Path $root 'tools/init_project_entry.ps1'
    $check = Join-Path $root 'scripts/check_project_entry.ps1'
    $err = Join-Path $root 'scripts/ti_c2000_error.ps1'
    $r = @(& pwsh -NoProfile -File $init -ProjectPath $fixture 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($r -join "`n") -notmatch 'RESULT: OK') { throw "entry generator failed: $($r -join '; ')" }
    $contents = @('AGENTS.md','CODEBUDDY.md','CLAUDE.md' | ForEach-Object { [IO.File]::ReadAllText((Join-Path $fixture $_)) })
    if ($contents.Count -ne 3 -or @($contents | Sort-Object -Unique).Count -ne 1) { throw 'AI entry files differ' }
    $c = @(& pwsh -NoProfile -File $check -ProjectPath $fixture 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($c -join "`n") -notmatch 'RESULT: OK') { throw "entry audit failed: $($c -join '; ')" }
    $bvPath = Join-Path $fixture 'BUILD_VERIFICATION.txt'
    if (-not (Test-Path -LiteralPath $bvPath)) { throw 'BUILD_VERIFICATION.txt was not created' }
    $bvText = [IO.File]::ReadAllText($bvPath)
    if ($bvText -notmatch '第一部分 · 系统配置说明' -or $bvText -notmatch '第二部分 · 改动留痕') { throw 'BUILD_VERIFICATION.txt missing two-part template sections' }
    $e = @(& pwsh -NoProfile -File $err -Code RESET_FAILED 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($e -join "`n") -notmatch 'RESULT: OK' -or ($e -join "`n") -notmatch 'halt') { throw "error lookup failed: $($e -join '; ')" }
    foreach ($pair in @(@('COMPILER_VERSION_MISSING','validation'),@('NO_PROBE','download_probe'),@('FRAME_CHANGED','data_verdict'))) {
        $e = @(& pwsh -NoProfile -File $err -Code $pair[0] 2>&1)
        if ($LASTEXITCODE -ne 0 -or ($e -join "`n") -notmatch ('CATEGORY: ' + $pair[1])) { throw "error category lookup failed: $($pair[0])" }
    }
    $log = Join-Path $fixture 'usage.log'
    [IO.File]::WriteAllText($log, "USAGE: BAD_DIMENSIONS`nRESULT: FAIL`n")
    $e = @(& pwsh -NoProfile -File $err -LogPath $log 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($e -join "`n") -notmatch 'CATEGORY: parameter') { throw 'USAGE log was not classified' }
    [IO.File]::WriteAllText($log, "Error -1138 recovered`nFAILURE: FRAME_CHANGED`nRESULT: FAIL`n")
    $e = @(& pwsh -NoProfile -File $err -LogPath $log 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($e -join "`n") -notmatch 'CODE    : FRAME_CHANGED') { throw 'an earlier recovered GEL error overrode the final failure' }
    $bad = @(& pwsh -NoProfile -File $err -Code NOT_IN_INDEX 2>&1)
    if ($LASTEXITCODE -ne 2 -or ($bad -join "`n") -notmatch 'ERROR_NOT_INDEXED') { throw 'unknown error was not refused' }
    Write-Output 'CHECK   : AI entries are identical and Error mode is offline and fail-closed'
    Write-Output 'RESULT: OK'; exit 0
} catch {
    Write-Output 'FAILURE: TEST_FAILED'; Write-Output ('REASON: ' + $_.Exception.Message)
    Write-Output 'RESULT: FAIL'; exit 1
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
