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
    inst_download "$base/install.ps1" "$tmp_dir/install.ps1" || rc=$?
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
tmp_source=$(mktemp "${TMPDIR:-/tmp}/inst-source.XXXXXX")
trap 'rm -f "$tmp_script" "$tmp_source"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
rc=0
inst_download "$base/scripts/install-unix.sh" "$tmp_script" '' "$tmp_source" || rc=$?
case "$rc" in 130|143) exit "$rc";; esac
if [ "$rc" -ne 0 ] && [ "$base_explicit" -eq 0 ] && [ "$base" != "$DEFAULT_BASE_URL" ] && [ "$base" != https://raw.githubusercontent.com/58cdn/inst/master ]; then
  say "selected mirror download failed; retrying default $DEFAULT_BASE_URL"
  base=$DEFAULT_BASE_URL
  rm -f "$tmp_script"
  rc=0
  inst_download "$base/scripts/install-unix.sh" "$tmp_script" '' "$tmp_source" || rc=$?
fi
[ "$rc" -eq 0 ] || exit "$rc"
base=$(cat "$tmp_source")
base=${base%/scripts/install-unix.sh}
# 通过管道运行时 stdin 是脚本本身，主脚本会自行从 /dev/tty 读取菜单输入。
if [ "$base_explicit" -eq 1 ]; then
  INST_RUN_MODE=remote INST_RAW_BASE_URL=$base bash "$tmp_script" "$@"
else
  INST_RUN_MODE=remote INST_SELECTED_BASE_URL=$base bash "$tmp_script" "$@"
fi
