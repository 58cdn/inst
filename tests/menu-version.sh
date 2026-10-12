#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export HOME="$scratch/home" INST_PREFIX="$scratch/prefix" INST_NO_TTY=1 INST_LIB_ONLY=1
export INST_REGION=global INST_NO_UPDATE_CHECK=1 NO_COLOR=1
mkdir -p "$HOME"
unset INST_RAW_BASE_URL INST_SELECTED_BASE_URL INST_INSTALLER_PATH INST_FORCE_UPDATE || true
source "$root/scripts/install-unix.sh"
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
main_menu_content > "$scratch/menu"
keys=$(sed -nE 's/^ *([0-9]+)  .*/\1/p' "$scratch/menu" | tr '\n' ' ')
[[ "$keys" == '1 2 3 4 5 6 7 8 9 10 11 0 ' ]] || fail "menu keys: $keys"
[[ $(grep -c '^---- \[' "$scratch/menu") == 5 ]] || fail 'category separators'
[[ $(wc -l < "$scratch/menu") -le 20 ]] || fail 'main menu too tall'
grep -q '01\|pyenv\|Hermes' "$scratch/menu" && fail 'long hints leaked into main menu'
menu_line 2 'Python 环境' 'pyenv / Python' > "$scratch/hint"
[[ $(wc -l < "$scratch/hint") -eq 2 ]] || fail 'submenu hint should have its own line'
for bad in '1.2' '01.2.3' '1.2.3.4' '1.2.3-beta' '<html>1.2.3</html>' '9999999999.0.0' $'1.2.3\n1.2.4'; do
  valid_release_version "$bad" && fail "accepted invalid version: $bad"
done
version_gt 1.2.10 1.2.9 || fail 'numeric version comparison'
echo 'PASS: single-column menu, separators, consecutive keys and strict numeric versions'

calls="$scratch/calls"; : > "$calls"
TEST_MODE=ok; TEST_REPLY=9.9.9
curl(){
  local url='' arg
  for arg in "$@"; do url="$arg"; done
  printf '%s\n' "$url" >> "$calls"
  [[ "$TEST_MODE" != offline ]] || return 28
  if [[ "$TEST_MODE" == fallback && "$url" != https://raw.githubusercontent.com/* ]]; then
    printf '<html>error</html>'; return 0
  fi
  printf '%s\n' "$TEST_REPLY"
}
unset INST_NO_UPDATE_CHECK
BASE_URL=https://inst.linux.yun
fetch_remote_version || fail 'online lookup'
[[ "$REMOTE_VERSION" == 9.9.9 && "$REMOTE_VERSION_SOURCE" == "$BASE_URL" ]] || fail 'online value/source'
fetch_remote_version || fail 'cached lookup'
[[ $(wc -l < "$calls") -eq 1 ]] || fail 'cache requested network'
TEST_REPLY=9.9.10
fetch_remote_version refresh || fail 'refresh'
[[ "$REMOTE_VERSION" == 9.9.10 ]] || fail 'stale cache after refresh'
TEST_MODE=fallback
fetch_remote_version refresh || fail 'GitHub fallback'
[[ "$REMOTE_VERSION_SOURCE" == https://raw.githubusercontent.com/58cdn/inst/master ]] || fail 'wrong fallback source'
export INST_RAW_BASE_URL=https://custom.invalid
BASE_URL="$INST_RAW_BASE_URL"; TEST_MODE=offline; : > "$calls"
fetch_remote_version refresh && fail 'offline accepted'
[[ $(wc -l < "$calls") -eq 1 ]] || fail 'explicit base unexpectedly fell back'
fetch_remote_version && fail 'cached failure accepted'
[[ $(wc -l < "$calls") -eq 1 ]] || fail 'failure not cached'
[[ "$(online_version_label)" == '不可用' ]] || fail 'offline status'
export INST_NO_UPDATE_CHECK=1
fetch_remote_version refresh && fail 'disabled accepted'
[[ $(wc -l < "$calls") -eq 1 && "$(online_version_label)" == '已关闭' ]] || fail 'disabled performed request'
echo 'PASS: online lookup, cache/refresh, fallback, explicit source, offline and disabled modes'

unset INST_NO_UPDATE_CHECK
TEST_MODE=ok; TEST_REPLY=9.9.9
current="$scratch/inst"; payload="$scratch/payload"
printf '#!/bin/bash\nINST_VERSION="1.0.0"\n' > "$current"
cp "$current" "$scratch/original"
self_update_target(){ printf '%s\n' "$current"; }
inst_download(){ cp "$payload" "$2"; }
printf '#!/bin/bash\nINST_VERSION="9.9.8"\n' > "$payload"
if self_update > "$scratch/update-log" 2>&1; then fail 'manifest mismatch accepted'; fi
cmp "$current" "$scratch/original" || fail 'mismatch changed installed file'
[[ ! -e "$current.bak" ]] || fail 'mismatch created backup'
printf '#!/bin/bash\nINST_VERSION="9.9.9"\n' > "$payload"
self_update > "$scratch/update-log" 2>&1 || { cat "$scratch/update-log"; fail 'valid update'; }
cmp "$current" "$payload" || fail 'update bytes'
cmp "$current.bak" "$scratch/original" || fail 'backup bytes'
export INST_NO_UPDATE_CHECK=1 INST_FORCE_UPDATE=1
printf '#!/bin/bash\nINST_VERSION="8.0.0"\n' > "$payload"
if self_update > "$scratch/update-log" 2>&1; then fail 'downgrade accepted'; fi
[[ "$(script_version "$current")" == 9.9.9 ]] || fail 'downgrade changed installed file'
echo 'PASS: update manifest consistency, backup and downgrade prevention'

# Exercise the actual main-menu dispatch. 10 opens updates, 0 exits.
choice_index=0
ask(){
  if ((choice_index == 0)); then printf -v "$1" '%s' 10; else printf -v "$1" '%s' 0; fi
  choice_index=$((choice_index + 1))
}
banner(){ :; }
menu_update(){ echo 'UPDATE_OPENED'; }
HAS_TTY=1
(main_menu) > "$scratch/routing"
[[ $(grep -c '^UPDATE_OPENED$' "$scratch/routing") -eq 1 ]] || fail '10 routing'
echo 'PASS: 10 opens update menu; 0 exits'
