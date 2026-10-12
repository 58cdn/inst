from pathlib import Path


def read(path):
    return Path(path).read_bytes().decode('utf-8')


def write(path, text):
    Path(path).write_bytes(text.encode('utf-8'))


def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f'Expected one occurrence: {old[:100]!r}; got {text.count(old)}')
    return text.replace(old, new, 1)


def between(text, start, end, replacement):
    if text.count(start) != 1 or text.count(end) != 1:
        raise RuntimeError(f'Ambiguous boundaries: {start!r}, {end!r}')
    a, b = text.index(start), text.index(end)
    if b <= a:
        raise RuntimeError('Reversed boundaries')
    return text[:a] + replacement + text[b:]


win = read('scripts/install-windows.ps1')
win = between(win, 'function Get-RemoteVersion {', 'function Get-SelfUpdateTarget {', r'''$script:RemoteVersion = ''
$script:RemoteVersionSource = ''
$script:RemoteVersionStatus = 'unchecked'
$script:RemoteVersionChecked = $false
function Test-ReleaseVersion([string]$Value) {
  return $Value -cmatch '\A(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\z'
}
function Get-RemoteVersion([switch]$Refresh) {
  if ($env:INST_NO_UPDATE_CHECK) {
    $script:RemoteVersion = ''; $script:RemoteVersionSource = ''
    $script:RemoteVersionStatus = 'disabled'; $script:RemoteVersionChecked = $false
    return ''
  }
  if (-not $Refresh -and $script:RemoteVersionChecked) { return $script:RemoteVersion }
  $script:RemoteVersionChecked = $true
  $script:RemoteVersion = ''; $script:RemoteVersionSource = ''; $script:RemoteVersionStatus = 'unavailable'
  $bases = @($InstBase.TrimEnd('/'))
  # An explicit/pinned source must not silently switch to the public release channel.
  if (-not $env:INST_RAW_BASE_URL) {
    $bases += @('https://inst.linux.yun', 'https://raw.githubusercontent.com/58cdn/inst/master')
  }
  foreach ($base in @($bases | Select-Object -Unique)) {
    try {
      Assert-HttpsUrl $base '版本源'
      if (([Uri]$base).UserInfo) { continue }
      $uri = "$base/VERSION?inst_check=$([DateTime]::UtcNow.Ticks)"
      $text = ([string](Invoke-RestMethod -Uri $uri -TimeoutSec 3 -UseBasicParsing -Headers @{ 'Cache-Control' = 'no-cache' })).Trim()
      if (Test-ReleaseVersion $text) {
        $script:RemoteVersion = $text; $script:RemoteVersionSource = $base; $script:RemoteVersionStatus = 'ok'
        return $text
      }
    } catch { }
  }
  return ''
}
function Get-OnlineVersionLabel {
  if ($env:INST_NO_UPDATE_CHECK -or $script:RemoteVersionStatus -eq 'disabled') { return '已关闭' }
  if ($script:RemoteVersion) { return "v$($script:RemoteVersion)" }
  if ($script:RemoteVersionStatus -eq 'unavailable') { return '不可用' }
  return '未检查'
}
''')
win = once(win, "function Get-RemoteScript {", "function Get-RemoteScript([string]$Base = $InstBase) {")
win = once(win, "  Assert-HttpsUrl $InstBase 'INST_RAW_BASE_URL'\n  $temp = Join-Path", "  Assert-HttpsUrl $Base 'INST_RAW_BASE_URL'\n  $temp = Join-Path")
win = once(win, '    Save-InstDownload "$InstBase/scripts/install-windows.ps1" $temp', '    Save-InstDownload "$Base/scripts/install-windows.ps1" $temp')
win = once(win, '  $remote = Get-RemoteVersion\n', '  $remote = Get-RemoteVersion -Refresh\n')
win = once(win, "  if (-not $env:INST_FORCE_UPDATE -and $current -and $remote -and (Compare-InstVersion $remote $current) -le 0) {", "  if ($current -and $remote -and (Compare-InstVersion $remote $current) -lt 0) {\n    Write-Warn \"在线源 v$remote 低于当前 v$current，未降级\"; return\n  }\n  if (-not $env:INST_FORCE_UPDATE -and $current -and $remote -and (Compare-InstVersion $remote $current) -eq 0) {")
win = once(win, "  $code = Get-RemoteScript\n  $newVersion", "  $source = if ($script:RemoteVersionSource) { $script:RemoteVersionSource } else { $InstBase }\n  $code = Get-RemoteScript $source\n  $newVersion")
win = once(win, "  if (-not $newVersion) { throw '下载的脚本缺少版本号，未替换' }\n  Copy-Item -LiteralPath $target -Destination \"$target.bak\" -Force -ErrorAction SilentlyContinue", "  if (-not (Test-ReleaseVersion $newVersion)) { throw '下载的脚本缺少有效版本号，未替换' }\n  if ($remote -and $newVersion -ne $remote) { throw \"版本清单 v$remote 与脚本 v$newVersion 不一致，请稍后刷新；未替换\" }\n  if ($current -and (Compare-InstVersion $newVersion $current) -lt 0) { throw '下载的脚本较旧，拒绝降级；未替换' }\n  Copy-Item -LiteralPath $target -Destination \"$target.bak\" -Force -ErrorAction Stop")
win = between(win, "# ---------------------------------------------------------------- 菜单\n$script:RemoteVersion = ''", 'function Invoke-MenuAction(', r'''# ---------------------------------------------------------------- 菜单
function Write-MenuSeparator { Write-Host ('-' * 48) -ForegroundColor Gray }
function Write-MenuSection([string]$Title) { Write-Host "---- [${Title}] ----" -ForegroundColor Cyan }
function Show-Banner {
  if ($Interactive) { Clear-Host }
  Write-Host " inst  v$InstVersion" -ForegroundColor Cyan
  $shell = switch ($env:INST_LAUNCHER) { 'cmd' { 'cmd' } 'bash' { 'Git Bash' } default { "PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)" } }
  Write-Host " 系统: Windows $([Environment]::OSVersion.Version.Build) $Arch"
  Write-Host " Shell: $shell | 区域: $(Get-InstRegion)"
  Write-Host " 本地: v$InstVersion | 在线: $(Get-OnlineVersionLabel)"
  if ($script:RemoteVersion -and (Compare-InstVersion $script:RemoteVersion $InstVersion) -gt 0) {
    Write-Host ' 发现新版本，输入 00 检查 / 更新 inst' -ForegroundColor Yellow
  }
  Write-MenuSeparator
}
function Write-MenuLine([string]$Key, [string]$Label, [string]$Hint = '') {
  # Pad only the ASCII key: character counts are not CJK display-column widths.
  Write-Host (' {0,2}  {1}' -f $Key, $Label) -ForegroundColor White
  if ($Hint) { Write-Host "     $Hint" -ForegroundColor Gray }
}
function Write-MainMenu {
  Write-MenuSection '开发环境'
  Write-MenuLine 1 'Node.js 环境'
  Write-MenuLine 2 'Python 环境'
  Write-MenuSection '网络与镜像'
  Write-MenuLine 3 '镜像源配置'
  Write-MenuSection 'AI 工具'
  Write-MenuLine 4 'Agents CLI'
  Write-MenuLine 5 'Agents 桌面端'
  Write-MenuLine 6 'Agents 地址配置'
  Write-MenuSection '工具与系统'
  Write-MenuLine 8 '环境检查'
  Write-MenuLine 10 'NVIDIA 显卡监控'
  Write-MenuLine 11 'Windows 系统管理'
  Write-MenuLine 12 'Windows 激活管理'
  Write-MenuSection '安装与维护'
  Write-MenuLine 7 '一键安装开发环境'
  Write-MenuLine 9 '更新已安装工具'
  Write-MenuLine '00' '检查 / 更新 inst'
  Write-MenuLine 88 '安装快捷命令'
  Write-MenuSeparator
  Write-MenuLine 0 '退出'
}
''')
win = between(win, 'function Show-UpdateMenu {', 'function Show-MainMenu {', r'''function Show-UpdateMenu {
  while (-not $script:ExitMenu) {
    Show-Banner
    Write-MenuSection 'inst 更新'
    if ($script:RemoteVersionSource) { Write-Host " 更新源: $($script:RemoteVersionSource)" -ForegroundColor Gray }
    Write-MenuLine 1 '立即更新'
    Write-MenuLine 2 '开启每日自动更新'
    Write-MenuLine 3 '关闭自动更新'
    Write-MenuLine 4 '刷新在线版本'
    Write-MenuLine 0 '返回'
    switch (Read-Choice '请选择' '0') {
      '1' {
        if (-not (Get-SelfUpdateTarget)) {
          Write-Inst '尚未安装本地快捷命令，将安装 inst 以便后续更新'
          Invoke-MenuAction { Install-Shortcut } | Out-Null
        } elseif (Invoke-MenuAction { Update-Installer }) {
          Write-Inst '请重新运行 inst 以加载本地脚本'
          $script:ExitMenu = $true
        }
      }
      '2' { Invoke-MenuAction { Set-AutoUpdate $true } | Out-Null }
      '3' { Invoke-MenuAction { Set-AutoUpdate $false } | Out-Null }
      '4' { [void](Get-RemoteVersion -Refresh) }
      '0' { return }
      'q' { return }
      default { Write-Warn '无效选项'; Wait-Inst }
    }
  }
}
''')
start = win.index('function Show-MainMenu {')
a = win.index('    Show-Banner\n', start)
b = win.index("    switch (Read-Choice '请输入你的选择')", a)
win = win[:a] + '    Show-Banner\n    Write-MainMenu\n' + win[b:]
write('scripts/install-windows.ps1', win)

