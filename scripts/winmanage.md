# Windows 系统管理（winmanage）

适用于 Windows 10/11 客户端，PowerShell 5.1 / 7。菜单 **11** 或 `inst -WindowsManagement` 仅安装命令与帮助到 `%USERPROFILE%\.command`，不更改更新或安全配置；新终端运行 `winmanage` 默认只读。安装沿用 inst 的 HTTPS 下载、可信回退、暂存与 PowerShell 语法检查。`inst -WindowsManagement -DryRun` 不下载、不写文件、不改 PATH。

## 显式操作

在 CMD / PowerShell 均可运行（直接运行 ps1 时用 `./scripts/winmanage.ps1`）：

```powershell
winmanage
winmanage -Action UpdateDisable -DryRun
winmanage -Action UpdateEnable -DryRun
winmanage -Action DefenderDisable -DryRun
winmanage -Action DefenderEnable -DryRun
# 只有显式 -Apply 才写入；每次必须使用新的备份文件，父目录须已存在。
winmanage -Action UpdateDisable -Apply -BackupPath C:\Backups\update-before.json
winmanage -Action DefenderEnable -Apply -BackupPath C:\Backups\defender-before.json
winmanage -Action Restore -RestorePath C:\Backups\update-before.json -DryRun
winmanage -Action Restore -RestorePath C:\Backups\update-before.json -Apply -BackupPath C:\Backups\before-restore.json
```

省略 `-Apply` 一律预演；`-DryRun` 优先于 `-Apply`。更改操作（含预演）必须通过适用性检查：管理员、Windows 客户端、64 位系统上的 64 位 PowerShell、管理策略检测。不会自动提权或永久修改 ExecutionPolicy。一次仅处理一个目标，无隐式批量禁用。

- `UpdateDisable` / `UpdateEnable`：仅将官方 `NoAutoUpdate` DWORD 策略设为 1 / 0。支持白名单中的 Pro、Enterprise、Education 及相应变体；Home/未知版本拒绝写入，可在 Windows 设置中暂停/恢复。启用不等于恢复原值：原先未配置应使用 Restore。不会停止 Windows Update 服务或任务，也不修复第三方工具造成的服务损坏；不承诺永久禁更。即时验证仅证明策略值写入，实际调度可能需后续策略刷新/重启，手动更新仍可用。
- `DefenderDisable` / `DefenderEnable`：仅使用 `Set-MpPreference -DisableRealtimeMonitoring` 切换实时保护，并同时验证配置与实际保护状态。关闭会降低安全性，Windows 可能自动重新开启。不会关闭防火墙、云保护、EDR 或所有安全组件。
- `Restore`：只接受本机、版本 1、目标白名单、严格类型的 JSON 备份。恢复原值；原先不存在的 NoAutoUpdate 会删除该值，保留键和其他数据。恢复前仍创建新备份。请保管可信备份，不使用来历不明的文件。
- `DefenderUninstall` / `SecurityCenterDisable`：明确返回不支持和非零退出码。Windows 10/11 内置组件不提供本工具支持的卸载方式；不强删文件，不绕过篡改防护，不隐藏安全中心冒充关闭防护。第三方杀毒卸载由用户使用厂商官方程序处理。

## 状态、限制与恢复

输出 JSON：系统版本、权限、更新策略、Defender 实时保护/运行模式/篡改防护、检测错误。Status 即使某个组件读取失败也返回其余信息，`Issues` 非空表示查询不完整，不代表该组件已关闭。

域加入、Entra 加入、MDM 注册、组策略历史、Defender 策略或其他更新策略迹象会保守阻止写入；检测失败也阻止。检测不是所有管理产品的完整枚举，第三方管理或未来策略仍可能覆盖本机值。篡改防护启用/未知、Defender 缺失或非 Normal 模式拒绝 Defender 修改。不会引导用户绕过防护。PowerShell 7 若无法加载系统 Defender 模块，请改用 Windows PowerShell 5.1，不会静默替换管理方式。

备份以 CreateNew 创建，拒绝覆盖；先写入并读回，再修改系统。修改前再次检查权限/策略/原值。命令报错或验证不符时退出 1，说明“失败或部分完成”，保留备份。不会自动覆盖可能同时变化的策略：先运行 Status 确认，再显式 Restore。若恢复被组织策略或篡改防护阻止，请由原管理渠道处理。成功 `Verified` 表示当时读取一致，不保证永久生效。

## 微软官方依据（核对于 2026-10-11）

- [Windows Update 设置与 NoAutoUpdate 注册表方式](https://learn.microsoft.com/en-us/windows/deployment/update/waas-wu-settings#configuring-automatic-updates-by-editing-the-registry)：未部署 Active Directory 的本机管理方式；不是永久关闭服务。
- [Update Policy CSP / AllowAutoUpdate 适用版本](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-update#allowautoupdate)：Pro / Enterprise / Education 等版本边界。本工具不注册 MDM、不直接设置 CSP。
- [Set-MpPreference / DisableRealtimeMonitoring](https://learn.microsoft.com/en-us/powershell/module/defender/set-mppreference)：实时保护开关。
- [篡改防护](https://learn.microsoft.com/en-us/defender-endpoint/tamper-protection-overview)：管理工具可能报告成功但设置实际被阻止，因此需状态复核。
- [Defender 与其他安全产品的兼容性](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-compatibility)：Windows 客户端/Server、主动/被动模式边界；Server 卸载指令不适用于本功能。
- [Windows Update FAQ](https://support.microsoft.com/en-us/windows/deployment/updates-lifecycle/windows-update-faq)：面向个人设备的暂停/恢复入口。

## 验证范围

`tests/windows-management.ps1` 以 mock 隔离系统读取与写入，使用临时目录测试真实 JSON 备份/恢复。CI 分别用 Windows PowerShell 5.1、PowerShell 7 运行。不在开发机或 CI 实际修改 Defender、更新策略、注册表或系统服务。真实设备的生效时机、组织策略覆盖、重启后的状态须在单独授权的 Windows 测试机验证。
