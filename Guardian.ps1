#requires -Version 5.1
<#
  ACE-Guardian 主守护脚本 v2
  双态设计：
    静默态(Idle)   - 开机自动进入。低频巡检，仅确认系统健康，不做密集采集
    激活态(Active) - 手动开启或检测到游戏进程时进入。密集采集 + 全面管控
  关游戏时执行"退场检查"：主动停掉 ACE 驱动、确认无异常后回落静默态
#>

$ErrorActionPreference = 'SilentlyContinue'
$Root = 'C:\ACE-Guardian'
$Cfg  = Get-Content "$Root\config.json" -Raw -Encoding UTF8 | ConvertFrom-Json

$SnapDir   = "$Root\snapshots"
$StateFile = "$Root\state.json"
$FlagFile  = "$Root\ACTIVE.flag"      # 手动激活标记，由 开启守护.ps1 创建
$SilentFile = "$Root\SILENT.flag"     # 强制静默标记，优先级高于一切自动判定
$AlertDir  = "$Root\alerts"

function Get-LogPath { "$Root\logs\guardian-{0}.log" -f (Get-Date -Format 'yyyyMMdd') }
function Get-EventPath { "$Root\logs\events-{0}.log" -f (Get-Date -Format 'yyyyMMdd') }

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
    Add-Content -Path (Get-LogPath) -Value $line -Encoding UTF8
    if ($Level -in 'WARN','ALERT','ACTION','PASS') { Add-Content -Path (Get-EventPath) -Value $line -Encoding UTF8 }
}

$script:AlertSeen = @{}
function Send-Alert {
    param([string]$Title, [string]$Body, [string]$Kind = 'Warning', [int]$抑制分钟 = 0)
    # 同一条告警在抑制窗口内不重复弹窗，避免刷屏
    if ($抑制分钟 -gt 0) {
        $k = "$Title|$Body"
        if ($script:AlertSeen.ContainsKey($k) -and ((Get-Date) - $script:AlertSeen[$k]).TotalMinutes -lt $抑制分钟) {
            Write-Log "$Title | $Body （重复，已抑制弹窗）" 'INFO'
            return
        }
        $script:AlertSeen[$k] = Get-Date
    }
    Write-Log "$Title | $Body" 'ALERT'
    if (-not $Cfg.弹窗) { return }
    New-Item -ItemType Directory -Path $AlertDir -Force | Out-Null
    $payload = @{ 时间=(Get-Date -Format 'HH:mm:ss'); 标题=$Title; 内容=$Body; 类型=$Kind } | ConvertTo-Json -Compress
    $f = "$AlertDir\{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    [System.IO.File]::WriteAllText($f, $payload, [System.Text.UTF8Encoding]::new($false))
}

# === 三类进程严格分开，职责不同不可混用 ===
# 1) 游戏本体：唯一能代表"真实游戏会话"的依据。所有安全闸门只看它。
function Get-GameProcs {
    $names = $Cfg.游戏本体进程名
    return @(Get-Process | Where-Object { $names -contains $_.Name })
}

# 2) 登录器：说明用户准备玩游戏。可触发激活态，但不作为退场判定依据，
#    因为它常在游戏启动后自行退出，也可能长期常驻（如 wegame）。
function Get-LauncherProcs {
    $names = $Cfg.登录器进程名
    return @(Get-Process | Where-Object { $names -contains $_.Name })
}

function Get-AceServices {
    $out = @()
    foreach ($k in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services') {
        $n = $k.PSChildName
        $hit = $false
        foreach ($pre in $Cfg.ACE服务前缀) { if ($n -like "$pre*") { $hit = $true; break } }
        if (-not $hit) { continue }
        $p = Get-ItemProperty $k.PSPath
        $drv = Get-CimInstance Win32_SystemDriver -Filter "Name='$n'"
        $out += [pscustomobject]@{
            Name      = $n
            Start     = $p.Start
            StartText = switch ($p.Start) { 0{'Boot'} 1{'System'} 2{'Auto'} 3{'Manual'} 4{'Disabled'} default{"($($p.Start))"} }
            State     = if ($drv) { $drv.State } else { '-' }
        }
    }
    return $out
}

function Get-AceProcs {
    $names = $Cfg.ACE进程名
    return @(Get-Process | Where-Object { $names -contains $_.Name })
}