unix = read('scripts/install-unix.sh')
unix = between(unix, "REMOTE_VERSION=''\nfetch_remote_version(){", 'self_update_target(){', r'''REMOTE_VERSION=''; REMOTE_VERSION_SOURCE=''; REMOTE_VERSION_STATUS=unchecked; REMOTE_VERSION_CHECKED=0
valid_release_version(){ [[ "$1" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]]; }
fetch_remote_version(){
  if [[ -n "${INST_NO_UPDATE_CHECK:-}" ]]; then
    REMOTE_VERSION=''; REMOTE_VERSION_SOURCE=''; REMOTE_VERSION_STATUS=disabled; REMOTE_VERSION_CHECKED=0
    return 1
  fi
  if [[ "${1:-}" != refresh ]] && ((REMOTE_VERSION_CHECKED)); then [[ -n "$REMOTE_VERSION" ]]; return; fi
  REMOTE_VERSION=''; REMOTE_VERSION_SOURCE=''; REMOTE_VERSION_STATUS=unavailable; REMOTE_VERSION_CHECKED=1
  local base text seen='|' stamp
  local -a bases=("${BASE_URL%/}")
  if [[ -z "${INST_RAW_BASE_URL:-}" ]]; then
    bases+=('https://inst.linux.yun' 'https://raw.githubusercontent.com/58cdn/inst/master')
  fi
  stamp="$(date +%s)"
  for base in "${bases[@]}"; do
    [[ "$seen" == *"|$base|"* ]] && continue
    seen="$seen$base|"
    case "$base" in https://*@*) continue;; https://*) ;; *) continue;; esac
    text="$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 2 --max-time 3 \
      -H 'Cache-Control: no-cache' "$base/VERSION?inst_check=$stamp" 2>/dev/null \
      | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
    if valid_release_version "$text"; then
      REMOTE_VERSION="$text"; REMOTE_VERSION_SOURCE="$base"; REMOTE_VERSION_STATUS=ok
      return 0
    fi
  done
  return 1
}
online_version_label(){
  if [[ -n "${INST_NO_UPDATE_CHECK:-}" || "$REMOTE_VERSION_STATUS" == disabled ]]; then printf '已关闭'
  elif [[ -n "$REMOTE_VERSION" ]]; then printf 'v%s' "$REMOTE_VERSION"
  elif [[ "$REMOTE_VERSION_STATUS" == unavailable ]]; then printf '不可用'
  else printf '未检查'; fi
}
''')
unix = once(unix, '  if [[ -z "${INST_FORCE_UPDATE:-}" && -n "$current" ]] && fetch_remote_version && ! version_gt "$REMOTE_VERSION" "$current"; then', '''  fetch_remote_version refresh || true
  if [[ -n "$current" && -n "$REMOTE_VERSION" ]] && version_gt "$current" "$REMOTE_VERSION"; then
    warn "在线源 v${REMOTE_VERSION} 低于当前 v${current}，未降级"; return 0
  fi
  if [[ -z "${INST_FORCE_UPDATE:-}" && -n "$current" && "$REMOTE_VERSION" == "$current" ]]; then''')
