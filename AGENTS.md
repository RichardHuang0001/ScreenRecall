# AGENTS.md — 本项目对 AI Agent 的强制约定

> **本文件是权威规范。** 任何 Agent（Codex / Claude / 其他）在**修改、提交、打包、推送、发版**本仓库前，必须先读本文件。
> 当本文件与其它历史文档（`LOCAL_PREVIEW.md`、`PHASE*_VALIDATION.md`、`ACCEPTANCE_AUDIT_*.md`、`DEVELOPMENT_PLAN.md` 的早期条目、`README.md` 的旧版本）冲突时，**一律以本文件为准**。

---

## 0. 一句话

ScreenRecall 是 macOS 原生屏幕历史工具。本仓库对**个人身份信息（PII）零容忍**：提交、构建产物、文档中都不得出现作者姓名、邮箱、本机用户名/路径、主机名、设备标识。

## 1. 仓库身份（现行，2026-10-10 起）

- 远端：`git@github.com:RichardHuang0001/ScreenRecall.git`（SSH）
- 可见性：public
- 默认分支：`main`
- ⚠️ 本仓库在 2026-10-10 因旧历史泄露而被**删除并重建**：旧提交 SHA 全部作废，任何旧 SHA / 旧 clone / 旧 fork 都不代表当前仓库，不要再引用。

## 2. 提交身份（硬性）

本仓库已用 `git config --local` 固定为中性身份：

```
user.name  = ScreenRecall
user.email = noreply@screenrecall.local
```

- **不得**改回含真实姓名的身份；**不得**引入个人邮箱。
- 在其它环境克隆本仓库后，务必先本地设置（或设 `GIT_AUTHOR_*` / `GIT_COMMITTER_*` 环境变量）：
  ```sh
  git config user.name  "ScreenRecall"
  git config user.email "noreply@screenrecall.local"
  ```

## 3. Bundle ID（硬性）

- 现行 Bundle ID：**`com.screenrecall.app`**
- **禁止**使用任何含个人拼音 / 姓名的 Bundle ID（历史版本曾用过含个人名的 ID，已废弃）。
- 修改位置：`ScreenRecall.xcodeproj/project.pbxproj` 里的 `PRODUCT_BUNDLE_IDENTIFIER`（Debug 与 Release **两处**都要改）。源码中不写死 bundle id（只用 `Bundle.main.bundleIdentifier` 动态取值），改这里即可。

## 4. 签名策略（关键）

| 用途 | 签名方式 | 说明 |
|---|---|---|
| 本地自用 / 快速迭代 | 本机 `Apple Development` 证书 | TCC 屏幕录制权限稳定；**产物内含证书邮箱，仅限本机使用** |
| 对外分发 / 上传 Release | **ad-hoc 匿名签名** | 用脚本剥离个人证书身份 |

- 对外打包**一律**使用：
  ```sh
  zsh Tools/package-release.sh <version>
  ```
  该脚本：构建 Release → ad-hoc 匿名签名 → 打包 DMG → 自动校验签名与二进制中不含个人身份；产物落在 `dist/`。
- **严禁**将用 `Apple Development` 证书签名的 `.app` / `.dmg` 上传、外发或提交。
- 原因：`Apple Development` 证书的 CN 形如 `Apple Development: <个人邮箱> (<TEAMID>)`，会把邮箱直接写进二进制；`TeamIdentifier` 同理会进入产物。

## 5. 禁止入库的内容（红线）

以下已在 `.gitignore` 中忽略，**不得**用 `-f` 强制添加：

- `dist/` 下的 `*.dmg`、`*.app`（安装包 / 构建产物）
- `PRIVACY_AUDIT*.md`（安全审计记录，含敏感引用）
- `.workbuddy/`（本地记忆，含敏感引用）
- `DerivedData/`、`.build/`、`__pycache__/` 等构建缓存

**任何情况下**都不得提交：个人邮箱、真实姓名、主机名（尤其含姓名的 Mac 名称）、本机绝对路径（`/Users/<用户名>`）、设备序列号、API key / token / 私钥、含个人信息的截图。

## 6. 提交前自检（每次 `git push` 前必做）

