# TXMascot-macOS

华硕天选姬（ASUS 天选姬桌宠）的 macOS 移植版。把 Windows 的 WPF 桌宠程序逆向出动画帧资源，用原生 ObjC + AppKit 重新实现了一个 macOS 桌宠。

> 仅供学习研究使用。天选姬角色形象及相关素材版权归华硕（ASUS）所有，本仓库只包含移植代码，**不含任何角色动画资源**。

## 功能

- 桌宠常驻：无边框透明悬浮窗口，多桌面/全屏可见，可拖动
- 随机待机 / 看表演（随机动作）、吃面等经典动作还原
- 散步模式：屏幕四边游走
- 单击互动、双击触发 Gift/Event 彩蛋、猫咪彩蛋
- 换装模式（黑白新装）：待机/表演/互动全动作跟随
- 找茬小游戏：像素差分自动出题 + 计分
- AI 对话气泡（在线 / 离线词库）
- 系统状态、壁纸更换、定时提醒
- 50%/100% 大小、不透明度调节、位置记忆
- 开机自启动（SMAppService）、全局快捷键 ⌥⌘C、状态栏菜单

## 编译

```bash
clang -O2 -Wno-deprecated-declarations -fobjc-arc \
  -framework AppKit -framework AVFoundation -framework Carbon \
  -framework ServiceManagement -framework Foundation \
  -o TXMascot main.m
```

单文件源码，无第三方依赖，Xcode CLT 即可编译。

## 组包 App

```text
TXMascot.app/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/TXMascot
│   └── Resources/
│       ├── Actions/*.frames        # 帧序列（f0000.png ...）
│       ├── Game/Ep*/               # 找茬关卡 a.png / b.png / diffs.json
│       └── Sound/Voice/*.wav       # 语音
```

DMG 打包建议用 `dmgbuild` + 自绘背景图（Finder AppleScript 设背景会被 TCC 拦）。

## 资源提取原理

原版 Windows 包是多层嵌套安装器，动画帧藏在 .NET 程序集的内嵌资源里：

```text
外层 exe → 内嵌 7z → TX Mascot Installer.exe (.NET)
  → 托管资源 Installer.Source.TX Mascot Installer.msi
  → MSI 大流 = tx_app.exe (.NET) → 329 个 ManifestResource
```

每个 `Action.Image_Dll.*.dll` 资源内含 `DllTemplate.Images.lzma`：
LZMA-alone 压缩的 BinaryFormatter `Dictionary<string, PNG[]>`。
LZMA 解压后按 `\x89PNG ... IEND` 顺序切割即可得到帧序列，天然保持帧序。

## 已知的坑

- 本机 Xcode CLT 的 Swift 工具链存在 SwiftBridging modulemap 重复 bug，改用 ObjC + clang
- plist 存 `NSValue pointValue` 会静默失败，位置持久化改用 `posX` / `PosY` 数值
- `SMAppService` 的 ObjC 属性名是 `mainAppService`（Swift 才是 `mainApp`）
- `DailySuit_HideSomething` 组含全透明帧，进动作池会导致角色凭空消失
- `WalkAround_1/_4` 是站立挥手不是迈步，`WAM_*` 是猫——散步池只收 `_2/_3/_5/_6`
- CGWindowList 查窗口要按属主名「天选姬」过滤，不是 TXMascot

## License

MIT
