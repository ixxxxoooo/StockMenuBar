<div align="center">

# StockMenuBar

**A native macOS menu-bar monitor for China A-shares, futures, precious metals and global indices**

Menu bar · Popover · Main window · Floating mini panel · Multi-source failover

[![CI](https://github.com/ixxxxoooo/StockMenuBar/actions/workflows/ci.yml/badge.svg)](https://github.com/ixxxxoooo/StockMenuBar/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/ixxxxoooo/StockMenuBar)](https://github.com/ixxxxoooo/StockMenuBar/releases/latest)
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
- **In-app updates**: checks GitHub Releases, then downloads, verifies, replaces itself and relaunches with one click.
- **Zero dependencies**: Swift 6, SwiftUI, AppKit, Swift Charts, SwiftData.

## Install

Download `StockMenuBar-<version>-macOS.zip` (universal binary) from [Releases](https://github.com/ixxxxoooo/StockMenuBar/releases/latest), unzip and drag `StockMenuBar.app` into `/Applications`. The app is ad-hoc signed and not notarized: on first launch right-click → Open (or `xattr -dr com.apple.quarantine /Applications/StockMenuBar.app`). Verify with `shasum -a 256 -c <file>.sha256`.

### Updates

The app checks the latest GitHub release on launch and every 6 hours (also via *Settings → Software Update* or the *Check for Updates…* menu items). "Update and Restart" downloads the zip, verifies SHA-256, bundle ID, version and code signature, quits, atomically swaps the `.app` (rolling back on failure) and relaunches. A native app cannot patch running code, so "hot update" here means an automatic download + replace + relaunch. The app runs **without App Sandbox** because a sandboxed app cannot replace its own bundle. Logs: `~/Library/Logs/StockMenuBar/update.log`.

### Releasing

Push a tag such as `v1.2.0`; the [release workflow](.github/workflows/release.yml) tests, builds a universal binary, packages zip + sha256 and publishes a GitHub Release using the matching `CHANGELOG.md` section.

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
