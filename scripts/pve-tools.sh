#!/usr/bin/env bash
# inst PVE tools. Host-level changes require explicit confirmation; default is read-only.
set -Eeuo pipefail
VERSION=1.0.0
usage() {
cat <<'EOF'
Usage: pve-tools.sh COMMAND [arguments]
  audit                       Read-only host, IOMMU and GPU capability report
  devices                     List PCI and persistent disk identifiers
  vms                         List current virtual machines
  vm-clone TEMPLATE_ID NEW_ID NAME  Clone a stopped template and optionally start it
  passthrough VMID PCI_BDF     Add one PCI device to a stopped VM (confirmation required)
  disk-attach VMID DISK_BY_ID  Attach one whole disk to a stopped VM (confirmation required)
  vgpu                        Read-only NVIDIA vGPU prerequisites and status
  menu                        Interactive menu
Environment: PVE_DRY_RUN=1 previews mutations; PVE_YES=1 skips prompts (not safety checks).
Always back up the VM and host before changing hardware or kernel settings.
EOF
}
error(){ printf '[pve] ERROR: %s\n' "$*" >&2; exit 1; }
info(){ printf '[pve] %s\n' "$*"; }
is_id(){ [[ "$1" =~ ^[1-9][0-9]{1,8}$ ]]; }
is_pci(){ [[ "$1" =~ ^([[:xdigit:]]{4}:)?[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]]; }
require_host(){
  [[ "$(uname -s)" == Linux ]] || error 'Linux PVE host required'
  command -v pveversion >/dev/null 2>&1 || error 'pveversion missing: run on a PVE host'
  command -v qm >/dev/null 2>&1 || error 'qm missing: run on a PVE host'
}
require_root(){ [[ "$(id -u)" == 0 ]] || error 'Run as root on the PVE host'; }
confirm(){
  [[ "${PVE_DRY_RUN:-0}" == 1 ]] && { info "DRY RUN: $*"; return 1; }
  [[ "${PVE_YES:-0}" == 1 ]] && return 0
  [[ -t 0 ]] || error 'Non-interactive write requires PVE_YES=1'
  local reply
  read -r -p "Type APPLY to $*: " reply
  [[ "$reply" == APPLY ]] || error 'Cancelled'
}
vm_exists(){ qm status "$1" >/dev/null 2>&1; }
vm_stopped(){ [[ "$(qm status "$1")" == *"stopped"* ]] || error "VM $1 must be stopped"; }
backup_conf(){
  local id="$1" dest
  dest="/var/lib/vz/snippets/inst-pve-backups"
  mkdir -p "$dest"
  local timestamp
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  cp -a "/etc/pve/qemu-server/$id.conf" "$dest/$id.$timestamp.conf"
  info "Config backup: $dest/$id.$timestamp.conf (NOT a VM data backup)"
}
next_slot(){
  local id="$1" prefix="$2" n
  for ((n=0;n<16;n++)); do
    if ! qm config "$id" | grep -Eq "^${prefix}${n}:"; then printf '%s%s' "$prefix" "$n"; return; fi
  done
  error "No free $prefix slot"
}
audit(){
  info "PVE: $(pveversion | head -n 1)"
  info "Kernel: $(uname -r)"
  if grep -Eqi 'vmx|svm' /proc/cpuinfo; then info 'CPU virtualization flag: present'; else info 'CPU virtualization flag: missing'; fi
  if [[ -d /sys/kernel/iommu_groups ]] && find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    info 'IOMMU groups: present'
  else
    info 'IOMMU groups: missing; check firmware BIOS and kernel cmdline'
  fi
  info "Kernel cmdline: $(cat /proc/cmdline)"
  if command -v lspci >/dev/null 2>&1; then lspci -nn | grep -Ei 'vga|3d controller|audio|ethernet|network|nvme' || true; fi
  info 'No host settings have been changed.'
}
devices(){
  command -v lspci >/dev/null 2>&1 && lspci -Dnn || info 'Install pciutils for PCI inventory'
  info 'Disk identifiers (inspect carefully; never use the host system disk):'
  if [[ -d /dev/disk/by-id ]]; then find /dev/disk/by-id -maxdepth 1 -type l -printf '%f -> %l\n' | sort; fi
}
vms(){ qm list; }
vm_clone(){
  local template="${1:-}" id="${2:-}" name="${3:-}"
  is_id "$template" && is_id "$id" || error 'Template and new VM ID must be numeric'
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || error 'Name must contain 1-63 letters/digits/dots/hyphens/underscores'
  vm_exists "$template" || error "Template $template not found"
  vm_stopped "$template"
  ! vm_exists "$id" || error "VM $id already exists"
  qm config "$template" | grep -q '^template: 1' || error 'Source must be a PVE template'
  info "Clone template $template to VM $id ($name) (full clone)"
  confirm 'clone VM' || return 0
  qm clone "$template" "$id" --name "$name" --full 1
  info 'Clone completed. VM not started. Configure storage/network and check before starting.'
}
pci_group(){
  local pci="$1" sys="/sys/bus/pci/devices/$1"
  [[ -d "$sys" ]] || error "PCI device $pci not present"
  [[ -e "$sys/iommu_group" ]] || error "No IOMMU group for $pci"
  info "IOMMU group for $pci:"
  for p in "$sys"/iommu_group/devices/*; do printf '  %s\n' "${p##*/}"; done
}
pci_attach(){
  local id="${1:-}" pci="${2:-}" slot
  is_id "$id" || error 'Invalid VM ID'
  is_pci "$pci" || error 'Invalid PCI BDF'
  [[ "$pci" == *:*:* ]] || pci="0000:$pci"
  vm_exists "$id" || error 'VM not found'
  vm_stopped "$id"
  pci_group "$pci"
  [[ -d /sys/kernel/iommu_groups ]] || error 'IOMMU must be enabled first'
  if grep -qE "(^|,)host=${pci#0000:}" /etc/pve/qemu-server/*.conf 2>/dev/null; then error 'PCI device appears assigned to a VM'; fi
  slot="$(next_slot "$id" hostpci)"
  info "Will add $pci as $slot to VM $id. Passing through a NIC/GPU can disconnect the host."
  confirm 'attach PCI device' || return 0
  backup_conf "$id"
  qm set "$id" --"$slot" "$pci,pcie=1"
  info 'Device added. Check IOMMU isolation, host driver binding and VM firmware before starting.'
}
disk_attach(){
  local id="${1:-}" disk="${2:-}" slot target
  is_id "$id" || error 'Invalid VM ID'
  [[ "${PVE_ALLOW_DISK_ATTACH:-0}" == 1 ]] || error 'Whole-disk passthrough requires explicit PVE_ALLOW_DISK_ATTACH=1 after checking host storage'
  [[ "$disk" == /dev/disk/by-id/* && "$disk" != *..* ]] || error 'Only /dev/disk/by-id/* is accepted'
  [[ -L "$disk" ]] || error 'Disk identifier not found'
  target="$(readlink -f "$disk")"
  [[ -b "$target" ]] || error 'Target is not a block device'
  [[ "$target" =~ ^/dev/(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+)$ ]] || error 'Whole physical disk required'
  vm_exists "$id" || error 'VM not found'
  vm_stopped "$id"
  if lsblk -nrpo MOUNTPOINT "$target" | grep -q '[^[:space:]]'; then error 'Disk or a partition is mounted'; fi
  if pvs --noheadings -o pv_name 2>/dev/null | grep -Fqx "$target"; then error 'Disk is an LVM physical volume'; fi
  if findmnt -rn -o SOURCE | grep -Fq "$target"; then error 'Disk is used by the host'; fi
  # Any holder (mdraid, dm-crypt, LVM, multipath) makes whole-disk passthrough unsafe.
  if find "/sys/class/block/${target##*/}/holders" -mindepth 1 -print -quit | grep -q .; then error 'Disk has active device-mapper/RAID holders'; fi
  slot="$(next_slot "$id" scsi)"
  info "Will attach $disk ($target) to VM $id as $slot; guest can ERASE ALL data."
  confirm 'attach whole disk' || return 0
  backup_conf "$id"
  qm set "$id" --"$slot" "$disk"
}
vgpu(){
  audit
  if command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi -L || true; else info 'nvidia-smi absent'; fi
  if lsmod | grep -Eq '^nvidia_vgpu_vfio '; then info 'nvidia_vgpu_vfio loaded'; else info 'vGPU host driver not loaded'; fi
  info 'vGPU provisioning is NOT automated: GPU/driver/license/kernel and mdev compatibility must be checked individually.'
  info 'GTX model series alone does not guarantee official NVIDIA vGPU support.'
}
menu(){
  local c id pci disk name template
  while true; do
    printf '\n--- PVE tools v%s ---\n1  Host audit\n2  PCI/disk inventory\n3  List VMs\n4  Clone template\n5  PCI passthrough\n6  Whole-disk attach\n7  vGPU diagnostics\n0  Exit\n' "$VERSION"
    read -r -p 'Choice: ' c || return 0
    case "$c" in
      1) audit;; 2) devices;; 3) vms;;
      4) read -r -p 'Template VM ID: ' template; read -r -p 'New VM ID: ' id; read -r -p 'New name: ' name; vm_clone "$template" "$id" "$name";;
      5) read -r -p 'Stopped VM ID: ' id; read -r -p 'PCI BDF: ' pci; pci_attach "$id" "$pci";;
      6) read -r -p 'Stopped VM ID: ' id; read -r -p 'Disk /dev/disk/by-id/...: ' disk; disk_attach "$id" "$disk";;
      7) vgpu;; 0) return 0;; *) info 'Unknown option';;
    esac
  done
}
main(){
  case "${1:-menu}" in
    --help|-h|help) usage; return;;
    audit|devices|vms|vgpu|menu|vm-clone|passthrough|disk-attach) ;;
    *) usage; error 'Unknown command';;
  esac
  require_host
  case "${1:-menu}" in
    audit) audit;; devices) devices;; vms) vms;; vgpu) vgpu;;
    vm-clone) require_root; vm_clone "${2:-}" "${3:-}" "${4:-}";;
    passthrough) require_root; pci_attach "${2:-}" "${3:-}";;
    disk-attach) require_root; disk_attach "${2:-}" "${3:-}";;
    menu) require_root; menu;;
  esac
}
main "$@"
