# Windows 外接屏开机闪屏排查实录：换了显示器还闪 → 向日葵的虚拟显示器驱动

> 一次真实的 Windows 桌面故障排查（2026-10-10）。
> 现象是外接显示器**每次开机都黑白一闪一闪，几分钟后才正常**，换了一台显示器照样闪。最后定位到**向日葵远程控制装的 IDD 虚拟显示器（`OrayIddDriver Device`）**，禁用后不再闪。
>
> 本篇覆盖：现象 → 先排除显示器 → 用 PowerShell 摸清显卡 / 显示器 / 接口 → 揪出多余的虚拟显示设备 → 用设备安装时间对上时间线 → 修复 → 原理（IDD + 显示拓扑重配）→ 复盘。所有命令都能直接复制。

---

## 一、现象

- 外接显示器开机后**黑白交替闪烁**，持续几分钟，之后自己恢复正常
- 换了一台显示器，**还是闪**
- 系统能正常进桌面，闪的时候也能操作

**第一个结论**：换了显示器还闪，说明问题不在显示器本身，在**主机这一侧**（显卡、驱动、线、口，或者系统里的某个软件）。

---

## 二、排查过程

### 2.1 第一刀：显卡、驱动、显示器、接口类型

```powershell
# 显卡 + 驱动版本 + 当前分辨率/刷新率
Get-CimInstance Win32_VideoController |
  Select-Object Name,DriverVersion,DriverDate,CurrentHorizontalResolution,CurrentVerticalResolution,CurrentRefreshRate,Status |
  Format-List

# 显示器型号 | 厂商代码（EDID 里读出来的）
Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID | ForEach-Object {
  [Text.Encoding]::ASCII.GetString($_.UserFriendlyName -ne 0) + ' | ' +
  [Text.Encoding]::ASCII.GetString($_.ManufacturerName -ne 0)
}

# 每台显示器走的是什么接口
Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams |
  Select-Object InstanceName,VideoOutputTechnology | Format-Table -AutoSize
```

结果：

| 项 | 值 |
| --- | --- |
| 显卡 1 | `Intel(R) UHD Graphics 730`（只有核显，没有独显），2560×1440@60 |
| 显卡 2 | ⚠️ **`OrayIddDriver Device`**，分辨率为空 |
| 显示器 | `PS27QA2`（`VideoOutputTechnology=10`，DP）、`AOC 2380`（`=5`，HDMI） |

`VideoOutputTechnology` 常用取值速查（来自 `D3DKMDT_VIDEO_OUTPUT_TECHNOLOGY`）：

| 值 | 接口 | 值 | 接口 |
| --- | --- | --- | --- |
| 0 | VGA (HD15) | 10 | DisplayPort（外接） |
| 4 | DVI | 11 | DisplayPort（内嵌，笔记本屏） |
| 5 | HDMI | 15 | Miracast（无线投屏） |
| 6 | LVDS（笔记本屏） | 16 | Indirect wired（间接显示，USB/软件屏） |

> 💡 **"显卡"列表里多出来一个不认识的设备，就是最大的嫌疑**。正常台式机只该有真实显卡（核显 / 独显）。`Oray` 就是向日葵的开发商。

### 2.2 第二刀：排除驱动崩溃和快速启动

```powershell
# 近 7 天显卡驱动相关的系统日志；4101 = "显示驱动程序停止响应并已恢复"（TDR）
Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue |
  Where-Object { $_.ProviderName -match 'Display|nvlddmkm|amdkmdag|igfx|dxgkrnl' -or $_.Id -eq 4101 } |
  Select-Object -First 40 TimeCreated,ProviderName,Id,LevelDisplayName,Message |
  Format-Table -AutoSize -Wrap

# 本次开机时间
(Get-CimInstance Win32_OperatingSystem).LastBootUpTime

# 快速启动是否开启（1 = 开）
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled
```

结果：**没有任何 TDR / 显卡驱动报错**，说明驱动没有崩溃；快速启动是开着的（`HiberbootEnabled=1`），先记下来，作为备选原因。

### 2.3 第三刀：揪出向日葵

