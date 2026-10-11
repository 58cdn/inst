# 网络与镜像

菜单 3 / `--mirrors` / `-Mirrors` 管理 npm/pnpm、pip、conda、nvm/pyenv 及支持的平台系统源。预设包含 tuna、aliyun、ustc、tencent、huawei、official。

系统源变更继续要求显式确认/应用参数并备份；GitHub 代理仅由用户显式配置。入口镜像发现与 payload 下载是不同职责，不将自选代理扩展为可信自动回退源。

[下载边界与参数](../../README.md#下载失败与回退) 保持不变：HTTPS、有限启动/停滞超时、可信路径白名单、校验及临时文件清理。