unix = once(unix, '  if ! inst_download "$BASE_URL/scripts/install-unix.sh" "$tmp" \\\n', '  if ! inst_download "${REMOTE_VERSION_SOURCE:-$BASE_URL}/scripts/install-unix.sh" "$tmp" \\\n')
unix = once(unix, '  cp -p "$target" "$target.bak" 2>/dev/null || true\n', '''  local downloaded; downloaded="$(script_version "$tmp")"
  if ! valid_release_version "$downloaded" || [[ -n "$REMOTE_VERSION" && "$downloaded" != "$REMOTE_VERSION" ]]; then
    rm -f "$tmp"; err '版本清单与脚本不一致，请稍后刷新；未替换'; return 1
  fi
  if [[ -n "$current" ]] && version_gt "$current" "$downloaded"; then
    rm -f "$tmp"; err '下载的脚本较旧，拒绝降级；未替换'; return 1
  fi
  if ! cp -p "$target" "$target.bak"; then
    rm -f "$tmp"; err '备份失败，未替换'; return 1
  fi
''')
unix = once(unix, "  REMOTE_VERSION=''\n  ok \"已更新:", "  REMOTE_VERSION=''; REMOTE_VERSION_CHECKED=0\n  ok \"已更新:")
unix = between(unix, '# ---------------------------------------------------------------- 菜单\nbanner(){', 'LAST_RC=0\nrun_action(){', r'''# ---------------------------------------------------------------- 菜单
menu_separator(){ printf '%s\n' '------------------------------------------------'; }
menu_section(){ printf '%s---- [%s] ----%s\n' "$C_C" "$1" "$C_0"; }
banner(){
  if ((HAS_TTY)) && [[ -t 1 ]]; then clear; fi
  printf '%s inst  v%s%s\n' "$C_C" "$INST_VERSION" "$C_0"
  printf ' 系统: %s\n Shell: %s | 区域: %s\n' "$(platform_label)" "$LOGIN_SHELL" "$REGION"
  printf ' 本地: v%s | 在线: %s\n' "$INST_VERSION" "$(online_version_label)"
  if [[ -n "$REMOTE_VERSION" ]] && version_gt "$REMOTE_VERSION" "$INST_VERSION"; then
    printf '%s 发现新版本，输入 00 检查 / 更新 inst%s\n' "$C_Y" "$C_0"
  fi
  menu_separator
}
menu_line(){
  # Only ASCII keys are padded. Submenu hints get their own line, never CJK columns.
  printf ' %2s  %s\n' "$1" "$2"
  if [[ -n "${3:-}" ]]; then printf '     %s%s%s\n' "$C_D" "$3" "$C_0"; fi
}
main_menu_content(){
  menu_section '开发环境'
  menu_line 1 'Node.js 环境'
  menu_line 2 'Python 环境'
  menu_section '网络与镜像'
  menu_line 3 '镜像源配置'
  menu_section 'AI 工具'
  menu_line 4 'Agents CLI'
  menu_line 5 'Agents 桌面端'
  menu_line 6 'Agents 地址配置'
  menu_section '工具与系统'
  menu_line 8 '环境检查'
  menu_section '安装与维护'
  menu_line 7 '一键安装开发环境'
  menu_line 9 '更新已安装工具'
  menu_line 00 '检查 / 更新 inst'
  menu_line 88 '安装快捷命令'
  menu_separator
  menu_line 0 '退出'
}
''')
unix = between(unix, 'menu_update(){', 'all_in_one(){', r'''menu_update(){
  local c
  while true; do
    banner
    menu_section 'inst 更新'
    if [[ -n "$REMOTE_VERSION_SOURCE" ]]; then printf ' 更新源: %s\n' "$REMOTE_VERSION_SOURCE"; fi
    menu_line 1 立即更新; menu_line 2 开启每日自动更新; menu_line 3 关闭自动更新
    menu_line 4 刷新在线版本; menu_line 0 返回
    ask c '请选择' 0
    case "$c" in
      1) if [[ -z "$(self_update_target)" ]]; then run_action install_shortcut
         else run_action self_update; if ((LAST_RC == 0)); then log '重新启动...'; exec bash "$(self_update_target)"; fi; fi;;
      2) run_action auto_update on;;
      3) run_action auto_update off;;
      4) fetch_remote_version refresh || true;;
      0|q) return;;
      *) warn '无效选项'; pause;;
    esac
  done
}
''')
start = unix.index('main_menu(){')
a = unix.index('    banner\n', start)
b = unix.index("    ask c '请输入你的选择'", a)
unix = unix[:a] + '    banner\n    main_menu_content\n' + unix[b:]
# A library-only path for isolated menu/network tests, matching Windows -LibOnly.
unix = once(unix, '\nmain "$@"', '\nif [[ "${INST_LIB_ONLY:-}" != 1 ]]; then main "$@"; fi')
write('scripts/install-unix.sh', unix)

