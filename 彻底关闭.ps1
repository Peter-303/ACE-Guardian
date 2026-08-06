#requires -Version 5.1
<#
  彻底关闭 ACE 管控系统。
  与"休眠"/"关闭守护"不同：本操作把守护和托盘进程全部结束，并禁用开机自启的计划任务，
  做到 0 进程、0 占用、开机也不自启，直到你手动运行 彻底启动.ps1 为止。
  适用场景：确认长期不玩需要 ACE 的游戏、或进入"无 ACE 观察期"，让管控彻底让出资源。

  注意：本操作不碰 ACE 本身（不停驱动、不改注册表），只是让管控系统自己下线。
  若此刻 ACE 内核驱动仍在运行，管控下线后将不再对其预警/干预——这是彻底关闭的预期行为。
#>
$ErrorActionPreference = 'SilentlyContinue'
$Root = 'C:\ACE-Guardian'

Write-Host "`n正在彻底关闭 ACE 管控系统…" -ForegroundColor Cyan

# 1. 禁用计划任务（阻止开机自启）——这是"直到手动启动"的关键
$tasks = @('ACE-Guardian','ACE-Guardian-Tray')
foreach ($t in $tasks) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Disable-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue | Out-Null
        Write-Host "  已禁用计划任务: $t（开机不再自启）"
    }
}

# 2. 结束守护主进程（Guardian.ps1）
$guardian = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -match 'Guardian\.ps1' }
foreach ($p in $guardian) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Host "  已结束守护进程 PID $($p.ProcessId)"
}

# 3. 结束托盘进程（Tray.ps1）
$tray = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -match 'Tray\.ps1' }
foreach ($p in $tray) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Host "  已结束托盘进程 PID $($p.ProcessId)"
}

# 4. 记一笔关闭事件，并把状态标记为已停止（供面板/托盘判断）
$ev = "$Root\logs\events-$(Get-Date -Format yyyyMMdd).log"
Add-Content -Path $ev -Value ("{0} [ACTION] 管控系统已彻底关闭（进程结束+计划任务禁用，需手动启动）" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
@{ mode='Off'; silent=$true; stopped=$true; time=(Get-Date -Format 'o') } | ConvertTo-Json -Compress |
    Set-Content "$Root\state.json" -Encoding UTF8

# 5. 复查
Start-Sleep -Seconds 1
$remain = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -match 'Guardian\.ps1|Tray\.ps1' }).Count

Write-Host "`n===== 关闭结果 =====" -ForegroundColor Green
if ($remain -eq 0) {
    Write-Host "  ✓ 守护与托盘进程已全部结束" -ForegroundColor Green
} else {
    Write-Host "  ⚠ 仍有 $remain 个相关进程，可能权限不足，请以管理员重试" -ForegroundColor Yellow
}
foreach ($t in $tasks) {
    $st = (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue).State
    Write-Host ("  计划任务 {0}: {1}" -f $t, $st)
}
Write-Host "`n管控系统已彻底下线，0 占用，开机也不会自启。" -ForegroundColor Cyan
Write-Host "需要时运行  彻底启动.ps1  重新拉起。`n" -ForegroundColor Cyan
