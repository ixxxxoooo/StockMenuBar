//
//  UpdateTests.swift
//  StockMenuBarTests
//
//  在线更新:版本比较、发布 JSON 解析、双路径检测、下载校验、解压校验、安装脚本替换与回滚、状态机。
//  @author ixxxxoooo
//

import CryptoKit
import Foundation
import Testing

// MARK: - 测试工具

/// 可编排响应的网络桩
struct StubNetwork: UpdateNetwork {
    var routes: [String: Result<(Data, URL), Error>]

    func get(_ url: URL, accept: String) async throws -> (Data, URL) {
        guard let result = routes[url.absoluteString] else { throw ProviderError.httpStatus(404) }
        return try result.get()
    }
}

enum UpdateFixtures {
    static let bundleID = "com.ixxxxoooo.StockMenuBar"

    static func tempDir(_ name: String = UUID().uuidString) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smb-update-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 构造一个带 ad-hoc 签名的最小应用包
    @discardableResult
    static func makeApp(at dir: URL, version: String, bundleID: String = bundleID, marker: String = "") async throws -> URL {
        let app = dir.appendingPathComponent("StockMenuBar.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macos.appendingPathComponent("StockMenuBar").path)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleVersion": "1",
            "CFBundleExecutable": "StockMenuBar", "CFBundlePackageType": "APPL"
        ]
        (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try marker.write(to: app.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)
        let sign = try await UpdateInstaller.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
        #expect(sign.status == 0, "\(sign.output)")
        return app
    }

    /// 把应用打成 zip,并返回 (zip, sha256)
    static func zip(_ app: URL, version: String) async throws -> (URL, String) {
        let zip = app.deletingLastPathComponent().appendingPathComponent("StockMenuBar-\(version)-macOS.zip")
        let r = try await UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        #expect(r.status == 0, "\(r.output)")
        return (zip, sha(of: try Data(contentsOf: zip)))
    }

    static func sha(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 指向本地 zip 的发布信息(下载走 file:// 协议)
    static func release(version: String, zip: URL, sha: String?, checksumURL: URL? = nil) -> ReleaseInfo {
        ReleaseInfo(version: SemanticVersion(version)!, tag: "v\(version)", name: "v\(version)", notes: "说明",
                    pageURL: URL(string: "https://example.com/r")!, publishedAt: nil,
                    zipURL: zip, zipName: zip.lastPathComponent, zipSize: 0, sha256: sha, checksumURL: checksumURL)
    }

    /// 一个已经结束的进程号(安装脚本不用等待)
    static func deadPID() throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }
}

// MARK: - 版本号

struct SemanticVersionTests {
    @Test func 解析各种写法() {
        #expect(SemanticVersion("v1.2.3")?.description == "1.2.3")
        #expect(SemanticVersion("1.2")?.description == "1.2.0")
        #expect(SemanticVersion("2")?.description == "2.0.0")
        #expect(SemanticVersion("1.2.3-beta.1+45")?.description == "1.2.3-beta.1")
        #expect(SemanticVersion("abc") == nil)
        #expect(SemanticVersion("1.2.3.4") == nil)
        #expect(SemanticVersion("1.-2.3") == nil)
    }

    @Test func 比较规则() {
        func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }
        #expect(v("1.10.0") > v("1.9.9"))
        #expect(v("1.2.0") > v("1.1.9"))
        #expect(v("2.0.0") > v("1.99.99"))
        #expect(v("1.2.0") > v("1.2.0-rc.1"))
        #expect(v("1.2.0-rc.2") > v("1.2.0-rc.1"))
        #expect(v("1.2.0-rc.10") > v("1.2.0-rc.2"))
        #expect(v("1.2.0-beta") > v("1.2.0-alpha"))
        #expect(v("v1.2.0") == v("1.2.0+build9"))
    }
}

// MARK: - 发布 JSON

struct ReleaseParserTests {
    @Test func 解析真实结构的发布信息() throws {
        let release = try GitHubReleaseParser.parse(try Fixture.data("github_release_latest.json"))
        #expect(release.version.description == "1.2.0")
        #expect(release.tag == "v1.2.0")
        #expect(release.zipName == "StockMenuBar-1.2.0-macOS.zip")
        #expect(release.zipSize == 4_096_000)
        // 摘要统一为小写
        #expect(release.sha256 == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        #expect(release.checksumURL?.lastPathComponent == "StockMenuBar-1.2.0-macOS.zip.sha256")
        #expect(release.notes.contains("在线更新"))
        #expect(release.publishedAt != nil)
    }

