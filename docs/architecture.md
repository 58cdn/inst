# 按功能组织，保持发布兼容

本次只整理菜单、帮助、功能文档，并新增独立 Windows 激活信息命令；不拆分平台安装器，不建立空 src 框架。

## 当前职责

- 根目录 `install.sh` / `install.zsh` / `install.ps1` / `install.cmd`：平台引导与参数转交。
- `scripts/install-unix.sh` / `scripts/install-windows.ps1`：可独立运行的平台安装器，承载开发环境、镜像、AI、工具和维护功能。
- `scripts/cgpu.*`、`scripts/winmanage.*`、`scripts/activation.*`：独立命令与离线帮助；系统管理与激活信息保持独立。
- `scripts/lib/download.*`：下载实现唯一来源；`tools/embed-download.mjs` 生成入口中的下载段。
- `docs/features/`：功能分组、操作边界与来源；README 保留原快速开始和详细说明。
- `tools/build-site.mjs`：按显式清单生成 dist；`worker/index.mjs`：根路径按 User-Agent 分流。
- `tools/update-versions.mjs`：定时依赖版本同步；`tests/` 和 CI：隔离回归。

## 不变的外部约定

全部已有数字动作、CLI 参数、命令安装位置、根入口及 `/scripts/install-*`、`/scripts/cgpu.*` 的 raw/静态发布 URL 保留。Windows 菜单 11 为系统管理，菜单 12 为系统激活；Unix 不提供不可执行的 Windows 菜单。菜单 7 / All 仍只组合原有四项安装。

单文件快捷命令、自更新、远程临时脚本不能依赖下载目录中的旁侧源码。只在 dist 复制旧路径无法保障 GitHub raw，因此原仓库路径也必须保留。

## 后续最小迁移顺序

1. 按功能逐块抽取到实际需要的源码目录，新增确定性组装和 `--check` 校验；在原路径提交可独立运行的发布脚本。
2. 一次只迁移一个功能，保持现有函数/参数行为；同步修改版本同步工具的唯一源码位置。
3. 发布清单、下载嵌入目标、CI、站点文档链接同批更新；验证本地 checkout、远程引导、旧快捷命令和自更新。
4. 保持 PowerShell 5.1 BOM、引导 ASCII、CMD CRLF、Shell LF；不扩大下载回退白名单或增加动态远程模块执行。

系统管理由已合并的 PR #8 提供，菜单 11 与 12 分组独立；集成保留两套参数、发布资产与 mock 测试。系统激活不调用系统管理的安全配置变更。