# ---------- 管控动作 ----------
# 休眠标记：用户明确知道此刻不玩游戏（例如登录器只在下载），
# 管控没有意义，纯属损耗。置位后守护停掉所有巡检与干预，只维持心跳。
# 优先级最高，盖掉登录器/游戏本体自动判定与手动激活标记。
function Test-休眠 { Test-Path $SilentFile }

# 安全闸门统一判定：游戏本体或登录器在跑时，一律不干预 ACE。
# 登录器在跑意味着即将进入游戏，此时动 ACE 会导致游戏进不去或被判定异常。
function Test-干预禁止 {
    if ((Get-GameProcs).Count -gt 0)     { return '游戏本体正在运行' }
    if ((Get-LauncherProcs).Count -gt 0) { return '登录器正在运行' }
    return $null
}

# 设计原则：ACE 必须能正常工作，否则游戏进不去，且异常干预可能被 ACE 判定为作弊。
# 因此只做一件事——不让它开机常驻内核（Boot/System/Auto 降为 Manual）。
# 游戏运行期间完全不干预，让 ACE 自由加载运行。
function Enforce-ManualStart {
    if (-not $Cfg.管控开关.强制ACE驱动为Manual) { return 0 }
    # 安全闸门：游戏本体或登录器在跑就绝不改注册表，避免 ACE 检测到配置被篡改
    if (Test-干预禁止) { return 0 }
    $n = 0
    foreach ($s in Get-AceServices) {
        # 只降级"开机常驻"类型；Manual/Disabled 不动
        if ($s.Start -in 0,1,2) {
            # 驱动正在运行说明 ACE 在工作中，不动它，等退场时再处理
            if ($s.State -eq 'Running') {
                Write-Log "$($s.Name) 为 $($s.StartText) 但正在运行，暂不改动（等退场检查）" 'INFO'
                continue
            }
            $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)"
            Set-ItemProperty -Path $key -Name Start -Value 3 -Type DWord
            if ((Get-ItemProperty $key).Start -eq 3) {
                Write-Log "$($s.Name) 启动类型 $($s.StartText) -> Manual" 'ACTION'
                Send-Alert 'ACE 启动方式已优化' "$($s.Name) 原为 $($s.StartText)（开机常驻内核），已改为 Manual（按需加载）。游戏仍可正常启动，ACE 功能不受影响。" 'Warning' 60
                $n++
            } else {
                Write-Log "无法修改 $($s.Name) 启动类型（权限不足）" 'WARN'
            }
        }
    }
    return $n
}

function Stop-AceDrivers {
    # 安全闸门：游戏本体或登录器在跑时绝不停 ACE 驱动，否则 ACE 会认为被攻击并可能上报
    $阻 = Test-干预禁止
    if ($阻) {
        Write-Log "$阻，跳过停止 ACE 驱动（防止误封）" 'WARN'
        return @()
    }
    $stopped = @()
    foreach ($s in Get-AceServices) {
        if ($s.State -eq 'Running') {
            & sc.exe stop $s.Name *>$null
            Start-Sleep -Milliseconds 600
            $d = Get-CimInstance Win32_SystemDriver -Filter "Name='$($s.Name)'"
            if ($d.State -ne 'Running') { $stopped += $s.Name }
            else { Write-Log "$($s.Name) 停止失败（内核驱动通常需重启才能卸载，属正常）" 'INFO' }
        }
    }
    return $stopped
}

function Stop-AceProcs {
    # 安全闸门：游戏本体或登录器在跑时绝不杀 ACE 进程
    $阻 = Test-干预禁止
    if ($阻) {
        Write-Log "$阻，跳过结束 ACE 进程（防止误封）" 'WARN'
        return @()
    }
    $killed = @()
    foreach ($p in Get-AceProcs) {
        Stop-Process -Id $p.Id -Force
        Start-Sleep -Milliseconds 200
        if (-not (Get-Process -Id $p.Id -EA SilentlyContinue)) { $killed += $p.Name }
    }
    return $killed
}

