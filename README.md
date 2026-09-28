# inst

跨平台开发环境 & AI Agents 一键安装器，交互方式参考 [kejilion.sh](https://github.com/kejilion/sh)：一条命令打开数字菜单，也可以带参数非交互执行。自动识别 Windows（PowerShell 5.1 / 7、cmd、Git Bash）、macOS（zsh / bash / sh）与 Linux / WSL（常见发行版与包管理器），并自动判断是否处于中国网络，按需启用国内镜像。

## 快速开始

| 环境 | 命令 |
| --- | --- |
| macOS / Linux / WSL（sh、bash、zsh 均可） | `curl -fsSL https://inst.linux.yun \| sh` |
| Windows PowerShell 5.1 / 7 | `irm https://inst.linux.yun \| iex` |
| Windows cmd | `curl -fsSL https://inst.linux.yun/install.cmd -o %TEMP%\inst.cmd && %TEMP%\inst.cmd` |
| Windows Git Bash / MSYS2 | `curl -fsSL https://inst.linux.yun \| sh`（自动转交 PowerShell 实现） |

根地址按 User-Agent 返回入口脚本：PowerShell（`irm` / `iwr`）得到 `install.ps1`，curl、wget 等得到 `install.sh`，浏览器看到的是说明页。完整路径 `/install.sh`、`/install.ps1`、`/install.cmd` 同样可用；其他下载方式（如 `Net.WebClient`）不带 User-Agent，请使用完整路径。

带参数运行：

```bash
curl -fsSL https://inst.linux.yun | sh -s -- --all --dry-run
```

```powershell
& ([scriptblock]::Create((irm https://inst.linux.yun))) -All -DryRun
```

安装快捷命令后，新终端中输入 `inst` 即可再次打开菜单（Unix 为 `~/.local/bin/inst`，Windows 为 `%LOCALAPPDATA%\inst\bin\inst.cmd`，cmd、PowerShell、Git Bash 均可调用）。

inst.linux.yun 无法访问时，可以直接从 GitHub 获取。`INST_RAW_BASE_URL` 让本次运行的后续下载也走同一地址；需要长期使用时，把它写入 shell 配置或用户环境变量。

```bash
curl -fsSL https://raw.githubusercontent.com/58cdn/inst/master/install.sh | INST_RAW_BASE_URL=https://raw.githubusercontent.com/58cdn/inst/master sh
```

```powershell
$env:INST_RAW_BASE_URL = 'https://raw.githubusercontent.com/58cdn/inst/master'; irm "$env:INST_RAW_BASE_URL/install.ps1" | iex
```

## 安装入口镜像自动选择

未设置 `INST_RAW_BASE_URL` 时，Unix 与 Windows 的远程 bootstrap 会在正式下载平台安装器前读取官网的 `mirrors.json`。安装器对清单中的每个 HTTPS 节点请求 `/VERSION`，使用本机观测到的请求耗时排序，选择可连通且延迟最低的节点；清单中的官方地址会自动作为最终回退地址。镜像探测使用有限超时，不会阻塞现有安装流程。

- `INST_RAW_BASE_URL=https://...`：显式指定地址并跳过自动选择，适合自建分发站或临时排障。
- `INST_MIRROR_AUTO=0`：关闭自动镜像探测，直接使用默认官网地址。
- `INST_MIRROR_TIMEOUT=5`：单个清单请求与节点探测的超时时间（秒，默认 5，允许 1-60）。
- 清单获取失败、节点探测超时、节点返回错误或全部节点不可用时，继续使用 `https://inst.linux.yun`；只有后续实际下载也失败时才按原流程报错。
- `mirrors.json` 是官网发布的节点清单，新增节点必须提供与站点相同的静态路径（至少包含 `VERSION`、`scripts/` 和入口脚本）。

## 菜单
```
 1  Node.js 环境     nvm / Node.js LTS / npm / pnpm
 2  Python 环境      pyenv / Python / Miniconda
 3  镜像源配置       系统 / npm / pip / conda / Homebrew
 4  Agents CLI       Claude Code / Codex / Gemini / OpenCode / Grok / OpenClaw / Hermes / Pi
 5  Agents 桌面端    Claude / Codex Desktop
 6  Agents 地址配置  API Base URL / Key
 7  一键安装         1 + 2 + 3 + 4
 8  环境检查
 9  更新已安装工具
 00 脚本更新         立即更新 / 开启或关闭每日自动更新
 88 安装快捷命令
 0  退出
```

## 功能

### 1. Node.js

- macOS / Linux：nvm → Node.js LTS → corepack / npm 安装 pnpm。
- Windows：nvm-windows（默认 1.2.2 免安装包，可用 `INST_NVM_WINDOWS_VERSION` 指定；2.x 自动改用 `nvm config set` 配置镜像）。已有独立安装的 Node.js 时与 nvm-windows 冲突，脚本会停止并提示先卸载（不会自动卸载）；`-DryRun` 只给出警告并继续预览。

### 2. Python

- pyenv（Windows 为 pyenv-win）+ Python 最新稳定版（`--python-version 3.12` 可指定），Miniconda 安装到用户目录。
- 中国区域自动使用 Python 下载镜像（Unix: npmmirror，Windows: 华为云）。

### 3. 镜像

- 预设：`tuna`、`aliyun`、`ustc`、`tencent`、`huawei`、`official`（恢复官方）。
- 覆盖 npm / pnpm、pip、conda、nvm / pyenv 下载、GitHub 加速（`--gh-proxy`）。
- 系统源：
  - Debian / Ubuntu（含 DEB822 `.sources`、arm64 的 `ubuntu-ports`）、Alpine、Rocky、AlmaLinux、Fedora、Arch。
  - 修改前备份为 `*.inst.bak`，`official` 可恢复。
  - 必须交互确认或显式加 `--apply-system-mirror` / `-ApplySystemMirror`。
- macOS 系统源即 Homebrew（`HOMEBREW_API_DOMAIN` / `HOMEBREW_BOTTLE_DOMAIN` / `HOMEBREW_BREW_GIT_REMOTE`）。
- 所有持久化变量写在 `~/.local/inst/env.sh` 的标记块中，shell rc 只 source 一次，可重复执行。

### 4. Agents CLI

| id | 名称 | 官方安装脚本 | npm 包 |
| --- | --- | --- | --- |
| claude | Claude Code | ✅ | `@anthropic-ai/claude-code` |
| codex | Codex CLI | ✅ | `@openai/codex` |
| gemini | Gemini CLI | — | `@google/gemini-cli` |
| opencode | OpenCode | ✅（Unix） | `opencode-ai` |
| grok | Grok Build | ✅ | — |
| openclaw | OpenClaw | ✅（跳过引导） | `openclaw` |
| hermes | Hermes Agent | ✅（跳过引导） | — |
| pi | Pi | ✅（Unix） | `@earendil-works/pi-coding-agent` |

`--agent-method auto` 的选择规则：海外优先用官方脚本，中国区域优先用 npm（可走镜像）；没有对应渠道时自动换另一种。默认安装 `claude,codex,gemini,opencode`，`--agent-list all` 安装全部。

### 5. 桌面端

| 应用 | Windows | macOS | Linux |
| --- | --- | --- | --- |
| Claude Desktop | 官方安装包静默安装；指定目录时安装后移动并留目录联接 | 官方更新源 zip，复制到指定目录（默认 `/Applications`） | 官方 apt 源 `claude-desktop`（beta） |
| Codex（ChatGPT 桌面端） | 官方 MSIX，失败时改用 Microsoft Store（winget） | Apple Silicon 官方 dmg；Intel 使用 `brew --cask chatgpt` | 官方 deb / rpm |

MSIX、deb、rpm 的安装位置由系统管理，指定目录无效，脚本会提示。也可用 `INST_DESKTOP_CLAUDE_URL` / `INST_DESKTOP_CODEX_URL` 指定 HTTPS 安装包（dmg / zip / AppImage / deb / rpm / exe / msix）。

### 6. 地址配置

`--endpoint claude,codex,gemini,opencode,pi,openai --base-url URL --model NAME`：以合并方式写入各 Agent 的配置文件，不会覆盖其他字段：

- Claude Code：`~/.claude/settings.json`
- Codex：`~/.codex/config.toml`
- Gemini CLI：`~/.gemini/.env` 与 `settings.json`
- OpenCode：`opencode.json`
- Pi：`models.json`
- 通用 OpenAI 兼容：`OPENAI_BASE_URL`

API Key 只从环境变量 `INST_API_KEY` 或隐藏输入读取，不接受命令行参数，避免泄露到 shell 历史与进程列表。Unix 配置文件权限为 600。

### 7. 自动更新

- 启动菜单时读取远端 `VERSION`，有新版本时在横幅提示，输入 `00` 更新。
- 自更新流程：
  1. 下载到临时文件。
  2. 校验非空、shebang、版本号与语法（PowerShell 做语法解析）。
  3. 旧版本备份为 `.bak`，再原子替换。
- 远端版本不高于本地时跳过；设 `INST_FORCE_UPDATE=1` 可强制下载。
- 每日自动更新：Unix 使用 crontab，在 04 点的随机分钟执行；Windows 使用计划任务。

## 常用参数

```bash
inst --node --python                        # 只装 Node 与 Python
inst --mirrors --mirror-preset aliyun --apply-system-mirror
inst --agents --agent-list claude,codex,pi --agent-method official
inst --desktop --desktop-apps claude --desktop-dir ~/Applications
INST_API_KEY=sk-xxx inst --endpoint claude,codex --base-url https://api.example.com/v1 --model m1
inst --check                                # 只读检查
inst --update                               # 更新已安装工具与 Agents
inst --all --dry-run                        # 只显示将执行的命令
```

```powershell
inst -Node -Python
inst -Mirrors -MirrorPreset tuna
inst -Agents -AgentList 'claude,codex,gemini' -AgentMethod npm
inst -Desktop -DesktopApps 'claude,codex' -DesktopDir D:\Apps
inst -All -DryRun
```

完整参数见 `inst --help` / `inst -Help`。PowerShell 中逗号列表请加引号。

常用环境变量：

- `INST_REGION=cn|global`：跳过自动识别。
- `INST_RAW_BASE_URL`：自建分发地址，仅限 HTTPS。
- `INST_NO_UPDATE_CHECK=1`：不检查更新。
- `INST_NO_TTY=1`：禁止交互。
- `NO_COLOR=1`：关闭颜色。

## 安全约定

- 所有下载只接受 HTTPS，并禁止降级重定向。
- 官方安装脚本先完整下载到临时文件再执行，不会执行半截脚本。
- `--dry-run` / `-DryRun` 不创建目录、不下载、不修改配置。
- 修改系统源和写入需要 root 的位置前会提示确认。

## 发布与托管

`https://inst.linux.yun` 部署在 Cloudflare Workers 上：

- 所有文件都是静态资源（Workers Static Assets）：`tools/build-site.mjs` 把入口脚本、`scripts/`、`VERSION`、`README.md` 与 `site/` 组装到 `dist/`，响应头见 `site/_headers`。
- 只有根路径 `/` 会经过 `worker/index.mjs`，按 User-Agent 返回 `install.sh`、`install.ps1` 或说明页（`wrangler.jsonc` 中的 `run_worker_first`）。
- 静态资源请求免费且不限量。免费计划下 Worker 每天可调用 10 万次，超出后只影响根路径短命令，完整路径不受影响。
- 推送到 `master` 后，`.github/workflows/checks.yml` 先跑全部测试，通过后执行 `wrangler deploy`。
- 首次部署会自动创建 `inst.linux.yun` 的 DNS 记录和证书。前提是 `linux.yun` 已托管在 Cloudflare，且没有同名的 `inst` 记录。
- 仓库 Secrets 需要配置两项，未配置时部署步骤只执行 `--dry-run` 并给出警告：
  - `CLOUDFLARE_API_TOKEN`：用 “Edit Cloudflare Workers” 模板创建
  - `CLOUDFLARE_ACCOUNT_ID`
- 本地预览：`npx wrangler@4 dev`（http://localhost:8787）。手动发布：`npx wrangler@4 deploy`。

备选方案是 GitHub Pages，由 `.github/workflows/pages.yml` 手动触发发布：

- 在 Settings → Pages 中把 Source 设为 GitHub Actions，并在同一页面填写自定义域名。
- 该域名在 Cloudflare 上需设为仅 DNS（灰色云朵）。
- GitHub Pages 不能按 User-Agent 分流，只能使用完整路径命令。

## 目录

- `install.sh`：POSIX sh 入口（macOS / Linux / WSL / Git Bash）
- `install.zsh`：zsh 入口
- `install.ps1`：PowerShell 引导，纯 ASCII，可安全用于 `irm | iex`
- `install.cmd`：cmd 入口（CRLF 换行）
- `scripts/install-unix.sh`：Unix 实现（兼容 bash 3.2）
- `scripts/install-windows.ps1`：Windows 实现（UTF-8 BOM，兼容 PowerShell 5.1）
- `site/`：说明页 `index.html` 与响应头 `_headers`
- `mirrors.json`：远程 bootstrap 探测的官网镜像节点清单
- `worker/index.mjs`：根路径 User-Agent 分流
- `tools/build-site.mjs`：生成 `dist/`，并检查换行符（`.sh` 必须是 LF，`.cmd` 必须是 CRLF）
- `wrangler.jsonc`：Cloudflare Workers 配置（静态资源目录、自定义域名）
- `tests/`：隔离回归测试，不修改真实用户环境

## 测试

```bash
bash tests/unix-regression.sh
node tools/build-site.mjs && node tests/worker.test.mjs
```

```powershell
./tests/check-readonly.ps1; ./tests/python-version.ps1; ./tests/windows-regression.ps1
```
