#requires -Version 5.1
<#  ACE-Guardian 状态面板（独立进程） #>
$ErrorActionPreference = 'Stop'
$Root   = 'C:\ACE-Guardian'
$Flag   = "$Root\ACTIVE.flag"
$StateF = "$Root\state.json"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$WndTitle = 'ACE 管控守护'

# 单实例：Mutex 负责判定是否已有实例（可靠），命名事件仅负责通知已有实例显示窗口。
# 不用 FindWindow，因为面板以 -WindowStyle Hidden 启动，顶层窗口搜不到。
$evShow = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Global\ACE-Guardian-Panel-Show')
$mx = New-Object System.Threading.Mutex($false, 'Global\ACE-Guardian-Panel')
# 上个实例被强杀时锁会变成 abandoned，WaitOne 抛异常但锁实际已获取，必须继续运行
$gotLock = $false
try {
    $gotLock = $mx.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $gotLock = $true
}
if (-not $gotLock) {
    # 已有实例在跑：发信号让它把窗口拉到前台，自己退出
    $evShow.Set() | Out-Null
    exit
}
# 抢到互斥说明是首个实例，清掉可能残留的旧信号
$evShow.Reset() | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

function Get-Status {
    $o = [ordered]@{ 存活=$false; 模式='未知'; 心跳秒=999; 手动=$false; ACE=@(); 游戏=@(); 登录器=@(); ACE进程=@(); 今日风险=0 }
    try {
        if (Test-Path $StateF) {
            $o.心跳秒 = [math]::Round(((Get-Date) - (Get-Item $StateF).LastWriteTime).TotalSeconds)
            $o.存活   = ($o.心跳秒 -lt 90)
            $st = Get-Content $StateF -Raw -Encoding UTF8 | ConvertFrom-Json
            $o.模式 = if ($st.mode -eq 'Active') { '激活态' } else { '静默态' }
        }
        $o.手动 = Test-Path $Flag
        $cfg = Get-Content "$Root\config.json" -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue) {
            foreach ($p in $cfg.ACE服务前缀) {
                if ($k.PSChildName -like "$p*") {
                    $pr  = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
                    $stt = switch ($pr.Start) { 0{'Boot'} 1{'System'} 2{'Auto'} 3{'Manual'} 4{'Disabled'} default{'?'} }
                    $d   = Get-CimInstance Win32_SystemDriver -Filter "Name='$($k.PSChildName)'" -ErrorAction SilentlyContinue
                    $o.ACE += [pscustomobject]@{ 名称=$k.PSChildName; 启动=$stt; 状态=$(if($d){$d.State}else{'-'}); 危险=($pr.Start -in 0,1,2) }
                    break
                }
            }
        }
        $o.游戏 = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $cfg.游戏本体进程名 -contains $_.Name } | Select-Object -Expand Name -Unique)
        $o.登录器 = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $cfg.登录器进程名 -contains $_.Name } | Select-Object -Expand Name -Unique)
        $o.ACE进程 = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $cfg.ACE进程名 -contains $_.Name } | Select-Object -Expand Name -Unique)
        $t = (Get-Date).Date
        $o.今日风险 = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=1001; StartTime=$t} -ErrorAction SilentlyContinue).Count +
                      @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$t} -ErrorAction SilentlyContinue).Count
    } catch { }
    return $o
}

$f = New-Object System.Windows.Forms.Form
$f.Text            = $WndTitle
$f.ClientSize      = New-Object System.Drawing.Size(440,480)
$f.StartPosition   = 'CenterScreen'
$f.BackColor       = [System.Drawing.Color]::FromArgb(30,32,38)
$f.ForeColor       = [System.Drawing.Color]::White
$f.FormBorderStyle = 'FixedSingle'
$f.MaximizeBox     = $false
$f.TopMost         = $true

