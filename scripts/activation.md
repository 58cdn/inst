# activation（Windows 激活状态与入口）

默认 `activation` 只读查询 Windows 10/11 状态，不激活系统、不读取或输出产品密钥。

- `activation -Action Settings`：显示微软激活设置入口。
- `activation -Action Troubleshoot`：显示微软官方疑难解答地址。
- `activation -Action LicenseHelp`：已有许可证的微软使用说明。
- `activation -Action MasReference`：第三方 MAS GitHub 项目参考，非微软官方许可渠道。
- 显式添加 `-Open` 才请求打开设置/网页；`-DryRun` 优先，不查询、不打开。

打开入口不代表激活成功；激活状态不证明正版许可。无记录/未知状态退出 2，查询/打开失败退出 1。Office 查询及实际激活未实现。不会下载或执行第三方激活脚本。

完整边界与来源：[功能说明](https://github.com/58cdn/inst/blob/master/docs/features/activation.md)。