# ---------- 风险检测 ----------
function Test-DiskThrash {
    if (-not $Cfg.管控开关.磁盘抖动超阈值时告警) { return $false }
    $win = (Get-Date).AddSeconds(-1 * $Cfg.阈值.磁盘抖动_窗口秒)
    $c = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='disk'; StartTime=$win}).Count
    if ($c -ge $Cfg.阈值.磁盘抖动_次数) {
        Send-Alert '危险：磁盘写缓存反复开关' "$($Cfg.阈值.磁盘抖动_窗口秒) 秒内 $c 次 disk 缓存抖动。这是 8/3 硬卡死的直接前兆，建议立即退出游戏和磁盘检测工具。" 'Error' 10
        return $true
    }
    return $false
}

function Test-DefenderCrash {
    if (-not $Cfg.管控开关.Defender崩溃时告警) { return $false }
    $win = (Get-Date).AddSeconds(-1 * $Cfg.阈值.Defender崩溃_窗口秒)
    $a = @(Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error'; StartTime=$win} | Where-Object { $_.Message -match 'MsMpEng|mpengine' }).Count
    $b = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=7031,7034; StartTime=$win} | Where-Object { $_.Message -match 'Defender' }).Count
    if (($a+$b) -ge $Cfg.阈值.Defender崩溃_次数) {
        Send-Alert 'Defender 与 ACE 冲突' "$([int]($Cfg.阈值.Defender崩溃_窗口秒/60)) 分钟内 Defender 异常 $($a+$b) 次。ACE 与 Defender 正互相干扰内核内存，是 0x139 的诱因。" 'Error' 15
        return $true
    }
    return $false
}

function Test-NewWhea {
    param([datetime]$Since)
    if (-not $Cfg.管控开关.WHEA错误时告警) { return $null }
    $e = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$Since.AddSeconds(1)})
    if ($e.Count -gt 0) {
        $d = ($e | ForEach-Object { "ID=$($_.Id) $($_.TimeCreated.ToString('HH:mm:ss'))" }) -join '; '
        Send-Alert 'WHEA 硬件错误' "新增 $($e.Count) 条：$d。若为 Internal parity error 属 CPU 核心校验错误。" 'Error'
        return $e[0].TimeCreated
    }
    return $null
}

function Test-NewBsod {
    param([datetime]$Since)
    $e = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=1001; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'; StartTime=$Since.AddSeconds(1)})
    if ($e.Count -gt 0) {
        foreach ($x in $e) {
            $code = if ($x.Message -match '0x([0-9a-fA-F]{8})') { "0x$($matches[1])" } else { '未知' }
            Send-Alert '检测到蓝屏记录' "停止代码 $code，时间 $($x.TimeCreated.ToString('MM-dd HH:mm:ss'))。dump 已保存可供分析。" 'Error'
        }
        return $e[0].TimeCreated
    }
    return $null
}

function Save-Snapshot {
    param([string]$Mode)
    $os = Get-CimInstance Win32_OperatingSystem
    $commitPct = if ($os.TotalVirtualMemorySize -gt 0) {
        [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory)/$os.TotalVirtualMemorySize*100,1)
    } else { 0 }
    $top = (Get-Process | Sort-Object WS -Descending | Select-Object -First 8 |
            ForEach-Object { "{0}:{1}MB" -f $_.Name,[math]::Round($_.WS/1MB) }) -join ' '
    $ace = (Get-AceServices | ForEach-Object { "{0}[{1}/{2}]" -f $_.Name,$_.StartText,$_.State }) -join ' '

    [pscustomobject]@{
        时间=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); 模式=$Mode
        内存已用GB=[math]::Round(($os.TotalVisibleMemorySize-$os.FreePhysicalMemory)/1MB,2)
        内存总GB=[math]::Round($os.TotalVisibleMemorySize/1MB,2)
        提交率百分比=$commitPct
        C盘可用GB=[math]::Round((Get-PSDrive C).Free/1GB,1)
        ACE状态=$(if($ace){$ace}else{'无ACE'}); 内存前八进程=$top
    } | ConvertTo-Json -Compress |
      Set-Content ("$SnapDir\snap-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) -Encoding UTF8

    if ($commitPct -ge $Cfg.阈值.内存提交率告警_百分比) {
        Send-Alert '内存提交率过高' "当前 $commitPct%。页面文件仅 2GB，继续升高可能整机硬卡死（无蓝屏无 dump）。建议关闭部分程序。" 'Error' 10
    }
    return $commitPct
}

