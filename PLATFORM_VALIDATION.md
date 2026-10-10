# Phase 0 平台验证报告

日期：2026-10-09（Asia/Shanghai）  
状态：**已完成平台验证；生产功能未开始**

## 环境

| 项目 | 实测值 |
|---|---|
| 机器 | MacBookAir10,1；Apple M1；16 GiB 统一内存 |
| 系统 | macOS 15.7.4（24G517） |
| 开发工具 | Xcode 16.3（16E140）；Swift 6.1 编译器，Swift 5 语言模式 |
| SDK | macOS 15.4 SDK；部署目标 macOS 15.0；arm64 |
| 显示器 | 内置 Retina 屏 + Sidecar 虚拟显示器；本次未接物理外接屏 |

已直接核对本机 SDK 的 `SCScreenshotManager.h`、`SCStream.h` 和 `SCShareableContent.h`：`captureImage(contentFilter:configuration:)` 对应 API 自 macOS 14.0 可用；`SCContentFilter(display:excludingApplications:exceptingWindows:)`、`contentRect` 和 `pointPixelScale` 在当前 SDK 中可用。没有使用仅从 macOS 15.2 开始提供的 `captureImage(in:)`。

## 已执行验证

- 建立原生 AppKit 菜单栏 Xcode 项目；Debug 与 Release 均构建成功，Swift 完整并发检查未报告源码警告。
- 应用包使用本机 Apple Development 身份签名后，以一次性 `--headless-probe` 入口运行；屏幕捕捉权限预检通过，实际完成两块显示器的截图与编码。常规启动不会自动截图。
- `SCShareableContent` 同批只枚举一次；两块显示器按顺序截图、编码；每张图 JPEG（质量 0.88）和 HEIC（质量 0.88）均能重新解码，尺寸与返回的 `CGImage` 一致，字节数非零。临时图片在每次验证后删除。
- 内置屏本次截图为 **2880 × 1800** 像素；Sidecar 为 **2732 × 2048** 像素。实际截图尺寸作为最终值记录，没有借用另一屏的缩放比例。
- 10 批、每批 2 屏的连续进程验证全部成功。下表是这 10 批的一次性探针基准，原始数据见 `Validation/baseline-2026-10-09.jsonl` 和 `Validation/baseline-2026-10-09-time.txt`。

| 指标 | 最小值 | 中位数 | 最大值 |
|---|---:|---:|---:|
| 显示器枚举 | 0.096 s | 0.113 s | 0.200 s |
| 两屏截图调用耗时合计 | 0.133 s | 0.205 s | 0.334 s |
| 两屏 JPEG 编码耗时合计 | 0.038 s | 0.046 s | 0.123 s |
| 两屏 HEIC 编码耗时合计 | 0.108 s | 0.120 s | 0.237 s |
| 两屏 JPEG 文件总量 | 1,643,197 B | 1,643,455 B | 1,659,827 B |
| 两屏 HEIC 文件总量 | 768,095 B | 768,197 B | 775,298 B |

10 批进程的 `/usr/bin/time -l` 结果：约 **5.95 s** 墙钟时间、**0.96 s** 用户态 CPU、**0.47 s** 内核态 CPU、**102.5 MiB** 最大 RSS、**63.1 MiB** 峰值 Memory Footprint。这是开发探针的测量值，包含双格式编码与图片校验，不能视为正式应用每 30 秒运行时的资源预算。单次进程四轮独立测量的峰值 Memory Footprint 约 59.7–61.1 MiB。

## 局限与后续验证

- 当前账户已有可用的屏幕捕捉授权；**首次授权弹窗、撤销后的提示和重启要求尚未实测**，将在权限与正式界面阶段验证。
- 第二块屏是 Sidecar 虚拟显示器；物理 1080p/1440p/4K、旋转、镜像、热插拔和不同缩放仍需真实设备场景验证。
- 10 批的峰值没有显示明显无界增长迹象，但没有逐批常驻内存曲线，不能据此断言长期无泄漏。8 小时与更长驻留测试安排在发布验收阶段。
- JPEG 与 HEIC 速度和体积只来自当前屏幕内容；尚未评价小字体质量、能耗和 WindowServer 增量，不能据此决定正式默认格式。
- 菜单栏交互入口已构建，但自动化桌面控制当时超时，**未完成菜单点击的人工交互验收**。这不影响已执行的应用包截图验证；交互流程将在正式 UI 阶段验收。
- 尚未测量“工具关闭、单屏、双屏、重负载”的对照组；这属于 Phase 5。

## 结论

目标机器、系统与 SDK 满足规范基线；指定的单帧 ScreenCaptureKit API 可以在当前 macOS 15 环境编译并完成双显示器逐屏截图。可以进入 Phase 1 核心采集引擎开发。生产级权限流程、存储、稳定运行与最终性能目标均未在本阶段宣称通过。
