#requires -Version 5.1
<#
  ACE-Guardian 托盘组件 v2
  职责：
    1. 任务栏托盘图标，颜色/提示实时反映守护状态
    2. 右键菜单：开启/关闭守护、打开面板、查看日志
    3. 消费主进程投递的告警并弹出气泡通知
    4. 简单状态面板（WinForms）
#>
$ErrorActionPreference = 'SilentlyContinue'
$Root     = 'C:\ACE-Guardian'
$AlertDir = "$Root\alerts"
$Flag     = "$Root\ACTIVE.flag"
$StateF   = "$Root\state.json"
New-Item -ItemType Directory -Path $AlertDir -Force | Out-Null

# 单实例互斥，避免重复启动多个托盘图标。
# 注意：上一个实例被强杀或未释放锁时，锁会变成 abandoned 状态，
# 此时 WaitOne 会抛 AbandonedMutexException —— 这代表锁已成功获取，必须继续运行，
# 不能当成"已有实例"而退出，否则托盘会永久起不来。
$mutex = New-Object System.Threading.Mutex($false, 'Global\ACE-Guardian-Tray')
$gotLock = $false
try {
    $gotLock = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $gotLock = $true
}
if (-not $gotLock) { exit }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- 动态生成圆点图标 ----------
function New-DotIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap 32,32
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(60,0,0,0))), 3,3,28,28)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $Color), 5,5,22,22)
    $g.DrawEllipse((New-Object System.Drawing.Pen ([System.Drawing.Color]::White),2), 5,5,22,22)
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$IconIdle   = New-DotIcon ([System.Drawing.Color]::FromArgb(40,180,80))    # 绿：静默正常
$IconActive = New-DotIcon ([System.Drawing.Color]::FromArgb(255,170,0))    # 橙：激活监控中
$IconAlert  = New-DotIcon ([System.Drawing.Color]::FromArgb(220,50,50))    # 红：有异常
$IconDead   = New-DotIcon ([System.Drawing.Color]::FromArgb(130,130,130))  # 灰：守护未运行

# ---------- 读取状态 ----------
function Get-Status {
    $o = [ordered]@{ 存活=$false; 模式='未知'; 心跳秒=999; 手动=$false; ACE=@(); 游戏=@(); 登录器=@(); 今日风险=0 }
    if (Test-Path $StateF) {
        $o.心跳秒 = [math]::Round(((Get-Date) - (Get-Item $StateF).LastWriteTime).TotalSeconds)
        $o.存活   = ($o.心跳秒 -lt 90)
        $st = Get-Content $StateF -Raw -Encoding UTF8 | ConvertFrom-Json
        $o.模式 = if ($st.mode -eq 'Active') { '激活态' } else { '静默态' }
    }
    $o.手动 = Test-Path $Flag
    $cfg = Get-Content "$Root\config.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services') {
        foreach ($p in $cfg.ACE服务前缀) {
            if ($k.PSChildName -like "$p*") {
                $pr = Get-ItemProperty $k.PSPath
                $stt = switch ($pr.Start) { 0{'Boot'} 1{'System'} 2{'Auto'} 3{'Manual'} 4{'Disabled'} }
                $d = Get-CimInstance Win32_SystemDriver -Filter "Name='$($k.PSChildName)'"
                $o.ACE += [pscustomobject]@{ 名称=$k.PSChildName; 启动=$stt; 状态=$(if($d){$d.State}else{'-'}); 危险=($pr.Start -in 0,1,2) }
                break
            }
        }
    }
    $o.游戏 = @(Get-Process | Where-Object { $cfg.游戏本体进程名 -contains $_.Name } | Select-Object -Expand Name -Unique)
    $o.登录器 = @(Get-Process | Where-Object { $cfg.登录器进程名 -contains $_.Name } | Select-Object -Expand Name -Unique)
    $t = (Get-Date).Date
    $o.今日风险 = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=1001; StartTime=$t}).Count +
                  @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$t}).Count
    return $o
}

