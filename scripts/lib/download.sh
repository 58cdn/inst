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
  if tail -n 15 "$3" 2>/dev/null | grep -Eiq '^content-type:.*(text/html|application/(json|problem\+json))' \
    || head -c 512 "$2" | LC_ALL=C grep -Eiq '<(!doctype[[:space:]]+html|html|head|body)([[:space:]>])'; then
    echo 'download: unexpected error document' >&2; return 1
  fi
  magic=$(od -An -tx1 -N4 "$2" | tr -d ' \n')
  case "${1%%\?*}" in
    *.zip|*.msix) case "$magic" in 504b0304*) ;; *) echo 'download: invalid ZIP prefix' >&2; return 1;; esac;;
    *.exe) case "$magic" in 4d5a*) ;; *) echo 'download: invalid EXE prefix' >&2; return 1;; esac;;
    *.sh) case "$magic" in 2321*) ;; *) echo 'download: invalid script prefix' >&2; return 1;; esac;;
    *.ps1) case "$magic" in 23*|efbbbf23*) ;; *) echo 'download: invalid PowerShell prefix' >&2; return 1;; esac;;
  esac
}
inst_download_candidates() {
  printf '%s\n' "$1"
  # Exact public paths only: never mirror queries, credentials, custom hosts or proxies.
  case "$1" in
    https://inst.linux.yun/scripts/install-unix.sh|https://inst.linux.yun/scripts/install-windows.ps1|https://inst.linux.yun/install.sh|https://inst.linux.yun/install.ps1)
      printf 'https://raw.githubusercontent.com/58cdn/inst/master/%s\n' "${1#https://inst.linux.yun/}";;
    https://raw.githubusercontent.com/58cdn/inst/master/scripts/install-unix.sh|https://raw.githubusercontent.com/58cdn/inst/master/scripts/install-windows.ps1|https://raw.githubusercontent.com/58cdn/inst/master/install.sh|https://raw.githubusercontent.com/58cdn/inst/master/install.ps1)
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
    if inst_download_attempt "$candidate" "$2" "${3:-}"; then exit 0; else rc=$?; fi
    echo "download: attempt failed ($rc); candidate $index" >&2
    case "$rc" in 130|143) exit "$rc";; esac
  done <<EOF_CANDIDATES
$candidates
EOF_CANDIDATES
  echo 'download: candidates exhausted' >&2
  exit "$rc"
)