$fontH = New-Object System.Drawing.Font('Microsoft YaHei UI',14,[System.Drawing.FontStyle]::Bold)
$fontN = New-Object System.Drawing.Font('Microsoft YaHei UI',9)
$fontM = New-Object System.Drawing.Font('Consolas',9)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'ACE 管控守护'
$lblTitle.Font = $fontH
$lblTitle.Location = New-Object System.Drawing.Point(18,14)
$lblTitle.Size = New-Object System.Drawing.Size(300,30)

$lblDot = New-Object System.Windows.Forms.Label
$lblDot.Text = [string][char]0x25CF
$lblDot.Font = New-Object System.Drawing.Font('Segoe UI',22)
$lblDot.TextAlign = 'MiddleCenter'
$lblDot.Location = New-Object System.Drawing.Point(378,10)
$lblDot.Size = New-Object System.Drawing.Size(44,44)

$lblState = New-Object System.Windows.Forms.Label
$lblState.Font = $fontN
$lblState.Location = New-Object System.Drawing.Point(18,48)
$lblState.Size = New-Object System.Drawing.Size(350,44)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = '自动刷新'
$chkAuto.Font = $fontN
$chkAuto.Checked = $true
$chkAuto.ForeColor = [System.Drawing.Color]::FromArgb(160,166,178)
$chkAuto.Location = New-Object System.Drawing.Point(330,76)
$chkAuto.Size = New-Object System.Drawing.Size(92,20)

$box = New-Object System.Windows.Forms.TextBox
$box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Vertical'
$box.Font = $fontM
$box.BackColor = [System.Drawing.Color]::FromArgb(22,24,29)
$box.ForeColor = [System.Drawing.Color]::FromArgb(210,215,225)
$box.BorderStyle = 'FixedSingle'
$box.Location = New-Object System.Drawing.Point(18,98)
$box.Size = New-Object System.Drawing.Size(404,290)

function New-Btn {
    param([string]$Text,[int]$X,[int]$W,[System.Drawing.Color]$Bg)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Font = $fontN
    $b.Location = New-Object System.Drawing.Point($X,404)
    $b.Size = New-Object System.Drawing.Size($W,40)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Bg
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}
$btnToggle  = New-Btn '开启守护' 18  130 ([System.Drawing.Color]::FromArgb(0,120,215))
$btnRefresh = New-Btn '刷新'     158  84 ([System.Drawing.Color]::FromArgb(58,62,70))
$btnLog     = New-Btn '查看日志' 250  90 ([System.Drawing.Color]::FromArgb(58,62,70))
$btnClose   = New-Btn '关闭'     348  74 ([System.Drawing.Color]::FromArgb(58,62,70))

$f.Controls.AddRange(@($lblTitle,$lblDot,$lblState,$chkAuto,$box,$btnToggle,$btnRefresh,$btnLog,$btnClose))

