#requires -Version 5.1
<#
  彻底启动 ACE 管控系统（与 彻底关闭.ps1 配对）。
  重新启用两个计划任务并立即拉起守护与托盘。
  用计划任务方式启动，父进程为 Task Scheduler(svchost)，
  避免被启动它的终端进程树连带杀死。
#>
$ErrorActionPreference = 'SilentlyContinue'
$Root = 'C:\ACE-Guardian'

Write-Host "`n正在启动 ACE 管控系统…" -ForegroundColor Cyan

# 1. 清掉"已彻底关闭"的状态标记，避免面板误判
if (Test-Path "$Root\state.json") {
    $st = Get-Content "$Root\state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($st.stopped) { Remove-Item "$Root\state.json" -Force -ErrorAction SilentlyContinue }
}

# 2. 启用并立即运行计划任务
$tasks = @('ACE-Guardian','ACE-Guardian-Tray')
foreach ($t in $tasks) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Enable-ScheduledTask  -TaskName $t -ErrorAction SilentlyContinue | Out-Null
        Start-ScheduledTask   -TaskName $t -ErrorAction SilentlyContinue
        Write-Host "  已启用并启动: $t"
    } else {
        Write-Host "  ⚠ 计划任务不存在: $t（可能需重新注册）" -ForegroundColor Yellow
    }
}

# 3. 复查
Start-Sleep -Seconds 3
Write-Host "`n===== 启动结果 =====" -ForegroundColor Green
$guardian = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'Guardian\.ps1' })
$tray = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'Tray\.ps1' })
Write-Host ("  守护进程: {0}" -f $(if($guardian.Count){"运行中 PID $($guardian[0].ProcessId)"}else{'未起，请稍候或查看日志'}))
Write-Host ("  托盘进程: {0}" -f $(if($tray.Count){"运行中 PID $($tray[0].ProcessId)"}else{'未起，请稍候'}))
foreach ($t in $tasks) {
    Write-Host ("  计划任务 {0}: {1}" -f $t, (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue).State)
}
Write-Host "`n管控系统已启动。托盘图标应在几秒内出现。`n" -ForegroundColor Cyan
