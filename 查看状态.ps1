#requires -Version 5.1
<# ACE-Guardian 状态查询工具，直接双击或在 PowerShell 中运行 #>
$ErrorActionPreference = 'SilentlyContinue'
$Root = 'C:\ACE-Guardian'

Write-Host "`n===== ACE 管控系统 状态 =====" -ForegroundColor Cyan

# 守护进程：以 state.json 心跳判断存活（SYSTEM 任务在非管理员会话下查不到）
$sf = "$Root\state.json"
if (Test-Path $sf) {
    $age = ((Get-Date) - (Get-Item $sf).LastWriteTime).TotalSeconds
    $st  = Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($age -lt 90) {
        Write-Host ("守护进程   : 运行中（心跳 {0} 秒前）" -f [math]::Round($age)) -ForegroundColor Green
    } else {
        Write-Host ("守护进程   : 可能已停止（心跳 {0} 分钟前）" -f [math]::Round($age/60)) -ForegroundColor Red
    }
    $manual = Test-Path "$Root\ACTIVE.flag"
    if ($st.mode -eq 'Active') {
        Write-Host ("运行模式   : 激活态（密集监控中{0}）" -f $(if($manual){'，手动开启'}else{'，检测到游戏'})) -ForegroundColor Yellow
    } else {
        Write-Host "运行模式   : 静默态（低频巡检，等待游戏或手动开启）" -ForegroundColor Green
    }
} else {
    Write-Host "守护进程   : 未启动（无心跳文件）" -ForegroundColor Red
}
$t2 = Get-ScheduledTask -TaskName 'ACE-Guardian-Notifier' -EA SilentlyContinue
Write-Host ("弹窗组件   : {0}" -f $(if($t2){$t2.State}else{'查询需管理员权限'}))

# ACE 现状
Write-Host "`n--- ACE 当前状态 ---" -ForegroundColor Yellow
$cfg = Get-Content "$Root\config.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$found = $false
foreach ($k in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services') {
    $n = $k.PSChildName; $hit = $false
    foreach ($p in $cfg.ACE服务前缀) { if ($n -like "$p*") { $hit = $true; break } }
    if (-not $hit) { continue }
    $found = $true
    $pr = Get-ItemProperty $k.PSPath
    $st = switch ($pr.Start) { 0 {'Boot'} 1 {'System'} 2 {'Auto'} 3 {'Manual'} 4 {'Disabled'} }
    $d = Get-CimInstance Win32_SystemDriver -Filter "Name='$n'"
    $color = if ($pr.Start -in 0,1,2) { 'Red' } else { 'Green' }
    Write-Host ("  {0,-22} Start={1,-9} State={2}" -f $n, $st, $(if($d){$d.State}else{'-'})) -ForegroundColor $color
}
if (-not $found) { Write-Host "  未安装 ACE（游戏未装或已卸载）" -ForegroundColor Green }

# 游戏本体 / 登录器 / ACE 进程分开显示
$g = Get-Process | Where-Object { $cfg.游戏本体进程名 -contains $_.Name }
$l = Get-Process | Where-Object { $cfg.登录器进程名 -contains $_.Name }
$a = Get-Process | Where-Object { $cfg.ACE进程名 -contains $_.Name }
Write-Host ("`n游戏本体   : {0}" -f $(if($g){($g|Select -Expand Name -Unique) -join ', '}else{'未运行'}))
Write-Host ("登录器     : {0}" -f $(if($l){($l|Select -Expand Name -Unique) -join ', '}else{'未运行'}))
Write-Host ("ACE 进程   : {0}" -f $(if($a){($a|Select -Expand Name -Unique) -join ', '}else{'未运行'}))

# 今日事件
Write-Host "`n--- 今日风险事件 ---" -ForegroundColor Yellow
$today = (Get-Date).Date
foreach ($x in @(
  @{n='蓝屏';       f=@{LogName='System'; Id=1001; StartTime=$today}},
  @{n='非正常关机'; f=@{LogName='System'; Id=41;   StartTime=$today}},
  @{n='WHEA硬件错误'; f=@{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$today}},
  @{n='磁盘缓存抖动'; f=@{LogName='System'; ProviderName='disk'; StartTime=$today}}
)) {
  $r = @(Get-WinEvent -FilterHashtable $x.f -EA SilentlyContinue)
  $c = if ($r.Count -eq 0) { 'Green' } else { 'Red' }
  Write-Host ("  {0,-14}: {1} 条" -f $x.n, $r.Count) -ForegroundColor $c
}

# 管控记录
Write-Host "`n--- 最近管控/告警记录 ---" -ForegroundColor Yellow
$ev = Get-ChildItem "$Root\logs" -Filter 'events-*.log' | Sort-Object LastWriteTime -Desc | Select-Object -First 1
if ($ev) { Get-Content $ev.FullName -Tail 15 | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  暂无（说明一切正常）" -ForegroundColor Green }

# 快照
$sn = @(Get-ChildItem "$Root\snapshots" -Filter 'snap-*.json')
Write-Host ("`n状态快照   : {0} 份（滚动保留最近 {1} 分钟）" -f $sn.Count, $cfg.快照保留分钟)
if ($sn.Count -gt 0) {
    $l = Get-Content ($sn | Sort-Object LastWriteTime -Desc | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
    Write-Host ("最新快照   : {0} 内存{1}/{2}GB 提交率{3}% ACE[{4}]" -f $l.时间, $l.内存已用GB, $l.内存总GB, $l.提交率百分比, $l.ACE状态)
}
Write-Host ""
