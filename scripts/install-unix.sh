#!/usr/bin/env bash
# inst: macOS / Linux / WSL 开发环境安装器。需兼容 macOS 自带的 bash 3.2。
set -Eeuo pipefail

INST_VERSION="1.0.0"

# ---------------------------------------------------------------- 默认配置
DRY_RUN=0; ASSUME_YES=0; INTERACTIVE=0; QUIET=0
DO_NODE=0; DO_PYTHON=0; DO_MIRRORS=0; DO_AGENTS=0; DO_DESKTOP=0; DO_ENDPOINT=0
DO_CHECK=0; DO_UPDATE=0; DO_SELF_UPDATE=0; DO_SHORTCUT=0; DO_MENU=0
APPLY_SYSTEM_MIRROR=0; WITH_BUILD_DEPS=0
BASE_URL="${INST_RAW_BASE_URL:-${INST_SELECTED_BASE_URL:-https://inst.linux.yun}}"
PREFIX="${INST_PREFIX:-$HOME/.local/inst}"
ENV_DIR="${INST_ENV_DIR:-$HOME/.config/inst}"
ENV_FILE="$ENV_DIR/env.sh"
BIN_DIR="${INST_BIN_DIR:-$HOME/.local/bin}"
SHORTCUT_NAME="${INST_SHORTCUT:-inst}"
SHELL_RC="${INST_SHELL_RC:-}"
REGION="${INST_REGION:-auto}"
MIRROR_PRESET="${INST_MIRROR_PRESET:-}"
NPM_REGISTRY="${INST_NPM_REGISTRY:-}"
PIP_INDEX="${INST_PIP_INDEX:-}"
SYSTEM_MIRROR="${INST_SYSTEM_MIRROR:-}"
NODE_MIRROR="${INST_NODE_MIRROR:-}"
PYTHON_MIRROR="${INST_PYTHON_MIRROR:-}"
CONDA_MIRROR="${INST_CONDA_MIRROR:-}"
GH_PROXY="${INST_GH_PROXY:-}"
PYTHON_VERSION="${INST_PYTHON_VERSION:-latest}"
AGENT_IDS="${INST_AGENTS:-}"
AGENT_METHOD="${INST_AGENT_METHOD:-auto}"
AGENT_PACKAGES="${INST_AGENT_PACKAGES:-}"
DESKTOP_APPS="${INST_DESKTOP_APPS:-claude,codex}"
DESKTOP_DIR="${INST_DESKTOP_DIR:-}"
ENDPOINT_AGENTS="${INST_ENDPOINT_AGENTS:-}"
ENDPOINT_URL="${INST_BASE_URL:-${INST_AGENT_API_URL:-}}"
ENDPOINT_KEY="${INST_API_KEY:-}"
ENDPOINT_MODEL="${INST_MODEL:-}"
ANTHROPIC_URL="${INST_ANTHROPIC_BASE_URL:-}"
OPENAI_URL="${INST_OPENAI_BASE_URL:-}"
DEFAULT_AGENTS="claude,codex,gemini,opencode"

# ---------------------------------------------------------------- 输出与交互
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_0=$'\033[0m'; C_B=$'\033[1m'; C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'; C_D=$'\033[2m'
else
  C_0=''; C_B=''; C_R=''; C_G=''; C_Y=''; C_C=''; C_D=''
fi
log(){ ((QUIET)) || printf '%s[inst]%s %s\n' "$C_C" "$C_0" "$*"; }
ok(){ ((QUIET)) || printf '%s[ ok ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn(){ printf '%s[warn]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err(){ printf '%s[fail]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
step(){ ((QUIET)) || printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }
die(){ err "$1"; exit "${2:-1}"; }

HAS_TTY=0
if [[ -z "${INST_NO_TTY:-}" && -r /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; then HAS_TTY=1; fi

# ask VAR "提示" [默认值]：从终端读取，管道运行时同样可用。
ask(){
  local __var="$1" __prompt="$2" __default="${3:-}" __reply=''
  if ((HAS_TTY)); then
    if [[ -n "$__default" ]]; then printf '%s %s[%s]%s: ' "$__prompt" "$C_D" "$__default" "$C_0" > /dev/tty
    else printf '%s: ' "$__prompt" > /dev/tty; fi
    IFS= read -r __reply < /dev/tty || true
  fi
  [[ -z "$__reply" ]] && __reply="$__default"
  printf -v "$__var" '%s' "$__reply"
}
ask_secret(){
  local __var="$1" __prompt="$2" __reply=''
  if ((HAS_TTY)); then
    printf '%s: ' "$__prompt" > /dev/tty
    IFS= read -rs __reply < /dev/tty || true
    printf '\n' > /dev/tty
  fi
  printf -v "$__var" '%s' "$__reply"
}
confirm(){
  ((ASSUME_YES)) && return 0
  ((HAS_TTY)) || return 1
  local answer
  ask answer "$1 (y/N)" "${2:-n}"
  case "$answer" in y|Y|yes|YES) return 0;; *) return 1;; esac
}
pause(){ ((HAS_TTY)) || return 0; local _; printf '%s按回车键继续...%s' "$C_D" "$C_0" > /dev/tty; IFS= read -r _ < /dev/tty || true; }

run(){
  if ((DRY_RUN)); then printf '+ %q' "$1"; shift; (($#)) && printf ' %q' "$@"; printf '\n'; else "$@"; fi
}
have(){ command -v "$1" >/dev/null 2>&1; }
need(){ have "$1" || { err "缺少 $1，请先安装后重试"; return 1; }; }
as_root(){
  if [[ "$(id -u)" == 0 ]]; then run "$@"
  elif have sudo; then run sudo "$@"
  else err '需要 root 权限，但未找到 sudo'; return 1; fi
}
assert_https(){
  case "$1" in https://?*.?*|https://localhost*) return 0;; *) err "$2 必须是 HTTPS URL"; return 1;; esac
}
csv_has(){ case ",$1," in *",$2,"*) return 0;; *) return 1;; esac; }
version_gt(){ # a > b，按数字逐段比较
  local IFS=. i; local -a a b
  a=($1); b=($2)
  for ((i=0; i<${#a[@]} || i<${#b[@]}; i++)); do
    (( 10#${a[i]:-0} > 10#${b[i]:-0} )) && return 0
    (( 10#${a[i]:-0} < 10#${b[i]:-0} )) && return 1
  done
  return 1
}

# ---------------------------------------------------------------- 平台识别
OS_NAME="$(uname -s)"; ARCH="$(uname -m)"
case "$OS_NAME" in
  Darwin) PLATFORM=macOS;;
  Linux) PLATFORM=Linux;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM=Windows;;
  *) die "不支持的平台: $OS_NAME" 1;;
esac
IS_WSL=0; DISTRO_ID=''; DISTRO_LIKE=''; DISTRO_CODENAME=''; DISTRO_VERSION=''; PKG=''
if [[ "$PLATFORM" == Linux ]]; then
  grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=1
  if [[ -r /etc/os-release ]]; then
    DISTRO_ID="$(. /etc/os-release; printf '%s' "${ID:-}")"
    DISTRO_LIKE="$(. /etc/os-release; printf '%s' "${ID_LIKE:-}")"
    DISTRO_CODENAME="$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}")"
    DISTRO_VERSION="$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")"
  fi
  for p in apt-get dnf yum pacman apk zypper; do have "$p" && { PKG="$p"; break; }; done
elif [[ "$PLATFORM" == macOS ]]; then
  DISTRO_ID=macos; DISTRO_VERSION="$(sw_vers -productVersion 2>/dev/null || true)"
  have brew && PKG=brew
fi
LOGIN_SHELL="$(basename "${SHELL:-/bin/sh}")"; LOGIN_SHELL="${LOGIN_SHELL%.exe}"

platform_label(){
  local label="$PLATFORM"
  [[ "$PLATFORM" == Linux && -n "$DISTRO_ID" ]] && label="$DISTRO_ID ${DISTRO_VERSION}"
  [[ "$PLATFORM" == macOS ]] && label="macOS ${DISTRO_VERSION}"
  ((IS_WSL)) && label="$label (WSL)"
  printf '%s %s' "$label" "$ARCH"
}

# ---------------------------------------------------------------- 区域与镜像预设
detect_region(){
  case "$REGION" in cn|global) return 0;; esac
  local country
  country="$(curl -fsS --max-time 3 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -z "$country" ]]; then
    curl -fsS -o /dev/null --max-time 3 https://www.google.com 2>/dev/null && country=XX || country=CN
  fi
  if [[ "$country" == CN ]]; then REGION=cn; else REGION=global; fi
}
mirror_site(){
  case "$1" in
    tuna) echo https://mirrors.tuna.tsinghua.edu.cn;;
    aliyun) echo https://mirrors.aliyun.com;;
    ustc) echo https://mirrors.ustc.edu.cn;;
    tencent) echo https://mirrors.cloud.tencent.com;;
    huawei) echo https://repo.huaweicloud.com;;
    *) return 1;;
  esac
}
preset_pip(){
  case "$1" in
    tuna) echo https://pypi.tuna.tsinghua.edu.cn/simple;;
    aliyun) echo https://mirrors.aliyun.com/pypi/simple/;;
    ustc) echo https://mirrors.ustc.edu.cn/pypi/simple;;
    tencent) echo https://mirrors.cloud.tencent.com/pypi/simple;;
    huawei) echo https://repo.huaweicloud.com/repository/pypi/simple;;
    official) echo https://pypi.org/simple;;
  esac
}
preset_npm(){
  case "$1" in
    tencent) echo https://mirrors.cloud.tencent.com/npm/;;
    huawei) echo https://repo.huaweicloud.com/repository/npm/;;
    official) echo https://registry.npmjs.org/;;
    *) echo https://registry.npmmirror.com;;
  esac
}
preset_conda(){
  case "$1" in
    ustc) echo https://mirrors.ustc.edu.cn/anaconda;;
    aliyun) echo https://mirrors.aliyun.com/anaconda;;
    official) echo '';;
    *) echo https://mirrors.tuna.tsinghua.edu.cn/anaconda;;
  esac
}
# 中国区域默认使用镜像下载 Node 与 Python 源码包；显式参数优先。
apply_region_defaults(){
  detect_region
  if [[ "$REGION" == cn ]]; then
    [[ -n "$NODE_MIRROR" ]] || NODE_MIRROR=https://npmmirror.com/mirrors/node
    [[ -n "$PYTHON_MIRROR" ]] || PYTHON_MIRROR=https://registry.npmmirror.com/-/binary/python
    [[ -n "$CONDA_MIRROR" ]] || CONDA_MIRROR="$(preset_conda "${MIRROR_PRESET:-tuna}")"
  fi
}
gh_url(){
  case "$1" in
    https://github.com/*|https://raw.githubusercontent.com/*|https://objects.githubusercontent.com/*)
      if [[ -n "$GH_PROXY" ]]; then printf '%s/%s' "${GH_PROXY%/}" "$1"; return; fi;;
  esac
  printf '%s' "$1"
}

