# 天选姬 Mac 版

## 交付物
- DMG: /Users/macmini/Desktop/天选姬_Mac版.dmg
- App: /Applications/TXMascot.app

## 技术要点
- 原版 TXMascot V4.1.4 是 WPF/.NET 程序，角色动画 = PNG 帧序列，封装在 Action.Image_Dll.*.dll 内嵌资源里
  （资源名 DllTemplate.Images.lzma = LZMA-alone 压缩的 BinaryFormatter Dictionary<string,PNG[]>）
- 提取链: 外层 exe → 内嵌 7z → TX Mascot Installer.exe(.NET) → 托管资源 Installer.Source.TX Mascot Installer.msi → MSI 大流 = tx_app.exe(.NET) → 329 个 ManifestResource
- 帧切割: LZMA 解压后按 \x89PNG..IEND 顺序 carve，天然保持帧序
- Mac 端: ObjC/AppKit 无边框透明窗口（floating、canJoinAllSpaces），12fps，点击触发 Interactive 动作，拖动移动，右键/状态栏菜单（大小/不透明度/看表演/退出）

## 重建 DMG
cd /tmp/tx_build  # 或 workspace txmascot-mac
clang -O2 -fobjc-arc -framework AppKit -framework Foundation -o TXMascot main.m
# 组包: Contents/MacOS/TXMascot + Resources/Actions/*.frames + Info.plist + icns
hdiutil create -volname "天选姬-Mac版" -srcfolder dmg_stage -format UDZO -o 天选姬_Mac版.dmg

## 坑
- 本机 CLT 的 Swift 工具链有 SwiftBridging modulemap 重复 bug（需 sudo 修复），改用 ObjC+clang
- CGWindowList 查窗口要按属主名「天选姬」过滤，不是 TXMascot
