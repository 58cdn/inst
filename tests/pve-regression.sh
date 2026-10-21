#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
bash -n scripts/pve-tools.sh
bash scripts/pve-tools.sh --help | grep -q 'vm-cloudinit'
if bash scripts/pve-tools.sh audit >/dev/null 2>&1; then
  echo 'FAIL: audit accepted a non-PVE CI runner' >&2
  exit 1
fi
# Test CLI validation with simulated PVE commands, never bind real /sys devices.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/pveversion" <<'EOF'
#!/bin/sh
echo 'pve-manager/8.x test'
EOF
cat > "$tmp/qm" <<'EOF'
#!/bin/sh
case "$1" in
  status) [ "$2" = 9000 ] && { echo 'status: stopped'; exit 0; } || exit 1;;
  config) [ "$2" = 9000 ] && { echo 'template: 1'; exit 0; } || exit 1;;
  clone|set) echo 'UNEXPECTED MUTATION' >&2; exit 99;;
  *) exit 1;;
esac
EOF
chmod +x "$tmp/pveversion" "$tmp/qm"
# Every invalid input must be rejected before any qm mutation.
for args in 'vm-clone invalid 120 test' 'vm-clone 9000 INVALID test' 'vm-clone 9000 120 ../unsafe' 'passthrough 9000 invalid' 'disk-attach 9000 /etc/passwd' 'vm-cloudinit 9000 bad/user /tmp/foo'; do
  read -r -a values <<< "$args"
  if PATH="$tmp:$PATH" PVE_YES=1 PVE_ALLOW_HOST_CHANGES=1 bash scripts/pve-tools.sh "${values[@]}" >"$tmp/output" 2>&1; then
    printf 'FAIL: accepted invalid arguments: %s\n' "$args" >&2
    exit 1
  fi
  if grep -q 'UNEXPECTED MUTATION' "$tmp/output"; then
    printf 'FAIL: mutated with invalid arguments: %s\n' "$args" >&2
    exit 1
  fi
done
# Dry-run of template clone must not run the actual qm clone action.
PATH="$tmp:$PATH" PVE_DRY_RUN=1 bash scripts/pve-tools.sh vm-clone 9000 120 safe-vm >"$tmp/output"
grep -q 'DRY RUN' "$tmp/output"
! grep -q 'UNEXPECTED MUTATION' "$tmp/output"
echo 'PASS: PVE CLI guards, invalid inputs and dry-run'