# BEGIN GENERATED DOWNLOAD
# Embedded into standalone entry points by tools/embed-download.mjs.
# Arguments: URL destination [expected SHA256] [start seconds] [idle seconds].
inst_download_attempt() (
  url=$1 out=$2 expected=${3:-} start=${4:-30} idle=${5:-120}
  case "$url" in https://*@*) echo 'download: credentials in URL not supported' >&2; exit 2;; https://*) ;; *) echo 'download: HTTPS required' >&2; exit 2;; esac
  dir=$(mktemp -d "${out}.part.XXXXXX") || exit 1
  pid='' deadline=''
  cleanup() {
    [ -z "$pid" ] || { kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; }
    [ -z "$deadline" ] || { kill "$deadline" 2>/dev/null || :; wait "$deadline" 2>/dev/null || :; }
    rm -rf "$dir"
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # One deadline across DNS, connect, TLS, all redirects, headers and prefix.
  sleep "$start" & deadline=$!
  curl --proto '=https' --proto-redir '=https' -fsSL --retry 0 \
    --connect-timeout 20 --max-redirs 5 --no-buffer \
    -D "$dir/headers" "$url" -o "$dir/body" & pid=$!
  started=0 previous=0 quiet=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$started" -eq 0 ] && ! kill -0 "$deadline" 2>/dev/null; then
      echo 'download: start deadline exceeded' >&2; exit 28
    fi
    size=0
    [ ! -f "$dir/body" ] || size=$(wc -c < "$dir/body" | tr -d ' ')
    if [ "$started" -eq 0 ] && [ "$size" -ge 512 ]; then
      inst_download_prefix "$url" "$dir/body" "$dir/headers" || exit 65
      started=1
      kill "$deadline" 2>/dev/null || :; wait "$deadline" 2>/dev/null || :; deadline=''
    fi
    if [ "$started" -eq 1 ]; then
      if [ "$size" -gt "$previous" ]; then quiet=0; else quiet=$((quiet + 1)); fi
      if [ "$quiet" -ge "$idle" ]; then echo 'download: no progress deadline exceeded' >&2; exit 28; fi
    fi
    previous=$size
    sleep 1
  done
  rc=0; wait "$pid" || rc=$?; pid=''
  [ "$rc" -eq 0 ] || { echo "download: transport failed ($rc)" >&2; exit "$rc"; }
  if [ "$started" -eq 0 ] && ! kill -0 "$deadline" 2>/dev/null; then echo 'download: start deadline exceeded' >&2; exit 28; fi
  [ -s "$dir/body" ] || { echo 'download: empty response' >&2; exit 65; }
  inst_download_prefix "$url" "$dir/body" "$dir/headers" || exit 65
  if [ -n "$expected" ]; then
    if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$dir/body"); else actual=$(shasum -a 256 "$dir/body"); fi
    [ "${actual%% *}" = "$expected" ] || { echo 'download: SHA256 mismatch' >&2; exit 65; }
  fi
  mv -f "$dir/body" "$out"
)
inst_download_prefix() {
  http_status=$(awk '/^HTTP\// { code=$2 } END { print code }' "$3")
  [ "$http_status" = 200 ] || { echo "download: HTTP ${http_status:-missing status}" >&2; return 1; }
  # Reject error pages even when a server incorrectly returns 200/octet-stream.
  if awk '/^HTTP\// { type="" } tolower($0) ~ /^content-type:/ { type=$0 } END { print type }' "$3" | grep -Eiq '^content-type:.*(text/html|application/(json|problem\+json))' \
    || head -c 512 "$2" | LC_ALL=C grep -Eiq '<(!doctype[[:space:]]+html|html|head|body)([[:space:]>])'; then
    echo 'download: unexpected error document' >&2; return 1
  fi
  magic=$(od -An -tx1 -N4 "$2" | tr -d ' \n')
  case "${1%%\?*}" in
    *.zip|*.msix) case "$magic" in 504b0304*) ;; *) echo 'download: invalid ZIP prefix' >&2; return 1;; esac;;
    *.exe) case "$magic" in 4d5a*) ;; *) echo 'download: invalid EXE prefix' >&2; return 1;; esac;;
    *.sh) case "$magic" in 2321*) ;; *) echo 'download: invalid script prefix' >&2; return 1;; esac;;
    *.asc) head -c 512 "$2" | grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----' || { echo 'download: invalid PGP prefix' >&2; return 1; };;
    *.ps1) case "$magic" in 23*|efbbbf23*) ;; *) echo 'download: invalid PowerShell prefix' >&2; return 1;; esac;;
    *) [ "$(wc -c < "$2" | tr -d ' ')" -ge 512 ] || { echo 'download: unrecognized short response' >&2; return 1; };;
  esac
}
inst_download_candidates() {
  printf '%s\n' "$1"
  # Exact public paths only: never mirror queries, credentials, custom hosts or proxies.
  case "$1" in
    https://inst.linux.yun/scripts/install-unix.sh|https://inst.linux.yun/scripts/install-windows.ps1|https://inst.linux.yun/install.sh|https://inst.linux.yun/install.ps1)
      [ -z "${INST_RAW_BASE_URL:-}" ] && [ "${INST_MIRROR_AUTO:-1}" != 0 ] || return 0
      printf 'https://raw.githubusercontent.com/58cdn/inst/master/%s\n' "${1#https://inst.linux.yun/}";;
    https://raw.githubusercontent.com/58cdn/inst/master/scripts/install-unix.sh|https://raw.githubusercontent.com/58cdn/inst/master/scripts/install-windows.ps1|https://raw.githubusercontent.com/58cdn/inst/master/install.sh|https://raw.githubusercontent.com/58cdn/inst/master/install.ps1)
      [ -z "${INST_RAW_BASE_URL:-}" ] && [ "${INST_MIRROR_AUTO:-1}" != 0 ] || return 0
      printf 'https://inst.linux.yun/%s\n' "${1#https://raw.githubusercontent.com/58cdn/inst/master/}";;
  esac
  # Miniconda mutable aliases are only portable with a pinned digest.
  if [ -n "${2:-}" ]; then
    case "$1" in
      https://repo.anaconda.com/miniconda/Miniconda3-*) suffix=${1#https://repo.anaconda.com/miniconda/};;
      https://mirrors.tuna.tsinghua.edu.cn/anaconda/miniconda/Miniconda3-*) suffix=${1#https://mirrors.tuna.tsinghua.edu.cn/anaconda/miniconda/};;
      *) return 0;;
    esac
    case "$suffix" in *[!a-zA-Z0-9._-]*) return 0;; esac
    for base in https://repo.anaconda.com/miniconda https://mirrors.tuna.tsinghua.edu.cn/anaconda/miniconda; do
      [ "$base/$suffix" = "$1" ] || printf '%s/%s\n' "$base" "$suffix"
    done
  fi
}
inst_download() (
  rc=1 index=0
  candidates=$(inst_download_candidates "$1" "${3:-}")
  while IFS= read -r candidate; do
    index=$((index + 1))
    if inst_download_attempt "$candidate" "$2" "${3:-}"; then
      [ -z "${4:-}" ] || printf '%s' "$candidate" > "$4"
      exit 0
    else rc=$?; fi
    echo "download: attempt failed ($rc); candidate $index" >&2
    case "$rc" in 130|143) exit "$rc";; esac
  done <<EOF_CANDIDATES
$candidates
EOF_CANDIDATES
  echo 'download: candidates exhausted' >&2
  exit "$rc"
)
# END GENERATED DOWNLOAD

# ---------------------------------------------------------------- 下载
download(){
  local url="$1" out="$2"
  if ((DRY_RUN)); then printf '+ download %q -> %q\n' "$url" "$out"; return 0; fi
  inst_download "$url" "$out" "${3:-}"
}
# 下载到临时文件再执行，避免执行半截脚本。
official_script(){
  local url="$1"; shift
  if ((DRY_RUN)); then printf '+ download and execute %q' "$url"; (($#)) && printf ' %q' "$@"; printf '\n'; return 0; fi
  need curl || return 1
  local script_file rc=0
  script_file="$(mktemp)"
  inst_download "$url" "$script_file" || rc=$?
  if ((rc == 0)); then bash "$script_file" "$@" < /dev/null || rc=$?; fi
  rm -f "$script_file"
  return "$rc"
}
github_latest_tag(){
  local repo="$1" fallback="$2" tag=''
  ((DRY_RUN)) || tag="$(curl -fsSL --max-time 6 "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  printf '%s' "${tag:-$fallback}"
}

# ---------------------------------------------------------------- 环境文件
# 所有持久化配置写入 ENV_FILE 中带标记的块，shell rc 只需 source 一次。
env_block(){
  local id="$1" content="$2"
  if ((DRY_RUN)); then log "将写入 $ENV_FILE [$id]"; return 0; fi
  mkdir -p "$ENV_DIR"
  [[ -f "$ENV_FILE" ]] || printf '# 由 inst 管理，可安全删除对应块\n' > "$ENV_FILE"
  local tmp; tmp="$(mktemp)"
  awk -v id="$id" '$0=="# >>> inst:" id {skip=1; next} $0=="# <<< inst:" id {skip=0; next} !skip' "$ENV_FILE" > "$tmp"
  if [[ -n "$content" ]]; then printf '# >>> inst:%s\n%s\n# <<< inst:%s\n' "$id" "$content" "$id" >> "$tmp"; fi
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
  chmod 600 "$ENV_FILE"
  ensure_rc_hook
}
env_var(){ # env_var NAME VALUE；VALUE 为空时删除
  local line=''
  [[ -n "$2" ]] && printf -v line 'export %s=%q' "$1" "$2"
  env_block "var:$1" "$line"
  if ((!DRY_RUN)); then if [[ -n "$2" ]]; then export "$1=$2"; else unset "$1"; fi; fi
}
env_path(){ # env_path ID DIR
  env_block "path:$1" "case \":\$PATH:\" in *\":$2:\"*) ;; *) export PATH=\"$2:\$PATH\";; esac"
  case ":$PATH:" in *":$2:"*) ;; *) export PATH="$2:$PATH";; esac
}
rc_files(){
  if [[ -n "$SHELL_RC" ]]; then echo "$SHELL_RC"; return; fi
  echo "$HOME/.profile"
  if [[ -f "$HOME/.bashrc" || "$LOGIN_SHELL" == bash ]]; then echo "$HOME/.bashrc"; fi
  if [[ "$PLATFORM" == macOS && ( -f "$HOME/.bash_profile" || "$LOGIN_SHELL" == bash ) ]]; then echo "$HOME/.bash_profile"; fi
  if [[ -f "$HOME/.zshrc" || "$LOGIN_SHELL" == zsh ]] || have zsh; then echo "$HOME/.zshrc"; fi
}
ensure_rc_hook(){
  local hook='[ -f "$HOME/.config/inst/env.sh" ] && . "$HOME/.config/inst/env.sh"'
  [[ "$ENV_FILE" == "$HOME/.config/inst/env.sh" ]] || hook="[ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\""
  local rc
  while IFS= read -r rc; do
    [[ -n "$rc" ]] || continue
    touch "$rc"
    grep -Fqx "$hook" "$rc" 2>/dev/null || printf '\n# inst\n%s\n' "$hook" >> "$rc"
  done < <(rc_files)
  if [[ "$LOGIN_SHELL" == fish ]]; then warn 'fish 需手动加载: bass source ~/.config/inst/env.sh（或改用 bash/zsh）'; fi
}
load_env(){ set +eu; [[ -f "$ENV_FILE" ]] && . "$ENV_FILE"; set -eu; }