```sh
# 1) 全历史 + 工作区不得出现个人标识
git grep -n -I -E '[A-Za-z0-9._%+-]+@(qq|gmail|163|126|outlook|hotmail)\.[A-Za-z]{2,}|/Users/[A-Za-z0-9._-]+/|Apple Development:' $(git rev-list --all) || echo "clean"

# 2) 待提交清单里不得有安装包 / 审计文件
git status --short

# 3) 最新提交身份必须是中性身份
git log -1 --format='%an <%ae>'
```

三条中任何一条不干净 → **立即停止推送**，先清理干净再继续。

## 7. 推送 / 发版要求

- 推送：`git push origin main`。
  - SSH（`ssh.github.com:443`）偶发网络抖动（`Connection ... closed by remote host`），重试即可；持续失败可临时改 HTTPS 并用 gh 凭据助手：
    ```sh
    git -c credential.helper='!gh auth git-credential' push origin main
    ```
- 发版流程：
  1. 递增版本号：`project.pbxproj` 的 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`
  2. 更新受影响的文档（`README.md` / `LOCAL_PREVIEW.md` / `DEVELOPMENT_PLAN.md`）
  3. 产出匿名包：`zsh Tools/package-release.sh <version>`
  4. **只提交代码与文档**（绝不提交 DMG / app）
  5. `git push origin main`
  6. 需要对外分发时，把步骤 3 产出的**匿名 DMG** 作为 GitHub Release 附件上传
- 提交信息、Release 标题/正文同样不得出现任何个人信息。

## 8. 单实例与清理约定（硬性）

**整机任何时候只允许存在一个可运行的 `ScreenRecall.app` 实例：`/Applications/ScreenRecall.app`。**

由此产生的要求：

- **不得**把构建产物或安装包以可运行的 `.app` 形态留在别处（`dist/`、项目内、`~/Desktop`、备份目录、`/Applications` 隐藏名等）。
- 构建输出统一走 `-derivedDataPath .build/...`（隐藏目录，Spotlight 不索引）；项目内不要另建 app 副本。
- 备份旧版本时，**必须压缩成 `*.zip` / `*.tar.gz`** 保存，不要把 `.app` 目录平铺在磁盘上（否则会被 Spotlight 与 LaunchServices 当作又一个实例）。
- 对外分发只发 DMG（见 §7），不发裸 `.app`。
- **每次构建/打包后自检**（发现多余副本立即清理，删除走废纸篓）：
  ```sh
  # 全机应只列出 /Applications/ScreenRecall.app
  find /Applications "$HOME" -maxdepth 8 -iname "ScreenRecall*.app" -prune 2>/dev/null | sort -u
  # 清除失效注册（删掉副本后执行一次）
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user
  ```
- 若需清掉某个 bundle id 的屏幕录制授权残留条目（例如旧 Bundle ID）：
  ```sh
  tccutil reset ScreenCapture <旧.bundle.id>
  ```
- 备份目录与 Xcode `DerivedData` 已放置 `.metadata_never_index`，Spotlight 不再索引其中内容。新设备/新目录请照做。

## 9. 变更历史

| 日期 | 变更 |
|---|---|
| 2026-10-10 | 建立本文件。起因：安全审计发现旧 git 历史泄露了作者个人邮箱、本机主机名与含姓名的 Bundle ID。处置：Bundle ID 改为 `com.screenrecall.app`；提交身份改为中性；`git filter-repo` 重写全历史并从历史剔除安装包；删除并重建远端仓库；新增 `Tools/package-release.sh` 匿名发布脚本。 |
| 2026-10-10 | 新增 §8 单实例约定。起因：替换应用后机器上出现 7 个 `ScreenRecall.app` 副本（安装暂存、`.build/` 构建缓存、`dist/` 旧产物、`DerivedData`、备份、废纸篓），导致 Spotlight 与屏幕录制权限列表出现重复项。处置：只保留 `/Applications/ScreenRecall.app`；其余副本清除、备份改为 zip；`tccutil reset` 清除旧 Bundle ID 的授权条目；重建 LaunchServices；备份目录与 `DerivedData` 加 `.metadata_never_index`。 |
