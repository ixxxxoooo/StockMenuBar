//
//  UpdateInstaller.swift
//  StockMenuBar
//
//  下载、校验、解压并"就地替换"应用包:
//  1. 流式下载 zip,边下边算 SHA-256,与发布页校验值比对;
//  2. 用 ditto 解压,校验 Bundle ID、版本号与代码签名完整性;
//  3. 写出独立的安装脚本:等待旧进程退出 → 复制到同目录暂存 → 原子改名替换 → 清除隔离属性 → 重新打开;
//     任何一步失败都会回滚到旧版本。
//  @author ixxxxoooo
//

import CryptoKit
import Foundation

struct UpdateInstaller: Sendable {
    /// 工作目录(下载与解压都在这里)
    let workDirectory: URL
    let network: UpdateNetwork
    let session: URLSession

    /// - Parameters:
    ///   - workDirectory: 默认放在 ~/Library/Caches/<BundleID>/Updates
    init(workDirectory: URL = UpdateInstaller.defaultWorkDirectory(),
         network: UpdateNetwork = URLSessionUpdateNetwork(),
         session: URLSession = UpdateInstaller.makeSession()) {
        self.workDirectory = workDirectory
        self.network = network
        self.session = session
    }

    static func defaultWorkDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let id = Bundle.main.bundleIdentifier ?? "com.ixxxxoooo.StockMenuBar"
        return caches.appendingPathComponent(id).appendingPathComponent("Updates")
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "StockMenuBar-Updater"]
        return URLSession(configuration: config)
    }

    // MARK: - 下载与校验

    /// 下载安装包并校验 SHA-256
    /// - Parameters:
    ///   - release: 目标版本
    ///   - progress: 进度回调(0...1),可能在任意线程调用
    /// - Returns: 已校验通过的 zip 本地路径
    func download(_ release: ReleaseInfo, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let expected = try await expectedChecksum(for: release)

        let dir = workDirectory.appendingPathComponent(release.version.description, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent(release.zipName)
        FileManager.default.createFile(atPath: zip.path, contents: nil)

        do {
            let (bytes, response) = try await session.bytes(from: release.zipURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UpdateError.downloadFailed("HTTP \(http.statusCode)")
            }
            let total = response.expectedContentLength > 0 ? response.expectedContentLength : release.zipSize
            let handle = try FileHandle(forWritingTo: zip)
            defer { try? handle.close() }

            var hasher = SHA256()
            var buffer = Data()
            buffer.reserveCapacity(1 << 17)
            var received: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 17 {
                    hasher.update(data: buffer)
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if total > 0 { progress(min(Double(received) / Double(total), 1)) }
                }
            }
            if !buffer.isEmpty {
                hasher.update(data: buffer)
                try handle.write(contentsOf: buffer)
            }
            progress(1)
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                try? FileManager.default.removeItem(at: zip)
                throw UpdateError.checksumMismatch
            }
            return zip
        } catch let error as UpdateError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }
    }

    /// 取得期望的校验值:优先使用 API 内置摘要,其次读取 .sha256 附件;都没有则拒绝安装
    private func expectedChecksum(for release: ReleaseInfo) async throws -> String {
        if let sha = release.sha256 { return sha }
        guard let url = release.checksumURL else { throw UpdateError.checksumMissing }
        do {
            let (data, _) = try await network.get(url, accept: "text/plain")
            guard let text = String(data: data, encoding: .utf8),
                  let sha = GitHubReleaseParser.parseChecksumFile(text) else { throw UpdateError.checksumMissing }
            return sha
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.checksumMissing
        }
    }

    // MARK: - 解压与校验

    /// 解压并校验新版本应用包
    /// - Parameters:
    ///   - zip: 已校验的安装包
    ///   - release: 目标版本
    ///   - bundleIdentifier: 期望的 Bundle ID(必须与当前应用一致)
    /// - Returns: 解压出的 .app 路径
    func unpack(zip: URL, release: ReleaseInfo, bundleIdentifier: String) async throws -> URL {
        let extractDir = zip.deletingLastPathComponent().appendingPathComponent("extract", isDirectory: true)
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let unzip = try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, extractDir.path])
        guard unzip.status == 0 else { throw UpdateError.unpackFailed(unzip.output) }

        let contents = (try? FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.unpackFailed("压缩包中没有应用")
        }

        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else {
            throw UpdateError.validationFailed("无法读取 Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateError.validationFailed("Bundle ID 与当前应用不一致")
        }
        guard let shortVersion = info["CFBundleShortVersionString"] as? String,
              SemanticVersion(shortVersion) == release.version else {
            throw UpdateError.validationFailed("安装包版本与发布页不一致")
        }
        let verify = try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verify.status == 0 else { throw UpdateError.validationFailed("代码签名不完整:\(verify.output)") }
        return app
    }

    // MARK: - 就地安装

    /// 能否就地替换目标应用;不能时返回原因
    /// - Parameter target: 当前运行的应用包路径
    static func inPlaceBlocker(for target: URL) -> String? {
        if target.path.contains("/AppTranslocation/") {
            return "应用正处于 macOS 的隔离运行状态,请先把它拖到「应用程序」文件夹,重新打开后再更新。"
        }
        let parent = target.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: parent) {
            return "没有权限写入 \(parent),无法自动替换。"
        }
        return nil
    }

    /// 启动安装脚本(脱离当前进程独立运行),调用方随后应立即退出应用
    /// - Parameters:
    ///   - newApp: 解压出的新版应用
    ///   - target: 需要被替换的应用包
    ///   - pid: 等待退出的旧进程
    ///   - relaunch: 安装完成后是否重新打开
    @discardableResult
    func launchInstaller(newApp: URL, target: URL, waitingFor pid: Int32, relaunch: Bool = true) throws -> Process {
        let script = workDirectory.appendingPathComponent("install.sh")
        let log = Self.logURL()
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try Self.installScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(pid), newApp.path, target.path, relaunch ? "1" : "0"]
        let handle = try? FileHandle(forWritingTo: log)
        _ = try? handle?.seekToEnd()
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw UpdateError.installerLaunchFailed(error.localizedDescription) }
        return process
    }

    /// 追加一行更新日志(与安装脚本共用同一个文件,便于用户反馈问题)
    static func appendLog(_ message: String) {
        let url = logURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) [app] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 安装日志位置
    static func logURL() -> URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/StockMenuBar/update.log")
    }

    /// 安装脚本:参数 pid、新版路径、目标路径、是否重启(1/0)。所有路径均以位置参数传入,避免注入。
    static let installScript = """
    #!/bin/sh
    PID="$1"; NEW="$2"; DEST="$3"; RELAUNCH="$4"
    STAGE="$DEST.updating"; OLD="$DEST.old"
    log() { echo "$(date '+%F %T') $*"; }
    reopen() { [ "$RELAUNCH" = "1" ] && /usr/bin/open "$DEST"; }

    log "开始安装: $NEW -> $DEST (等待进程 $PID 退出)"
    n=0
    while kill -0 "$PID" 2>/dev/null; do
      n=$((n + 1))
      if [ "$n" -gt 100 ]; then log "等待旧进程退出超时"; exit 1; fi
      sleep 0.3
    done

    rm -rf "$STAGE" "$OLD"
    if ! /usr/bin/ditto "$NEW" "$STAGE"; then
      log "复制新版失败,保留旧版"; rm -rf "$STAGE"; reopen; exit 1
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null
    if ! mv "$DEST" "$OLD"; then
      log "无法移开旧版(权限不足?),保留旧版"; rm -rf "$STAGE"; reopen; exit 1
    fi
    if ! mv "$STAGE" "$DEST"; then
      log "替换失败,回滚旧版"; mv "$OLD" "$DEST"; reopen; exit 1
    fi
    rm -rf "$OLD"
    log "安装完成"
    reopen
    exit 0
    """

    // MARK: - 子进程

    /// 运行子进程并等待结束(不阻塞协作线程池)
    static func run(_ path: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (proc.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
