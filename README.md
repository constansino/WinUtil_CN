# WinUtil 中文汉化版（非官方）— 2026-01-03/Release 25.12.18同步版本
<img width="2000" height="1583" alt="PixPin_2026-01-03_12-08-32" src="https://github.com/user-attachments/assets/fa871cb1-4d96-4f2e-9a9d-99730a720812" />


首先非常感谢 Chris Titus Tech 以及所有贡献者开发并维护 WinUtil。这个工具把“安装软件 / 系统优化 / 修复 / 更新策略 / MicroWin”等常用功能整合得非常清晰，对普通用户也很友好。

为方便中文用户理解每个选项的意义，我基于 **2026-01-03 我同步到的 WinUtil 版本**制作了一个 **中文汉化 + 功能说明**版本，并开放给社区使用与共同维护。

> 免责声明：  
> - 本汉化版为个人维护的**非官方**版本，与上游无隶属关系。  
> - 我尽量只翻译 UI 文本与说明，不改动功能逻辑；但系统优化类工具仍存在风险，请自行评估并做好备份。  
> - 如你更信任上游，请以官方版本为准。

---



## 使用方法（建议）

###  一。傻瓜式
powershell管理员执行

```powershell
irm "https://raw.githubusercontent.com/constansino/WinUtil_CN/refs/heads/main/winutil.zh_CN.commented.20260103.ps1" | iex
````
### 二。更推荐的方式：下载到本地后运行（更安全、可审计）
1. 下载汉化版脚本到本地（`winutil.zh_CN...ps1`）
2. 打开 PowerShell（建议管理员权限）
3. 解除“来自互联网文件”的锁定（避免无法运行/闪退）：

```powershell
Unblock-File -Path ""你的目录\winutil.zh_CN.commented.20260103.ps1""
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\winutil.zh_CN.commented.20260103.ps1
````

> 为什么要 Unblock-File：
> Windows 会对从浏览器下载的脚本打上“Mark of the Web”，导致执行被限制或出现各种异常。解除锁定后更稳定。

---

## 汉化范围（已完成）

### 1) UI 顶部导航与通用按钮
- Install / Tweaks / Config / Updates / MicroWin 等导航标签
- 常用按钮、提示文本、部分弹窗提示

### 2) Tweaks 页面（重点）
- **功能项标题：中文化**
- **功能项解释：补充中文说明**（帮助理解“这个开关到底改了什么，会影响什么”）
- 分组标题与注意事项（例如 Advanced Tweaks - CAUTION）

> 说明：WinUtil 的很多条目不是写死在 XAML 里，而是来自脚本内部的配置（例如 tweaks 配置集合）。因此单纯汉化 XAML 会“看起来只翻了少量文字”。本汉化版把“配置层的条目标题/说明”也一起做了中文化。

### 3) 其他页面（逐步完善中）
- Install / Config / Updates / MicroWin：已汉化常用区域的标题与说明
- 软件条目名称（例如 7-Zip、VS Code）通常保留产品英文名，避免用户对照困难

---


## 后续维护汉化的方法（给贡献者）

为了尽量降低与上游合并冲突，本汉化遵循以下原则：

1. **不改动功能逻辑**
   不改注册表路径、命令、参数、键名、逻辑分支；只处理用户可见文本（标题/描述/提示）。

2. **优先在“配置层”维护翻译**
   WinUtil 很多 UI 文本来自配置集合（例如 tweaks 项的 Title/Description）。
   因此维护时建议只更新对应配置项的显示字段，而不是改内部 key/逻辑判断字段。

3. **建议用 patch / diff 方式维护**

   * 上游更新后先同步原版脚本
   * 再应用汉化 patch
   * 对照冲突位置补齐新增条目的翻译

如果你希望参与维护：

* 提交 PR 增补新条目的中文解释
* 或提交 issue 标注“哪一项翻译/解释不准确、需要更好的中文描述”

---

再次感谢上游开发者与社区贡献者！
