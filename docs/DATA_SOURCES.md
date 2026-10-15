# 数据源说明

所有接口均为第三方公开接口,字段含义来自实测,可能随时变化。每个解析器都是纯函数,并附真实响应样本测试(`StockMenuBarTests/Fixtures`)。

## 腾讯(`qt.gtimg.cn` / `web.ifzq.gtimg.cn`)

| 能力 | 接口 | 说明 |
| --- | --- | --- |
| A 股行情 | `https://qt.gtimg.cn/q=sh600519,...`(GBK,`~` 分隔) | 1 名称、3 现价、4 昨收、5 今开、9–28 五档、30 时间、33 最高、34 最低、36 成交量(手)、37 成交额(万)、38 换手率 |
| 美股指数行情 | 同上,代码 `usDJI` / `usIXIC` / `usINX` | 3 现价、4 昨收、5 今开、6 成交量(股)、30 美东时间、33 最高、34 最低 |
| A 股分时 | `appstock/app/minute/query?code=sh600519` | `HHMM 价格 累计量 累计额` |
| 美股指数分时 | `appstock/app/UsMinute/query?code=usDJI` | `HHMM 价格 累计量`,美东 9:30–16:00 |
| 搜索 | `smartbox.gtimg.cn/s3/?v=2&q=...&t=all` | 支持拼音首字母 |

不支持:期货、日韩指数。

## 新浪(`hq.sinajs.cn`,必须带 `Referer: https://finance.sina.com.cn`,GBK)

| 能力 | 代码 / 接口 | 说明 |
| --- | --- | --- |
| A 股行情 | `sh600519` | 0 名称、1 今开、2 昨收、3 现价、4 最高、5 最低、8 成交量(股)、9 成交额、10–29 五档、30–31 日期时间 |
| 国内期货 | `nf_CU0`(主连)、`nf_CU2612` | 0 名称、2 今开、3 最高、4 最低、5 昨收、8 现价、10 昨结算、13 持仓量、14 成交量 |
| 外盘期货 | `hf_GC` `hf_XAU` `hf_SI` `hf_XAG` `hf_CL` `hf_OIL` `hf_CAD` `hf_HG` | 0 现价、4 最高、5 最低、7 昨收、8 今开、13 名称;`hf_HG` 单位为美分,按 0.01 换算 |
| 美股指数 | `gb_$dji` `gb_ixic` `gb_inx` | 1 现价、3 时间(北京时间)、4 涨跌额、5 今开、6 最高、7 最低、10 成交量、26 昨收 |
| 日韩指数 | `znb_NKY` `znb_KOSPI` `znb_KOSDAQ` | 1 现价、6–7 日期时间、8 今开、9 昨收、10 最高、11 最低 |
| A 股分时 | `CN_MarketDataService.getKLineData?symbol=sh600519&scale=1&datalen=250` | 1 分钟 K 线,取最新交易日合成分时;不含昨收(由行情覆盖) |
| 国内期货分时 | `InnerFuturesNewService.getMinLine?symbol=CU0` | 行 `[HH:mm, 价, 均价, 量, 持仓, 昨收, 交易日]`,夜盘跨零点按时刻回绕累计 |
| 外盘期货分时 | `GlobalFuturesService.getGlobalFuturesMinLine?symbol=XAU` | 首行含昨收与交易所;完整时间为北京时间 |
| 搜索 | `suggest3.sinajs.cn/suggest/type=11,12,13,14,15&key=...` | |

## 东方财富(`push2*.eastmoney.com`、`searchapi.eastmoney.com`)

| 能力 | 接口 | 说明 |
| --- | --- | --- |
| 行情 | `push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&secids=...` | f2 现价、f5 成交量、f6 成交额、f8 换手率、f15 最高、f16 最低、f17 今开、f18 昨收、f28 昨结算、f108 持仓量、f1 小数位 |
| 分时 | `push2his.eastmoney.com/api/qt/stock/trends2/get?secid=...&ndays=1` | 期货含 `beticks` 交易时段(自零点起的秒数,夜盘跨零点) |
| 搜索 | `searchapi.eastmoney.com/api/suggest/get?...&token=...` | `Classify` 区分 Futures / UniversalFutures / UniversalIndex |

secid:A 股 `1.600519`(沪)/`0.000001`(深);期货 `113.cum`(上期所)、`114.jmm`(大商所)、`101.GC00Y`(COMEX)、`122.XAU`(伦敦金)、`112.B00Y`(布伦特);全球指数 `100.DJIA` `100.NDX` `100.SPX` `100.N225` `100.KS11`。韩国 KOSDAQ 东财未收录。

> 东财对短时间内的高频请求会限流(空响应 / 连接中断),这也是需要多源兜底的原因。

## 雅虎财经(`query1/2.finance.yahoo.com/v8/finance/chart/{symbol}`)

- `interval=5m&range=1d` 取行情(体积小),`interval=1m&range=1d` 取分时。
- `meta`:`regularMarketPrice`、`chartPreviousClose`(昨收)、`regularMarketDayHigh/Low`(指数常为 0,由分时点统计)、`currentTradingPeriod.regular`(常规交易时段)、`gmtoffset`。
- 常规时段给的是最近 / 下一个交易日,解析时按整天平移到数据所在交易日;指数横轴使用交易所本地时间,期货使用北京时间。
- 部分指数(如 KOSPI)的成交量几乎全集中在某一分钟(收盘集合竞价),量能无参考价值,解析时丢弃。
- 代码:`^DJI` `^IXIC` `^GSPC` `^N225` `^KS11` `^KQ11` `^KS200` `^GDAXI` `^FTSE` `^FCHI` `^NDX`、期货 `GC=F` `SI=F` `HG=F` `CL=F` `BZ=F`。伦敦现货金银雅虎没有对应代码。

## 缺失字段的处理

- 指数没有五档盘口:详情页展示「指数概览」(日内区间位置、较开盘 / 前收、振幅、交易时段、可用数据源)。
- 没有数据的统计字段(成交量 / 成交额 / 持仓量 / 换手率 / 今开)直接隐藏,不显示 `--`。
- 没有成交量的分时(外盘、部分指数)隐藏下方的量能图。
