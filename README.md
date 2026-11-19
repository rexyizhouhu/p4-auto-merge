# P4 自动合并工具

选择来源 CL（变更列表）合并到目标分支，冲突手动处理，最后自行提交。

当前源码为 **1.0.2**。GitHub 上现有 EXE / 安装包仍为 **1.0.1**；下列自动更新、新合并方式和独立 CL 窗口需运行当前源码，或等待 1.0.2 安装包发布。旧 EXE 不会自行获得更新功能。

## 1. 前置需求

- Windows x64，PowerShell 5.1、.NET Framework 4.8。
- 安装 P4 命令行和 P4V；终端中能运行 `p4`。
- 在 P4V 建好目标 stream 的 workspace，同步到最新，确保没有待提交文件或本地修改。

## 2. 使用前准备

在 PowerShell 中执行，先替换服务器地址、账号和 workspace 名称：

```powershell
p4 set P4PORT=服务器地址:1666
p4 set P4USER=你的账号
p4 set P4CLIENT=目标workspace名称
p4 login
```

源码会自动识别服务器模式：Unicode 使用 UTF-8，非 Unicode 不做字符集转换；无需手动设置 P4CHARSET。非 Unicode 服务器返回非 UTF-8 文本时会停止并提示。已发布的 1.0.1 安装包尚不包含此修复。

## 3. 使用操作

1. 从 [下载页](https://github.com/rexyizhouhu/p4-auto-merge/releases/latest)下载安装版，或解压便携版运行 EXE。源码版双击 [Start.cmd](./Start.cmd)。
2. 确认界面的服务器、账号与上面一致，选择目标 workspace、来源 stream、目标 stream。目标必须是该 workspace 实际绑定的分支。
3. 点击“加载来源 CL”（默认最近 1000 条），按编号、提交人或描述搜索后勾选；也可直接输入 CL 编号。
4. 独立的“已选择的 CL”窗口会随主界面打开，自动展示勾选及手动输入的 CL、提交人、说明和执行顺序。核对后点“1. 预览”→“2. 执行合并”。所选 CL 按编号升序合入同一个待提交 CL。
5. 遇到待处理项，在 P4V 中完成 Resolve，再回工具点“检查并继续”；全部完成后检查并手动提交。

- **跨分支**：勾选“允许跨分支合并”才显示其他目标分支。
- **强制重合并**：确认需要重新合入时勾选；忽略本次全部所选 CL 的合并历史，改变选项后重新预览。
- **合并方式**：默认“自动解决（不合并内容）”，也可选择其他 P4V Resolve 方式，见下文。
- **中断恢复**：选择原 workspace，点“恢复该 workspace 队列”；结果不确定时报错停止，先在 P4V 核对。

预览区可拖动分隔条上下调整。工具不会自动提交、同步或撤销文件；运行期间不要用其他工具操作同一 workspace。

已选 CL 窗口可独立移动、缩放或最小化；点击关闭会将其最小化，退出主程序时一并关闭。搜索隐藏的勾选项仍展示并参与合并，切换来源会清空旧选择。未知手动编号标记为未加载详情；窗口仅整理选择，执行前仍需点“1. 预览”。

## 4. 合并方式

选项与 [P4V 的 Resolve 方式](https://help.perforce.com/helix-core/server-apps/p4v/current/Content/P4V/branches.resolve.html)对应：

- **自动解决（不合并内容，默认） / Safe automatic resolve (no merging)**：P4 `-as`，需要合并内容时留给手工处理。
- **自动解决（允许无冲突合并） / Automatic resolve (allow merging)**：P4 `-am`，有冲突时仍留给手工处理。
- **自动解决（允许带冲突合并） / Automatic resolve (allow merging with conflicts)**：P4 `-af`，可能把含冲突标记的结果接受为已解决；本工具每个 CL 后暂停，人工检查并确认后继续。
- **接受来源 / Accept Source：来源 stream**：P4 `-at`，用来源覆盖目标，可能覆盖目标修改及接受删除等操作。
- **保留目标 / Accept Target：目标 stream**：P4 `-ay`，忽略来源修改，但会记录已解决的集成历史。

接受来源、保留目标选项会显示当前实际 stream 名称。改变方式需重新预览；执行确认框显示所选方式。活动队列保存并锁定方式，恢复时沿用；旧队列缺少该字段时仍按默认安全方式处理。该选项与跨分支、强制重新合并相互独立。

## 5. 自动更新与提醒

- **每次启动均检查** GitHub 最新正式 Release；检查在后台进行，不需要 Git 或 GitHub 账号。网络失败仅显示状态，不影响 P4 操作。
- 新版提示窗附发布日志，提供“更新”“取消”“跳过此版本”；窗内可直接设置“每次启动都提醒”“每周提醒一次”“每月提醒一次”“永不提醒”。取消或关闭提示窗也会保存频率。
- 每周按上次弹窗起 7 天计算，每月按一个日历月计算；跳过只针对该版本。永不提醒只关闭自动弹窗，后台检查仍执行。
- 底部“更新 / 设置”可改频率或手动检查。手动检查忽略跳过和频率限制；合并命令或活动队列未结束时，提示和安装均会推迟。
- 点击更新后下载官方 Release 安装包，并校验长度及 SHA-256；校验失败不执行安装。确认合并队列已结束后退出当前工具，释放运行锁，再启动安装向导。
- 安装版覆盖原安装目录，保留用户队列、诊断和更新设置。便携版点击更新会转为安装新版，保留原便携文件；源码启动点击更新只打开下载页。
- 更新配置及下载位于当前用户 `%LOCALAPPDATA%\FlamesTools\P4AutoMerge`，不会写入 P4。安装包目前未代码签名；SHA-256 用于检查下载完整性，发布源为本仓库 HTTPS Release。

## 6. 开发与发布

源文件通过 [Start.cmd](./Start.cmd)运行。更新、核心及隐藏界面验证分别为 [Test-Update.ps1](./Test-Update.ps1)、[Test-P4AutoMerge.ps1](./Test-P4AutoMerge.ps1)和 `P4AutoMerge.ps1 -HeadlessTest`；这些验证不执行真实合并、安装或项目编译。

获得编译授权后，先运行 [Build-Release.ps1](./Build-Release.ps1)生成内置脚本的 EXE，再以生成的包目录运行 [Build-Installer.ps1](./Build-Installer.ps1)。安装包脚本会输出同版本 `update.json`，包含安装包地址、大小、SHA-256 与 [CHANGELOG.md](./CHANGELOG.md)中的日志。

发布时创建对应 `v版本号` 的草稿 Release，上传安装包、压缩包、校验清单及 `update.json`，验证后再公开为最新正式版。客户端优先读取 `releases/latest/download/update.json`，避免共享网络触发匿名 API 限流；旧版发布缺少清单时回退 GitHub Release API。不要将未验证的安装包设为 latest，不要覆盖已发布的同版本安装包。