    @Test func 草稿与缺少安装包与坏数据被拒绝() throws {
        let json = String(decoding: try Fixture.data("github_release_latest.json"), as: UTF8.self)
        let draft = json.replacingOccurrences(of: "\"draft\": false", with: "\"draft\": true")
        #expect(throws: UpdateError.invalidResponse) { try GitHubReleaseParser.parse(Data(draft.utf8)) }
        let noAsset = json.replacingOccurrences(of: "-macOS.zip\"", with: "-linux.tar\"")
        #expect(throws: UpdateError.noInstallableAsset) { try GitHubReleaseParser.parse(Data(noAsset.utf8)) }
        #expect(throws: UpdateError.invalidResponse) { try GitHubReleaseParser.parse(Data("{}".utf8)) }
    }

    @Test func 校验文件格式() {
        let hex = String(repeating: "ab", count: 32)
        #expect(GitHubReleaseParser.parseChecksumFile("\(hex)  StockMenuBar-1.2.0-macOS.zip\n") == hex)
        #expect(GitHubReleaseParser.parseChecksumFile("SHA256 (x.zip) = \(hex.uppercased())") == hex)
        #expect(GitHubReleaseParser.parseChecksumFile("not a checksum") == nil)
        #expect(GitHubReleaseParser.parseDigest("sha1:abc") == nil)
    }
}

// MARK: - 检测(API 与网页回退)

struct UpdateCheckerTests {
    let api = URL(string: "https://api.github.com/repos/o/r/releases/latest")!
    let web = URL(string: "https://github.com/o/r/releases/latest")!

    @Test func API正常时直接解析() async throws {
        let data = try Fixture.data("github_release_latest.json")
        let checker = UpdateChecker(network: StubNetwork(routes: [api.absoluteString: .success((data, api))]),
                                    apiURL: api, fallbackRepository: "o/r")
        #expect(try await checker.fetchLatest().version.description == "1.2.0")
    }

    @Test func API被限流时回退到网页重定向() async throws {
        let final = URL(string: "https://github.com/o/r/releases/tag/v1.3.0")!
        let net = StubNetwork(routes: [
            api.absoluteString: .failure(ProviderError.httpStatus(403)),
            web.absoluteString: .success((Data("<html/>".utf8), final))
        ])
        let latest = try await UpdateChecker(network: net, apiURL: api, fallbackRepository: "o/r").fetchLatest()
        #expect(latest.version.description == "1.3.0")
        #expect(latest.zipURL.absoluteString == "https://github.com/o/r/releases/download/v1.3.0/StockMenuBar-1.3.0-macOS.zip")
        #expect(latest.checksumURL?.absoluteString.hasSuffix(".zip.sha256") == true)
        #expect(latest.sha256 == nil)
    }

    @Test func 覆盖地址时不回退() async {
        let net = StubNetwork(routes: [api.absoluteString: .failure(ProviderError.httpStatus(500))])
        let checker = UpdateChecker(network: net, apiURL: api, fallbackRepository: nil)
        await #expect(throws: ProviderError.self) { try await checker.fetchLatest() }
    }

    @Test func 环境变量覆盖latest地址() {
        let c = UpdateChecker.makeDefault(environment: [UpdateChecker.apiOverrideEnvironmentKey: "http://127.0.0.1:1/latest.json"])
        #expect(c.apiURL.absoluteString == "http://127.0.0.1:1/latest.json")
        #expect(c.fallbackRepository == nil)
        #expect(UpdateChecker.makeDefault(environment: [:]).fallbackRepository == UpdateChecker.defaultRepository)
    }
}

// MARK: - 下载、校验、解压

struct UpdateInstallerTests {
    @Test func 下载校验通过并报告进度() async throws {
        let dir = UpdateFixtures.tempDir()
        let app = try await UpdateFixtures.makeApp(at: dir, version: "9.0.0")
        let (zip, sha) = try await UpdateFixtures.zip(app, version: "9.0.0")
        let installer = UpdateInstaller(workDirectory: dir.appendingPathComponent("work"))
        let box = ProgressBox()
        let out = try await installer.download(UpdateFixtures.release(version: "9.0.0", zip: zip, sha: sha)) { box.record($0) }
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(box.last == 1)
    }

