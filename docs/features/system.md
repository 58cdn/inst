# 系统管理

Windows 菜单 **11** / `inst -WindowsManagement` 安装 `winmanage`，默认只读查询 Windows Update、Defender 和安全中心状态。

更新策略、Defender 实时保护切换与原值恢复必须显式选择，实际写入另需 `-Apply` 和新的备份路径。`-DryRun` 不写入；版本、管理员权限、受管策略和篡改防护检查继续适用。

该功能由已合并的 [PR #8](https://github.com/58cdn/inst/pull/8) 提供。完整操作、回滚方式与微软依据见 [winmanage 说明](../../scripts/winmanage.md)。不承诺永久禁更，不支持卸载内置 Defender 或隐藏安全中心代替关闭防护。

系统激活使用独立菜单 **12** / `activation`，不会调用系统管理动作；一键安装与工具更新也不修改这些安全设置。
