# P4 自动合并工具

选择来源 CL（变更列表）合并到目标分支，冲突手动处理，最后自行提交。

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
4. 点击“查看已选 CL”核对选择，再点“1. 预览”→“2. 执行合并”。所选 CL 按编号升序合入同一个待提交 CL。
5. 遇到待处理项，在 P4V 中完成 Resolve，再回工具点“检查并继续”；全部完成后检查并手动提交。

- **跨分支**：勾选“允许跨分支合并”才显示其他目标分支。
- **强制重合并**：确认需要重新合入时勾选；忽略本次全部所选 CL 的合并历史，改变选项后重新预览。
- **自动 Resolve**：仅使用 `-as`，需要合并内容的文件留给手工处理。
- **中断恢复**：选择原 workspace，点“恢复该 workspace 队列”；结果不确定时报错停止，先在 P4V 核对。

预览区可拖动分隔条上下调整。工具不会自动提交、同步或撤销文件；运行期间不要用其他工具操作同一 workspace。