# ---------------------------------------------------------------- Node.js
nvm_do(){ local rc=0; set +eu; nvm "$@" || rc=$?; set -eu; return "$rc"; }
load_nvm(){ export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"; [[ -s "$NVM_DIR/nvm.sh" ]] || return 1; set +eu; . "$NVM_DIR/nvm.sh"; set -eu; }
npm_global(){
  local -a extra=()
  [[ -n "$NPM_REGISTRY" ]] && extra=(--registry "$NPM_REGISTRY")
  run npm install --global "$@" ${extra[@]+"${extra[@]}"}
}
install_node(){
  step 'Node.js: nvm / Node.js LTS / npm / pnpm'
  apply_region_defaults
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  [[ -n "$NODE_MIRROR" ]] && export NVM_NODEJS_ORG_MIRROR="$NODE_MIRROR"
  if ((DRY_RUN)); then
    [[ -s "$NVM_DIR/nvm.sh" ]] || printf '+ download and execute %q\n' "$(gh_url "https://raw.githubusercontent.com/nvm-sh/nvm/$(github_latest_tag nvm-sh/nvm v0.40.3)/install.sh")"
    run nvm install --lts; run nvm alias default 'lts/*'; run nvm use default; run npm install --global pnpm
    env_block nvm 'nvm.sh'
    return 0
  fi
  if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    need curl; need git
    local tag; tag="$(github_latest_tag nvm-sh/nvm v0.40.3)"
    log "安装 nvm $tag 到 $NVM_DIR"
    PROFILE=/dev/null NVM_SOURCE="$(gh_url https://github.com/nvm-sh/nvm.git)" \
      official_script "$(gh_url "https://raw.githubusercontent.com/nvm-sh/nvm/$tag/install.sh")"
  else
    log "复用已有 nvm: $NVM_DIR"
  fi
  load_nvm || { err "安装后未找到 $NVM_DIR/nvm.sh"; return 1; }
  local block='export NVM_DIR="$HOME/.nvm"'
  [[ "$NVM_DIR" == "$HOME/.nvm" ]] || printf -v block 'export NVM_DIR=%q' "$NVM_DIR"
  [[ -n "$NODE_MIRROR" ]] && block="$block"$'\n'"export NVM_NODEJS_ORG_MIRROR=$NODE_MIRROR"
  block="$block"$'\n''[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
  env_block nvm "$block"
  nvm_do install --lts
  nvm_do alias default 'lts/*'
  nvm_do use default
  npm_global pnpm
  ok "node $(node --version)  npm $(npm --version)  pnpm $(pnpm --version 2>/dev/null || echo '?')"
}

# ---------------------------------------------------------------- Python
python_build_deps(){
  case "$PKG" in
    apt-get) echo 'build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev curl git libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev';;
    dnf|yum) echo 'make gcc patch zlib-devel bzip2 bzip2-devel readline-devel sqlite sqlite-devel openssl-devel tk-devel libffi-devel xz-devel libuuid-devel gdbm-libs libnsl2 git';;
    pacman) echo 'base-devel openssl zlib xz tk git';;
    apk) echo 'git bash build-base libffi-dev openssl-dev bzip2-dev zlib-dev xz-dev readline-dev sqlite-dev tk-dev';;
    zypper) echo 'gcc automake bzip2 libbz2-devel xz xz-devel openssl-devel ncurses-devel readline-devel zlib-devel tk-devel libffi-devel sqlite3-devel gdbm-devel make findutils patch git';;
    brew) echo 'openssl readline sqlite3 xz zlib tcl-tk@8 libb2 zstd pkgconfig';;
  esac
}
install_build_deps(){
  local deps; deps="$(python_build_deps)"
  [[ -n "$deps" ]] || { warn '未识别包管理器，请参考 pyenv 文档安装编译依赖'; return 0; }
  if ((!WITH_BUILD_DEPS)) && ! { ((INTERACTIVE)) && confirm "安装 Python 编译依赖 ($PKG)"; }; then
    warn "如编译失败，请先安装依赖: $PKG install $deps"
    return 0
  fi
  local -a list; IFS=' ' read -r -a list <<< "$deps"
  case "$PKG" in
    apt-get) as_root apt-get update; as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${list[@]}";;
    dnf|yum) as_root "$PKG" install -y "${list[@]}";;
    pacman) as_root pacman -S --needed --noconfirm "${list[@]}";;
    apk) as_root apk add --no-cache "${list[@]}";;
    zypper) as_root zypper --non-interactive install "${list[@]}";;
    brew) run brew install "${list[@]}";;
  esac
}
resolve_python_version(){
  local requested="$1" list
  if [[ "$requested" != latest && ! "$requested" =~ ^3\.[0-9]+(\.[0-9]+)?$ ]]; then
    err 'Python 版本必须是 latest、3.x 或 3.x.y'; return 1
  fi
  list="$(pyenv install --list | sed -E 's/^[[:space:]]+//' | awk '/^3\.[0-9]+\.[0-9]+$/')"
  [[ "$requested" == latest ]] || list="$(printf '%s\n' "$list" | awk -v r="$requested" '$0==r || index($0, r ".")==1')"
  printf '%s\n' "$list" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}
install_python(){
  step 'Python: pyenv / Python / Miniconda'
  apply_region_defaults
  local pyenv_root="${PYENV_ROOT:-$HOME/.pyenv}"
  install_build_deps
  if [[ ! -d "$pyenv_root" ]]; then
    ((DRY_RUN)) || need git
    run git clone --depth 1 "$(gh_url https://github.com/pyenv/pyenv.git)" "$pyenv_root"
    run git clone --depth 1 "$(gh_url https://github.com/pyenv/pyenv-virtualenv.git)" "$pyenv_root/plugins/pyenv-virtualenv"
  else
    log "复用已有 pyenv: $pyenv_root"
  fi
  export PYENV_ROOT="$pyenv_root"
  export PATH="$pyenv_root/bin:$pyenv_root/shims:$PATH"
  local block
  printf -v block 'export PYENV_ROOT=%q' "$pyenv_root"
  block="$block"$'\n''case ":$PATH:" in *":$PYENV_ROOT/bin:"*) ;; *) export PATH="$PYENV_ROOT/bin:$PATH";; esac'
  if [[ -n "$PYTHON_MIRROR" ]]; then
    block="$block"$'\n'"export PYTHON_BUILD_MIRROR_URL=$PYTHON_MIRROR"$'\n''export PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM=1'
    export PYTHON_BUILD_MIRROR_URL="$PYTHON_MIRROR" PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM=1
  fi
  block="$block"$'\n''if command -v pyenv >/dev/null 2>&1; then
  if [ -n "$BASH_VERSION" ]; then eval "$(pyenv init - bash)"; elif [ -n "$ZSH_VERSION" ]; then eval "$(pyenv init - zsh)"; else export PATH="$PYENV_ROOT/shims:$PATH"; fi
fi'
  env_block pyenv "$block"

  local version="$PYTHON_VERSION"
  if ((DRY_RUN)); then
    [[ "$version" == latest ]] && version='3.x-latest'
  else
    version="$(resolve_python_version "$PYTHON_VERSION")"
    [[ -n "$version" ]] || { err "pyenv 没有返回匹配 $PYTHON_VERSION 的稳定版本"; return 1; }
    log "选择 Python $version"
  fi
  run pyenv install -s "$version"
  run pyenv global "$version"
  install_miniconda
}
install_miniconda(){
  local conda_root="${INST_CONDA_DIR:-$HOME/miniconda3}" conda_os=Linux conda_arch=x86_64
  if [[ -x "$conda_root/bin/conda" ]]; then log "复用已有 Miniconda: $conda_root"
  elif [[ -e "$conda_root" ]]; then err "Miniconda 目录已存在但不完整: $conda_root"; return 1
  else
    [[ "$PLATFORM" == macOS ]] && conda_os=MacOSX
    case "$ARCH" in arm64|aarch64) [[ "$PLATFORM" == macOS ]] && conda_arch=arm64 || conda_arch=aarch64;; esac
    local file="Miniconda3-latest-${conda_os}-${conda_arch}.sh" site=https://repo.anaconda.com/miniconda
    [[ "$REGION" == cn ]] && site="$(preset_conda "${MIRROR_PRESET:-tuna}")/miniconda"
    local installer="$PREFIX/$file"
    run mkdir -p "$PREFIX"
    local digest=''
    if ((!DRY_RUN)); then
      digest=$(curl --proto '=https' --proto-redir '=https' -fsSL --max-time 30 --max-redirs 5 https://repo.anaconda.com/miniconda/ \
        | tr '\n' ' ' | sed 's@</tr>@\n@g' | grep -F ""$file"" | grep -Eo '[0-9a-f]{64}' | head -n 1) || return 1
      [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { err 'Miniconda 官方 SHA256 不可用'; return 1; }
    fi
    download "$site/$file" "$installer" "$digest"
    run bash "$installer" -b -p "$conda_root"
    run rm -f "$installer"
    if ((!DRY_RUN)) && [[ ! -x "$conda_root/bin/conda" ]]; then err "Miniconda 安装后未找到 conda: $conda_root"; return 1; fi
  fi
  # 只提供 conda 命令，不自动激活 base，避免覆盖 pyenv 的 python。
  env_block conda "[ -f \"$conda_root/etc/profile.d/conda.sh\" ] && . \"$conda_root/etc/profile.d/conda.sh\""
  [[ -n "$CONDA_MIRROR" ]] && mirror_conda "$CONDA_MIRROR"
  return 0
}