# ---------- 退场检查：关游戏时主动执行 ----------
function Invoke-ExitCheck {
    Write-Log '===== 开始退场检查 =====' 'WARN'
    Send-Alert '游戏已退出，开始退场检查' '正在停止 ACE 内核驱动并检查系统状态...' 'Info' 10
    $issues = @()

    # 1. 停 ACE 驱动
    $stopped = Stop-AceDrivers
    if ($stopped.Count) { Write-Log "已停止 ACE 驱动: $($stopped -join ', ')" 'ACTION' }

    # 2. 结束 ACE 用户态进程
    $killed = Stop-AceProcs
    if ($killed.Count) { Write-Log "已结束 ACE 进程: $($killed -join ', ')" 'ACTION' }

    # 3. 确保启动类型是 Manual
    Enforce-ManualStart | Out-Null

    # 4. 复查（驱动已加载进内核时无法卸载，属正常现象，不算问题）
    Start-Sleep -Seconds 2
    $still = @(Get-AceServices | Where-Object { $_.State -eq 'Running' })
    if ($still.Count) {
        Write-Log "仍在内核中的 ACE 驱动: $(($still|Select -Expand Name) -join ',')（已设为 Manual，重启后不再加载）" 'INFO'
    }
    $sp = Get-AceProcs
    if ($sp.Count) { $issues += "仍有 ACE 用户态进程: $(($sp|Select -Expand Name) -join ',')" }

    # 5. 健康检查
    if (Test-DiskThrash)    { $issues += '磁盘缓存抖动超阈值' }
    if (Test-DefenderCrash) { $issues += 'Defender 异常' }
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $w = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$boot}).Count
    if ($w -gt 0) { $issues += "本次开机有 $w 条 WHEA 硬件错误" }

    if ($issues.Count -eq 0) {
        Write-Log '退场检查通过：ACE 已全部停止，无异常，回落静默态' 'PASS'
        Send-Alert '退场检查通过' "ACE 驱动已全部停止$(if($stopped.Count){"（$($stopped.Count) 个）"})，系统无异常。已进入静默态。" 'Info' 10
        return $true
    } else {
        Write-Log "退场检查发现问题: $($issues -join '; ')" 'WARN'
        Send-Alert '退场检查发现问题' ($issues -join '；') 'Error'
        return $false
    }
}

# ---------- 静默态巡检：不打游戏时，压制 ACE 的一切活动 ----------
function Invoke-IdleCheck {
    param([ref]$St, [switch]$重检日志)
    if ($重检日志) {
        $t = Test-NewWhea -Since ([datetime]$St.Value.lastWhea)
        if ($t) { $St.Value.lastWhea = $t.ToString('o') }
        $b = Test-NewBsod -Since ([datetime]$St.Value.lastBsod)
        if ($b) { $St.Value.lastBsod = $b.ToString('o') }
    }

    # 防 ACE 偷偷把自己改回开机常驻
    Enforce-ManualStart | Out-Null

    # 核心：游戏没开却有 ACE 在跑，说明它在后台扫盘/驻留，直接停掉
    # 此时游戏未运行，ACE 不在检测会话中，停它不会触发误封
    if ($Cfg.管控开关.游戏退出后清理ACE残留) {
        $procs = Get-AceProcs
        if ($procs.Count) {
            $k = Stop-AceProcs
            if ($k.Count) {
                Write-Log "静默态清理 ACE 后台进程: $($k -join ', ')" 'ACTION'
                Send-Alert 'ACE 后台活动已拦截' "游戏未运行，但 ACE 进程 $($k -join '、') 在后台活动（通常是全盘扫描）。已结束，不影响下次开游戏。" 'Warning' 30
            }
        }
        $run = @(Get-AceServices | Where-Object { $_.State -eq 'Running' })
        if ($run.Count) {
            $s = Stop-AceDrivers
            if ($s.Count) {
                Write-Log "静默态停止 ACE 驱动: $($s -join ', ')" 'ACTION'
                Send-Alert 'ACE 驱动已停止' "游戏未运行，已停止 $($s.Count) 个 ACE 内核驱动，避免后台扫盘。开游戏时会自动重新加载。" 'Warning' 30
            }
        }
    }
}

