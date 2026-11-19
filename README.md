# P4 自动合并工具

当前版本 **1.0.4**（安装包与源码一致），更新内容见 [CHANGELOG](./CHANGELOG.md)；历史版本可按 tag（如 `v1.0.1`、`v1.0.3`）回溯。

## 1. 前置需求

- Windows x64，PowerShell 5.1、.NET Framework 4.8。
- 安装 P4 命令行和 P4V，终端能运行 `p4`。

## 2. 使用前准备

替换下面的服务器、账号和 workspace 名称，在 PowerShell 执行：

```powershell
p4 set P4PORT=服务器地址:1666
p4 set P4USER=你的账号
p4 set P4CLIENT=目标workspace名称
p4 login
```

在 P4V 将目标 workspace 同步到最新，确保没有待提交文件或本地修改。

## 3. 使用操作

1. 从 [下载页](https://github.com/rexyizhouhu/p4-auto-merge/releases/latest)安装，或解压便携版运行 EXE。源码版双击 [Start.cmd](./Start.cmd)。
2. 确认服务器和账号，选择目标 workspace、来源分支、目标分支。目标分支必须与 workspace 一致。
3. 点击“加载来源 CL”（默认 1000 条），按 CL 编号或提交人搜索并勾选，也可在右侧“手动 CL”输入编号。
4. 核对已选 CL，点击“1. 预览”→“2. 执行合并”。合并方式保持默认即可。
5. 需手工处理时，在 P4V 完成 Resolve，再点“检查并继续”；全部完成后检查并手动提交。

- **跨分支**：需要其他目标分支时，勾选“允许跨分支合并”。
- **强制重合并**：需忽略所选 CL 的合并历史时开启，再重新预览。
- **更新提醒**：在“更新 / 设置”调整。

运行期间不要用其他工具操作同一 workspace。
