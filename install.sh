#!/bin/sh
# inst 入口（POSIX sh）：可用 sh / bash / zsh / dash 执行，也可 curl | sh。
#   curl -fsSL https://inst.linux.yun | sh               （根地址按 User-Agent 返回本文件，即 /install.sh）
#   curl -fsSL https://inst.linux.yun | sh -s -- --all
set -eu
base=${INST_RAW_BASE_URL:-https://inst.linux.yun}
case "$base" in https://*) ;; *) echo 'INST_RAW_BASE_URL must use HTTPS' >&2; exit 2;; esac

say() { printf '[inst] %s\n' "$*" >&2; }

# Windows 下的 Git Bash / MSYS2 / Cygwin 交给 PowerShell 实现。
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    ps=powershell.exe
    command -v pwsh.exe >/dev/null 2>&1 && ps=pwsh.exe
    export INST_LAUNCHER=bash INST_RAW_BASE_URL="$base"
    here=''
    [ -f "$0" ] && here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    if [ -n "$here" ] && [ -f "$here/install.ps1" ]; then
      exec "$ps" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$here/install.ps1" 2>/dev/null || echo "$here/install.ps1")" "$@"
    fi
    say "Windows 环境，转交 PowerShell 执行"
    tmp_dir=$(mktemp -d)
    rc=0
    curl --proto '=https' --proto-redir '=https' -fsSL "$base/install.ps1" -o "$tmp_dir/install.ps1" || rc=$?
    if [ "$rc" -eq 0 ]; then
      "$ps" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$tmp_dir/install.ps1" 2>/dev/null || echo "$tmp_dir/install.ps1")" "$@" || rc=$?
    fi
    rm -rf "$tmp_dir"
    exit "$rc"
    ;;
esac

# 本地仓库模式
if [ -f "$0" ]; then
  root_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  if [ -f "$root_dir/scripts/install-unix.sh" ]; then
    INST_INSTALLER_PATH=${INST_INSTALLER_PATH:-$root_dir/scripts/install-unix.sh} exec bash "$root_dir/scripts/install-unix.sh" "$@"
  fi
fi

# 最小化镜像（alpine / debian-slim 等）可能缺少 bash 或 curl。
pkg_install() {
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then sudo_cmd=sudo; else say "缺少 $*，且没有 root 权限，请手动安装"; exit 1; fi
  else sudo_cmd=''
  fi
  say "安装依赖: $*"
  if command -v apk >/dev/null 2>&1; then $sudo_cmd apk add --no-cache "$@"
  elif command -v apt-get >/dev/null 2>&1; then $sudo_cmd apt-get update -qq && $sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  elif command -v dnf >/dev/null 2>&1; then $sudo_cmd dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then $sudo_cmd yum install -y "$@"
  elif command -v pacman >/dev/null 2>&1; then $sudo_cmd pacman -Sy --needed --noconfirm "$@"
  elif command -v zypper >/dev/null 2>&1; then $sudo_cmd zypper --non-interactive install "$@"
  else say "缺少 $*，请手动安装后重试"; exit 1
  fi
}
missing=''
command -v bash >/dev/null 2>&1 || missing="$missing bash"
command -v curl >/dev/null 2>&1 || missing="$missing curl"
command -v git >/dev/null 2>&1 || missing="$missing git"
# shellcheck disable=SC2086
[ -z "$missing" ] || pkg_install $missing ca-certificates

tmp_script=$(mktemp "${TMPDIR:-/tmp}/inst.XXXXXX")
trap 'rm -f "$tmp_script"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
curl --proto '=https' --proto-redir '=https' -fsSL --retry 2 --connect-timeout 20 "$base/scripts/install-unix.sh" -o "$tmp_script"
# 通过管道运行时 stdin 是脚本本身，主脚本会自行从 /dev/tty 读取菜单输入。
INST_RUN_MODE=remote INST_RAW_BASE_URL=$base bash "$tmp_script" "$@"
