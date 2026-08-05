#requires -Version 5.1
<# 手动关闭 ACE 守护。会触发退场检查：停止 ACE 驱动、确认无异常后回落静默态 #>
$Root = 'C:\ACE-Guardian'
$Flag = "$Root\ACTIVE.flag"

if (-not (Test-Path $Flag)) {
    Write-Host "`n守护当前未处于手动激活状态。" -ForegroundColor Yellow
    Write-Host "（若游戏仍在运行，守护会自动保持激活，关闭游戏后自动退场检查）`n"
    return
}

Remove-Item $Flag -Force
Write-Host "`n已请求关闭守护，正在执行退场检查…" -ForegroundColor Cyan
Write-Host "  - 停止所有 ACE 内核驱动"
Write-Host "  - 结束 ACE 残留进程"
Write-Host "  - 复查系统健康状态"

$ev = "$Root\logs\events-$(Get-Date -Format yyyyMMdd).log"
$before = if (Test-Path $ev) { (Get-Content $ev).Count } else { 0 }

for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Seconds 3
    $st = Get-Content "$Root\state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($st.mode -eq 'Idle') { break }
    Write-Host "  等待中…" -ForegroundColor DarkGray
}

Write-Host "`n===== 退场检查结果 =====" -ForegroundColor Green
if (Test-Path $ev) {
    $new = Get-Content $ev | Select-Object -Skip $before
    if ($new) { $new | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  无新记录" }
}
$st = Get-Content "$Root\state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host ("`n当前模式: {0}" -f $(if($st.mode -eq 'Idle'){'静默态'}else{$st.mode})) -ForegroundColor Cyan
Write-Host ""
