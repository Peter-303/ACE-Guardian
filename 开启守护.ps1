#requires -Version 5.1
<# 手动开启 ACE 守护（玩游戏前运行）#>
$Root = 'C:\ACE-Guardian'
$Flag = "$Root\ACTIVE.flag"

$sf = "$Root\state.json"
if (-not (Test-Path $sf) -or ((Get-Date) - (Get-Item $sf).LastWriteTime).TotalSeconds -gt 90) {
    Write-Host "`n[警告] 守护主进程似乎未运行，请重启电脑或联系 AI 检查。" -ForegroundColor Red
}

Set-Content -Path $Flag -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Encoding UTF8
Write-Host "`n===== 守护已手动开启 =====" -ForegroundColor Green
Write-Host "现在可以启动无畏契约了。守护将："
Write-Host "  - 每 5 秒采集一次系统快照"
Write-Host "  - 持续把 ACE 驱动锁定为 Manual（阻止开机常驻）"
Write-Host "  - 监控磁盘抖动 / Defender 冲突 / WHEA / 蓝屏"
Write-Host "  - 游戏退出后自动执行退场检查并关闭 ACE`n"
Write-Host "如需提前手动关闭，运行：关闭守护.ps1" -ForegroundColor Yellow

Start-Sleep -Seconds 3
$st = Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host ("`n当前模式: {0}" -f $(if($st.mode -eq 'Active'){'激活态（已生效）'}else{'切换中，请稍候…'})) -ForegroundColor Cyan
