#!/bin/sh
# inst 入口（POSIX sh）：可用 sh / bash / zsh / dash 执行，也可 curl | sh。
#   curl -fsSL https://inst.linux.yun | sh               （根地址按 User-Agent 返回本文件，即 /install.sh）
#   curl -fsSL https://inst.linux.yun | sh -s -- --all
set -eu

DEFAULT_BASE_URL=https://inst.linux.yun
base=${INST_RAW_BASE_URL:-$DEFAULT_BASE_URL}
base_explicit=0
[ -n "${INST_RAW_BASE_URL:-}" ] && base_explicit=1
case "$base" in https://*) ;; *) echo 'INST_RAW_BASE_URL must use HTTPS' >&2; exit 2;; esac

say() { printf '[inst] %s\n' "$*" >&2; }

# Discover the mirror list from the official site and choose the fastest
# reachable endpoint. An explicit INST_RAW_BASE_URL always wins.
select_mirror_base() {
  [ "$base_explicit" -eq 0 ] || { printf '%s' "$base"; return 0; }
  [ "${INST_MIRROR_AUTO:-1}" != 0 ] || { printf '%s' "$base"; return 0; }

  local timeout manifest urls mirror probe status elapsed score best best_score
  timeout=${INST_MIRROR_TIMEOUT:-5}
  case "$timeout" in ''|*[!0-9]*) timeout=5;; esac
  [ "$timeout" -gt 0 ] 2>/dev/null || timeout=5
  [ "$timeout" -le 60 ] 2>/dev/null || timeout=60
  manifest=$(mktemp "${TMPDIR:-/tmp}/inst-mirrors.XXXXXX") || { printf '%s' "$base"; return 0; }
  if ! curl --proto '=https' --proto-redir '=https' -fsSL --retry 0 \
      --connect-timeout "$timeout" --max-time "$timeout" \
      "$DEFAULT_BASE_URL/mirrors.json" -o "$manifest" 2>/dev/null; then
    rm -f "$manifest"
    say "mirror list unavailable; using default $base"
    printf '%s' "$base"
    return 0
  fi

  urls=$(tr ',' '\n' < "$manifest" \
    | sed -nE 's/.*"url"[[:space:]]*:[[:space:]]*"([^"\\]+)".*/\1/p')
  rm -f "$manifest"
  [ -n "$urls" ] || { say "mirror list is empty; using default $base"; printf '%s' "$base"; return 0; }

  best=''; best_score=''
  while IFS= read -r mirror; do
    [ -n "$mirror" ] || continue
    case "$mirror" in https://*) ;; *) continue;; esac
    mirror=${mirror%/}
    probe=$(curl --proto '=https' --proto-redir '=https' -fsSL --retry 0 \
      --connect-timeout "$timeout" --max-time "$timeout" \
      -o /dev/null -w '%{http_code} %{time_total}' "$mirror/VERSION" 2>/dev/null || true)
    status=${probe%% *}
    elapsed=${probe#* }
    case "$status" in 2??|3??) ;; *) continue;; esac
    case "$elapsed" in ''|*[!0-9.]*|.*|*.) continue;; esac
    case "$elapsed" in *.*.*) continue;; esac
    score="$elapsed"
    if [ -z "$best_score" ] || [ "$(printf '%s\n%s\n' "$score" "$best_score" | LC_ALL=C sort -n | head -n 1)" = "$score" ]; then
      best="$mirror"
      best_score="$score"
    fi
  done <<EOF
$urls
EOF

  if [ -n "$best" ]; then
    say "selected mirror $best (latency ${best_score}s)"
    printf '%s' "$best"
  else
    say "no reachable mirror; using default $base"
    printf '%s' "$base"
  fi
}

# Windows 下的 Git Bash / MSYS2 / Cygwin 交给 PowerShell 实现。
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    ps=powershell.exe
    command -v pwsh.exe >/dev/null 2>&1 && ps=pwsh.exe
    if [ "$base_explicit" -eq 1 ]; then export INST_RAW_BASE_URL="$base"; else unset INST_RAW_BASE_URL; fi
    export INST_LAUNCHER=bash
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

if [ "$base_explicit" -eq 0 ]; then
  base=$(select_mirror_base)
fi

tmp_script=$(mktemp "${TMPDIR:-/tmp}/inst.XXXXXX")
trap 'rm -f "$tmp_script"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
rc=0
curl --proto '=https' --proto-redir '=https' -fsSL --retry 2 --connect-timeout 20 "$base/scripts/install-unix.sh" -o "$tmp_script" || rc=$?
if [ "$rc" -ne 0 ] && [ "$base_explicit" -eq 0 ] && [ "$base" != "$DEFAULT_BASE_URL" ]; then
  say "selected mirror download failed; retrying default $DEFAULT_BASE_URL"
  base=$DEFAULT_BASE_URL
  rm -f "$tmp_script"
  rc=0
  curl --proto '=https' --proto-redir '=https' -fsSL --retry 2 --connect-timeout 20 "$base/scripts/install-unix.sh" -o "$tmp_script" || rc=$?
fi
[ "$rc" -eq 0 ] || exit "$rc"
# 通过管道运行时 stdin 是脚本本身，主脚本会自行从 /dev/tty 读取菜单输入。
INST_RUN_MODE=remote INST_RAW_BASE_URL=$base bash "$tmp_script" "$@"
