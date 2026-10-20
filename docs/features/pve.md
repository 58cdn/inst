# PVE 虚拟机部署与直通工具（实验性）

在 **Proxmox VE 宿主机** 使用 `inst --pve`，或在 Unix 主菜单中选择「PVE 虚拟机与直通工具」。需要 root，且必须存在 `pveversion`、`qm`；在 macOS、普通 Linux、WSL 和 Windows 上不显示该菜单项。

## 已实现

- **只读自检**：PVE 与内核版本、CPU 虚拟化标志、IOMMU 分组、内核命令行、PCI 设备。
- **设备清单**：`lspci -Dnn` 和 `/dev/disk/by-id`（不修改配置）。
- **虚拟机清单**：`qm list`。
- **从已有 PVE 模板创建 VM**：使用 `qm clone --full 1`，要求模板已停止，校验目标 VMID 和名称。创建后默认不启动。
- **PCI 直通**：对已停止 VM 使用 `qm set --hostpciN`，验证 PCI BDF、IOMMU 分组、空闲槽位、已分配状态，操作前备份 VM 配置。
- **整盘挂载**：使用 `/dev/disk/by-id/*` 指向的整盘，拒绝常见挂载中、LVM PV、device-mapper/RAID holder 的磁盘，操作前备份 VM 配置。**仍须由管理员在宿主机核实磁盘用途**。
- **vGPU 诊断**：检查 NVIDIA 驱动及 `nvidia_vgpu_vfio` 状态；不自动下载非官方驱动或绕过许可。
- **预览与确认**：`PVE_DRY_RUN=1` 不执行 VM 修改；每个实际写入步骤要求输入 `APPLY`，自动化调用可以设置 `PVE_YES=1`，但不绕过前置检查。

## 用法

```bash
# 完整交互菜单（在 PVE 宿主机运行）
inst --pve

# 单独从仓库获取审阅后再运行（建议不要直接 curl | bash）
curl -fL https://raw.githubusercontent.com/58cdn/inst/master/scripts/pve-tools.sh -o pve-tools.sh
bash -n pve-tools.sh
sudo bash pve-tools.sh audit
sudo bash pve-tools.sh devices
sudo bash pve-tools.sh vms
sudo bash pve-tools.sh vm-clone 9000 120 ubuntu-test
sudo bash pve-tools.sh passthrough 120 0000:05:00.0
sudo bash pve-tools.sh disk-attach 120 /dev/disk/by-id/ata-EXAMPLE
sudo bash pve-tools.sh vgpu
```

`PVE_DRY_RUN=1` 应用于独立模块的写入命令；注意主入口 `inst --pve --dry-run` **只预览模块下载，不进入交互菜单**。

## 限制与风险

截图中所列的 Windows XP/7/10/11/Server、Ubuntu、Debian、CentOS、NAS、OpenWrt、软路由和 Android 等系统不能直接凭操作系统名称“一键安装”。当前实现使用**已经由管理员创建、审阅和维护的 PVE 模板**；ISO 下载、无人值守安装、驱动、磁盘容量和许可不自动处理。部分旧系统的官方生命周期已经结束。

**GPU/网卡直通可能导致宿主机黑屏、断网、无法 SSH，整盘直通可能造成数据永久损坏。** 配置备份不是 VM 数据备份，变更前必须单独备份 VM 数据与宿主机；验证 IOMMU 分组是否隔离，确认目标设备不承载宿主机启动盘、网络或存储。不要在唯一管理网卡、系统盘或生产设备上试验。

GPU vGPU 依赖 NVIDIA 官方支持清单、特定驱动分支、宿主机内核、许可证与 guest 驱动。**不能承诺 GTX 7/10/20 或 P 系列全部支持，也不支持 AMD 的 NVIDIA vGPU**。本模块只提供只读检查，尚不包含图中所示 vGPU 宿主驱动安装、授权、去虚拟化、批量克隆、修改显存等操作。

可选的下一阶段模块：模板镜像清单与校验、离线 cloud-init/无人值守安装、GPU VFIO 绑定辅助向导、SR-IOV 可用性检测、批量 VM/模板部署和回滚演练。涉及宿主机内核和网卡驱动的部分必须先经过真实硬件测试。
