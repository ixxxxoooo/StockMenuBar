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