    @Test func 校验值不一致时拒绝并删除文件() async throws {
        let dir = UpdateFixtures.tempDir()
        let app = try await UpdateFixtures.makeApp(at: dir, version: "9.0.0")
        let (zip, _) = try await UpdateFixtures.zip(app, version: "9.0.0")
        let installer = UpdateInstaller(workDirectory: dir.appendingPathComponent("work"))
        let bad = String(repeating: "0", count: 64)
        await #expect(throws: UpdateError.checksumMismatch) {
            try await installer.download(UpdateFixtures.release(version: "9.0.0", zip: zip, sha: bad)) { _ in }
        }
        let leftover = installer.workDirectory.appendingPathComponent("9.0.0/\(zip.lastPathComponent)")
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test func 没有任何校验信息时拒绝安装() async throws {
        let dir = UpdateFixtures.tempDir()
        let zip = dir.appendingPathComponent("StockMenuBar-9.0.0-macOS.zip")
        try Data("x".utf8).write(to: zip)
        let installer = UpdateInstaller(workDirectory: dir.appendingPathComponent("work"))
        await #expect(throws: UpdateError.checksumMissing) {
            try await installer.download(UpdateFixtures.release(version: "9.0.0", zip: zip, sha: nil)) { _ in }
        }
    }

    @Test func 通过校验附件取得校验值() async throws {
        let dir = UpdateFixtures.tempDir()
        let app = try await UpdateFixtures.makeApp(at: dir, version: "9.0.0")
        let (zip, sha) = try await UpdateFixtures.zip(app, version: "9.0.0")
        let sumURL = URL(string: "https://example.com/x.sha256")!
        let net = StubNetwork(routes: [sumURL.absoluteString: .success((Data("\(sha)  \(zip.lastPathComponent)\n".utf8), sumURL))])
        let installer = UpdateInstaller(workDirectory: dir.appendingPathComponent("work"), network: net)
        let out = try await installer.download(UpdateFixtures.release(version: "9.0.0", zip: zip, sha: nil, checksumURL: sumURL)) { _ in }
        #expect(FileManager.default.fileExists(atPath: out.path))
    }

