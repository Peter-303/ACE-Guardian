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
# 用 $script: 显式限定作用域：WinForms 事件 scriptblock 的变量查找不保证能命中
# 脚本顶层的普通变量，缺失时 Get-ChildItem 会拿到空路径而静默失败。
$script:Root     = 'C:\ACE-Guardian'
$script:AlertDir = "$script:Root\alerts"
$script:Flag     = "$script:Root\ACTIVE.flag"
$script:SleepF   = "$script:Root\SILENT.flag"   # 休眠标记：停止巡检与干预，省资源
$script:StateF   = "$script:Root\state.json"
$script:DiagLog  = "$script:Root\logs\tray-diag.log"
New-Item -ItemType Directory -Path $script:AlertDir -Force | Out-Null

# 托盘自身的问题必须能被看见：定时器里任何异常都写入独立诊断日志，
# 不再用空 catch 吞掉（这正是"告警反复重弹"长期查不出原因的根源）。
function Write-Diag {
    param([string]$Msg)
    try { Add-Content -Path $script:DiagLog -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Msg" -Encoding UTF8 } catch { }
}

# 标记文件的建立/删除必须容错：守护进程（SYSTEM）可能正持有句柄，
# 瞬时共享冲突不应让按钮静默失效。短暂重试，失败记日志并返回 $false。
function Set-FlagFile {
    param([string]$Path,[bool]$On)
    for ($i = 0; $i -lt 5; $i++) {
        try {
            if ($On) {
                if (-not (Test-Path $Path)) { Set-Content $Path (Get-Date -Format 'u') -Encoding UTF8 -ErrorAction Stop }
            } else {
                if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction Stop }
            }
            return $true
        } catch {
            Write-Diag "写标记失败(第$($i+1)次) $Path On=$On : $($_.Exception.Message)"
            Start-Sleep -Milliseconds 200
        }
    }
    return $false
}

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
    $o = [ordered]@{ 存活=$false; 模式='未知'; 心跳秒=999; 手动=$false; 休眠=$false; ACE=@(); 游戏=@(); 登录器=@(); 今日风险=0 }
    if (Test-Path $StateF) {
        $o.心跳秒 = [math]::Round(((Get-Date) - (Get-Item $StateF).LastWriteTime).TotalSeconds)
        $st = Get-Content $StateF -Raw -Encoding UTF8 | ConvertFrom-Json
        $o.模式 = switch ($st.mode) { 'Active' { '激活态' } 'Sleep' { '休眠' } default { '静默态' } }
        # 休眠时心跳每 5 分钟一次，存活阈值要放宽否则误报未运行
        $o.存活 = if ($st.mode -eq 'Sleep') { $o.心跳秒 -lt 400 } else { $o.心跳秒 -lt 90 }
    }
    $o.手动 = Test-Path $Flag
    $o.休眠 = Test-Path $SleepF
    # 休眠时托盘也跟着省电：跳过注册表遍历与事件日志查询，
    # 这些每 3 秒一次的开销在用户已明确不玩游戏时同样没有意义。
    if ($o.休眠) { return $o }
    $cfg = Get-Content "$Root\config.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    # 一次性拉全部驱动状态，循环内查表；原先每个命中服务单独 CIM -Filter 累计要 3~4 秒。
    $drvState = @{}
    Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue | ForEach-Object { $drvState[$_.Name] = $_.State }
    foreach ($k in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services') {
        foreach ($p in $cfg.ACE服务前缀) {
            if ($k.PSChildName -like "$p*") {
                $pr = Get-ItemProperty $k.PSPath
                $stt = switch ($pr.Start) { 0{'Boot'} 1{'System'} 2{'Auto'} 3{'Manual'} 4{'Disabled'} }
                $state = if ($drvState.ContainsKey($k.PSChildName)) { $drvState[$k.PSChildName] } else { '-' }
                $o.ACE += [pscustomobject]@{ 名称=$k.PSChildName; 启动=$stt; 状态=$state; 危险=($pr.Start -in 0,1,2) }
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
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$script:Root\Panel.ps1"
}

# ---------- 托盘 ----------
$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = $IconIdle
$ni.Visible = $true
$ni.Text = 'ACE 管控守护'

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miPanel  = $menu.Items.Add('打开状态面板')
$miSleep  = $menu.Items.Add('休眠管控（下载游戏时用）')
$miToggle = $menu.Items.Add('开启守护')
$menu.Items.Add('-') | Out-Null
$miLog    = $menu.Items.Add('打开日志文件夹')
$menu.Items.Add('-') | Out-Null
$miExit   = $menu.Items.Add('退出托盘（守护仍继续运行）')
$ni.ContextMenuStrip = $menu

$miPanel.Add_Click({ Show-Panel })
$ni.Add_MouseDoubleClick({ Show-Panel })
$miLog.Add_Click({ Start-Process explorer.exe "$script:Root\logs" })
$miSleep.Add_Click({
    $on = -not (Test-Path $script:SleepF)
    $ok = Set-FlagFile $script:SleepF $on
    if ($on -and $ok) { [void](Set-FlagFile $script:Flag $false) }   # 与手动激活互斥
    if (-not $ok) {
        $ni.ShowBalloonTip(5000,'操作失败','无法切换休眠状态（文件被占用或权限不足），详见 logs\tray-diag.log',[System.Windows.Forms.ToolTipIcon]::Warning)
    } elseif ($on) {
        $ni.ShowBalloonTip(5000,'管控已休眠','已停止巡检与干预，几乎不占资源。下载完成准备开游戏前记得恢复。',[System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        $ni.ShowBalloonTip(4000,'管控已恢复','恢复正常巡检，可以开游戏了。',[System.Windows.Forms.ToolTipIcon]::Info)
    }
})
$miToggle.Add_Click({
    $on = -not (Test-Path $script:Flag)
    $ok = Set-FlagFile $script:Flag $on
    if ($on -and $ok) { [void](Set-FlagFile $script:SleepF $false) } # 手动开启守护时解除休眠
    if (-not $ok) {
        $ni.ShowBalloonTip(5000,'操作失败','无法切换守护状态（文件被占用或权限不足），详见 logs\tray-diag.log',[System.Windows.Forms.ToolTipIcon]::Warning)
    } elseif ($on) {
        $ni.ShowBalloonTip(4000,'守护已开启','已进入激活态，可以启动游戏了。',[System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        $ni.ShowBalloonTip(4000,'守护已关闭','正在执行退场检查：停止 ACE 驱动并复查系统状态…',[System.Windows.Forms.ToolTipIcon]::Info)
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
        } elseif ($s.休眠) {
            # 休眠优先显示：让用户清楚知道此刻管控已暂停
            $ni.Icon = $IconDead;   $ni.Text = "ACE 守护 · 休眠中（管控已暂停）"
        } elseif ($danger) {
            $ni.Icon = $IconAlert;  $ni.Text = "ACE 守护 · ACE 为开机常驻，待优化"
        } elseif ($s.模式 -eq '激活态') {
            $g = if ($s.游戏) { $s.游戏[0] } elseif ($s.登录器) { "登录器 $($s.登录器[0])" } else { '手动' }
            $ni.Icon = $IconActive; $ni.Text = "ACE 守护 · 激活态（$g）"
        } else {
            $ni.Icon = $IconIdle;   $ni.Text = "ACE 守护 · 静默态 正常"
        }
        $miToggle.Text = if ($s.手动) { '关闭守护' } else { '开启守护' }
        $miSleep.Text  = if ($s.休眠) { '恢复管控' } else { '休眠管控（下载游戏时用）' }
        # 休眠期间"开启守护"没有意义，禁用避免语义打架
        $miToggle.Enabled = -not $s.休眠

        # 告警消费：每轮最多弹一条，但过期的一律清空，不留在队列里等下一轮重弹。
        $files = @(Get-ChildItem $script:AlertDir -Filter '*.json' -ErrorAction Stop | Sort-Object LastWriteTime)
        $popped = $false
        foreach ($fl in $files) {
            # 时效判定：告警描述的是"此刻正在发生的事"，过期后内容已失真，直接丢弃不弹。
            $age = ((Get-Date) - $fl.LastWriteTime).TotalSeconds
            if ($age -gt 120) {
                Remove-Item $fl.FullName -Force -ErrorAction Stop
                Write-Diag "丢弃过期告警 $($fl.Name)（已产生 $([int]$age) 秒）"
                continue
            }
            if ($popped) { continue }   # 本轮已弹过，其余留到下轮（未过期，不会丢）

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
            # 删除必须成功，否则同一条会被无限重弹。失败就记下来，让问题暴露出来。
            Remove-Item $fl.FullName -Force -ErrorAction Stop
            $popped = $true
        }
    } catch {
        Write-Diag "定时器异常: $($_.Exception.GetType().FullName) -> $($_.Exception.Message)"
    }
})
$timer.Start()

$ni.ShowBalloonTip(3000,'ACE 管控守护已就绪','托盘图标已常驻，双击可打开状态面板。',[System.Windows.Forms.ToolTipIcon]::Info)
[System.Windows.Forms.Application]::Run()
# 正常退出时释放互斥并清理图标，避免锁变成 abandoned 状态导致下次起不来
$ni.Visible = $false
$ni.Dispose()
try { $mutex.ReleaseMutex() } catch { }
$mutex.Dispose()
