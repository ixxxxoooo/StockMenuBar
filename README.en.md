<div align="center">

# StockMenuBar

**A native macOS menu-bar monitor for China A-shares, futures, precious metals and global indices**

Menu bar · Popover · Main window · Floating mini panel · Multi-source failover

[![CI](https://github.com/ixxxxoooo/StockMenuBar/actions/workflows/ci.yml/badge.svg)](https://github.com/ixxxxoooo/StockMenuBar/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

English · [简体中文](README.md)

</div>

![Main window](docs/images/main.png)

## Features

- **Four surfaces**: a colored menu-bar title (pin several symbols and rotate), a quick-look popover, a main window (minute chart, volume, 5-level order book) and a draggable floating mini panel.
- **Coverage**: A-shares / ETFs / indices; futures (copper, coking coal, coke, gold, silver…); precious metals (COMEX / London gold & silver); global indices (Dow, Nasdaq, S&P 500, Nikkei 225, KOSPI, KOSDAQ, DAX, FTSE 100, CAC 40…).
- **High availability**: Tencent, Sina, Eastmoney and Yahoo Finance behind a router with health scoring, circuit breaker, hedged requests, validation, completeness checks for minute data and exponential-backoff retry.
- **Watchlist**: groups, drag-to-reorder, pinyin / name / code search.
- **Smart refresh**: follows trading sessions, pauses on sleep / lock / screen saver.
- **Zero dependencies**: Swift 6, SwiftUI, AppKit, Swift Charts, SwiftData.

## Build

```bash
brew install xcodegen
git clone https://github.com/ixxxxoooo/StockMenuBar.git && cd StockMenuBar
xcodegen generate
xcodebuild -scheme StockMenuBar -configuration Release -derivedDataPath build build
open build/Build/Products/Release/StockMenuBar.app
```

Requires macOS 14+ and Xcode 16+. Run tests with `xcodebuild test -scheme StockMenuBar -destination 'platform=macOS'`.

## Data sources

All market data comes from public third-party endpoints (Tencent, Sina, Eastmoney, Yahoo Finance). See [docs/DATA_SOURCES.md](docs/DATA_SOURCES.md) (Chinese) for field mappings. Data may be delayed or inaccurate and is **not investment advice**.

## Contributing & License

See [CONTRIBUTING.md](CONTRIBUTING.md). Released under the [MIT License](LICENSE) © 2026 [ixxxxoooo](https://github.com/ixxxxoooo).