```powershell
# 向日葵相关服务（新版叫 AweSun，老版叫 Sunlogin）
Get-Service | Where-Object { $_.Name -match 'Oray|Sunlogin|AweSun' } |
  Format-Table Name,DisplayName,Status,StartType -AutoSize

# 所有显示适配器 + 显示器设备（含已断开的历史设备，Status=Unknown）
Get-PnpDevice -Class Display,Monitor | Format-Table Status,Class,FriendlyName,InstanceId -AutoSize

# 进程是什么时候起来的
Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'AweSun|Sunlogin' } |
  Select-Object Name,CreationDate | Format-Table -AutoSize

# 安装版本和目录
Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*,
                 HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName -match 'AweSun|向日葵|Sunlogin|Oray' } |
  Select-Object DisplayName,DisplayVersion,InstallLocation
```

结果：

- `AweSunService` 是**开机自启**（Automatic），本次开机 9:18:53 – 9:19:09 先后拉起了 3 个 `AweSun.exe` 加一个 `awesun_guard.exe`
- 虚拟显示设备的 InstanceId 是 `ROOT\DISPLAY\0000`。`ROOT\` 开头说明它是**软件枚举出来的设备**，不挂在 PCI 总线上
- 向日葵版本是 16.6，安装目录下有 `driver\Idd64`，就是这个虚拟屏驱动
- `Get-PnpDevice` 里还能看到旧显示器（Status=Unknown）和新显示器挂在**同一个 UID**上，说明换的就是那台 DP 屏，也说明 DP 线和 DP 口其实没换过

### 2.4 第四刀：用设备安装时间对上时间线（关键证据）

```powershell
foreach ($id in 'ROOT\DISPLAY\0000', 'DISPLAY\PDA0270\4&3806CF40&0&UID4162') {
  $id
  Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_FirstInstallDate,DEVPKEY_Device_LastArrivalDate |
    Format-Table KeyName,Data -AutoSize
}
```

| 设备 | 首次安装 | 本次开机挂载 |
| --- | --- | --- |
| 虚拟屏 `ROOT\DISPLAY\0000` | **2026-09-11 15:13:44**（和向日葵安装日志同一分钟） | 9:18:53 |
| 真显示器 PS27QA2 | 2026-10-10 | 9:18:52 |

两条证据对上了：

1. 虚拟屏是跟着向日葵一起装的，闪屏是装上**几天后**开始的，时间对得上
2. 开机时它比真显示器**晚 1 秒挂载**，正好赶在显示器刚亮的时候改了一次屏幕组合

**没查清的一点**：为什么不是装完马上闪，而是过了几天才开始。翻了驱动安装日志，虚拟屏驱动只在 9 月 11 日装过一次，之后没有重装或更新的记录，所以不是驱动后来被换掉了。可能是向日葵在某次启动或自动更新后才开始挂虚拟屏，这次没有继续追。

```powershell
# 驱动安装日志：看某个驱动被装 / 更新过几次、每次是谁调起的
Select-String -Path C:\Windows\INF\setupapi.dev.log -Pattern 'Device Install.*OrayIdd' -Context 0,2
```

> 💡 `DEVPKEY_Device_FirstInstallDate` / `LastArrivalDate` 很好用，**能回答"这个设备是什么时候混进来的"**，对排查"某天之后开始出问题"这类故障是关键证据。

---

## 三、修复

关掉向日葵的虚拟显示器后重启，**不再闪**，确认就是这个原因。这次实际做了两件事：禁用虚拟设备（之后 `Get-PnpDevice` 里它的 Status 显示为 `Error`，设备被禁用后就是这个状态），再把 `AweSunService` 改成手动启动。

三种做法，任选其一，都能撤回：

| 做法 | 操作 | 影响 |
| --- | --- | --- |
| 向日葵设置里关 | 设置 → 被控 / 远程 / 高级设置 → 关闭"虚拟屏幕 / 无显示器模式"（16.6 新界面的菜单名以实际为准） | 最温和 |
| **禁用虚拟设备（推荐）** | `Win+X` → 设备管理器 → 显示适配器 → `OrayIddDriver Device` → 右键「禁用设备」 | 不接显示器时没法远控这台电脑 |
| 服务改手动 | `services.msc` → `AweSunService` → 启动类型「手动」→ 停止 | 开机不自动运行向日葵，要远程时手动打开 |

命令行等价写法（**管理员** PowerShell）：

```powershell
Disable-PnpDevice -InstanceId 'ROOT\DISPLAY\0000' -Confirm:$false   # 恢复：Enable-PnpDevice
Set-Service -Name AweSunService -StartupType Manual                  # 恢复：-StartupType Automatic
Stop-Service -Name AweSunService
```

⚠️ **向日葵升级或重装后，虚拟屏可能被重新装上或重新启用**。以后开机再闪，先去设备管理器看它的状态。

---

## 四、原理：为什么一块虚拟屏会让真显示器闪

### 4.1 IDD 虚拟屏在系统眼里就是一块真屏幕

Windows 的 **IDD（Indirect Display Driver，间接显示驱动）** 模型允许软件凭空造出一块"显示器"，向日葵、Parsec、各种副屏软件都用它。造出来的屏幕和真显示器地位相同：有分辨率、刷新率，参与多屏排列。区别只在于它的画面不发给线缆，而是交给软件编码后传到远端。

向日葵装它是为了**无显示器远控**：电脑没接显示器时，显卡不渲染桌面，远控只能看到黑屏，挂一块虚拟屏就能让桌面照常渲染。

### 4.2 屏幕组合一变，所有屏幕一起"重新上电"

```
屏幕组合变化（多一块 / 少一块，虚拟屏也算）
  → Windows 重新计算拓扑（位置、分辨率、主屏）
  → 对每个输出重新设置显示模式（mode set）
  → 显卡重新出信号，DP 链路重新握手（link training）
  → 显示器短暂失去信号 → 黑 → 信号恢复 → 亮
