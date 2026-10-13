<div align="center">

# 🖥️ ScreenRecall

**macOS 原生轻量级屏幕历史时光机 · 100% 本地存储 · 零云端隐私**

[![Release](https://img.shields.io/github/v/release/RichardHuang0001/ScreenRecall?style=flat-square&color=3478F6)](https://github.com/RichardHuang0001/ScreenRecall/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2015.0%2B-blue?style=flat-square&logo=apple)](https://github.com/RichardHuang0001/ScreenRecall)
[![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon%20(arm64)-orange?style=flat-square)](https://github.com/RichardHuang0001/ScreenRecall)
[![License](https://img.shields.io/badge/license-PolyForm%20Noncommercial-red?style=flat-square)](LICENSE)
[![Privacy](https://img.shields.io/badge/privacy-100%25%20Local%20Only-success?style=flat-square)](LICENSE)

<p align="center">
  <a href="#-快速下载">📥 立即下载</a> •
  <a href="#-核心特性">✨ 核心功能</a> •
  <a href="#-使用指南">🚀 使用指南</a> •
  <a href="#-隐私与安全承诺">🔒 隐私承诺</a> •
  <a href="#-开发者指引">🛠️ 编译开发</a> •
  <a href="#-许可证--license">📜 许可证</a>
</p>

</div>

---

## 💡 为什么选择 ScreenRecall？

在日常使用 Mac 工作、学习或浏览时，我们经常遇到这样的烦恼：
- *“刚才看的那篇技术文章/设计图叫什么名字来着？忘了收藏标签页……”*
- *“刚刚终端里弹出的那行瞬时报错日志是什么？窗口不小心关了……”*
- *“昨天下午写方案时查过的某条关键数据，现在怎么都找不到了……”*

**ScreenRecall** 正是为此而生。它是一款为 macOS 深度打造的**原生轻量屏幕记忆工具**。在后台以极低资源开销定时记录屏幕状态，构建属于你自己的可回溯、可定位、可导出的**视觉时光胶囊**。

更重要的是：**你的数据只属于你。所有屏幕画面与元数据全部保存在你的 Mac 本机，永不联网上传。**

---

## ✨ 核心特性

| 功能 | 说明 |
| :--- | :--- |
| **🖥️ 原生多屏无缝采集** | 深度集成 Apple 官方 ScreenCaptureKit，支持多显示器独立识别与异步捕捉，不阻塞主线程，无掉帧卡顿。 |
| **⚡ 极简资源能耗开销** | 硬件加速图像编码，内建系统压力感知：在系统睡眠、高能耗压力或会话锁定期间智能暂停，保证全天候静默驻留。 |
| **🎛️ 随心自定记录节奏** | 顶部菜单栏常驻指示，支持自由配置采集间隔（15s / 30s / 45s / 60s / 2m / 5m），支持一键暂停或立即记录。 |
| **🛡️ 灵活隐私排除黑名单** | 自动发现正在运行的前台应用，一键添加隐私排除；包含敏感信息的应用在截图时会被自动忽略。 |
| **⏱️ 沉浸时光画廊回溯** | 直观的时间线分页界面，按“全部 / 今天 / 近1小时 / 近4小时 / 自定义日期”快速筛选，支持全分辨率预览与原图复制导出。 |
| **📦 本地自动循环轮转** | 内置高效 SQLite 索引与容量管理，可自由配置历史保留天数与存储上限，超出限制自动平滑清理最早快照。 |

---

## 📥 快速下载

最新正式版本：**v0.6.5**

| 安装包 | 适用平台 | 架构 | 校验值 (SHA-256) |
| :--- | :--- | :--- | :--- |
| [**ScreenRecall-0.6.5.dmg**](https://github.com/RichardHuang0001/ScreenRecall/releases/download/v0.6.5/ScreenRecall-0.6.5.dmg) | macOS 15.0+ | Apple Silicon (M1/M2/M3/M4) | `87e96700923158bc6e4764778aaeb3ceed06d3b8d84d169adb1789f023b6d789` |

> [!TIP]
> 也可以前往 [**GitHub Releases 页面**](https://github.com/RichardHuang0001/ScreenRecall/releases/latest) 查看完整的发布记录与变更日志。

---

## 🚀 使用指南

### 1. 安装与首次打开

1. 下载 **`ScreenRecall-0.6.5.dmg`**；
2. 双击打开镜像，将 **`ScreenRecall.app`** 拖拽至 **`Applications`（应用程序）** 文件夹；
3. **首次打开安全提示**：
   - 本开源版本采用脱敏无身份的 ad-hoc 签名构建，未进行 Apple 付费商业公证；
   - 若系统 Gatekeeper 提示“无法验证开发者”，请在访达（Finder）的「应用程序」目录中，**按住 Control 键点按应用**（或右键），在弹出菜单中点击 **「打开」**，随后在确认框中再次点击「打开」即可正常启动。

### 2. 授予屏幕录制权限

1. 启动应用后，菜单栏右上角将出现层次化双屏图标；
2. 首次启动**默认不会自动截屏**；
3. 点击菜单栏图标打开「屏幕历史」窗口，点击右上角齿轮 ⚙️ 打开设置；
4. 在「定时采集」选项卡中点击 **「前往授权」**，在 macOS「系统设置 → 隐私与安全性 → 屏幕制作与系统音频录制」中勾选允许 **ScreenRecall**；
5. 回到设置页，授权状态将**自动感知并刷新**，无需反复重启。

### 3. 日常使用

- **菜单栏图标**：悬停可查看当前状态与最后一次记录时刻，单机即刻唤出历史画廊。
- **控制采集**：历史窗口顶部提供「启用 / 暂停 / 继续」以及「立即记录当前屏幕」快捷操作。
- **检索与预览**：点击历史流缩略图可开启沉浸式大图预览，支持跨屏幕自由切换，快捷键支持一键复制到剪贴板或在访达中定位原图文件。
- **排除私密应用**：在「设置 → 隐私过滤」中直接从当前运行列表勾选需排除的应用（如密码管理器、聊天窗口等）。

---

## 🔒 隐私与安全承诺

数据隐私是 ScreenRecall 的第一准则：

1. **100% 纯本地运行**：应用没有内嵌任何第三方统计 SDK、追踪器或云端同步服务。
2. **私有沙盒存储**：所有截屏图片保存在本机受保护的沙盒数据目录（`~/Library/Application Support/ScreenRecall`），不会混入系统相册或公共目录。
3. **不常驻后台轮询鉴权**：权限状态仅在用户主动唤起设置窗口或应用重获焦点时由事件驱动触发，绝不浪费多余后台周期。
4. **一键彻底清空**：随时可以在设置中点击「清空全部历史」，即刻原子化抹除数据库记录与本地图片文件。

---

## 🛠️ 开发者指引

如果您希望从源码编译或对项目进行二次开发：

### 编译构建

要求环境：macOS 15.0+，Xcode 16.0+。

```sh
# 克隆仓库
git clone https://github.com/RichardHuang0001/ScreenRecall.git
cd ScreenRecall

# 命令行调试构建
xcodebuild -project ScreenRecall.xcodeproj -scheme ScreenRecall -configuration Debug -destination 'platform=macOS' build
```

### 自动化测试套件

本仓库维护了覆盖核心调度、并发隔离与异常恢复的自动化测试：

```sh
# 核心调度与状态机测试（涵盖代次失效、多屏撤回、挂起唤醒）
zsh Validation/run-engine-tests.sh

# 用户偏好设置与排除规则测试
zsh Validation/run-preferences-tests.sh

# 存储持久化与 SQLite 索引测试
zsh Validation/run-storage-tests.sh

# 跨进程异常退出 (SIGKILL) 崩溃恢复自愈测试
zsh Validation/run-storage-crash-test.sh

# 多屏 JPEG/HEIC 编解码与性能基准评估
python3 Validation/run-performance-benchmark.py
```

### 匿名发布打包

为他人或社区分发安装包时，运行打包脚本即可自动产出剥离开发者个人证书的匿名 DMG：

```sh
zsh Tools/package-release.sh <版本号>
```

> [!NOTE]
> 仓库工程协作、敏感信息规避及单实例约定请查阅权威规范文档 [`AGENTS.md`](AGENTS.md)。

---

## 📜 许可证 / License

本项目采用 **[PolyForm Noncommercial License 1.0.0](LICENSE)** 许可协议（**严格禁止商用**）：

- **个人与非商业用途**：完全免费供个人使用、学习研讨、学术研究及非商业性质的改进与分享。
- **商业用途严格禁止**：未经版权所有者明确书面授权，严禁任何形式的商业销售、付费分发、打包转售、闭源商业集成或作为商业营利服务提供。
- 详情请查阅仓库完整 [LICENSE](LICENSE) 文件。
