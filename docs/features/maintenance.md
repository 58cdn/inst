# 组合安装与 inst 维护

| 功能 | Windows 菜单 | Unix 菜单 | CLI |
| --- | --- | --- | --- |
| 一键安装开发环境 | 11 | 8 | `--all` / `-All` |
| 更新已安装工具 | 12 | 9 | `--update` / `-Update` |
| inst 自更新与定时更新管理 | 13 | 10 | `--self-update` / `-SelfUpdate` |
| 安装快捷命令 | 14 | 11 | `--install-shortcut` / `-InstallShortcut` |

组合安装仅包含 Node、Python、镜像与 Agents CLI，不包含激活、防护或系统更新策略变更。

主菜单编号按功能展示顺序排列。旧版 `00` 与 `88` 仍分别作为更新与快捷命令的隐藏别名；其他旧数字编号在新菜单中不再代表原功能，建议自动化改用稳定的 CLI 参数。

自更新保留原 URL、版本校验、临时下载、备份替换和单文件运行约定。这里的“自动更新”指 inst 自身，不是 Windows Update 系统策略；升级不会自动安装或执行 `winmanage` / `activation`。
