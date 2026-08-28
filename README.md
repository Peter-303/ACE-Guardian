# ACE-Guardian

针对腾讯 ACE 反作弊（AntiCheatExpert）的**管控**工具，不是杀毒式的清除工具。

设计目标：让 ACE 在玩游戏时完整正常工作（不引起误封），在不玩游戏时无法在后台常驻内核或扫盘。


## 核心设计：三类进程严格分开

这三者职责完全不同，混用会导致管控失效或误封：

| 类别 | 进程示例 | 职责 |
|---|---|---|
| **游戏本体** | `VALORANT`、`VALORANT-Win64-Shipping` | 唯一代表真实游戏会话，**退场判定只看它** |
| **登录器** | `ACLOS`、`RiotClientServices`、`wegame` | 触发激活态（用户准备玩），但**不参与退场判定**（它会自行退出，也可能长期常驻） |
| **ACE** | `SGuard64`、`SGuardSvc64` | **被管控对象**，绝不能作为"游戏在跑"的依据（它后台扫盘时也在跑） |

## 双态运行

**静默态**（默认，20 秒巡检）
- 检测到 ACE 进程在后台活动 → 结束它（游戏没跑，此时 ACE 不在检测会话中，停它不会被判定为对抗）
- 检测到 ACE 驱动为 `Boot/System/Auto` → 改为 `Manual`
- 每 3 轮查一次 WHEA / 蓝屏 / Defender 冲突

**激活态**（5 秒巡检，游戏本体或登录器启动、或手动开启时进入）
- **完全不干预 ACE**，只做观察记录和状态快照
- 游戏退出后执行退场检查：停 ACE 驱动与进程、确认启动方式为 Manual、复查系统健康

## 防误封的三道闸门

`Enforce-ManualStart`、`Stop-AceDrivers`、`Stop-AceProcs` 三个函数开头统一调用 `Test-干预禁止`：

只要**游戏本体或登录器**在运行，一律直接 return，一行注册表都不改、一个进程都不杀。

登录器也纳入闸门，是因为此时即将进入游戏，动 ACE 会导致游戏进不去。

唯一的持久性改动是把服务 `Start` 从 `Boot/System/Auto` 改为 `Manual`。这是 Windows 标准服务配置，ACE 新版驱动本身就装成 Manual，游戏启动时会主动加载，功能不受影响。且驱动正在 Running 时也不改，等退场后处理。

另有 90 秒退出宽限期：游戏本体进程消失后不立刻退场（登录器→游戏本体切换时进程名会断档），避免 Idle/Active 抖动刷屏。

## 文件说明

| 文件 | 作用 |
|---|---|
| `Guardian.ps1` | 守护主进程，SYSTEM 权限，开机自启 |
| `Tray.ps1` | 任务栏托盘图标 + 气泡告警，登录自启 |
| `Panel.ps1` | 状态面板 GUI（独立进程） |
| `config.json` | 进程名、阈值、开关的单一配置源，改后下一轮自动生效 |
| `开启守护.ps1` / `关闭守护.ps1` | 创建/删除 `ACTIVE.flag`，命令行备用入口 |
| `查看状态.ps1` | 命令行状态查询 |

托盘图标颜色：绿=静默正常、橙=激活态、红=ACE 为开机常驻、灰=守护未运行。

## 安装

需要管理员权限：

```powershell
# 1. 复制到 C:\ACE-Guardian

# 2. 注册守护主进程（SYSTEM + 开机启动）
$a = New-ScheduledTaskAction -Execute 'powershell.exe' `
     -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\ACE-Guardian\Guardian.ps1"'
$t = New-ScheduledTaskTrigger -AtStartup
$p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
     -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'ACE-Guardian' -Action $a -Trigger $t -Principal $p -Settings $s -Force

# 3. 注册托盘（当前用户 + 登录启动）
$a2 = New-ScheduledTaskAction -Execute 'powershell.exe' `
      -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\ACE-Guardian\Tray.ps1"'
$t2 = New-ScheduledTaskTrigger -AtLogOn
$p2 = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'ACE-Guardian-Tray' -Action $a2 -Trigger $t2 -Principal $p2 -Force
```

## 日常使用

托盘图标右键即可完成全部操作，或双击打开状态面板。

正常情况下不需要手动干预——检测到游戏或登录器会自动进入激活态，游戏退出后自动退场检查并回落静默态。

## 开销

实测数据（i9-14900HX / 32 逻辑核心）：

| 指标 | 守护主进程 | 托盘 | 合计 |
|---|---|---|---|
| CPU（总占用） | 0.224% | 0.109% | 0.33% |
| 内存 | 76 MB | 129 MB | 205 MB |
| 磁盘写入 | — | — | 0.47 MB/天 |

静默态每 20 秒中约 0.2 秒在工作，其余在 sleep。内存主要是 PowerShell 运行时的固定成本（.NET CLR + WinForms），脚本自身数据不到 1 MB。

## 开发注意事项

**PowerShell 5.1 编码**：含中文标识符的 `.ps1` 必须存为 **UTF-8 带 BOM**，否则 PS 5.1 按 GBK 解析导致语法错误。但 `config.json` 必须**无 BOM**，否则 `ConvertFrom-Json` 失败。

**Abandoned Mutex**：进程被强杀后互斥锁进入 abandoned 状态，`WaitOne(0)` 会抛 `AbandonedMutexException`。该异常意味着**锁已成功获取**，必须继续运行，不能当成"已有实例"退出。若脚本顶部设了 `$ErrorActionPreference='SilentlyContinue'`，异常会被静默吞掉、返回值变 `$null`，导致进程永久起不来。

**跨会话通信**：Guardian 以 SYSTEM 运行，无法直接弹窗。它把告警写成 `alerts\*.json`，由用户会话的 Tray 进程消费后弹气泡。

**面板窗口激活**：Panel 以 `-WindowStyle Hidden` 启动，`Get-Process` 拿不到 `MainWindowHandle`，`FindWindow` 也搜不到（不在顶层窗口链）。改用 Mutex 判定单实例 + 命名事件 `Global\ACE-Guardian-Panel-Show` 通知已有实例把窗口拉到前台。
