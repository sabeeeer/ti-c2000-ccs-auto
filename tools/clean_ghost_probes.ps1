#requires -Version 7.0
<#
clean_ghost_probes.ps1 -- 清掉"幽灵"调试探针实例，让 "Only one XDS100" 能自己选对。

为什么需要它（2026-11-18 A/B 实测）：
  * 同一块板、同一个 .out、统一 10 s 间隔，唯一变量是 ccxml 的 Emulator Selection：
        Only one XDS100  ->  Error -215 "semaphore for the test bus controller is in a
                             time-out state"（连不上）
        按串号 TI90I42A  ->  LOAD #113 OK
  * 也就是说：默认的"自动选择"在有多组历史探针残留的机器上会失败，而按串号能绕开。
  * 但如果要求"程序不依赖串号"，就必须让"自动选择"本身可用 —— 做法就是删掉那些
    物理上已不存在（Status=Unknown / Present=False）的历史实例。

安全性：
  * 只处理 Status **不是 OK** 的实例；当前正在用的探针（Status=OK）绝不会被碰。
  * 默认只列出、不删除。必须显式加 -Confirm 才执行删除。
  * 每个被删的都是 Windows 里"已拔出但仍留有记录"的设备，重新插上会重新枚举。

用法（需要管理员）：
  pwsh -NoProfile -File tools\clean_ghost_probes.ps1            # 只列出
  pwsh -NoProfile -File tools\clean_ghost_probes.ps1 -Confirm   # 真删
#>
[CmdletBinding()]
param(
    [switch]$Confirm,
    [string]$Match = 'XDS|XDS100|XDS110|XDS2xx|Debug Probe'
)

$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$all = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match $Match })
$live = @($all | Where-Object { $_.Status -eq 'OK' })
$ghosts = @($all | Where-Object { $_.Status -ne 'OK' })

Write-Output ('探针相关设备：{0} 个（OK {1} / 幽灵 {2}）' -f $all.Count, $live.Count, $ghosts.Count)
Write-Output ''
if ($live.Count -gt 0) {
    Write-Output '保留（Status=OK，正在使用）：'
    foreach ($d in $live) { Write-Output ('  {0,-9} {1}  [{2}]' -f $d.Status, $d.FriendlyName, $d.InstanceId) }
    Write-Output ''
}
if ($ghosts.Count -eq 0) {
    Write-Output '没有幽灵实例，"Only one XDS100" 应当可以正常工作。'
    Write-Output 'RESULT: OK'
    exit 0
}

Write-Output '幽灵（Status≠OK，物理上已不在）：'
foreach ($d in $ghosts) { Write-Output ('  {0,-9} {1}  [{2}]' -f $d.Status, $d.FriendlyName, $d.InstanceId) }
Write-Output ''

if (-not $Confirm) {
    Write-Output '（仅列出。要真正删除，请用管理员身份重跑并加 -Confirm）'
    Write-Output 'RESULT: OK'
    exit 0
}
if (-not $isAdmin) {
    Write-Output 'FAILURE: NEED_ADMIN'
    Write-Output 'RESULT: FAIL'
    Write-Output 'REASON: 删除设备记录需要管理员权限；请用"以管理员身份运行"的 PowerShell 重试'
    exit 1
}

$removed = 0
$failed = @()
foreach ($d in $ghosts) {
    $id = [string]$d.InstanceId
    try {
        & pnputil.exe /remove-device "$id" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $removed++ } else { $failed += $id }
    } catch { $failed += $id }
}

Write-Output ('已删除：{0} 个' -f $removed)
if ($failed.Count -gt 0) {
    Write-Output ('未删除：{0} 个' -f $failed.Count)
    foreach ($f in $failed) { Write-Output ('  ' + $f) }
}
Write-Output ''
Write-Output 'NEXT    : 现在可以不带任何串号运行：'
Write-Output '          pwsh -NoProfile -File scripts\ti_c2000_service.ps1 -ProjectPath <工程> -Start -ConfirmLoad'
if ($failed.Count -gt 0) { Write-Output 'RESULT: FAIL'; exit 1 }
Write-Output 'RESULT: OK'
exit 0
