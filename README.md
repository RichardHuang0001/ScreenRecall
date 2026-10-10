# ScreenRecall

macOS 原生轻量屏幕历史工具。目前已实现 **Phase 0–5**：平台验证、核心采集、持久化与崩溃恢复、权限及系统保护、历史与设置界面、性能优化。正式路径将截图保存在本机私有目录；首次启动默认关闭，须用户主动启用。版本 0.6.4 为本机试用版，阶段 6 的长期发布验收尚未完成。

## 打开与构建

在 Xcode 16.3 或兼容版本中打开 `ScreenRecall.xcodeproj`，选择 `ScreenRecall` scheme 和本机 macOS 目标后构建运行。命令行构建：

```sh
xcodebuild -project ScreenRecall.xcodeproj -scheme ScreenRecall -configuration Debug -destination 'platform=macOS' build
```

当前项目使用 macOS 15.0 部署目标、arm64、Swift 5 语言模式和完整并发检查。Bundle ID 为 `com.screenrecall.app`。本机开发签名或后续正式签名可在 Xcode 的 Signing & Capabilities 中配置；Phase 0 构建测试使用了 `CODE_SIGNING_ALLOWED=NO`，并为运行探针的 Debug 应用单独使用本机 Apple Development 证书签名。

本机自用包在 `dist/`：可直接打开 `ScreenRecall.app`（本机 Apple Development 证书签名，屏幕录制权限稳定，仅限本机自用与快速迭代）。

## 对外发布打包

面向他人分发的安装包请用脚本生成。它会用无身份的 ad-hoc 签名覆盖掉 Apple Development 证书（该证书名称含个人邮箱），确保产物不残留个人信息：

```sh
zsh Tools/package-release.sh 0.6.5
```

产物为 `dist/ScreenRecall-<版本>-local-preview.dmg`，脚本会自动校验签名与二进制中不含个人身份。`dist/`、`*.dmg` 已加入 `.gitignore`，安装包不进入版本库。`dist/试用说明.txt` 写有首次启用、数据保留和试用反馈方法。

## 当前使用方式

普通启动显示一个固定宽度的菜单栏图标，悬停可看状态，点击直接打开屏幕历史窗口；第一次不会自动截屏。窗口顶部可启用、暂停、继续或立即记录，齿轮按钮打开二级设置页，管理排除应用 Bundle ID、保留时间与容量、登录后启动、本地数据和诊断。启用后每 45 秒逐屏截图。“屏幕历史”按时间分页加载；点击缩略图可预览，复制原图、导出或在 Finder 中显示。系统睡眠、会话不可采集、严重内存或热压力会暂停新批次。窗口关闭后，已启用的后台采集仍继续。

## 验证入口

设置页中的“平台验证…”可重复阶段 0 的 JPEG/HEIC 对照探针。为自动测量，可编译 `Validation/ProbeCLI.swift` 与 `ScreenRecall/Validation/PlatformProbe.swift` 为一次性命令行程序。它调用相同的探针实现；见 `PLATFORM_VALIDATION.md`。

阶段 1 自动测试：`zsh Validation/run-engine-tests.sh`。测试结果与真实 30 秒采集记录见 `PHASE1_VALIDATION.md`。

阶段 2 自动测试：`zsh Validation/run-storage-tests.sh`；跨进程强制退出恢复测试：`zsh Validation/run-storage-crash-test.sh`。存储模块采用 SQLite 与本地私有图片目录，不上传图片；阶段 2 结果见 `PHASE2_VALIDATION.md`。

阶段 3 首次启用与排除设置测试：`zsh Validation/run-preferences-tests.sh`；系统暂停语义由引擎测试覆盖。已签名应用连续双屏持久化实测见 `PHASE3_VALIDATION.md`。真实锁屏、外接屏热插拔和长期驻留仍需在后续验收中完成。

阶段 4 以显式 `--phase4-smoke` 入口生成独立的合成历史，验证分页、日期定位、缩略图与文件操作；报告和界面截图见 `PHASE4_VALIDATION.md`。截图中的蓝橙色图片只是测试样本。

阶段 5 资源对照、JPEG/HEIC 选择与剩余性能限制见 `PERFORMANCE.md`。阶段 6 仍需长期驻留、屏幕变化、更新迁移和电池模式验收。
