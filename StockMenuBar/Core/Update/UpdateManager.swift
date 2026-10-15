//
//  UpdateManager.swift
//  StockMenuBar
//
//  在线更新的状态机与对外入口:自动/手动检查 → 发现新版 → 下载校验 → 就地替换并重启。
//  界面只读取 state,所有动作都通过本类触发。
//  @author ixxxxoooo
//

import Foundation
import Observation

/// 更新流程状态
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(ReleaseInfo)
    case downloading(ReleaseInfo, progress: Double)
    case verifying(ReleaseInfo)
    case installing(ReleaseInfo)
    case failed(String)
}

extension UpdateState {
    /// 写入日志的简短描述
    var logDescription: String {
        switch self {
        case .idle: return "空闲"
        case .checking: return "检查中"
        case .upToDate: return "已是最新"
        case .available(let r): return "发现新版本 \(r.version)"
        case .downloading(let r, _): return "下载 \(r.version)"
        case .verifying(let r): return "校验 \(r.version)"
        case .installing(let r): return "安装 \(r.version)"
        case .failed(let m): return "失败: \(m)"
        }
    }
}

@MainActor
@Observable
final class UpdateManager {
    /// 自动检查的最小间隔
    static let autoCheckInterval: TimeInterval = 6 * 3600

    private(set) var state: UpdateState = .idle {
        didSet { if !isProgressOnly(oldValue, state) { UpdateInstaller.appendLog("状态 → \(state.logDescription)") } }
    }
    /// 无法就地安装时,已下载好的新版应用位置(用于在 Finder 中显示,手动替换)
    private(set) var manualInstallURL: URL?

    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let checker: UpdateChecker
    @ObservationIgnored private let installer: UpdateInstaller
    @ObservationIgnored private let currentVersion: SemanticVersion
    @ObservationIgnored private let bundleIdentifier: String
    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let processID: Int32
    @ObservationIgnored private let relaunchAfterInstall: Bool
    /// 安装脚本启动后调用,应退出应用
    @ObservationIgnored var terminate: @MainActor () -> Void = {}
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var autoCheckTask: Task<Void, Never>?

    /// 当前版本号(来自 Info.plist)
    var current: SemanticVersion { currentVersion }

    /// 是否有可用的新版本(被用户跳过的不算)
    var hasAvailableUpdate: Bool {
        switch state {
        case .available(let r), .downloading(let r, _), .verifying(let r), .installing(let r):
            return r.version.description != prefs.skippedUpdateVersion || isBusy
        default: return false
        }
    }

    /// 是否正在执行检查或安装
    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    /// 当前可更新的版本(用于界面展示)
    var availableRelease: ReleaseInfo? {
        switch state {
        case .available(let r), .downloading(let r, _), .verifying(let r), .installing(let r): return r
        default: return nil
        }
    }

    init(prefs: Preferences,
         checker: UpdateChecker = .makeDefault(),
         installer: UpdateInstaller = UpdateInstaller(),
         currentVersion: SemanticVersion? = nil,
         bundleIdentifier: String? = nil,
         bundleURL: URL = Bundle.main.bundleURL,
         processID: Int32 = ProcessInfo.processInfo.processIdentifier,
         relaunchAfterInstall: Bool = true) {
        self.relaunchAfterInstall = relaunchAfterInstall
        self.prefs = prefs
        self.checker = checker
        self.installer = installer
        let plistVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.currentVersion = currentVersion ?? plistVersion.flatMap(SemanticVersion.init) ?? SemanticVersion("0.0.0")!
        self.bundleIdentifier = bundleIdentifier ?? Bundle.main.bundleIdentifier ?? "com.ixxxxoooo.StockMenuBar"
        self.bundleURL = bundleURL
        self.processID = processID
    }

    // MARK: - 自动检查

    /// 启动自动检查:启动后稍等片刻检查一次,之后每小时判断一次是否到期
    func startAutoCheck() {
        autoCheckTask?.cancel()
        autoCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                if let self { await self.autoCheckIfDue() }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private func autoCheckIfDue() async {
        guard prefs.autoCheckUpdates, !isBusy else { return }
        if let last = prefs.lastUpdateCheck, Date().timeIntervalSince(last) < Self.autoCheckInterval { return }
        await check(userInitiated: false)
    }

    // MARK: - 检查

    /// 检查更新
    /// - Parameter userInitiated: 手动检查会展示"已是最新/失败"结果;自动检查失败时保持静默
    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        let previous = state
        state = .checking
        do {
            let latest = try await checker.fetchLatest()
            prefs.lastUpdateCheck = Date()
            if latest.version > currentVersion {
                // 自动检查时尊重"跳过此版本";手动检查总是展示
                if !userInitiated, prefs.skippedUpdateVersion == latest.version.description {
                    state = .upToDate
                } else {
                    state = .available(latest)
                }
            } else {
                state = .upToDate
            }
        } catch {
            if userInitiated {
                state = .failed("检查更新失败:\(Self.describe(error))")
            } else {
                state = previous == .checking ? .idle : previous
            }
        }
    }

    /// 跳过当前提示的版本
    func skipAvailableVersion() {
        guard let release = availableRelease, !isBusy else { return }
        prefs.skippedUpdateVersion = release.version.description
        state = .upToDate
    }

    /// 清除失败提示
    func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    // MARK: - 更新

    /// 下载、校验并安装当前可用版本,完成后自动重启
    func installAvailableUpdate() {
        guard case .available(let release) = state, task == nil else { return }
        manualInstallURL = nil
        prefs.skippedUpdateVersion = nil
        task = Task { [weak self] in
            await self?.performInstall(release)
            self?.task = nil
        }
    }

    private func performInstall(_ release: ReleaseInfo) async {
        do {
            if let blocker = UpdateInstaller.inPlaceBlocker(for: bundleURL) {
                // 提前拦截:不必下载就能知道无法自动替换
                state = .downloading(release, progress: 0)
                let (zip, app) = try await downloadAndUnpack(release)
                _ = zip
                manualInstallURL = app
                state = .failed(blocker + " 新版本已下载,可在 Finder 中手动替换。")
                return
            }
            let (_, app) = try await downloadAndUnpack(release)
            state = .installing(release)
            try installer.launchInstaller(newApp: app, target: bundleURL, waitingFor: processID, relaunch: relaunchAfterInstall)
            // 给安装脚本一点启动时间,再退出让它接管
            try? await Task.sleep(for: .milliseconds(400))
            terminate()
        } catch is CancellationError {
            state = .available(release)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    private func downloadAndUnpack(_ release: ReleaseInfo) async throws -> (zip: URL, app: URL) {
        state = .downloading(release, progress: 0)
        let zip = try await installer.download(release) { [weak self] value in
            Task { @MainActor in
                guard let self, case .downloading(let r, _) = self.state else { return }
                self.state = .downloading(r, progress: value)
            }
        }
        state = .verifying(release)
        let app = try await installer.unpack(zip: zip, release: release, bundleIdentifier: bundleIdentifier)
        return (zip, app)
    }

    /// 下载进度变化不重复写日志
    private func isProgressOnly(_ old: UpdateState, _ new: UpdateState) -> Bool {
        if case .downloading = old, case .downloading = new { return true }
        return false
    }

    /// 错误转为中文描述
    static func describe(_ error: Error) -> String {
        if let e = error as? UpdateError { return e.errorDescription ?? "未知错误" }
        if let e = error as? ProviderError { return e.errorDescription ?? "网络错误" }
        return error.localizedDescription
    }
}