# ---------------------------------------------------------------- 镜像
mirror_npm(){
  local url="$1"
  assert_https "$url" NPM_REGISTRY || return 2
  load_env
  if have npm; then run npm config set registry "$url"
  else
    ((DRY_RUN)) && { log "将写入 ~/.npmrc registry=$url"; return 0; }
    touch "$HOME/.npmrc"; local tmp; tmp="$(mktemp)"
    grep -v '^registry=' "$HOME/.npmrc" > "$tmp" || true
    printf 'registry=%s\n' "$url" >> "$tmp"; cat "$tmp" > "$HOME/.npmrc"; rm -f "$tmp"
  fi
  ok "npm / pnpm registry: $url"
}
pip_conf_file(){ echo "${PIP_CONFIG_FILE:-$HOME/.config/pip/pip.conf}"; }
mirror_pip(){
  local url="$1"
  assert_https "$url" PIP_INDEX || return 2
  load_env
  local py=''; for c in python3 python; do have "$c" && "$c" -m pip --version >/dev/null 2>&1 && { py="$c"; break; }; done
  if [[ -n "$py" ]]; then run "$py" -m pip config --user set global.index-url "$url"
  else
    local conf; conf="$(pip_conf_file)"
    ((DRY_RUN)) && { log "将写入 $conf index-url=$url"; return 0; }
    mkdir -p "$(dirname "$conf")"
    printf '[global]\nindex-url = %s\n' "$url" > "$conf"
  fi
  env_var UV_DEFAULT_INDEX "$url"
  ok "pip index-url: $url"
}
mirror_conda(){
  local base="$1" condarc="$HOME/.condarc"
  if ((DRY_RUN)); then log "将写入 $condarc (conda 镜像: ${base:-官方})"; return 0; fi
  [[ -f "$condarc" && ! -f "$condarc.inst.bak" ]] && cp "$condarc" "$condarc.inst.bak"
  if [[ -z "$base" ]]; then
    if [[ -f "$condarc.inst.bak" ]]; then mv "$condarc.inst.bak" "$condarc"; else rm -f "$condarc"; fi
    ok 'conda 已恢复官方源'; return 0
  fi
  cat > "$condarc" <<EOF
channels:
  - defaults
show_channel_urls: true
default_channels:
  - $base/pkgs/main
  - $base/pkgs/r
  - $base/pkgs/msys2
custom_channels:
  conda-forge: $base/cloud
  pytorch: $base/cloud
EOF
  ok "conda 镜像: $base"
}
mirror_brew(){
  local preset="$1" site
  if [[ "$preset" == official ]]; then
    for v in HOMEBREW_API_DOMAIN HOMEBREW_BOTTLE_DOMAIN HOMEBREW_BREW_GIT_REMOTE HOMEBREW_CORE_GIT_REMOTE HOMEBREW_PIP_INDEX_URL; do env_var "$v" ''; done
    ok 'Homebrew 已恢复官方源'; return 0
  fi
  case "$preset" in ustc|aliyun) ;; *) preset=tuna;; esac
  site="$(mirror_site "$preset")"
  # Homebrew 4.x 默认走 JSON API，homebrew-core 不再需要 git 镜像（USTC 已于 2026-06 停止该镜像），清理旧变量。
  env_var HOMEBREW_CORE_GIT_REMOTE ''
  case "$preset" in
    tuna)
      env_var HOMEBREW_API_DOMAIN "$site/homebrew-bottles/api"
      env_var HOMEBREW_BOTTLE_DOMAIN "$site/homebrew-bottles"
      env_var HOMEBREW_BREW_GIT_REMOTE "$site/git/homebrew/brew.git";;
    ustc)
      env_var HOMEBREW_API_DOMAIN "$site/homebrew-bottles/api"
      env_var HOMEBREW_BOTTLE_DOMAIN "$site/homebrew-bottles"
      env_var HOMEBREW_BREW_GIT_REMOTE "$site/brew.git";;
    aliyun)
      env_var HOMEBREW_API_DOMAIN "$site/homebrew-bottles/api"
      env_var HOMEBREW_BOTTLE_DOMAIN "$site/homebrew/homebrew-bottles"
      env_var HOMEBREW_BREW_GIT_REMOTE "$site/homebrew/brew.git";;
  esac
  ok "Homebrew 镜像: $preset"
}
mirror_toolchain(){ # nvm / pyenv 下载镜像
  local on="$1"
  if [[ "$on" == 1 ]]; then
    env_var NVM_NODEJS_ORG_MIRROR "${NODE_MIRROR:-https://npmmirror.com/mirrors/node}"
    env_var PYTHON_BUILD_MIRROR_URL "${PYTHON_MIRROR:-https://registry.npmmirror.com/-/binary/python}"
    env_var PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM 1
  else
    env_var NVM_NODEJS_ORG_MIRROR ''; env_var PYTHON_BUILD_MIRROR_URL ''; env_var PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM ''
  fi
}

