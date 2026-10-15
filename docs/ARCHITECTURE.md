# 架构概览

```
数据源(腾讯 / 新浪 / 东财 / 雅虎) ──▶ ProviderRouter(actor) ──▶ QuoteStore(@Observable,单一数据源)
                                                                    ├─ 菜单栏 NSStatusItem
                                                                    ├─ Popover
                                                                    ├─ 主面板(NavigationSplitView)
                                                                    └─ 悬浮迷你窗(NSPanel)
RefreshScheduler(交易时段 / 电源状态 / 期货窗口) 驱动 QuoteStore 批量轮询
```

## 分层

| 层 | 目录 | 职责 |
| --- | --- | --- |
| App | `StockMenuBar/App` | 生命周期、菜单栏、主窗口 / 悬浮窗控制器、全局快捷键、Dock 策略 |
| Core | `StockMenuBar/Core` | `QuoteStore`、`MinuteLoader`、`RefreshScheduler`、`TradingClock`、自选与偏好 |
| Data | `StockMenuBar/Data` | 模型、`FuturesCatalog` 品种目录、各数据源 Provider 与 `ProviderRouter` |
| Features | `StockMenuBar/Features` | SwiftUI 界面 |
| Shared | `StockMenuBar/Shared` | 主题、格式化、GBK、东八区时间、应用信息 |

`Core` / `Data` / `Shared` 不依赖 UI,直接编入测试包,无需宿主应用即可单元测试。

## 标的标识

- A 股:`Market`(sh / sz / bj)+ 6 位代码,`full` 形如 `sh600519`。
- 期货与全球指数统一为 `Market.future`:`code` 即东财 secid(大小写敏感,如 `113.cum`、`101.GC00Y`、`100.KS11`),`full` 形如 `fu113.cum`。市场号 `100` 为全球指数(`kind == .index`)。
- 其他数据源的代码通过 `FuturesCatalog.Preset` 映射(`sinaCode`、`tencentCode`、`yahooCode`),`inEastmoney` 标记东财是否收录。

## 高可用路由(`ProviderRouter`)

1. **能力过滤**:`capabilities` + `canServe(_:symbol:)` 在发请求前剔除无法服务该标的的数据源。
2. **覆盖度排序**:能服务全部标的的数据源优先(`full` > `partial`),同级按健康评分 `latency × (1 + 5 × failureRate)` 升序。
3. **熔断**:连续失败 3 次熔断 30 秒,半开探测;全部熔断时 fail-open。
4. **对冲请求**:首选源 1.2 秒未返回,并发请求下一个源,先成功者胜出。
5. **数据校验**:行情要求 `prevClose > 0`,分时要求非空且昨收有效。
6. **缺失补查**:批量期货 / 指数行情里首选源缺失的品种,最多 3 轮交给其余数据源补齐。
7. **分时完整性**(`QuoteStore.fetchBestMinute`):A 股当日分时最后一根明显落后于当前交易分钟时,换源再取一次并择优。
8. **失败重试**(`MinuteLoader`):加载失败按 2 / 4 / 8 / 16 / 20 秒退避重试,界面提供「立即重试」。

## 分时横轴(`MinuteAxis`)

横轴由若干连续交易时段首尾相接而成,序号即累计交易分钟:

- A 股:9:30–11:30 + 13:00–15:00,共 240 分钟。
- 国内期货:夜盘(跨零点)+ 9:00–10:15 + 10:30–11:30 + 13:30–15:00,时段取自东财 `beticks` 或品种模板。
- 外盘期货:单一连续时段(新浪按交易所给定时长,雅虎按常规时段),统一用北京时间。
- 全球指数:交易所本地时间(美股 9:30–16:00 美东,日韩 9:00 起)。

## 刷新与界面性能

- 一次批量请求同时驱动所有界面;每只证券一个 `QuoteTicker`,行情变化只重绘对应行。
- 交易时段按用户间隔轮询,午休 1 分钟,休市不轮询;含期货 / 外盘时按各自窗口(周一 06:00 – 周六 05:00)至少 5 秒轮询。
- 睡眠、锁屏、屏保、全部界面隐藏时暂停;低电量 / 高热时间隔翻倍。

## 在线更新(`Core/Update`)

```
UpdateManager(@Observable 状态机)
 ├─ UpdateChecker   GitHub API → 失败回退 releases/latest 网页重定向 → ReleaseInfo
 ├─ UpdateInstaller 流式下载 + SHA-256 → ditto 解压 → 校验 Bundle ID/版本/codesign → 安装脚本
 └─ SemanticVersion 语义化版本比较(预发布 < 正式版)
```

- **发布约定**:Release 必须带 `StockMenuBar-<版本>-macOS.zip`;校验值优先取 API 的 `digest`,否则读同名 `.sha256`;都没有就拒绝安装。
- **为什么不用沙盒**:沙盒应用无法写入自己所在的 `.app`。应用只访问网络与自己的数据目录;自选数据库显式放在 `~/Library/Application Support/StockMenuBar/Watchlist.store`。
- **替换流程**:应用写出 `install.sh` 并启动后退出;脚本等待旧进程退出 → `ditto` 复制到同目录 `*.updating` → 去除隔离属性 → `mv` 旧版为 `*.old` → `mv` 新版就位 → 删除 `*.old` → `open`。复制或改名失败时回滚旧版并重新打开。所有路径以位置参数传入,不拼接进脚本。
- **拦截条件**:位于 `AppTranslocation`(从下载目录直接运行)或父目录不可写时,不自动替换,改为展示"在 Finder 中显示新版本"。
- **测试**:`UpdateTests` 覆盖版本比较、JSON 解析、双通道检测、下载校验(含篡改)、解压校验(含签名破坏)、安装脚本替换与回滚、状态机;`--update-now` + `STOCKMENUBAR_UPDATE_API` 用于端到端演练。
- **信任模型**:HTTPS + 仓库所有者的 Release 为信任根,SHA-256 防传输损坏,codesign 校验包完整性;未使用 Developer ID 与公证,因此无法抵御仓库本身被入侵。
