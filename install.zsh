#!/usr/bin/env zsh
# zsh 入口：本地仓库直接运行主脚本；否则转交 POSIX 入口 install.sh。
set -eu
ROOT_DIR="${0:A:h}"
if [[ -f "$ROOT_DIR/scripts/install-unix.sh" ]]; then
  INST_INSTALLER_PATH="${INST_INSTALLER_PATH:-$ROOT_DIR/scripts/install-unix.sh}" exec bash "$ROOT_DIR/scripts/install-unix.sh" "$@"
fi
base="${INST_RAW_BASE_URL:-https://inst.linux.yun}"
[[ "$base" == https://* ]] || { print -u2 'INST_RAW_BASE_URL must use HTTPS'; exit 2; }
exec sh -c "$(curl --proto '=https' --proto-redir '=https' -fsSL "$base/install.sh")" inst "$@"
