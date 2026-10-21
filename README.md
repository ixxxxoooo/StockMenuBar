<div align="center">

<img src="docs/images/icon.png" width="96" alt="StockMenuBar" />

# StockMenuBar

**原生 macOS 菜单栏行情监控:A 股、期货、贵金属、全球指数**

菜单栏常驻 · Popover 速览 · 主面板深度查看 · 悬浮迷你窗 · 多数据源高可用自动切换

[![CI](https://github.com/ixxxxoooo/StockMenuBar/actions/workflows/ci.yml/badge.svg)](https://github.com/ixxxxoooo/StockMenuBar/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/ixxxxoooo/StockMenuBar)](https://github.com/ixxxxoooo/StockMenuBar/releases/latest)
![Platform](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

[English](README.en.md) · 简体中文

</div>

![主面板](docs/images/main.png)

## 功能特性

- **四种形态**:菜单栏着色标题(可固定多只并轮播)、Popover 速览、主面板(分时 / 日K / 周K / 月K + 成交量 + 五档)、可拖动的悬浮迷你窗(胶囊 / 列表 / 卡片;列表形态鼠标悬停到哪一行,哪一行就展开分时图;悬停时可点分类按钮在左侧展开分类,一键切换迷你窗内容)。
- **覆盖品种**
  - A 股、ETF、指数(沪 / 深 / 北交所,自动识别创业板、科创板)
  - 期货:沪铜、伦铜、COMEX 铜、焦煤、焦炭、沪金、沪银,以及任意具体合约
  - 贵金属:纽约金、伦敦金、纽约银、伦敦银、现货黄金(XAU/USD)
  - 全球指数:道琼斯、纳斯达克、标普 500、日经 225、韩国 KOSPI / KOSDAQ,可搜索添加德国 DAX、英国富时 100、法国 CAC40 等
- **日 / 周 / 月 K 线**:蜡烛图 + MA5/10/20 + 成交量,悬停十字光标显示开高低收;A 股走腾讯 → 新浪,期货与美股指数走新浪 → 雅虎(周/月线本地聚合),日韩指数走雅虎。
- **摸鱼模式**:偏好设置 → 外观开启(或 ⌥⌘M 一键切换),涨跌色降为低饱和灰调、关闭价格闪色,整体不再醒目;红涨绿跌的方向习惯不变。
- **高可用行情**:腾讯、新浪、东方财富、雅虎财经多源路由,按延迟与成功率排序,熔断 + 对冲请求 + 数据校验;分时数据不完整时自动换源、失败自动退避重试。
- **自选管理**:分组、拖拽自定义排序、拼音首字母 / 中文 / 代码搜索、右键置顶 / 固定到菜单栏 / 加入悬浮窗。
- **智能刷新**:交易时段 3 / 5 / 10 秒,午休 1 分钟,休市不轮询;睡眠、锁屏、屏保自动暂停;期货与外盘按各自开市窗口轮询。
- **体验细节**:红涨绿跌(可反转)、价格闪色、深浅色、Dock 图标随主面板显示、⌥⌘F / ⌥⌘L / ⌥⌘H / ⌥⌘M 全局快捷键(悬浮窗 / 穿透 / 老板键 / 摸鱼模式)、⌘, 在应用任意窗口打开偏好设置。
- **备份与迁移**:偏好设置里一键导出自选分组与设置为 JSON,换机器后导入(支持合并 / 替换)即可恢复。
- **在线更新**:自动检查 GitHub 新版本,一键下载、校验并替换重启(见下文)。
- **零依赖**:Swift 6 严格并发 + SwiftUI + AppKit + Swift Charts + SwiftData。

| 全球指数 | 贵金属 | 悬浮迷你窗 |
| --- | --- | --- |
| ![全球指数](docs/images/index.png) | ![贵金属](docs/images/metals.png) | ![悬浮窗](docs/images/floating.png) |

## 数据源

| 品种 | 行情 | 分时 |
| --- | --- | --- |
| A 股 / ETF / A 股指数 | 腾讯 → 新浪 → 东财 | 腾讯 → 东财 → 新浪(1 分钟线合成) |
| 国内期货 | 东财 → 新浪 | 东财 → 新浪 |
| 外盘期货 / 贵金属 | 东财 → 新浪 → 雅虎 | 东财 → 新浪(外盘分时) → 雅虎 |
| 美股指数 | 东财 → 新浪 / 腾讯 → 雅虎 | 东财 / 腾讯 → 雅虎 |
| 日经 / 韩国指数 | 东财 / 新浪 → 雅虎 | 东财 → 雅虎 |
| 现货黄金 XAU/USD | TradingView | TradingView(WebSocket) |

K 线(日 / 周 / 月)固定优先级:腾讯 → 新浪 → 雅虎;现货黄金仅 TradingView。TradingView 为非官方接口,可能随网站变动;现货价与 COMEX / 伦敦金存在少量价差。

实际顺序由路由根据实时健康度动态决定,上表只是能力矩阵。字段映射与实测结论见 [docs/DATA_SOURCES.md](docs/DATA_SOURCES.md)。

## 安装

从 [Releases](https://github.com/ixxxxoooo/StockMenuBar/releases/latest) 下载 `StockMenuBar-<版本>-macOS.zip`(通用二进制,支持 Apple 芯片与 Intel),解压后把 `StockMenuBar.app` 拖进「应用程序」。

> 应用使用 ad-hoc 签名、未经过 Apple 公证。首次打开如果被 Gatekeeper 拦截,请右键 → 打开,或在「系统设置 → 隐私与安全性」中点「仍要打开」;也可以执行 `xattr -dr com.apple.quarantine /Applications/StockMenuBar.app`。
> 校验下载文件:`shasum -a 256 -c StockMenuBar-<版本>-macOS.zip.sha256`。

### 在线更新

- 启动后以及每 6 小时自动检查 GitHub 最新正式版;也可以在 **偏好设置 → 软件更新**、应用菜单或菜单栏右键里点「检查更新…」。有新版本时侧栏设置图标会出现红点。
- 点「立即更新并重启」后:下载安装包 → 校验 SHA-256 → 解压并校验 Bundle ID、版本号与代码签名 → 退出当前应用 → 原子替换 `.app` → 自动重新打开。任一步失败都保持旧版本不变(替换失败会回滚)。
- 检测优先走 GitHub API,被限流时回退到 `releases/latest` 网页重定向。
- 说明:原生 Swift 应用无法像脚本语言那样"热补丁"正在运行的代码,这里的"热更新"是指**无需手动操作的下载 + 替换 + 自动重启**,通常几秒内完成。
- 如果应用不在可写目录(例如从只读磁盘映像里运行),会改为提示在 Finder 中手动替换。更新日志位于 `~/Library/Logs/StockMenuBar/update.log`。

## 从源码构建

### 环境要求

- macOS 14 (Sonoma) 及以上
- Xcode 16 及以上(Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen):`brew install xcodegen`

### 构建

```bash
git clone https://github.com/ixxxxoooo/StockMenuBar.git
cd StockMenuBar
xcodegen generate                       # 生成 StockMenuBar.xcodeproj
xcodebuild -scheme StockMenuBar -configuration Release -derivedDataPath build build
open build/Build/Products/Release/StockMenuBar.app
```

也可以 `open StockMenuBar.xcodeproj` 后在 Xcode 里直接运行。

> 应用**不启用 App Sandbox**:沙盒应用无法替换自身所在的 `.app`,而在线更新需要这一能力。应用只访问网络,数据保存在 `~/Library/Application Support/StockMenuBar/` 与 `UserDefaults`。

### 测试

```bash
xcodebuild test -scheme StockMenuBar -destination 'platform=macOS' -derivedDataPath build
# 含真实网络的用例(默认跳过)
TEST_RUNNER_LIVE_TESTS=1 xcodebuild test -scheme StockMenuBar -destination 'platform=macOS' -derivedDataPath build
```

### 调试启动参数

`--show-main` `--show-settings` `--show-popover` `--show-floating` `--pin=sh000001,sz399001` `--fail-source=tencent,sina`(让指定数据源恒定失败,用于验证故障转移)、`--export-backup=PATH` / `--import-backup=PATH [--import-mode=merge|replace] [--no-settings]`(无界面导出 / 导入备份,完成后退出)、`--update-now`(启动后立即检查并安装更新,配合环境变量 `STOCKMENUBAR_UPDATE_API` 指向自建的 latest JSON,用于测试更新流程)。

## 项目结构

```
StockMenuBar/
├─ App/          应用生命周期、菜单栏、主窗口与悬浮窗控制器、全局快捷键
├─ Core/         QuoteStore(单一行情数据源)、调度器、交易时钟、自选与偏好
├─ Data/
│  ├─ Models/    证券标识、行情与分时模型、期货/指数目录
│  └─ Providers/ 腾讯 / 新浪 / 东财 / 雅虎 + ProviderRouter(熔断、对冲、覆盖度排序)
├─ Features/     主面板、Popover、悬浮窗、搜索等界面
├─ Shared/       主题、格式化、GBK 解码、东八区时间、应用信息
└─ Resources/    资源与应用图标
StockMenuBarTests/  Swift Testing 用例与真实接口样本(Fixtures)
Tools/              图标生成脚本
docs/               架构与数据源文档
```

架构概览见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md);设计与开发过程记录见 [开发进度.md](开发进度.md)。

## 常见问题

- **数据延迟或缺失?** 行情来自公开免费接口,可能有数秒到数分钟延迟;某个数据源被限流时会自动切到其余数据源,可在「偏好设置 → 行情数据源」查看各源状态。
- **韩国指数没有成交量?** 这些指数的免费数据源不提供成交量,界面会隐藏没有数据的字段。
- **升级后自选没了?** 1.1.0 起 Bundle ID 改为 `com.ixxxxoooo.StockMenuBar`;1.2.0 起不再启用沙盒,数据库移到 `~/Library/Application Support/StockMenuBar/`。这两次变更都不会迁移旧数据,此后在线更新不会影响数据。
- **换了新电脑怎么迁移自选?** 在旧机器打开 **偏好设置 → 备份与迁移 → 导出…**,把生成的 `StockMenuBar-backup-日期.json` 拷到新机器,在同一位置点 **导入…**,选「合并」(保留新机器已有内容)或「替换」(完全还原备份)。备份不含窗口位置、开机自启与更新状态。
- **更新提示「没有权限」?** 应用所在目录不可写时无法自动替换,请把应用放进「应用程序」后重试,或按提示手动替换。

## 发布流程

推送形如 `v1.2.0` 的标签即可发版,[Release 工作流](.github/workflows/release.yml)会自动运行测试、构建通用二进制、打包 zip 与 sha256,并发布到 GitHub Release(更新说明取自 `CHANGELOG.md`)。详见 [CONTRIBUTING.md](CONTRIBUTING.md#发布新版本)。

## 参与贡献

欢迎 Issue 与 PR,请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 免责声明

本项目的行情数据全部来自第三方公开接口,仅供个人学习与参考,不保证准确、完整与及时,**不构成任何投资建议**。使用者需自行承担使用风险;请遵守各数据提供方的服务条款,勿用于商业用途或高频抓取。

## 许可证

[MIT](LICENSE) © 2026 [ixxxxoooo](https://github.com/ixxxxoooo)