function Clear-OldFiles {
    $cut = (Get-Date).AddMinutes(-1 * $Cfg.快照保留分钟)
    Get-ChildItem $SnapDir -Filter 'snap-*.json' | Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force
    Get-ChildItem "$Root\logs" -Filter '*.log' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1*$Cfg.日志保留天数) } | Remove-Item -Force
    Get-ChildItem $AlertDir -Filter '*.json' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-2) } | Remove-Item -Force
}

# ================= 主流程 =================
Write-Log "===== ACE-Guardian v2 启动 (PID $PID) =====" 'INFO'

# 开机自检
$bootIssues = @()
$n = Enforce-ManualStart
if ($n -gt 0) { $bootIssues += "修正了 $n 个 ACE 驱动的启动类型" }
$runAce = @(Get-AceServices | Where-Object { $_.State -eq 'Running' })
if ($runAce.Count -and (Get-GameProcs).Count -eq 0) {
    $bootIssues += "开机时发现 $($runAce.Count) 个 ACE 驱动在运行但游戏未启动"
    Stop-AceDrivers | Out-Null
}
$lastBsod = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=41} -MaxEvents 1)
if ($lastBsod.Count -and $lastBsod[0].TimeCreated -gt (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.AddMinutes(-2)) {
    $bootIssues += '上次为非正常关机'
}

if ($bootIssues.Count) {
    Write-Log "开机自检: $($bootIssues -join '; ')" 'WARN'
    Send-Alert '开机自检发现问题' ($bootIssues -join '；') 'Warning'
} else {
    Write-Log '开机自检通过，进入静默态' 'PASS'
}

$state = @{ lastWhea=(Get-Date).ToString('o'); lastBsod=(Get-Date).ToString('o'); mode='Idle'; silent=$false }
$mode = 'Idle'
$prevGame = $false
$idleTick = 0
$gameGoneAt = $null   # 游戏进程消失的时刻，用于宽限期判定
$宽限秒 = if ($Cfg.游戏退出宽限秒) { $Cfg.游戏退出宽限秒 } else { 90 }

while ($true) {
    try {
        # ---- 休眠短路：用户明确表示此刻不玩游戏，管控纯属损耗 ----
        # 放在最前面，跳过进程枚举、注册表遍历、事件日志查询等全部开销，
        # 只维持心跳供面板判断存活。每 5 分钟醒一次，仅检查标记是否被撤销。
        if (Test-休眠) {
            if ($mode -ne 'Sleep') {
                # 进入休眠前若还在激活态，先做一次退场检查收尾，避免 ACE 残留在后台
                if ($mode -eq 'Active') { Invoke-ExitCheck | Out-Null }
                Write-Log '进入休眠（用户手动开启，停止巡检与干预）' 'WARN'
                Send-Alert '管控已休眠' '已停止巡检与干预，几乎不占资源。下载完成准备开游戏前请手动恢复。' 'Info' 60
                $mode = 'Sleep'
                $prevGame = $false
                $gameGoneAt = $null
            }
            $state.mode = 'Sleep'
            $state.silent = $true
            $state | ConvertTo-Json -Compress | Set-Content $StateFile -Encoding UTF8
            # 分段睡眠：总时长按配置（默认 5 分钟），但每 10 秒检查一次标记是否被撤销，
            # 这样用户取消休眠后能很快恢复，而不必等满一个周期。
            # Test-Path 开销极小，与整轮巡检相比可忽略。
            $总 = if ($Cfg.采集间隔秒_休眠) { $Cfg.采集间隔秒_休眠 } else { 300 }
            for ($w = 0; $w -lt $总; $w += 10) {
                Start-Sleep -Seconds 10
                if (-not (Test-休眠)) { break }
            }
            continue
        }
        if ($mode -eq 'Sleep') {
            Write-Log '退出休眠，恢复正常巡检' 'WARN'
            Send-Alert '管控已恢复' '已恢复正常巡检，可以开游戏了。' 'Info' 10
            $mode = 'Idle'
        }

        $game     = Get-GameProcs        # 游戏本体
        $launcher = Get-LauncherProcs    # 登录器
        $rawGame  = ($game.Count -gt 0)
        $inLauncher = ($launcher.Count -gt 0)
        $manual   = Test-Path $FlagFile

        # 游戏本体退出宽限期：进程消失后不立刻判定退出。
        # 原因1 登录器->游戏本体切换时游戏本体进程名会短暂断档；
        # 原因2 若立刻退场会造成 Idle/Active 反复抖动并重复弹窗。
        # 注意：宽限期只看游戏本体，不能用 ACE 是否在跑来判断——
        # ACE 自己后台扫盘时也在跑，那恰恰是需要拦截的情形。
        if ($rawGame) {
            $gameGoneAt = $null
            $inGame = $true
        } elseif ($prevGame) {
            if (-not $gameGoneAt) { $gameGoneAt = Get-Date }
            $等待 = ((Get-Date) - $gameGoneAt).TotalSeconds
            # 登录器还在时给足宽限（可能正在切换到游戏本体），否则用一半时间即可
            $限 = if ($inLauncher) { $宽限秒 } else { [math]::Max(30, $宽限秒 / 3) }
            if ($等待 -lt $限) {
                $inGame = $true   # 宽限期内仍视为在游戏中，不触发退场
            } else {
                $inGame = $false
                $gameGoneAt = $null
            }
        } else {
            $inGame = $false
            $gameGoneAt = $null
        }

        # 登录器在跑也进入激活态（用户准备玩），但它不参与退场判定
        $wantActive = $inGame -or $inLauncher -or $manual

        # ---- 态切换 ----
        if ($wantActive -and $mode -eq 'Idle') {
            $mode = 'Active'
            $why = if ($manual -and -not $inGame -and -not $inLauncher) { '手动开启' }
                   elseif ($rawGame) { '检测到游戏本体' }
                   elseif ($inLauncher) { '检测到登录器启动' }
                   else { '手动开启' }
            Write-Log "静默态 -> 激活态（$why）" 'WARN'
            # 抑制 30 分钟：避免登录器->游戏本体切换过程中重复弹窗
            Send-Alert '守护已激活' "$why。已提升到 $($Cfg.采集间隔秒_游戏中) 秒密集监控。游戏运行期间不会干预 ACE，只做观察记录。" 'Info' 30
            # 游戏本体尚未启动时（手动开启或仅登录器）做一次启动方式检查
            if (-not $rawGame) { Enforce-ManualStart | Out-Null }
        }
        elseif (-not $wantActive -and $mode -eq 'Active') {
            # 游戏刚退出 -> 退场检查
            if ($prevGame) { Start-Sleep -Seconds 3; Invoke-ExitCheck | Out-Null }
            else {
                Write-Log '激活态 -> 静默态（手动关闭）' 'WARN'
                Invoke-ExitCheck | Out-Null
            }
            $mode = 'Idle'
        }
        elseif ($mode -eq 'Active' -and $prevGame -and -not $inGame) {
            # 游戏退出了但手动 flag 还在：仍要立刻做退场检查，别让 ACE 在后台扫盘
            Write-Log '检测到游戏退出（手动开关仍开启）' 'WARN'
            Start-Sleep -Seconds 3
            Invoke-ExitCheck | Out-Null
        }

        # ---- 按态执行 ----
        if ($mode -eq 'Active') {
            # 游戏运行中：只观察不干预，让 ACE 正常工作，避免被判定作弊
            if (-not $inGame) { Enforce-ManualStart | Out-Null }
            Save-Snapshot -Mode $(if($inGame){'游戏中'}else{'手动激活'}) | Out-Null
            Test-DiskThrash    | Out-Null
            Test-DefenderCrash | Out-Null
            $t = Test-NewWhea -Since ([datetime]$state.lastWhea); if ($t) { $state.lastWhea = $t.ToString('o') }
            $b = Test-NewBsod -Since ([datetime]$state.lastBsod); if ($b) { $state.lastBsod = $b.ToString('o') }
        } else {
            # 静默态：ACE 活动每轮都查（20 秒内响应），日志类检测每 3 轮一次省开销
            Invoke-IdleCheck -St ([ref]$state) -重检日志:($idleTick % 3 -eq 0)
            $idleTick++
        }

        $state.mode = $mode
        $state.silent = $false
        $state | ConvertTo-Json -Compress | Set-Content $StateFile -Encoding UTF8
        Clear-OldFiles
        $prevGame = $inGame
        Start-Sleep -Seconds $(if ($mode -eq 'Active') { $Cfg.采集间隔秒_游戏中 } else { $Cfg.采集间隔秒_待机 })
    }
    catch {
        Write-Log "主循环异常: $($_.Exception.Message)" 'WARN'
        Start-Sleep -Seconds 30
    }
}
