# 组合安装与 inst 维护

| 编号 | CLI | 行为 |
| --- | --- | --- |
| 7 | `--all` / `-All` | 原有 Node + Python + 镜像 + Agents CLI，不含激活或防护变更 |
| 9 | `--update` / `-Update` | 更新已安装工具与 Agents |
| 00 | `--self-update` / `-SelfUpdate` | 脚本更新；菜单另有每日自动更新选择 |
| 88 | `--install-shortcut` / `-InstallShortcut` | 安装 inst 快捷命令 |

自更新保留原 URL、版本校验、临时下载、备份替换和单文件运行约定。此处的“自动更新”指 inst 自身，不是 Windows Update 系统策略。
