# 参与贡献

感谢你愿意改进 StockMenuBar!下面是提交 Issue 与 PR 的约定。

## 开发环境

- macOS 14+、Xcode 16+(Swift 6,开启严格并发)
- `brew install xcodegen`,然后 `xcodegen generate` 生成工程(工程文件不入库)
- 新增或移动源文件后需要重新执行 `xcodegen generate`

```bash
xcodegen generate
xcodebuild test -scheme StockMenuBar -destination 'platform=macOS' -derivedDataPath build
```

## 代码约定

- 零第三方依赖;逻辑层(`Core` / `Data` / `Shared`)不依赖 UI 框架,便于直接编入测试包。
- 命名:类型 `UpperCamelCase`,方法 / 变量 `lowerCamelCase`,常量 `UPPER_SNAKE_CASE`(或 Swift 惯例的 `static let`)。
- 注释使用中文;方法需说明用途、参数、返回值;单个方法不超过 300 行。
- 空值 / 合法性校验放在边界处;数据解析写成**纯函数**并配样本测试。
- 文件头保留 `@author` 信息。

## 新增数据源或品种

1. 先用 `curl` 实测接口,把**真实响应样本**(可裁剪)放进 `StockMenuBarTests/Fixtures/`。
2. 在 `Data/Providers/` 里实现 `QuoteProvider`:声明 `capabilities`,按标的重写 `canServe(_:symbol:)`,解析器写成纯函数。
3. 新品种在 `FuturesCatalog` 中登记 `Preset`(东财 secid、新浪 / 腾讯 / 雅虎代码、价格换算系数);需要默认展示时加入 `groupSeeds` 并提升 `WatchlistStore.catalogVersion`。
4. 补充解析、映射、路由兜底的单元测试;网络用例放在 `LiveProviderTests`(默认跳过)。
5. 更新 `docs/DATA_SOURCES.md` 与 `CHANGELOG.md`。

## 发布新版本

版本号只在 `project.yml` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 维护,**应用内在线更新依赖 Release 的资产命名,请勿改动**:`StockMenuBar-<版本>-macOS.zip` 与同名 `.sha256`。

1. 更新 `project.yml` 的版本号,并在 `CHANGELOG.md` 顶部新增 `## [x.y.z] - 日期` 小节(它会成为 Release 说明)。
2. 合并到 `main` 并确认 CI 通过。
3. 打标签并推送:`git tag v1.2.0 && git push origin v1.2.0`。
4. [Release 工作流](.github/workflows/release.yml)会自动测试、构建通用二进制、打包、校验并发布 Release;带连字符的标签(如 `v1.3.0-beta.1`)会标记为预发布,在线更新不会推送预发布版本。
5. 本地预演打包:`scripts/package.sh 1.2.0 1`,产物在 `dist/`。

### 在线更新的本地测试

```bash
# 1. 用 scripts/package.sh 分别打出旧版与新版,旧版解压到临时目录
# 2. 在新版 zip 所在目录放一个仿 GitHub API 的 latest.json(字段见 StockMenuBarTests/Fixtures/github_release_latest.json),
#    browser_download_url 指向本地 http.server
# 3. 让旧版指向它并立即更新
STOCKMENUBAR_UPDATE_API=http://127.0.0.1:8765/latest.json \
  /tmp/old/StockMenuBar.app/Contents/MacOS/StockMenuBar --update-now
tail -f ~/Library/Logs/StockMenuBar/update.log
```

## 提交规范

使用 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/),中文描述:

```
feat: 新增伦敦金/伦敦银行情与分时
fix: 修复夜盘分时跨零点序号错位
docs: 更新数据源文档
test: 补充雅虎分时解析用例
refactor: / chore: / ci: ...
```

## Pull Request 流程

1. Fork 并从 `main` 切出特性分支。
2. 保证 `xcodebuild test` 全部通过,界面改动请附截图。
3. 在 PR 描述里说明动机、方案与验证方式。

## 反馈问题

请使用 Issue 模板,尽量附上系统版本、应用版本、复现步骤,以及「偏好设置 → 行情数据源」里各源的状态。行情数据来自第三方公开接口,接口变更或限流属于已知风险,欢迎提交修复。

## 行为准则

请友善、尊重地交流。不接受骚扰、歧视或人身攻击。