# $Force=$true 表示手动刷新，会重绘日志区；自动刷新只更新上方状态，不动日志区
$refresh = {
    param([bool]$Force = $false)
    $s = Get-Status
    if (-not $s.存活) {
        $lblDot.ForeColor = [System.Drawing.Color]::Gray
        $lblState.Text = "守护未运行`r`n请重启电脑，或检查计划任务 ACE-Guardian"
    } elseif (@($s.ACE | Where-Object 危险).Count -gt 0) {
        $lblDot.ForeColor = [System.Drawing.Color]::FromArgb(255,170,0)
        $lblState.Text = "ACE 被设为开机常驻`r`n将在游戏关闭后改为按需加载"
    } elseif ($s.模式 -eq '激活态') {
        $lblDot.ForeColor = [System.Drawing.Color]::FromArgb(255,170,0)
        $由 = if ($s.游戏) { '游戏本体运行中' } elseif ($s.登录器) { '登录器已启动' } elseif ($s.手动) { '手动开启' } else { '观察中' }
        $lblState.Text = "激活态 · $由（每 5 秒）`r`n不干预 ACE 运行，仅观察记录"
    } else {
        $lblDot.ForeColor = [System.Drawing.Color]::FromArgb(40,180,80)
        $lblState.Text = "静默态 · 一切正常`r`n低频巡检中，等待游戏启动或手动开启"
    }
    if ($s.手动) {
        $btnToggle.Text = '关闭守护'
        $btnToggle.BackColor = [System.Drawing.Color]::FromArgb(200,80,40)
    } else {
        $btnToggle.Text = '开启守护'
        $btnToggle.BackColor = [System.Drawing.Color]::FromArgb(0,120,215)
    }

    # 非强制刷新时不重绘日志区，避免正在看日志被打断
    if (-not $Force -and $box.Text.Length -gt 0) { return }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("心跳         : $($s.心跳秒) 秒前")
    [void]$sb.AppendLine("运行模式     : $($s.模式)")
    [void]$sb.AppendLine("手动激活     : $(if($s.手动){'是'}else{'否'})")
    [void]$sb.AppendLine("游戏本体     : $(if($s.游戏){$s.游戏 -join ', '}else{'未运行'})")
    [void]$sb.AppendLine("登录器       : $(if($s.登录器){$s.登录器 -join ', '}else{'未运行'})")
    [void]$sb.AppendLine("ACE 进程     : $(if($s.ACE进程){$s.ACE进程 -join ', '}else{'未运行'})")
    [void]$sb.AppendLine("今日风险事件 : $($s.今日风险) 条")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- ACE 反作弊 ---')
    if ($s.ACE.Count -eq 0) {
        [void]$sb.AppendLine('  未安装（干净）')
    } else {
        foreach ($a in $s.ACE) {
            $mk = if ($a.危险) { '[常驻]' } else { '[按需]' }
            [void]$sb.AppendLine(('  {0} {1,-18} {2,-9} {3}' -f $mk,$a.名称,$a.启动,$a.状态))
        }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- 最近管控记录 ---')
    $ev = Get-ChildItem "$Root\logs" -Filter 'events-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($ev) {
        foreach ($l in (Get-Content $ev.FullName -Encoding UTF8 -Tail 10)) { [void]$sb.AppendLine("  $l") }
    } else {
        [void]$sb.AppendLine('  暂无（说明一切正常）')
    }
    $box.Text = $sb.ToString()
}

$btnRefresh.Add_Click({ & $refresh $true })
$btnClose.Add_Click({ $f.Close() })
$btnLog.Add_Click({ Start-Process explorer.exe "$Root\logs" })
$btnToggle.Add_Click({
    if (Test-Path $Flag) { Remove-Item $Flag -Force }
    else { Set-Content $Flag (Get-Date -Format 'u') -Encoding UTF8 }
    Start-Sleep -Milliseconds 600
    & $refresh $true
})

$tm = New-Object System.Windows.Forms.Timer
$tm.Interval = 3000
$tm.Add_Tick({ if ($chkAuto.Checked) { & $refresh $false } })
$tm.Start()

# 监听"再次打开"信号：其他实例启动时会 Set 这个事件，收到就把窗口拉到前台
$tmShow = New-Object System.Windows.Forms.Timer
$tmShow.Interval = 400
$tmShow.Add_Tick({
    if ($evShow.WaitOne(0)) {
        $f.WindowState = 'Normal'
        $f.Show()
        $f.TopMost = $true
        $f.BringToFront()
        $f.Activate()
        $f.TopMost = $false
        & $refresh $true
    }
})
$tmShow.Start()

$f.Add_Shown({ $f.TopMost = $false; $f.Activate() })
$f.Add_FormClosed({ $tm.Stop(); $tm.Dispose(); $tmShow.Stop(); $tmShow.Dispose() })

& $refresh $true
[System.Windows.Forms.Application]::Run($f)
# 窗口关闭后释放互斥与事件句柄，下次才能正常新建实例
try { $mx.ReleaseMutex() } catch { }
$mx.Dispose()
$evShow.Close()
[System.Environment]::Exit(0)