# 系统源：备份原文件后替换主机名，可通过 official 恢复。
system_source_files(){
  case "$DISTRO_ID" in
    ubuntu|debian|linuxmint|pop|kali|raspbian)
      [[ -f /etc/apt/sources.list ]] && echo /etc/apt/sources.list
      for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
        [[ -f "$f" ]] || continue
        case "$f" in */inst.*) continue;; esac
        grep -Eq 'ubuntu|debian' "$f" && echo "$f"
      done;;
    alpine) echo /etc/apk/repositories;;
    rocky|almalinux|fedora|centos|rhel|ol|opencloudos|anolis)
      for f in /etc/yum.repos.d/*.repo; do [[ -f "$f" ]] && echo "$f"; done;;
    arch|manjaro) echo /etc/pacman.d/mirrorlist;;
  esac
}
mirror_system(){
  local target="$1"   # 预设名、official 或 https URL
  if [[ "$PLATFORM" == macOS ]]; then mirror_brew "$target"; return; fi
  local files; files="$(system_source_files)"
  [[ -n "$files" ]] || { err "暂不支持自动切换 ${DISTRO_ID:-未知发行版} 的系统源，可使用 https://linuxmirrors.cn"; return 2; }
  if [[ "$target" == official ]]; then
    ((APPLY_SYSTEM_MIRROR)) || confirm '恢复系统源备份' || { warn '已取消'; return 0; }
    local f restored=0
    while IFS= read -r f; do
      [[ -f "$f.inst.bak" ]] && { as_root mv "$f.inst.bak" "$f"; restored=1; }
    done <<< "$files"
    ((restored)) && ok '已恢复系统源备份' || warn '没有找到 inst 备份文件'
    return 0
  fi
  local site="$target"
  [[ "$target" == https://* ]] || site="$(mirror_site "$target")" || { err "未知镜像: $target"; return 2; }
  if [[ "$target" == tuna ]] && [[ "$DISTRO_ID" == rocky || "$DISTRO_ID" == almalinux ]]; then
    warn "清华镜像不提供 ${DISTRO_ID}，改用阿里云"; target=aliyun; site="$(mirror_site aliyun)"
  fi
  assert_https "$site" SYSTEM_MIRROR || return 2
  site="${site%/}"
  local rocky_path=rockylinux; [[ "$target" == ustc ]] && rocky_path=rocky
  log "将为 ${DISTRO_ID} 替换系统源为 ${site}，原文件备份为 *.inst.bak："
  printf '  %s\n' $files
  if ((!APPLY_SYSTEM_MIRROR)) && ! confirm '确认修改系统源'; then
    warn '未修改系统源；非交互模式请追加 --apply-system-mirror'; return 0
  fi
  local f expr=''
  case "$DISTRO_ID" in
    ubuntu|debian|linuxmint|pop|kali|raspbian)
      expr="s#https?://[^/[:space:]]+/(ubuntu-ports|ubuntu|debian-security|debian)([/[:space:]]|\$)#$site/\\1\\2#g";;
    alpine) expr="s#https?://[^/[:space:]]+/alpine/#$site/alpine/#g";;
    rocky) expr="s|^mirrorlist=|#mirrorlist=|; s|^#?baseurl=https?://[^/]+/(\\\$contentdir\|pub/rocky)|baseurl=$site/$rocky_path|";;
    almalinux) expr="s|^mirrorlist=|#mirrorlist=|; s|^#?baseurl=https?://[^/]+/almalinux|baseurl=$site/almalinux|";;
    fedora) expr="s|^metalink=|#metalink=|; s|^#?baseurl=https?://[^/]+/pub/fedora/linux|baseurl=$site/fedora|";;
    arch|manjaro)
      ((DRY_RUN)) || { [[ -f /etc/pacman.d/mirrorlist.inst.bak ]] || as_root cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.inst.bak; }
      printf 'Server = %s/archlinux/$repo/os/$arch\n' "$site" | { if ((DRY_RUN)); then cat; else as_root tee /etc/pacman.d/mirrorlist >/dev/null; fi; }
      ok '已更新 pacman mirrorlist'; return 0;;
    *) err "暂不支持 ${DISTRO_ID}，可使用 https://linuxmirrors.cn"; return 2;;
  esac
  while IFS= read -r f; do
    if ((!DRY_RUN)) && [[ ! -f "$f.inst.bak" ]]; then as_root cp "$f" "$f.inst.bak"; fi
    as_root sed -E -i "$expr" "$f"
  done <<< "$files"
  case "$PKG" in
    apt-get) as_root apt-get update;;
    dnf|yum) as_root "$PKG" makecache;;
    apk) as_root apk update;;
  esac
  ok "系统源已切换到 $site"
}
configure_mirrors(){
  step '镜像配置'
  apply_region_defaults
  local preset="$MIRROR_PRESET"
  [[ -z "$preset" && "$REGION" == cn ]] && preset=tuna
  [[ -z "$NPM_REGISTRY" && -n "$preset" ]] && NPM_REGISTRY="$(preset_npm "$preset")"
  [[ -z "$PIP_INDEX" && -n "$preset" ]] && PIP_INDEX="$(preset_pip "$preset")"
  [[ -z "$NPM_REGISTRY" ]] || assert_https "$NPM_REGISTRY" NPM_REGISTRY || return 2
  [[ -z "$PIP_INDEX" ]] || assert_https "$PIP_INDEX" PIP_INDEX || return 2
  if [[ -z "$NPM_REGISTRY$PIP_INDEX$SYSTEM_MIRROR$preset" ]]; then
    log '当前区域无需镜像；可用 --mirror-preset tuna|aliyun|ustc|tencent|huawei 指定'; return 0
  fi
  [[ -n "$NPM_REGISTRY" ]] && mirror_npm "$NPM_REGISTRY"
  [[ -n "$PIP_INDEX" ]] && mirror_pip "$PIP_INDEX"
  if [[ -n "$preset" ]]; then
    mirror_toolchain "$([[ "$preset" == official ]] && echo 0 || echo 1)"
    mirror_conda "$(preset_conda "$preset")"
  fi
  local sys="${SYSTEM_MIRROR:-$preset}"
  if [[ -n "$sys" ]]; then
    if [[ "$PLATFORM" == macOS ]]; then mirror_brew "$sys"
    elif [[ -n "$SYSTEM_MIRROR" || "$APPLY_SYSTEM_MIRROR" == 1 ]]; then mirror_system "$sys"
    else log "系统源未修改；如需切换请追加 --apply-system-mirror"; fi
  fi
}

# ---------------------------------------------------------------- Agents CLI
# id|名称|命令|npm 包|官方 Unix 安装脚本|脚本参数（跳过交互式引导）|升级命令
AGENT_TABLE='claude|Claude Code|claude|@anthropic-ai/claude-code|https://claude.ai/install.sh||claude update
codex|Codex CLI|codex|@openai/codex|https://chatgpt.com/codex/install.sh||codex update
gemini|Gemini CLI|gemini|@google/gemini-cli|||
opencode|OpenCode|opencode|opencode-ai|https://opencode.ai/install||opencode upgrade
grok|Grok Build|grok||https://x.ai/cli/install.sh||grok update
openclaw|OpenClaw|openclaw|openclaw|https://openclaw.ai/install.sh|--no-onboard|openclaw update
hermes|Hermes Agent|hermes||https://hermes-agent.nousresearch.com/install.sh|--skip-setup|hermes update
pi|Pi|pi|@earendil-works/pi-coding-agent|https://pi.dev/install.sh||pi update'
AGENT_ID=''; AGENT_NAME=''; AGENT_BIN=''; AGENT_NPM=''; AGENT_SCRIPT=''; AGENT_ARGS=''; AGENT_UPGRADE=''
agent_read(){ IFS='|' read -r AGENT_ID AGENT_NAME AGENT_BIN AGENT_NPM AGENT_SCRIPT AGENT_ARGS AGENT_UPGRADE <<< "$1"; }
agent_lookup(){
  local line
  while IFS= read -r line; do
    agent_read "$line"
    [[ "$AGENT_ID" == "$1" ]] && return 0
  done <<< "$AGENT_TABLE"
  return 1
}
agent_ids(){ printf '%s\n' "$AGENT_TABLE" | cut -d'|' -f1; }
install_agent(){
  local id="$1" method="${2:-$AGENT_METHOD}"
  agent_lookup "$id" || { err "未知 Agent: ${id}（可选: $(agent_ids | paste -sd, -)）"; return 2; }
  # auto：海外优先官方脚本；中国区域优先 npm（走镜像），官方脚本多依赖 GitHub / GCS。
  if [[ "$method" == auto ]]; then
    if [[ -n "$AGENT_SCRIPT" && ( "$REGION" != cn || -z "$AGENT_NPM" ) ]]; then method=official; else method=npm; fi
  fi
  [[ "$method" == official && -z "$AGENT_SCRIPT" ]] && { warn "$AGENT_NAME 无官方脚本，改用 npm"; method=npm; }
  [[ "$method" == npm && -z "$AGENT_NPM" ]] && { warn "$AGENT_NAME 无 npm 包，改用官方脚本"; method=official; }
  log "安装 $AGENT_NAME ($method)"
  if [[ "$method" == npm ]]; then
    load_env; ((DRY_RUN)) || need npm || return 1
    npm_global "$AGENT_NPM"
  else
    local -a script_args=(); [[ -z "$AGENT_ARGS" ]] || IFS=' ' read -r -a script_args <<< "$AGENT_ARGS"
    official_script "$(gh_url "$AGENT_SCRIPT")" ${script_args[@]+"${script_args[@]}"}
    env_path localbin "$HOME/.local/bin"
  fi
}
install_agents(){
  step 'Agents CLI'
  detect_region
  local ids="${AGENT_IDS:-}" id
  if [[ -n "$AGENT_PACKAGES" ]]; then # 兼容旧参数：直接安装 npm 包
    load_env; ((DRY_RUN)) || need npm || return 1
    local -a pkgs; IFS=',' read -r -a pkgs <<< "$AGENT_PACKAGES"
    for id in "${pkgs[@]}"; do [[ -n "$id" ]] && npm_global "$id"; done
    [[ -z "$ids" ]] && return 0
  fi
  [[ "$ids" == all ]] && ids="$(agent_ids | paste -sd, -)"
  [[ -n "$ids" ]] || ids="$DEFAULT_AGENTS"
  local -a list failed=(); IFS=',' read -r -a list <<< "$ids"
  for id in "${list[@]}"; do
    [[ -n "$id" ]] || continue
    install_agent "$id" || failed+=("$id")
  done
  ((${#failed[@]} == 0)) || { err "安装失败: ${failed[*]}"; return 1; }
}

# ---------------------------------------------------------------- 桌面端
# Claude：macOS 读取官方更新源 RELEASES.json 取 zip（dmg 跳转地址对脚本有 Cloudflare 校验）；Linux 使用官方 apt 源（beta）。
# Codex：桌面端现为 ChatGPT 应用，macOS dmg 仅 Apple Silicon，Linux 提供 deb / rpm。
CLAUDE_MAC_FEED='https://downloads.claude.ai/releases/darwin/universal/RELEASES.json'
CLAUDE_APT_REPO='https://downloads.claude.ai/claude-desktop/apt/stable'
CLAUDE_APT_KEY='https://downloads.claude.ai/claude-desktop/key.asc'
CODEX_APP_BASE='https://persistent.oaistatic.com/codex-app-prod'
claude_mac_url(){
  if ((DRY_RUN)); then
    log "将读取 $CLAUDE_MAC_FEED 获取最新版本" >&2
    echo 'https://downloads.claude.ai/releases/darwin/universal/latest/Claude.zip'; return 0
  fi
  local feed ver url
  feed="$(curl --proto '=https' --proto-redir '=https' -fsSL --max-time 20 "$CLAUDE_MAC_FEED")" || return 1
  ver="$(printf '%s' "$feed" | sed -n 's/.*"currentRelease" *: *"\([^"]*\)".*/\1/p')"
  url="$(printf '%s' "$feed" | tr ',' '\n' | sed -n 's/.*"url" *: *"\(https:[^"]*\.zip\)".*/\1/p' | grep -F "/$ver/" | head -n 1)"
  [[ -n "$url" ]] || url="$(printf '%s' "$feed" | tr ',' '\n' | sed -n 's/.*"url" *: *"\(https:[^"]*\.zip\)".*/\1/p' | head -n 1)"
  [[ -n "$url" ]] && printf '%s' "$url"
}
desktop_url(){ # 优先使用环境变量覆盖；apt / brew 表示交给包管理器
  local app="$1" var
  var="INST_DESKTOP_$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')_URL"
  if [[ -n "${!var:-}" ]]; then printf '%s' "${!var}"; return; fi
  case "$app:$PLATFORM" in
    claude:macOS) claude_mac_url;;
    claude:Linux) have apt-get && echo apt;;
    codex:macOS)
      if [[ "$ARCH" == arm64 ]]; then echo "$CODEX_APP_BASE/Codex.dmg"; elif have brew; then echo brew:chatgpt; fi;;
    codex:Linux)
      local deb_arch rpm_arch
      case "$ARCH" in x86_64|amd64) deb_arch=amd64; rpm_arch=x86_64;; aarch64|arm64) deb_arch=arm64; rpm_arch=aarch64;; *) return 0;; esac
      if have apt-get; then echo "$CODEX_APP_BASE/linux/deb/latest/chatgpt_$deb_arch.deb"
      elif have dnf || have yum || have zypper; then echo "$CODEX_APP_BASE/linux/rpm/latest/chatgpt.$rpm_arch.rpm"; fi;;
  esac
}
copy_app(){ # copy_app SRC.app DEST_DIR
  local app="$1" dest="$2"
  if ((DRY_RUN)); then printf '+ cp -R %q %q\n' "$app" "$dest/"; return 0; fi
  mkdir -p "$dest" 2>/dev/null || as_root mkdir -p "$dest"
  if [[ -w "$dest" ]]; then rm -rf "$dest/$(basename "$app")"; cp -R "$app" "$dest/"
  else as_root rm -rf "$dest/$(basename "$app")"; as_root cp -R "$app" "$dest/"; fi
  ok "已安装 $(basename "$app") 到 $dest"
}
install_dmg(){
  local dmg="$1" dest="$2" mnt app
  if ((DRY_RUN)); then printf '+ hdiutil attach %q; cp -R *.app %q\n' "$dmg" "$dest"; return 0; fi
  mnt="$(mktemp -d)"
  hdiutil attach -nobrowse -quiet -mountpoint "$mnt" "$dmg"
  app="$(find "$mnt" -maxdepth 1 -name '*.app' | head -n 1)"
  if [[ -z "$app" ]]; then hdiutil detach -quiet "$mnt"; err 'dmg 中未找到 .app'; return 1; fi
  copy_app "$app" "$dest"
  hdiutil detach -quiet "$mnt"; rmdir "$mnt" 2>/dev/null || true
}
install_app_zip(){
  local zip="$1" dest="$2" tmp app
  if ((DRY_RUN)); then printf '+ ditto -x -k %q TMP; cp -R TMP/*.app %q\n' "$zip" "$dest"; return 0; fi
  tmp="$(mktemp -d)"
  ditto -x -k "$zip" "$tmp"
  app="$(find "$tmp" -maxdepth 1 -name '*.app' | head -n 1)"
  if [[ -z "$app" ]]; then rm -rf "$tmp"; err 'zip 中未找到 .app'; return 1; fi
  copy_app "$app" "$dest"
  rm -rf "$tmp"
}
install_claude_apt(){
  log 'Claude Desktop Linux 版为官方 beta，添加 apt 源后安装 claude-desktop（安装目录由系统管理）'
  local key=/etc/apt/keyrings/claude-desktop.asc
  as_root install -d -m 755 /etc/apt/keyrings
  if ((DRY_RUN)); then printf '+ curl %q -o %q\n' "$CLAUDE_APT_KEY" "$key"
  else
    local key_tmp key_rc=0
    key_tmp=$(mktemp)
    inst_download "$CLAUDE_APT_KEY" "$key_tmp" || key_rc=$?
    if ((key_rc == 0)); then
      if ! grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----' "$key_tmp" || ! grep -q '^-----END PGP PUBLIC KEY BLOCK-----' "$key_tmp"; then
        err '无效的 apt 公钥'; key_rc=65
      else as_root install -m 644 "$key_tmp" "$key" || key_rc=$?; fi
    fi
    rm -f "$key_tmp"
    ((key_rc == 0)) || return "$key_rc"
  fi
  printf 'deb [signed-by=%s] %s stable main\n' "$key" "$CLAUDE_APT_REPO" \
    | { if ((DRY_RUN)); then cat; else as_root tee /etc/apt/sources.list.d/claude-desktop.list >/dev/null; fi; }
  as_root apt-get update
  as_root apt-get install -y claude-desktop
}
install_desktop(){
  step '桌面端'
  local dir="$DESKTOP_DIR" app url
  if [[ -z "$dir" ]]; then
    dir=/Applications; [[ "$PLATFORM" == macOS ]] || dir="$PREFIX/desktop"
    ((INTERACTIVE)) && ask dir '安装目录' "$dir"
  fi
  [[ -n "$DESKTOP_APPS" ]] || { warn '未选择桌面端应用'; return 0; }
  local -a apps failed=(); IFS=',' read -r -a apps <<< "$DESKTOP_APPS"
  for app in "${apps[@]}"; do
    [[ -n "$app" ]] || continue
    url="$(desktop_url "$app")" || url=''
    if [[ -z "$url" ]]; then
      warn "$app desktop 暂无 $PLATFORM/$ARCH 可用安装包，可用 INST_DESKTOP_$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')_URL 指定下载地址"
      continue
    fi
    case "$url" in
      apt) install_claude_apt || failed+=("$app"); continue;;
      brew:*) log "通过 Homebrew cask 安装 ${url#brew:}（Intel Mac）"; run brew install --cask --appdir="$dir" "${url#brew:}" || failed+=("$app"); continue;;
    esac
    assert_https "$url" "$app desktop URL" || return 2
    local cache="$PREFIX/desktop-cache" file
    case "$url" in
      *.AppImage) file="$cache/$app.AppImage";; *.deb) file="$cache/$app.deb";; *.rpm) file="$cache/$app.rpm";;
      *.zip) file="$cache/$app.zip";; *) file="$cache/$app.dmg";;
    esac
    if [[ "$file" == *.dmg || "$file" == *.zip ]] && [[ "$PLATFORM" != macOS ]]; then warn "$app desktop: $PLATFORM 无法安装 ${file##*.}，跳过"; continue; fi
    case "$file" in *.deb|*.rpm) [[ -z "$DESKTOP_DIR" ]] || warn "$app desktop 为系统包，忽略安装目录 $DESKTOP_DIR";; esac
    run mkdir -p "$cache"
    if ! download "$url" "$file"; then failed+=("$app"); continue; fi
    case "$file" in
      *.dmg) install_dmg "$file" "$dir";;
      *.zip) install_app_zip "$file" "$dir";;
      *.AppImage) run mkdir -p "$dir"; run install -m 755 "$file" "$dir/$app.AppImage"; ok "已放置 $dir/$app.AppImage";;
      *.deb) as_root apt-get install -y "$file";;
      *.rpm) if have dnf; then as_root dnf install -y "$file"; elif have zypper; then as_root zypper --non-interactive install "$file"; else as_root yum install -y "$file"; fi;;
    esac || failed+=("$app")
    ((DRY_RUN)) || rm -f "$file"
  done
  ((${#failed[@]} == 0)) || { err "桌面端安装失败: ${failed[*]}"; return 1; }
}

# ---------------------------------------------------------------- 地址配置
json_str(){ local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }
# json_merge FILE PATCH_JSON：深度合并到 JSON 文件，保留其他字段。
json_merge(){
  local file="$1" patch="$2"
  if ((DRY_RUN)); then log "将合并配置到 $file"; return 0; fi
  mkdir -p "$(dirname "$file")"
  load_env
  if have node; then
    node -e '
const fs=require("fs"),[f,p]=process.argv.slice(1);
let cur={};try{cur=JSON.parse(fs.readFileSync(f,"utf8"))}catch(e){if(fs.existsSync(f)&&fs.readFileSync(f,"utf8").trim()){console.error("无法解析 "+f);process.exit(3)}}
const m=(a,b)=>{for(const k of Object.keys(b)){if(b[k]&&typeof b[k]=="object"&&!Array.isArray(b[k])&&a[k]&&typeof a[k]=="object")m(a[k],b[k]);else if(b[k]===null)delete a[k];else a[k]=b[k]}return a};
fs.writeFileSync(f,JSON.stringify(m(cur,JSON.parse(p)),null,2)+"\n",{mode:0o600});' "$file" "$patch"
  elif have python3; then
    python3 - "$file" "$patch" <<'PY'
import json, os, sys
f, p = sys.argv[1], json.loads(sys.argv[2])
cur = {}
if os.path.exists(f) and open(f).read().strip():
    cur = json.load(open(f))
def m(a, b):
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(a.get(k), dict): m(a[k], v)
        elif v is None: a.pop(k, None)
        else: a[k] = v
    return a
with open(f, 'w') as fh: json.dump(m(cur, p), fh, indent=2, ensure_ascii=False); fh.write('\n')
os.chmod(f, 0o600)
PY
  else err '需要 node 或 python3 来修改 JSON 配置'; return 1; fi
}
# dotenv_set FILE KEY VALUE
dotenv_set(){
  local file="$1" key="$2" value="$3"
  if ((DRY_RUN)); then log "将写入 $file: $key"; return 0; fi
  mkdir -p "$(dirname "$file")"; touch "$file"; chmod 600 "$file"
  local tmp; tmp="$(mktemp)"
  grep -v "^$key=" "$file" > "$tmp" || true
  [[ -n "$value" ]] && printf '%s=%s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$file"; rm -f "$tmp"
}
toml_codex(){
  local file="$HOME/.codex/config.toml" url="$1" model="$2"
  if ((DRY_RUN)); then log "将写入 $file [model_providers.inst]"; return 0; fi
  mkdir -p "$(dirname "$file")"; touch "$file"
  local tmp; tmp="$(mktemp)"
  # 移除旧的 inst 提供方与顶层 model_provider，再写入新值。
  awk -v m="${model:+1}" '
    BEGIN { top=1 }
    /^[[:space:]]*\[/ { top=0; skip=($0 ~ /^[[:space:]]*\[model_providers\.inst\][[:space:]]*$/) }
    skip { next }
    top && /^[[:space:]]*model_provider[[:space:]]*=/ { next }
    top && m && /^[[:space:]]*model[[:space:]]*=/ { next }
    { print }
  ' "$file" | awk 'NF {blank=0} !NF {blank++} blank<2' > "$tmp"
  {
    printf 'model_provider = "inst"\n'
    [[ -n "$model" ]] && printf 'model = "%s"\n' "$model"
    cat "$tmp"
    printf '\n[model_providers.inst]\nname = "inst"\nbase_url = "%s"\nenv_key = "INST_CODEX_API_KEY"\nwire_api = "responses"\n' "$url"
  } > "$file"
  rm -f "$tmp"
}
configure_endpoint_for(){
  local id="$1" url="$2" key="$3" model="$4"
  assert_https "$url" "$id Base URL" || return 2
  url="${url%/}"
  case "$id" in
    claude)
      local env="{\"ANTHROPIC_BASE_URL\":$(json_str "$url")"
      [[ -n "$key" ]] && env="$env,\"ANTHROPIC_AUTH_TOKEN\":$(json_str "$key")"
      [[ -n "$model" ]] && env="$env,\"ANTHROPIC_MODEL\":$(json_str "$model")"
      json_merge "$HOME/.claude/settings.json" "{\"env\":$env}}"
      json_merge "$HOME/.claude.json" '{"hasCompletedOnboarding":true}';;
    codex)
      toml_codex "$url" "$model"
      [[ -n "$key" ]] && env_var INST_CODEX_API_KEY "$key";;
    gemini)
      dotenv_set "$HOME/.gemini/.env" GOOGLE_GEMINI_BASE_URL "$url"
      [[ -n "$key" ]] && dotenv_set "$HOME/.gemini/.env" GEMINI_API_KEY "$key"
      [[ -n "$model" ]] && dotenv_set "$HOME/.gemini/.env" GEMINI_MODEL "$model"
      # 跳过首次启动的认证方式选择
      [[ -n "$key" ]] && json_merge "$HOME/.gemini/settings.json" '{"security":{"auth":{"selectedType":"gemini-api-key"}}}';;
    pi)
      local pi_dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}" pi_models='[]'
      [[ -n "$model" ]] && pi_models="[{\"id\":$(json_str "$model")}]"
      local pi_opts="\"baseUrl\":$(json_str "$url"),\"api\":\"openai-completions\",\"models\":$pi_models"
      [[ -n "$key" ]] && pi_opts="$pi_opts,\"apiKey\":$(json_str "$key")"
      json_merge "$pi_dir/models.json" "{\"providers\":{\"inst\":{$pi_opts}}}"
      [[ -n "$model" ]] && json_merge "$pi_dir/settings.json" "{\"defaultProvider\":\"inst\",\"defaultModel\":$(json_str "$model")}";;
    opencode)
      local models='{}'
      [[ -n "$model" ]] && models="{$(json_str "$model"):{\"name\":$(json_str "$model")}}"
      local opts="\"baseURL\":$(json_str "$url")"
      [[ -n "$key" ]] && opts="$opts,\"apiKey\":$(json_str "$key")"
      json_merge "$HOME/.config/opencode/opencode.json" \
        "{\"\$schema\":\"https://opencode.ai/config.json\",\"provider\":{\"inst\":{\"npm\":\"@ai-sdk/openai-compatible\",\"name\":\"inst\",\"options\":{$opts},\"models\":$models}}}"
      [[ -n "$model" ]] && json_merge "$HOME/.config/opencode/opencode.json" "{\"model\":$(json_str "inst/$model")}";;
    *)
      # 其余 Agent 使用 OpenAI 兼容环境变量。
      env_var OPENAI_BASE_URL "$url"
      [[ -n "$key" ]] && env_var OPENAI_API_KEY "$key";;
  esac
  ok "已配置 $id → $url"
}
configure_endpoints(){
  step 'Agents 地址配置'
  local ids="$ENDPOINT_AGENTS" id done_any=0
  # 兼容旧参数
  [[ -n "$ANTHROPIC_URL" ]] && { configure_endpoint_for claude "$ANTHROPIC_URL" "${INST_ANTHROPIC_API_KEY:-$ENDPOINT_KEY}" "$ENDPOINT_MODEL"; done_any=1; }
  [[ -n "$OPENAI_URL" ]] && { configure_endpoint_for codex "$OPENAI_URL" "${INST_OPENAI_API_KEY:-$ENDPOINT_KEY}" "$ENDPOINT_MODEL"; done_any=1; }
  if [[ -n "$ENDPOINT_URL" ]]; then
    [[ -n "$ids" ]] || ids=claude
    local -a list; IFS=',' read -r -a list <<< "$ids"
    for id in "${list[@]}"; do [[ -n "$id" ]] && configure_endpoint_for "$id" "$ENDPOINT_URL" "$ENDPOINT_KEY" "$ENDPOINT_MODEL"; done
    done_any=1
  fi
  ((done_any)) || log '未提供地址：使用 --endpoint claude,codex --base-url URL，密钥通过 INST_API_KEY 环境变量传入'
}

