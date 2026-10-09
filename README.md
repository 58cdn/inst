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
 10  cgpu 显卡监控     Windows CMD / PowerShell，1 秒刷新 nvidia-smi
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

### 8. 自动同步安装依赖版本

- `.github/workflows/sync-versions.yml` 每周一 03:17（UTC）运行，也支持手动触发。
- `tools/update-versions.mjs` 查询 GitHub Releases，只选择稳定且包含 `nvm-noinstall.zip` 的 nvm-windows 版本，并同步 Unix 端 nvm-sh 的回退 tag。
- 检测到新版本时，Actions 只修改源文件并创建或更新 `automation/sync-installer-versions` PR；没有变化时不会产生空 PR。
- `nvm-windows 2.x` 当前只有安装器或其他资产，不符合现有免安装流程，因此会被自动跳过，直到上游提供兼容资产。
- PR 需要先通过现有安装器检查，再由维护者审核合并；仓库需允许 Actions 的 `GITHUB_TOKEN` 写入内容、Pull Request 和 Actions 运行权限。

### 9. cgpu（Windows NVIDIA 显卡实时监控）

Windows 用户可通过菜单 **10** 或非交互参数 `-Cgpu` 安装：

```powershell
& ([scriptblock]::Create((irm https://inst.linux.yun/install.ps1))) -Cgpu
# 直接通过 GitHub：
$env:INST_RAW_BASE_URL = 'https://raw.githubusercontent.com/58cdn/inst/master'
& ([scriptblock]::Create((irm "$env:INST_RAW_BASE_URL/install.ps1"))) -Cgpu
```

安装时会在 `%USERPROFILE%\.command\` 创建 `cgpu.ps1`、`cgpu.cmd`、`cgpu.md`，并将该目录加入**用户 PATH**（重新打开 CMD / PowerShell 后生效）。不会永久修改 ExecutionPolicy，也不需要管理员权限；已有内容不同时会创建一次 `*.inst.bak` 备份。

```powershell
cgpu              # 每秒清屏刷新 nvidia-smi，Ctrl+C 退出
cgpu -Interval 2  # 每 2 秒刷新
cgpu -Once        # 仅查看一次
```

依赖 NVIDIA 显卡驱动提供的 `nvidia-smi`；未安装驱动或找不到命令时给出错误。CMD 包装器优先使用 PowerShell 7，未找到则使用 Windows PowerShell 5.1。

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
- `scripts/cgpu.ps1`、`scripts/cgpu.cmd`、`scripts/cgpu.md`：Windows 显卡监控命令与帮助
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
./tests/check-readonly.ps1; ./tests/python-version.ps1; ./tests/windows-regression.ps1; ./tests/cgpu.ps1
```

### 下载失败与回退

由 inst 自己发起的安装包、官方安装脚本、入口脚本和自更新下载采用以下边界：

- **连接 / TLS**：Unix curl 单次连接最多 20 秒；Windows HttpClient 的连接阶段包含在下面的 30 秒预算中。
- **响应头 / 首个有效文件数据**：每个候选源从请求开始共享 30 秒启动预算，重定向不重置预算（最多 5 次，禁止 HTTPS 降级）。HTTP 200、响应头或任意单字节不算下载开始；须收到并检查前 512 字节。小于 512 字节的文件必须在预算内完整结束并通过前缀检查。HTTP 错误、空文件和 HTML/JSON 错误页直接失败；已知脚本、ZIP/MSIX、EXE 另检查格式前缀。前缀检查不是签名或完整性证明。
- **下载中无进度**：开始后连续约 120 秒没有新文件数据则失败；Unix 以一秒采样观察文件增长，Windows 每次异步读取独立计时。
- **整体时限**：大文件没有总时限，持续下载可超过 30 秒。Ctrl+C/终止会取消请求并清理部分文件。CMD 最外层只获取一个很小的 PowerShell 引导脚本，使用 .NET HttpClient（不依赖 curl.exe）并设每个候选 30 秒整体上限；不影响后续大文件。

每个候选只尝试一次，自动映射最多两个源：本项目官网与 `58cdn/inst` GitHub master 的相同入口路径；Miniconda 官方目录与清华 TUNA 的相同文件名。已有节点测速选择继续保留；清单中其他选中节点失败后最多再进入这两个内置源。`INST_RAW_BASE_URL` 显式覆盖及 `INST_MIRROR_AUTO=0` 保留入口单源行为；自定义 URL、代理、含查询参数的 URL 不会自动改写；URL 内凭据被拒绝。错误记录保留候选序号和失败原因。

Miniconda 安装前从[Anaconda 官方目录](https://repo.anaconda.com/miniconda/)取得对应架构文件的 SHA256，两站必须匹配同一摘要（包括 `latest`），镜像未同步则失败后切换。无法取得官方摘要时停止安装，不降低校验要求。清华镜像的覆盖及维护方见 [TUNA 官方说明](https://mirrors.tuna.tsinghua.edu.cn/help/anaconda/)。不添加通用 GitHub 代理，不向其他站点发送自定义地址或凭据。下载成功并校验后才替换目标文件；失败保留已有目标，删除此次临时文件。系统安装器原有签名检查继续由系统执行。

范围说明：nvm、pyenv、npm/pip、包管理器以及第三方官方安装脚本内部的网络请求由它们自行管理，inst 不接管其超时，也不读取或转发 `NVM_AUTH_HEADER`；版本索引、区域探测等小型元数据仍使用各自的短总超时。本项目入口跟随发布通道，官网与 master 可能存在部署时间差；不将这类入口当成不可变版本资源。

下载实现维护在 `scripts/lib/download.sh`、`scripts/lib/download.ps1`，通过 `node tools/embed-download.mjs` 嵌入各独立入口，避免安装快捷命令后依赖旁侧文件。修改后运行：

```sh
node tools/embed-download.mjs --check
python3 tests/download-regression.py
bash tests/unix-regression.sh
node tools/build-site.mjs
node tests/worker.test.mjs
```

Windows 使用 `powershell -NoProfile -File tests/download-regression.ps1`，并运行 `.github/workflows/checks.yml` 中其他 Windows 回归。网络回归使用 Python 标准库 HTTPS 服务与临时 CA（仅设置该测试 curl 的 CA 文件），不修改系统信任；PowerShell 使用受控 HttpMessageHandler 测试异步超时和流读取。
