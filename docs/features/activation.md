# 系统激活：状态与入口

Windows 菜单 **10** / `inst -Activation` 安装 `activation.ps1`、`activation.cmd`、`activation.md` 到 `%USERPROFILE%\.command`，按现有方式加入用户 PATH。该安装动作不激活系统、不打开网页，不需要扩大权限。新开 CMD / PowerShell 后运行 `activation`。兼容 Windows PowerShell 5.1 / PowerShell 7；状态查询与实际打开入口限 Windows 10/11 客户端，不支持 Server。

```powershell
activation                                     # 默认只读 Windows 状态
activation -Action Settings                    # 仅展示微软设置入口
activation -Action Settings -Open              # 显式请求打开激活设置
activation -Action Troubleshoot -Open          # 微软官方疑难解答说明页
activation -Action LicenseHelp                 # 已有许可证的官方使用说明
activation -Action MasReference                # 明确标识的第三方项目参考
activation -Action MasReference -Open -DryRun   # 预演，不打开、不下载
```

## 已实现

- 通过微软 `SoftwareLicensingProduct` 查询 Windows 产品的 Name、LicenseStatus，按 Windows ApplicationID 与已安装密钥记录过滤。不会读取完整产品密钥、固件密钥，不输出密钥后五位，不查询 Microsoft 账户或记录凭据。
- 逐条显示 Licensed、Unlicensed、宽限期、Notification 或 Unknown；不根据多条记录推断整机、Office、账户关联或永久有效。无记录/未知状态返回 `Unknown` 和退出码 2；查询或打开失败退出 1；成功查询/展示入口返回 0。未激活是有效查询结果，不是查询错误。
- 固定允许列表中的 Windows 激活设置、微软许可说明/疑难解答网页及 MAS GitHub 项目页。未指定 `-Open` 只输出参考地址；`-DryRun` 优先，不查询系统、不打开窗口。`OpenRequested` 只代表已请求系统打开入口，不能证明浏览器加载成功，更不代表激活成功。
- 无自动提权、产品密钥参数、密钥安装、激活命令、任务或服务修改。不修改 Windows Update、Defender 或 Office。

## 微软官方渠道

已有数字许可证或匹配版本的有效产品密钥，请在 Windows 激活设置完成操作。硬件变更/激活错误按微软疑难解答操作；组织批量许可由组织管理员处理。本工具不代替许可证购买、授权验证或账户登录。

[微软激活说明](https://support.microsoft.com/en-us/windows/activation/activate-windows) 明确区分技术激活状态与正版验证；**激活成功不等于获得正版许可，也不保证系统副本为正版**。

- [官方激活疑难解答](https://support.microsoft.com/en-us/windows/activation/using-the-windows-activation-troubleshooter)
- [Windows 设置 URI](https://learn.microsoft.com/en-us/windows/apps/develop/launch/launch-settings)（`ms-settings:activation`）
- [SoftwareLicensingProduct 与 LicenseStatus](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/sppwmi/softwarelicensingproduct)

## 文章与第三方参考：不是内置激活功能

需求文章：[《一条命令永久激活win11或win10系统》](https://zhuanlan.zhihu.com/p/1969108135680643154)，小黄人，编辑于 2025-11-04。文章介绍 MAS，菜单 1 为 Windows HWID（联网），菜单 2 为 Office Ohook（文中称离线）。这些是文章对第三方方法的描述，不是 inst 验证或承诺的效果。

[Microsoft Activation Scripts 项目](https://github.com/massgravel/Microsoft-Activation-Scripts) 由 massgravel 维护，**非微软官方许可渠道**。其 README 列出 `get.activated.win`，PowerShell 方法标注 Windows 8.1/10/11；该边界不表示本模块支持 Windows 8.1，也不表示任意 Windows/Office 版本都能激活。工具、网络和产品版本变化可能改变行为。项目采用 GPL-3.0；本仓库仅链接参考，不复制或分发其源码。

用户可显式打开项目页自行阅读；inst 不自动获取或执行脚本，不提供下载后执行的一键命令，不运行 HWID/Ohook、不验证其效果、不承诺永久激活，不绕过防护。运行第三方代码可能修改系统/许可组件，用户需自行核实来源、适用条件与授权。访问受限时停止，不改用其他域名或代理绕过站点限制。

Office 激活状态查询、Office 官方激活操作、实际 Windows 激活、第三方激活自动化均**未实现**。安装、`-All`、优化或后台更新不会触发第三方激活。

## 测试边界

测试使用 mock / dry-run；不在开发宿主或 CI 实际激活、启动网页/设置、下载第三方脚本或修改安全配置。真实设备的许可状态覆盖、系统 URI 处理器和浏览器交互尚未实机验证。官方来源核对于 2026-10-11。