# Update only assertions affected by the presentation (all existing behavior tests remain).
features = read('tests/features.test.mjs')
features = once(features, "new RegExp(`Write-MenuLine ${key} `)", "new RegExp(`Write-MenuLine ['\\\"]?${key}['\\\"]? `)")
features = once(features, "/Write-MenuLine 12 '激活管理入口'/", "/Write-MenuLine 12 'Windows 激活管理'/")
features = once(features, "assert.ok(win.includes('[系统管理]') && win.includes('-WindowsManagement'));", "assert.ok(win.includes(\"Write-MenuSection '工具与系统'\") && win.includes('-WindowsManagement'));")
write('tests/features.test.mjs', features)

readme = read('README.md')
a = readme.index('## 菜单\n')
b = readme.index('\n## 功能\n', a)
readme = readme[:a] + '''## 菜单

主菜单使用单列短标签，分类之间有分割线；详细说明放在子菜单，不使用中文补空格对齐。原有编号及 CLI 参数保持不变，Windows 专属的 10 / 11 / 12 不出现在 Unix 菜单中。

```text
 inst  v<本地版本>
 系统: Windows 19045 x64
 Shell: PowerShell 5.1 | 区域: cn
 本地: v<本地版本> | 在线: v<在线版本>
------------------------------------------------
---- [开发环境] ----
  1  Node.js 环境
  2  Python 环境
---- [网络与镜像] ----
  3  镜像源配置
---- [AI 工具] ----
  4  Agents CLI
  5  Agents 桌面端
  6  Agents 地址配置
---- [工具与系统] ----
  8  环境检查
 10  NVIDIA 显卡监控
 11  Windows 系统管理
 12  Windows 激活管理
---- [安装与维护] ----
  7  一键安装开发环境
  9  更新已安装工具
 00  检查 / 更新 inst
 88  安装快捷命令
------------------------------------------------
  0  退出
```

一键安装仍然只包含 Node.js、Python、镜像和 Agents CLI，不包含显卡监控、系统管理或激活管理。

### 在线版本与自动发布

`VERSION` 是版本来源。默认分支的新改动通过 Ubuntu、macOS 和 Windows 检查后，发布任务自动将补丁号加一，并同步两个平台脚本中的常量；随后 Cloudflare 部署同一个版本提交。只在发布任务授予 `contents: write`，使用 `GITHUB_TOKEN` 的版本提交不会再次触发 push 工作流，部署在当前流程继续执行。无需额外 Token。

重复运行已发布的 CI 会复用已有版本，不再次递增；落后于默认分支的旧任务不发布。推送冲突、分支保护拒绝、测试失败都会阻止后续部署，不会强制推送或绕过保护。以后启用禁止自动化直接推送的分支保护时，需要改用版本 PR 流程。没有配置现有 Cloudflare 凭据时仍然仅执行 dry-run，不代表网站已更新。

本地维护命令（仅修改工作区，不自动提交）：

```bash
node tools/bump-version.mjs --check
node tools/bump-version.mjs patch
# 显式调整较大版本：minor 或 major
```

菜单每次启动检查一次在线版本；成功与失败都在会话中缓存，`00` → `4` 可以刷新。按当前下载源 → 官网 → GitHub Raw 的顺序回退，每个请求设置 3 秒超时，附带缓存刷新参数；显式设置 `INST_RAW_BASE_URL` 时只使用该源，不跳到公共发布通道。`INST_NO_UPDATE_CHECK=1` 关闭检查。无法获取时显示“在线: 不可用”，不会误报“已是最新版”；`-Version` / `--version` 仍然只输出本地版本，不联网。

更新前重新获取清单，从相应源下载并校验脚本版本和语法；清单与脚本版本不一致、下载到旧版本或备份失败时不替换本地脚本。`INST_FORCE_UPDATE=1` 允许重新下载相同版本，但不允许降级。在线版本号大于本地时，通过 `00` → `1` 更新本地快捷命令，再重新运行 `inst`。
''' + readme[b:]
write('README.md', readme)

# The branch-only preparation files never enter the final PR tree.
Path('tools/prepare-menu-version.py').unlink()
print('Applied focused menu/version changes; preparation script removed.')