```

**即使新增的是虚拟屏，真显示器也要跟着重新设一次模式**，因为整个桌面的布局变了。平时插拔显示器时，其他屏幕会黑一下，就是这个原因。"黑白闪"就是显示器在"丢信号 → 重新同步"之间来回切换。

### 4.3 为什么会反复闪好几分钟（推断）

> 以下是根据现象做的推断，向日葵没有公开实现细节。

开机时向日葵的服务、主进程、守护进程陆续启动，每个阶段都可能去判断"现在有没有真显示器"，再决定挂上还是摘掉虚拟屏。DP 显示器从开机到被稳定识别要一段时间，这期间判断结果可能来回变，虚拟屏就被反复挂上、摘下，**每变一次就触发一轮 4.2 的全屏重配**。等进程都起完、检测结果稳定下来，就不闪了。

两个放大因素：

- **只有 Intel 核显**：真屏和虚拟屏都由它管理，每次重配都要在核显驱动里走一遍
- **快速启动开着**：开机其实是从休眠状态恢复，显卡状态是恢复出来的，不是全新初始化，更容易和后挂上的虚拟屏冲突

禁用虚拟屏后，开机时屏幕组合从头到尾只有两块真显示器，只需配置一次，所以不闪了。

---

## 五、排查思路复盘

| 步骤 | 动作 | 价值 |
| --- | --- | --- |
| 1 | 换显示器 | **对照实验**：一步排除显示器本身 |
| 2 | 列出所有显示适配器 | 多出来的不认识的设备，就是第一嫌疑 |
| 3 | 查 TDR 日志 | 排除驱动崩溃，避免一上来就重装驱动 |
| 4 | 查设备首次安装时间 | 把"什么时候开始闪"和"什么时候装了什么"对上 |
| 5 | 禁用后重启验证 | 可撤回的最小改动，现象消失就坐实了 |

**通用套路**："换了硬件还复现"→ 转头查**主机侧最近新增了什么**，重点是驱动和常驻软件。远程控制（向日葵 / ToDesk / Parsec）、副屏软件、录屏软件、显卡厂商的叠加层，都可能往系统里装虚拟显示驱动或屏幕钩子。

如果禁用虚拟屏后还闪，备选排查顺序是：关快速启动（控制面板 → 电源选项 → 选择电源按钮的功能）→ 换 DP 线 / 改用 HDMI 对照 → 卸载后干净重装核显驱动。

---

## 六、附：在 Git Bash 里调 PowerShell

这次的命令是从 Git Bash 里调 `powershell.exe` 跑的。要注意 **`$` 要转义成 `\$`**，否则会被 bash 先展开掉：

```bash
powershell.exe -NoProfile -Command "Get-Service | Where-Object { \$_.Name -match 'AweSun' } | Format-Table Name,Status,StartType"
```

输出里的中文可能是乱码（PowerShell 按 GBK 输出），不影响英文字段的判断。直接在 PowerShell 窗口里跑就没有这两个问题。