# ---------- 状态面板（独立进程，避免异常被吞） ----------
# 直接启动即可：Panel.ps1 自带互斥，已开时会自行把已有窗口激活到前台
function Show-Panel {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$Root\Panel.ps1"
}

# ---------- 托盘 ----------
$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = $IconIdle
$ni.Visible = $true
$ni.Text = 'ACE 管控守护'

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miPanel  = $menu.Items.Add('打开状态面板')
$miToggle = $menu.Items.Add('开启守护')
$menu.Items.Add('-') | Out-Null
$miLog    = $menu.Items.Add('打开日志文件夹')
$menu.Items.Add('-') | Out-Null
$miExit   = $menu.Items.Add('退出托盘（守护仍继续运行）')
$ni.ContextMenuStrip = $menu

$miPanel.Add_Click({ Show-Panel })
$ni.Add_MouseDoubleClick({ Show-Panel })
$miLog.Add_Click({ Start-Process explorer.exe "$Root\logs" })
$miToggle.Add_Click({
    if (Test-Path $Flag) {
        Remove-Item $Flag -Force
        $ni.ShowBalloonTip(4000,'守护已关闭','正在执行退场检查：停止 ACE 驱动并复查系统状态…',[System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        Set-Content $Flag (Get-Date -Format 'u') -Encoding UTF8
        $ni.ShowBalloonTip(4000,'守护已开启','已进入激活态，可以启动游戏了。',[System.Windows.Forms.ToolTipIcon]::Info)
    }
})
$miExit.Add_Click({ $ni.Visible = $false; [System.Windows.Forms.Application]::Exit() })
# ---------- 主定时器：更新图标 + 消费告警 ----------
$script:Shown = @{}   # 已弹过的告警标题 -> 时间，用于去重
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
    try {
        $s = Get-Status
        $danger = @($s.ACE | Where-Object 危险).Count -gt 0
        if (-not $s.存活) {
            $ni.Icon = $IconDead;   $ni.Text = "ACE 守护 · 未运行"
        } elseif ($danger) {
            $ni.Icon = $IconAlert;  $ni.Text = "ACE 守护 · ACE 为开机常驻，待优化"
        } elseif ($s.模式 -eq '激活态') {
            $g = if ($s.游戏) { $s.游戏[0] } elseif ($s.登录器) { "登录器 $($s.登录器[0])" } else { '手动' }
            $ni.Icon = $IconActive; $ni.Text = "ACE 守护 · 激活态（$g）"
        } else {
            $ni.Icon = $IconIdle;   $ni.Text = "ACE 守护 · 静默态 正常"
        }
        $miToggle.Text = if ($s.手动) { '关闭守护' } else { '开启守护' }

        foreach ($fl in (Get-ChildItem $AlertDir -Filter '*.json' | Sort-Object LastWriteTime)) {
            $a = Get-Content $fl.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($a) {
                # 托盘侧再去重一层：同一标题 5 分钟内不重复弹，防止刷屏
                $k = [string]$a.标题
                $last = $script:Shown[$k]
                if (-not $last -or ((Get-Date) - $last).TotalMinutes -ge 5) {
                    $script:Shown[$k] = Get-Date
                    $ic = switch ($a.类型) { 'Error' {'Error'} 'Info' {'Info'} default {'Warning'} }
                    $ni.ShowBalloonTip(15000, $a.标题, $a.内容, [System.Windows.Forms.ToolTipIcon]::$ic)
                }
            }
            Remove-Item $fl.FullName -Force
            break   # 每轮只弹一条，避免刷屏
        }
    } catch { }
})
$timer.Start()

$ni.ShowBalloonTip(3000,'ACE 管控守护已就绪','托盘图标已常驻，双击可打开状态面板。',[System.Windows.Forms.ToolTipIcon]::Info)
[System.Windows.Forms.Application]::Run()
# 正常退出时释放互斥并清理图标，避免锁变成 abandoned 状态导致下次起不来
$ni.Visible = $false
$ni.Dispose()
try { $mutex.ReleaseMutex() } catch { }
$mutex.Dispose()