    @Test func 解压并校验包信息() async throws {
        let dir = UpdateFixtures.tempDir()
        let app = try await UpdateFixtures.makeApp(at: dir, version: "9.0.0")
        let (zip, sha) = try await UpdateFixtures.zip(app, version: "9.0.0")
        let installer = UpdateInstaller(workDirectory: dir.appendingPathComponent("work"))
        let release = UpdateFixtures.release(version: "9.0.0", zip: zip, sha: sha)
        let local = try await installer.download(release) { _ in }
        let unpacked = try await installer.unpack(zip: local, release: release, bundleIdentifier: UpdateFixtures.bundleID)
        #expect(unpacked.lastPathComponent == "StockMenuBar.app")

        // Bundle ID 不一致
        await #expect(throws: UpdateError.self) {
            try await installer.unpack(zip: local, release: release, bundleIdentifier: "com.evil.App")
        }
        // 版本与发布页不一致
        let other = UpdateFixtures.release(version: "9.0.1", zip: zip, sha: sha)
        await #expect(throws: UpdateError.self) {
            try await installer.unpack(zip: local, release: other, bundleIdentifier: UpdateFixtures.bundleID)
        }
    }

    @Test func 签名被破坏的包被拒绝() async throws {
        let dir = UpdateFixtures.tempDir()
        let app = try await UpdateFixtures.makeApp(at: dir, version: "9.0.0", marker: "ok")
        // 签名后再改动内容,codesign --verify 必须失败
        try "tampered".write(to: app.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)
        let (zip, sha) = try await UpdateFixtures.zip(app, version: "9.0.0")
        let installer = UpdateInstaller(workDirectory: dir.appendingPathComponent("work"))
        let release = UpdateFixtures.release(version: "9.0.0", zip: zip, sha: sha)
        let local = try await installer.download(release) { _ in }
        await #expect(throws: UpdateError.self) {
            try await installer.unpack(zip: local, release: release, bundleIdentifier: UpdateFixtures.bundleID)
        }
    }

    @Test func 安装脚本替换应用并清理暂存() async throws {
        let dir = UpdateFixtures.tempDir()
        let installDir = dir.appendingPathComponent("Applications")
        let newDir = dir.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let old = try await UpdateFixtures.makeApp(at: installDir, version: "1.0.0", marker: "old")
        let new = try await UpdateFixtures.makeApp(at: newDir, version: "2.0.0", marker: "new")

        let installer = UpdateInstaller(workDirectory: dir.appendingPathComponent("work"))
        let process = try installer.launchInstaller(newApp: new, target: old, waitingFor: try UpdateFixtures.deadPID(), relaunch: false)
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: old.appendingPathComponent("Contents/marker.txt"), encoding: .utf8) == "new")
        let names = try FileManager.default.contentsOfDirectory(atPath: installDir.path)
        #expect(names == ["StockMenuBar.app"], "不应残留 .updating/.old: \(names)")
    }

    @Test func 安装脚本失败时回滚保留旧版() async throws {
        let dir = UpdateFixtures.tempDir()
        let installDir = dir.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        let old = try await UpdateFixtures.makeApp(at: installDir, version: "1.0.0", marker: "old")
        let missing = dir.appendingPathComponent("not-exist/StockMenuBar.app")

        let installer = UpdateInstaller(workDirectory: dir.appendingPathComponent("work"))
        let process = try installer.launchInstaller(newApp: missing, target: old, waitingFor: try UpdateFixtures.deadPID(), relaunch: false)
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
        #expect(try String(contentsOf: old.appendingPathComponent("Contents/marker.txt"), encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: installDir.path) == ["StockMenuBar.app"])
    }

    @Test func 就地安装的拦截条件() throws {
        #expect(UpdateInstaller.inPlaceBlocker(for: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/StockMenuBar.app")) != nil)
        #expect(UpdateInstaller.inPlaceBlocker(for: URL(fileURLWithPath: "/System/Applications/Calculator.app")) != nil)
        #expect(UpdateInstaller.inPlaceBlocker(for: UpdateFixtures.tempDir().appendingPathComponent("StockMenuBar.app")) == nil)
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    func record(_ v: Double) { lock.lock(); value = v; lock.unlock() }
    var last: Double { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - 状态机

@MainActor
struct UpdateManagerTests {
    private func makePrefs() -> Preferences {
        Preferences(defaults: UserDefaults(suiteName: "smb-update-\(UUID().uuidString)")!)
    }

    private func checker(latest: String, tag: String? = nil) throws -> UpdateChecker {
        let json = String(decoding: try Fixture.data("github_release_latest.json"), as: UTF8.self)
            .replacingOccurrences(of: "v1.2.0", with: tag ?? "v\(latest)")
            .replacingOccurrences(of: "1.2.0", with: latest)
        let api = URL(string: "https://api.test/latest")!
        return UpdateChecker(network: StubNetwork(routes: [api.absoluteString: .success((Data(json.utf8), api))]),
                             apiURL: api, fallbackRepository: nil)
    }

    @Test func 发现新版本() async throws {
        let m = UpdateManager(prefs: makePrefs(), checker: try checker(latest: "1.3.0"), currentVersion: SemanticVersion("1.2.0"))
        await m.check(userInitiated: true)
        #expect(m.availableRelease?.version.description == "1.3.0")
        #expect(m.hasAvailableUpdate)
    }

    @Test func 已是最新或更高版本() async throws {
        let m = UpdateManager(prefs: makePrefs(), checker: try checker(latest: "1.2.0"), currentVersion: SemanticVersion("1.2.0"))
        await m.check(userInitiated: true)
        #expect(m.state == .upToDate)
        let dev = UpdateManager(prefs: makePrefs(), checker: try checker(latest: "1.2.0"), currentVersion: SemanticVersion("1.3.0"))
        await dev.check(userInitiated: true)
        #expect(dev.state == .upToDate)
    }

    @Test func 跳过版本后自动检查静默而手动检查仍提示() async throws {
        let prefs = makePrefs()
        let m = UpdateManager(prefs: prefs, checker: try checker(latest: "1.3.0"), currentVersion: SemanticVersion("1.2.0"))
        await m.check(userInitiated: true)
        m.skipAvailableVersion()
        #expect(prefs.skippedUpdateVersion == "1.3.0")
        await m.check(userInitiated: false)
        #expect(m.state == .upToDate)
        await m.check(userInitiated: true)
        #expect(m.availableRelease != nil)
        #expect(!m.hasAvailableUpdate)
    }

    @Test func 手动检查失败有提示自动检查失败静默() async {
        let api = URL(string: "https://api.test/latest")!
        let bad = UpdateChecker(network: StubNetwork(routes: [api.absoluteString: .failure(ProviderError.httpStatus(500))]),
                                apiURL: api, fallbackRepository: nil)
        let m = UpdateManager(prefs: makePrefs(), checker: bad, currentVersion: SemanticVersion("1.2.0"))
        await m.check(userInitiated: false)
        #expect(m.state == .idle)
        await m.check(userInitiated: true)
        if case .failed = m.state {} else { Issue.record("手动检查失败应展示错误: \(m.state)") }
    }

    @Test func 完整更新流程替换应用并请求退出() async throws {
        let dir = UpdateFixtures.tempDir()
        let installDir = dir.appendingPathComponent("Applications")
        let newDir = dir.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let old = try await UpdateFixtures.makeApp(at: installDir, version: "1.0.0", marker: "old")
        let new = try await UpdateFixtures.makeApp(at: newDir, version: "2.0.0", marker: "new")
        let (zip, sha) = try await UpdateFixtures.zip(new, version: "2.0.0")

        // 构造指向本地 zip 的 latest JSON
        let json: [String: Any] = [
            "tag_name": "v2.0.0", "name": "2.0.0", "body": "n", "draft": false, "prerelease": false,
            "html_url": "https://example.com/r",
            "assets": [["name": zip.lastPathComponent, "size": 1, "browser_download_url": zip.absoluteString, "digest": "sha256:\(sha)"]]
        ]
        let api = URL(string: "https://api.test/latest")!
        let data = try JSONSerialization.data(withJSONObject: json)
        let checker = UpdateChecker(network: StubNetwork(routes: [api.absoluteString: .success((data, api))]),
                                    apiURL: api, fallbackRepository: nil)
        let work = dir.appendingPathComponent("work")
        let manager = UpdateManager(prefs: makePrefs(), checker: checker, installer: UpdateInstaller(workDirectory: work),
                                    currentVersion: SemanticVersion("1.0.0"), bundleIdentifier: UpdateFixtures.bundleID,
                                    bundleURL: old, processID: try UpdateFixtures.deadPID(), relaunchAfterInstall: false)
        var terminated = false
        manager.terminate = { terminated = true }

        await manager.check(userInitiated: true)
        manager.installAvailableUpdate()
        for _ in 0..<200 where !terminated { try await Task.sleep(for: .milliseconds(50)) }
        #expect(terminated, "安装脚本启动后应请求退出, 当前状态 \(manager.state)")

        // 脚本异步运行,轮询等待替换完成
        let marker = old.appendingPathComponent("Contents/marker.txt")
        for _ in 0..<100 where (try? String(contentsOf: marker, encoding: .utf8)) != "new" {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "new")
    }

    @Test func 无法就地安装时给出手动替换入口() async throws {
        let dir = UpdateFixtures.tempDir()
        let newDir = dir.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let new = try await UpdateFixtures.makeApp(at: newDir, version: "2.0.0")
        let (zip, sha) = try await UpdateFixtures.zip(new, version: "2.0.0")
        let json: [String: Any] = [
            "tag_name": "v2.0.0", "name": "2.0.0", "draft": false, "html_url": "https://example.com/r",
            "assets": [["name": zip.lastPathComponent, "browser_download_url": zip.absoluteString, "digest": "sha256:\(sha)"]]
        ]
        let api = URL(string: "https://api.test/latest")!
        let checker = UpdateChecker(network: StubNetwork(routes: [api.absoluteString: .success((try JSONSerialization.data(withJSONObject: json), api))]),
                                    apiURL: api, fallbackRepository: nil)
        let manager = UpdateManager(prefs: makePrefs(), checker: checker,
                                    installer: UpdateInstaller(workDirectory: dir.appendingPathComponent("work")),
                                    currentVersion: SemanticVersion("1.0.0"), bundleIdentifier: UpdateFixtures.bundleID,
                                    bundleURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        await manager.check(userInitiated: true)
        manager.installAvailableUpdate()
        for _ in 0..<200 {
            if case .failed = manager.state { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if case .failed(let message) = manager.state { #expect(message.contains("手动替换")) } else { Issue.record("应进入失败态: \(manager.state)") }
        #expect(manager.manualInstallURL != nil)
    }
}