# ---------------------------------------------------------------- 检查与更新
tool_version(){
  local out
  out="$("$1" --version 2>/dev/null | head -n 1 || true)"
  printf '%s' "${out:0:48}"
}
check_installation(){
  step "环境检查  inst v$INST_VERSION  $(platform_label)  shell: $LOGIN_SHELL"
  load_env
  have nvm || load_nvm 2>/dev/null || true
  local tool path
  for tool in nvm node npm pnpm pyenv python3 conda claude codex gemini opencode grok openclaw hermes pi; do
    if [[ "$tool" == nvm ]] && type nvm >/dev/null 2>&1; then printf '  %-10s %s%-44s%s %s\n' nvm "$C_G" "$NVM_DIR" "$C_0" "$(nvm --version 2>/dev/null)"; continue; fi
    if path="$(command -v "$tool" 2>/dev/null)"; then
      printf '  %-10s %s%-44s%s %s\n' "$tool" "$C_G" "$path" "$C_0" "$(tool_version "$tool")"
    else printf '  %-10s %s%s%s\n' "$tool" "$C_D" '未找到' "$C_0"; fi
  done
  printf '\n  npm registry: %s\n' "$(npm config get registry 2>/dev/null || echo -)"
  printf '  pip index:    %s\n' "$(python3 -m pip config get global.index-url 2>/dev/null || echo -)"
  printf '  env 文件:     %s\n' "$([[ -f "$ENV_FILE" ]] && echo "$ENV_FILE" || echo '未创建')"
}
update_all(){
  step '更新已安装工具'
  load_env
  if load_nvm 2>/dev/null; then
    if ((DRY_RUN)); then run nvm install --lts --reinstall-packages-from=current
    else nvm_do install --lts --reinstall-packages-from=current; nvm_do alias default 'lts/*'; nvm_do use default; fi
    npm_global pnpm@latest
  fi
  local pyenv_root="${PYENV_ROOT:-$HOME/.pyenv}"
  if [[ -d "$pyenv_root/.git" ]]; then run git -C "$pyenv_root" pull --ff-only; fi
  if have pyenv; then
    local v; if ((DRY_RUN)); then v='3.x-latest'; else v="$(resolve_python_version "$PYTHON_VERSION" || true)"; fi
    [[ -n "$v" ]] && run pyenv install -s "$v"
  fi
  local line
  while IFS= read -r line; do
    agent_read "$line"
    have "$AGENT_BIN" || continue
    local where; where="$(command -v "$AGENT_BIN")"
    if have npm && [[ -n "$AGENT_NPM" && "$where" == "$(npm prefix -g 2>/dev/null)"/* ]]; then npm_global "$AGENT_NPM@latest"
    elif [[ -n "$AGENT_UPGRADE" ]]; then local -a cmd; IFS=' ' read -r -a cmd <<< "$AGENT_UPGRADE"; run "${cmd[@]}" || warn "$AGENT_NAME 更新失败"
    elif [[ -n "$AGENT_SCRIPT" ]]; then official_script "$(gh_url "$AGENT_SCRIPT")" || warn "$AGENT_NAME 更新失败"
    fi
  done <<< "$AGENT_TABLE"
  ok '更新完成'
}

# ---------------------------------------------------------------- 脚本自更新
SCRIPT_PATH=''
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"; fi
SHORTCUT_PATH="$BIN_DIR/$SHORTCUT_NAME"
REMOTE_VERSION=''
fetch_remote_version(){
  [[ -n "$REMOTE_VERSION" ]] && return 0
  [[ -n "${INST_NO_UPDATE_CHECK:-}" ]] && return 1
  REMOTE_VERSION="$(curl -fsSL --max-time 3 "$BASE_URL/VERSION" 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
  [[ "$REMOTE_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { REMOTE_VERSION=''; return 1; }
}
self_update_target(){
  if [[ -n "${INST_INSTALLER_PATH:-}" && -f "$INST_INSTALLER_PATH" ]]; then echo "$INST_INSTALLER_PATH"
  elif [[ -n "$SCRIPT_PATH" && "$SCRIPT_PATH" == "$SHORTCUT_PATH" ]]; then echo "$SCRIPT_PATH"
  elif [[ -f "$SHORTCUT_PATH" ]]; then echo "$SHORTCUT_PATH"; fi
}
self_update(){
  step '更新 inst 脚本'
  local target; target="$(self_update_target)"
  if [[ -z "$target" ]]; then
    err '自更新只支持本地文件模式：请先安装快捷命令（--install-shortcut / 菜单 88），在线运行时每次都是最新版'
    return 2
  fi
  assert_https "$BASE_URL" INST_RAW_BASE_URL || return 2
  if ((DRY_RUN)); then log "将下载并校验 $BASE_URL/scripts/install-unix.sh，再替换 ${target}（旧版备份为 $target.bak）"; return 0; fi
  local current; current="$(script_version "$target")"
  if [[ -z "${INST_FORCE_UPDATE:-}" && -n "$current" ]] && fetch_remote_version && ! version_gt "$REMOTE_VERSION" "$current"; then
    ok "已是最新版本 v${current}（INST_FORCE_UPDATE=1 可强制重新下载）"; return 0
  fi
  # 与 kejilion.sh 相同的防护：先下载到临时文件，校验非空、shebang、版本号与语法后再替换，并保留备份。
  local tmp; tmp="$(mktemp "${target}.tmp.XXXXXX")"
  if ! inst_download "$BASE_URL/scripts/install-unix.sh" "$tmp" \
    || [[ ! -s "$tmp" || "$(head -c 2 "$tmp")" != '#!' || -z "$(script_version "$tmp")" ]] || ! bash -n "$tmp"; then
    rm -f "$tmp"; err '下载或校验失败，未替换'; return 1
  fi
  cp -p "$target" "$target.bak" 2>/dev/null || true
  chmod +x "$tmp"; mv "$tmp" "$target"
  REMOTE_VERSION=''
  ok "已更新: $target (v${current:-?} -> v$(script_version "$target"))，备份: $target.bak"
}
script_version(){ sed -n 's/^INST_VERSION="\(.*\)"/\1/p' "$1" 2>/dev/null | head -n 1; }
install_shortcut(){
  step "安装快捷命令 $SHORTCUT_NAME"
  if ((DRY_RUN)); then log "将复制脚本到 $SHORTCUT_PATH"; return 0; fi
  mkdir -p "$BIN_DIR"
  if [[ -n "$SCRIPT_PATH" && "$SCRIPT_PATH" != "$SHORTCUT_PATH" ]]; then cp "$SCRIPT_PATH" "$SHORTCUT_PATH"
  elif [[ ! -f "$SHORTCUT_PATH" ]]; then inst_download "$BASE_URL/scripts/install-unix.sh" "$SHORTCUT_PATH"; fi
  chmod +x "$SHORTCUT_PATH"
  env_path localbin "$BIN_DIR"
  ok "已安装 ${SHORTCUT_PATH}，新终端中输入 $SHORTCUT_NAME 即可打开菜单"
}
AUTO_UPDATE_TAG='# inst-auto-update'
auto_update(){
  local mode="$1" current
  have crontab || { err '未找到 crontab'; return 1; }
  current="$(crontab -l 2>/dev/null | grep -v "$AUTO_UPDATE_TAG" || true)"
  if [[ "$mode" == on ]]; then
    [[ -f "$SHORTCUT_PATH" ]] || install_shortcut
    local minute=$((RANDOM % 60)) # 随机分钟，避免所有用户同一时刻请求
    ((DRY_RUN)) && { log "将添加每日 04:$(printf '%02d' "$minute") 自动更新任务"; return 0; }
    printf '%s\n%s\n' "$current" "$minute 4 * * * \"$SHORTCUT_PATH\" --self-update --quiet >/dev/null 2>&1 $AUTO_UPDATE_TAG" | sed '/^$/d' | crontab -
    ok "已开启每日自动更新（每天 04:$(printf '%02d' "$minute")）"
  else
    ((DRY_RUN)) && { log '将移除自动更新任务'; return 0; }
    printf '%s\n' "$current" | sed '/^$/d' | crontab -
    ok '已关闭自动更新'
  fi
}

# ---------------------------------------------------------------- 菜单
banner(){
  ((HAS_TTY)) && [[ -t 1 ]] && clear
  printf '%s' "$C_C"
  cat <<'EOF'
   _           _
  (_)_ __  ___| |_
  | | '_ \/ __| __|
  | | | | \__ \ |_
  |_|_| |_|___/\__|
EOF
  printf '%s  v%s  %s\n' "$C_0" "$INST_VERSION" "${C_D}跨平台开发环境 & AI Agents 安装器${C_0}"
  printf -- '------------------------------------------------\n'
  printf ' 系统: %s | Shell: %s | 区域: %s\n' "$(platform_label)" "$LOGIN_SHELL" "$REGION"
  if [[ -n "$REMOTE_VERSION" ]] && version_gt "$REMOTE_VERSION" "$INST_VERSION"; then
    printf ' %s发现新版本 v%s，输入 00 更新%s\n' "$C_Y" "$REMOTE_VERSION" "$C_0"
  fi
  printf -- '------------------------------------------------\n'
}
menu_line(){ printf ' %s%-4s%s %-14s %s%s%s\n' "$C_G" "$1" "$C_0" "$2" "$C_D" "${3:-}" "$C_0"; }
LAST_RC=0
run_action(){ # 在子 shell 中执行，失败返回菜单而不是退出；不能写成 ( ... ) || ，否则子 shell 内 set -e 失效
  set +e
  ( set -e; "$@" )
  LAST_RC=$?
  set -e
  ((LAST_RC == 0)) || err "操作失败 (退出码 $LAST_RC)"
  pause
}
pick_preset(){
  local __var="$1" choice
  menu_line 1 清华 TUNA; menu_line 2 阿里云; menu_line 3 中科大 USTC; menu_line 4 腾讯云; menu_line 5 华为云; menu_line 6 官方源 恢复默认
  ask choice '选择镜像' 1
  case "$choice" in 1) choice=tuna;; 2) choice=aliyun;; 3) choice=ustc;; 4) choice=tencent;; 5) choice=huawei;; 6) choice=official;; *) choice='';; esac
  printf -v "$__var" '%s' "$choice"
}
menu_mirrors(){
  local c p
  while true; do
    banner
    printf ' %s镜像源配置%s\n' "$C_B" "$C_0"
    menu_line 1 一键国内镜像 'npm + pip + conda + nvm/pyenv 下载 (+系统源)'
    menu_line 2 系统源 "$([[ "$PLATFORM" == macOS ]] && echo Homebrew || echo "${DISTRO_ID:-Linux} ($PKG)")"
    menu_line 3 npm/pnpm 源
    menu_line 4 pip 源
    menu_line 5 conda 源
    menu_line 6 'nvm/pyenv 下载镜像'
    menu_line 7 GitHub 加速 "当前: ${GH_PROXY:-未启用}"
    menu_line 8 恢复全部官方源
    menu_line 0 返回
    ask c '请选择' ''
    case "$c" in
      1) pick_preset p; [[ -n "$p" ]] && { MIRROR_PRESET="$p"; confirm '同时切换系统源' && APPLY_SYSTEM_MIRROR=1; run_action configure_mirrors; APPLY_SYSTEM_MIRROR=0; };;
      2) pick_preset p; [[ -n "$p" ]] && run_action mirror_system "$p";;
      3) pick_preset p; [[ -n "$p" ]] && run_action mirror_npm "$(preset_npm "$p")";;
      4) pick_preset p; [[ -n "$p" ]] && run_action mirror_pip "$(preset_pip "$p")";;
      5) pick_preset p; [[ -n "$p" ]] && run_action mirror_conda "$(preset_conda "$p")";;
      6) if confirm '启用 npmmirror 的 Node/Python 下载镜像' y; then run_action mirror_toolchain 1; else run_action mirror_toolchain 0; fi;;
      7) ask p 'GitHub 代理前缀（如 https://gh-proxy.com，留空关闭）' ''
         GH_PROXY="$p"; run_action env_var INST_GH_PROXY "$p";;
      8) MIRROR_PRESET=official; run_action configure_mirrors;;
      0|q) return;;
    esac
  done
}
menu_agents(){
  local c ids='' method i=1 line
  banner
  printf ' %sAgents CLI 安装%s\n' "$C_B" "$C_0"
  local -a all=()
  while IFS= read -r line; do
    agent_read "$line"
    all+=("$AGENT_ID")
    local how=''; [[ -n "$AGENT_SCRIPT" ]] && how='官方'; [[ -n "$AGENT_NPM" ]] && how="${how:+$how/}npm"
    local mark=''; have "$AGENT_BIN" && mark="${C_G}已安装${C_0}"
    menu_line "$i" "$AGENT_NAME" "$how $mark"
    i=$((i+1))
  done <<< "$AGENT_TABLE"
  menu_line a 全部; menu_line 0 返回
  ask c '选择（可多选，如 1 2 3）' '1 2 3 4'
  [[ "$c" == 0 ]] && return
  if [[ "$c" == a ]]; then ids=all
  else for i in $(printf '%s' "$c" | tr ',' ' '); do [[ "$i" =~ ^[0-9]+$ && "$i" -ge 1 && "$i" -le ${#all[@]} ]] && ids="$ids,${all[i-1]}"; done; ids="${ids#,}"; fi
  [[ -n "$ids" ]] || return
  menu_line 1 自动 '优先官方脚本，否则 npm'; menu_line 2 官方脚本; menu_line 3 npm
  ask method '安装方式' 1
  case "$method" in 2) method=official;; 3) method=npm;; *) method=auto;; esac
  AGENT_IDS="$ids" AGENT_METHOD="$method" run_action install_agents
}
menu_desktop(){
  local c
  banner
  printf ' %sAgents 桌面端%s\n' "$C_B" "$C_0"
  menu_line 1 'Claude Desktop' 'macOS 官方 zip / Linux 官方 apt 源（beta）'
  menu_line 2 'Codex Desktop' 'ChatGPT 桌面端（含 Codex），Linux 为 deb/rpm'
  menu_line 3 全部; menu_line 0 返回
  ask c '请选择' 3
  case "$c" in 1) DESKTOP_APPS=claude;; 2) DESKTOP_APPS=codex;; 3) DESKTOP_APPS=claude,codex;; *) return;; esac
  ask DESKTOP_DIR '安装目录' "$([[ "$PLATFORM" == macOS ]] && echo /Applications || echo "$PREFIX/desktop")"
  run_action install_desktop
}
menu_endpoint(){
  local c ids url key model
  banner
  printf ' %sAgents 地址配置%s（写入各 Agent 自己的配置文件）\n' "$C_B" "$C_0"
  menu_line 1 'Claude Code' '~/.claude/settings.json'
  menu_line 2 'Codex CLI' '~/.codex/config.toml'
  menu_line 3 'Gemini CLI' '~/.gemini/.env'
  menu_line 4 'OpenCode' '~/.config/opencode/opencode.json'
  menu_line 5 'Pi' '~/.pi/agent/models.json'
  menu_line 6 '其他 (OpenAI 兼容)' 'OPENAI_BASE_URL / OPENAI_API_KEY'
  menu_line 0 返回
  ask c '选择（可多选）' 1
  ids=''
  for i in $(printf '%s' "$c" | tr ',' ' '); do
    case "$i" in 1) ids="$ids,claude";; 2) ids="$ids,codex";; 3) ids="$ids,gemini";; 4) ids="$ids,opencode";; 5) ids="$ids,pi";; 6) ids="$ids,openai";; esac
  done
  ids="${ids#,}"; [[ -n "$ids" ]] || return
  ask url 'API Base URL (https://...)' ''
  [[ -n "$url" ]] || return
  ask_secret key 'API Key（输入不回显，留空跳过）'
  ask model '默认模型（可留空）' ''
  ENDPOINT_AGENTS="$ids" ENDPOINT_URL="$url" ENDPOINT_KEY="$key" ENDPOINT_MODEL="$model" ANTHROPIC_URL='' OPENAI_URL='' run_action configure_endpoints
}
menu_update(){
  local c
  banner
  printf ' %s脚本更新%s  当前 v%s  最新 v%s\n' "$C_B" "$C_0" "$INST_VERSION" "${REMOTE_VERSION:-未知}"
  menu_line 1 立即更新; menu_line 2 开启每日自动更新; menu_line 3 关闭自动更新; menu_line 0 返回
  ask c '请选择' 1
  case "$c" in
    1) if [[ -z "$(self_update_target)" ]]; then run_action install_shortcut
       else run_action self_update; ((LAST_RC == 0)) && { log '重新启动...'; exec bash "$(self_update_target)"; }; fi;;
    2) run_action auto_update on;;
    3) run_action auto_update off;;
  esac
}
all_in_one(){ install_node; install_python; configure_mirrors; install_agents; }
main_menu(){
  INTERACTIVE=1
  ((HAS_TTY)) || die '没有可交互的终端；请使用参数运行，例如 --all，详见 --help' 2
  detect_region
  fetch_remote_version || true
  local c
  while true; do
    banner
    menu_line 1 'Node.js 环境' 'nvm / Node.js LTS / npm / pnpm'
    menu_line 2 'Python 环境' 'pyenv / Python / Miniconda'
    menu_line 3 '镜像源配置' '系统 / npm / pip / conda / Homebrew'
    menu_line 4 'Agents CLI' 'Claude Code / Codex / Gemini / OpenCode / Grok / OpenClaw / Hermes / Pi'
    menu_line 5 'Agents 桌面端' 'Claude / Codex Desktop'
    menu_line 6 'Agents 地址配置' 'API Base URL / Key'
    printf -- '------------------------------------------------\n'
    menu_line 7 '一键安装' '1 + 2 + 3 + 4'
    menu_line 8 '环境检查'
    menu_line 9 '更新已安装工具'
    printf -- '------------------------------------------------\n'
    menu_line 00 '脚本更新' "$([[ -f "$SHORTCUT_PATH" ]] && echo "快捷命令: $SHORTCUT_NAME")"
    menu_line 88 '安装快捷命令' "$SHORTCUT_NAME"
    menu_line 0 '退出'
    printf -- '------------------------------------------------\n'
    ask c '请输入你的选择' ''
    case "$c" in
      1) run_action install_node;;
      2) run_action install_python;;
      3) menu_mirrors;;
      4) menu_agents;;
      5) menu_desktop;;
      6) menu_endpoint;;
      7) run_action all_in_one;;
      8) run_action check_installation;;
      9) run_action update_all;;
      00) menu_update;;
      88) run_action install_shortcut;;
      0|q|exit) printf '再见\n'; exit 0;;
    esac
  done
}

# ---------------------------------------------------------------- 参数
usage(){ cat <<EOF
inst v$INST_VERSION  跨平台开发环境 & AI Agents 安装器

用法: inst                      打开交互菜单（kejilion 风格）
      inst [组件] [选项]         非交互执行

组件:
  --all                  Node + Python + 镜像 + Agents CLI
  --node                 nvm、Node.js LTS、npm、pnpm
  --python               pyenv、Python 最新稳定版、Miniconda
  --mirrors              npm / pip / conda / nvm / pyenv 镜像（中国区域自动启用）
  --agents               Agents CLI（默认 ${DEFAULT_AGENTS}）
  --desktop              Claude / Codex 桌面端
  --endpoint LIST        为 Agent 写入地址配置: claude,codex,gemini,opencode,pi,openai
  --check                只读环境检查
  --update               更新已安装的工具与 Agents
  --self-update          更新本脚本（快捷命令模式）
  --install-shortcut     安装快捷命令 ~/.local/bin/$SHORTCUT_NAME
  --menu                 强制打开菜单

选项:
  --agent-list LIST      Agent id: $(agent_ids | paste -sd, -) 或 all
  --agent-method M       auto | official | npm
  --official-agents      等同于 --agents --agent-method official
  --agent-packages LIST  直接安装的 npm 包（逗号分隔）
  --base-url URL         Agent API 地址（密钥用环境变量 INST_API_KEY 传入）
  --model NAME           默认模型
  --anthropic-base-url URL / --openai-base-url URL  分别配置 Claude Code / Codex
  --region R             auto | cn | global
  --mirror-preset P      tuna | aliyun | ustc | tencent | huawei | official
  --npm-registry URL     --pip-index URL     --system-mirror URL|预设
  --apply-system-mirror  允许修改 Linux 系统源（会备份为 *.inst.bak）
  --gh-proxy URL         GitHub 下载加速前缀
  --python-version V     latest | 3.x | 3.x.y
  --with-build-deps      自动安装 Python 编译依赖（需要 sudo）
  --desktop-apps LIST    claude,codex     --desktop-dir DIR   安装目录
  --prefix DIR           缓存目录（默认 ~/.local/inst）
  -y, --yes              自动确认       --dry-run   只显示将执行的操作
  -q, --quiet            安静模式       -v, --version
EOF
}
parse_args(){
  while (($#)); do
    case "$1" in
      --agent-packages|--agent-list|--agents-list|--agent-method|--npm-registry|--pip-index|--system-mirror|--prefix|--agent-api-url|--anthropic-base-url|--openai-base-url|--base-url|--model|--region|--mirror-preset|--gh-proxy|--python-version|--desktop-apps|--desktop-dir|--endpoint)
        if (($# < 2)) || [[ -z "$2" || "$2" == --* ]]; then err "$1 缺少参数值"; exit 2; fi;;
    esac
    case "$1" in
      --all) DO_NODE=1; DO_PYTHON=1; DO_MIRRORS=1; DO_AGENTS=1;;
      --node) DO_NODE=1;; --python) DO_PYTHON=1;; --mirrors) DO_MIRRORS=1;; --agents) DO_AGENTS=1;;
      --desktop) DO_DESKTOP=1;; --check) DO_CHECK=1;; --update) DO_UPDATE=1;; --self-update) DO_SELF_UPDATE=1;;
      --install-shortcut) DO_SHORTCUT=1;; --menu) DO_MENU=1;;
      --official-agents) DO_AGENTS=1; AGENT_METHOD=official;;
      --apply-system-mirror) APPLY_SYSTEM_MIRROR=1;; --with-build-deps) WITH_BUILD_DEPS=1;;
      --dry-run) DRY_RUN=1;; -y|--yes) ASSUME_YES=1;; -q|--quiet) QUIET=1;;
      --agent-packages) AGENT_PACKAGES="$2"; DO_AGENTS=1; shift;;
      --agent-list|--agents-list) AGENT_IDS="$2"; shift;;
      --agent-method) AGENT_METHOD="$2"; shift;;
      --npm-registry) NPM_REGISTRY="$2"; shift;;
      --pip-index) PIP_INDEX="$2"; shift;;
      --system-mirror) SYSTEM_MIRROR="$2"; shift;;
      --prefix) PREFIX="$2"; shift;;
      --agent-api-url|--base-url) ENDPOINT_URL="$2"; DO_ENDPOINT=1; shift;;
      --anthropic-base-url) ANTHROPIC_URL="$2"; DO_ENDPOINT=1; shift;;
      --openai-base-url) OPENAI_URL="$2"; DO_ENDPOINT=1; shift;;
      --endpoint) ENDPOINT_AGENTS="$2"; DO_ENDPOINT=1; shift;;
      --model) ENDPOINT_MODEL="$2"; shift;;
      --region) REGION="$2"; shift;;
      --mirror-preset) MIRROR_PRESET="$2"; shift;;
      --gh-proxy) GH_PROXY="$2"; shift;;
      --python-version) PYTHON_VERSION="$2"; shift;;
      --desktop-apps) DESKTOP_APPS="$2"; shift;;
      --desktop-dir) DESKTOP_DIR="$2"; shift;;
      -v|--version) echo "$INST_VERSION"; exit 0;;
      -h|--help) usage; exit 0;;
      *) err "未知参数: $1"; usage >&2; exit 2;;
    esac
    shift
  done
  case "$AGENT_METHOD" in auto|official|npm) ;; *) err '--agent-method 只能是 auto、official 或 npm'; exit 2;; esac
  case "$REGION" in auto|cn|global) ;; *) err '--region 只能是 auto、cn 或 global'; exit 2;; esac
  [[ -z "$GH_PROXY" ]] || assert_https "$GH_PROXY" GH_PROXY || exit 2
}

main(){
  parse_args "$@"
  [[ "$PLATFORM" != Windows ]] || die "Windows 请在 PowerShell 中运行: irm $BASE_URL/install.ps1 | iex" 1
  if ((DO_MENU)) || (( ! DO_NODE && ! DO_PYTHON && ! DO_MIRRORS && ! DO_AGENTS && ! DO_DESKTOP && ! DO_ENDPOINT \
        && ! DO_CHECK && ! DO_UPDATE && ! DO_SELF_UPDATE && ! DO_SHORTCUT )); then
    if ((HAS_TTY)); then main_menu; fi
    usage; exit 2
  fi
  ((DO_CHECK)) && { check_installation; exit 0; }
  if ((DO_SELF_UPDATE)); then self_update; exit $?; fi
  ((QUIET)) || log "检测到 $(platform_label)，shell: $LOGIN_SHELL"
  ((DO_SHORTCUT)) && install_shortcut
  ((DO_ENDPOINT)) && configure_endpoints
  ((DO_MIRRORS)) && configure_mirrors
  ((DO_NODE)) && install_node
  ((DO_PYTHON)) && install_python
  ((DO_AGENTS)) && install_agents
  ((DO_DESKTOP)) && install_desktop
  ((DO_UPDATE)) && update_all
  if ((DRY_RUN)); then log '预览结束，未执行安装'; else ok '所选步骤执行结束；新开终端或执行 source ~/.config/inst/env.sh 使环境生效'; fi
}

main "$@"
