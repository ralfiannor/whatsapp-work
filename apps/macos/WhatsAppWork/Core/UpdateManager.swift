// Self-update from GitHub Releases: check → download → verify → stage →
// atomic bundle swap at quit (or "Restart to Update").
//
// Trust: builds are ad-hoc signed, which proves nothing about who built
// them, so the ONLY trust anchor is the maintainer's Ed25519 release key.
// Every release DMG ships with `<dmg>.sig` (base64 signature over the DMG
// bytes); the public half lives in Info.plist (WWUpdatePublicKey). An
// update that is unsigned, mis-signed, for another bundle, or not newer
// is never installed. Never add a path that skips the signature check.
import AppKit
import CryptoKit
import Foundation

/// Numeric dotted version ("v0.2.0", "1.4"); missing components are zero.
struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard !parts.isEmpty, numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else {
            return nil
        }
        components = numbers
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// The parts of GitHub's "latest release" answer the updater acts on.
/// Image and signature are optional here: a release that is not newer
/// (e.g. one published before signing existed) is simply "up to date".
struct AvailableRelease: Equatable {
    let version: AppVersion
    let pageURL: URL
    let imageURL: URL?
    let imageSize: Int
    let signatureURL: URL?

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int
        }
        let tag_name: String
        let html_url: URL
        let assets: [Asset]
    }

    static func parse(_ data: Data) throws -> AvailableRelease {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw UpdateError.malformedRelease("unreadable release data")
        }
        guard let version = AppVersion(payload.tag_name) else {
            throw UpdateError.malformedRelease("tag \(payload.tag_name) is not a version")
        }
        let image = payload.assets.first(where: { $0.name.hasSuffix(".dmg") })
        let signature = image.flatMap { image in
            payload.assets.first(where: { $0.name == image.name + ".sig" })
        }
        return AvailableRelease(version: version, pageURL: payload.html_url,
                                imageURL: image?.browser_download_url, imageSize: image?.size ?? 0,
                                signatureURL: signature?.browser_download_url)
    }
}

enum UpdateError: LocalizedError, Equatable {
    case http(Int)
    case malformedRelease(String)
    case missingSignature
    case badSignature
    case tooLarge
    case noAppInImage
    case wrongBundle(String)
    case versionMismatch(expected: String, found: String)
    case codesignFailed
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "GitHub answered HTTP \(code)"
        case .malformedRelease(let why): return why
        case .missingSignature: return "the release is not signed — not installing it"
        case .badSignature: return "the update's signature does not match — not installing it"
        case .tooLarge: return "the update is larger than expected"
        case .noAppInImage: return "the disk image contains no app"
        case .wrongBundle(let id): return "the update is a different app (\(id))"
        case .versionMismatch(let expected, let found):
            return "the update contains version \(found), not \(expected)"
        case .codesignFailed: return "the update's code signature is broken"
        case .toolFailed(let tool): return "\(tool) failed while preparing the update"
        }
    }
}

@MainActor
final class UpdateManager: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case downloading(String)
        /// Verified and staged; installs at quit or on Restart.
        case ready(String)
        /// Newer release, but this copy can't replace itself (read-only
        /// location, App Translocation): offer the release page instead.
        case manualOnly(String, URL)
        case upToDate
        case failed(String)
    }

    struct Configuration {
        var feedURL: URL
        var publicKey: Curve25519.Signing.PublicKey
        var currentVersion: AppVersion
        var bundleIdentifier: String
        /// The running bundle — what the swap replaces.
        var installedAppURL: URL
        /// Scratch space for downloads and the staged app.
        var workDirectory: URL

        /// nil (updater off) when the build carries no release key or feed,
        /// e.g. a fork that hasn't set up its own signing.
        static func fromMainBundle(environment: [String: String] = ProcessInfo.processInfo.environment)
            -> Configuration? {
            let info = Bundle.main.infoDictionary ?? [:]
            guard let keyString = info["WWUpdatePublicKey"] as? String,
                  let keyData = Data(base64Encoded: keyString),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
                  // The feed may be redirected for local testing; the
                  // signature check still decides what gets installed.
                  let feed = (environment["WW_UPDATE_FEED_URL"] ?? info["WWUpdateFeedURL"] as? String)
                    .flatMap(URL.init(string:)),
                  let versionString = info["CFBundleShortVersionString"] as? String,
                  let version = AppVersion(versionString),
                  let bundleID = Bundle.main.bundleIdentifier,
                  let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            else { return nil }
            return Configuration(feedURL: feed, publicKey: key, currentVersion: version,
                                 bundleIdentifier: bundleID, installedAppURL: Bundle.main.bundleURL,
                                 workDirectory: caches.appendingPathComponent("\(bundleID)/Updates",
                                                                              isDirectory: true))
        }
    }

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// A release image is ~20 MB; anything far past that is not ours.
    nonisolated static let maxImageBytes = 150 << 20
    private static let checkInterval: Duration = .seconds(12 * 60 * 60)

    @Published private(set) var status: Status = .idle
    /// Feedback for user-initiated checks (AppState routes it to the toast).
    var onMessage: ((String) -> Void)?

    private let configuration: Configuration?
    private let fetch: Fetch
    private var stagedApp: URL?
    private var relaunchAfterInstall = false
    private var automaticChecks: Task<Void, Never>?

    init(configuration: Configuration? = .fromMainBundle(),
         fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }) {
        self.configuration = configuration
        self.fetch = fetch
    }

    /// Launch + every 12 h. Release builds only: a Debug build lives in
    /// DerivedData and must not swap itself for a downloaded release.
    func startAutomaticChecks() {
        #if !DEBUG
        guard let configuration, automaticChecks == nil else { return }
        // A staged app from a run that never quit cleanly is stale.
        try? FileManager.default.removeItem(at: configuration.workDirectory)
        automaticChecks = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self?.checkNow(userInitiated: false)
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
        #endif
    }

    func checkNow(userInitiated: Bool) async {
        guard let configuration else {
            if userInitiated { onMessage?("Updates are not set up for this build") }
            return
        }
        switch status {
        case .checking, .downloading:
            return
        case .ready(let version):
            if userInitiated { onMessage?("WhatsApp Work \(version) is ready — restart to install it") }
            return
        default:
            break
        }
        status = .checking
        do {
            let release = try await latestRelease(configuration)
            let version = release.version.description
            guard release.version > configuration.currentVersion else {
                status = .upToDate
                if userInitiated {
                    onMessage?("You're on the latest version (\(configuration.currentVersion))")
                }
                return
            }
            guard Self.canReplace(configuration.installedAppURL) else {
                status = .manualOnly(version, release.pageURL)
                if userInitiated {
                    onMessage?("WhatsApp Work \(version) is available — this copy can't update itself")
                }
                return
            }
            guard let imageURL = release.imageURL else {
                throw UpdateError.malformedRelease("release \(version) has no disk image")
            }
            guard let signatureURL = release.signatureURL else { throw UpdateError.missingSignature }
            guard release.imageSize <= Self.maxImageBytes else { throw UpdateError.tooLarge }
            status = .downloading(version)
            if userInitiated { onMessage?("Downloading WhatsApp Work \(version)…") }
            let image = try await download(imageURL, limit: Self.maxImageBytes)
            let signature = try await download(signatureURL, limit: 1024)
            let staged = try await Task.detached(priority: .utility) {
                try Self.prepare(image: image, signature: signature, release: release,
                                 configuration: configuration)
            }.value
            stagedApp = staged
            status = .ready(version)
            if userInitiated { onMessage?("WhatsApp Work \(version) is ready — restart to install it") }
        } catch {
            status = .failed(error.localizedDescription)
            if userInitiated { onMessage?("Update failed: \(error.localizedDescription)") }
        }
    }

    /// "Restart to Update": quit normally (the core stops first), install
    /// in applicationShouldTerminate, then reopen.
    func restartToUpdate() {
        guard case .ready = status else { return }
        relaunchAfterInstall = true
        NSApp.terminate(nil)
    }

    /// Called while the app quits, after the core has stopped. Never throws
    /// at the user: a failed swap leaves the old app untouched and the next
    /// launch simply checks again.
    func installPendingUpdate() {
        guard case .ready = status, let stagedApp, let configuration else { return }
        do {
            try Self.swapInstall(staged: stagedApp, over: configuration.installedAppURL)
        } catch {
            return
        }
        if relaunchAfterInstall {
            Self.reopenAfterExit(configuration.installedAppURL)
        }
    }

    // MARK: pipeline

    private func latestRelease(_ configuration: Configuration) async throws -> AvailableRelease {
        var request = URLRequest(url: configuration.feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await fetch(request)
        try Self.requireOK(response)
        return try AvailableRelease.parse(data)
    }

    private func download(_ url: URL, limit: Int) async throws -> Data {
        let (data, response) = try await fetch(URLRequest(url: url))
        try Self.requireOK(response)
        // The release JSON's size is only a hint; the bytes decide.
        guard data.count <= limit else { throw UpdateError.tooLarge }
        return data
    }

    private nonisolated static func requireOK(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.http(http.statusCode)
        }
    }

    /// Verify, unpack and validate a downloaded release; returns the staged
    /// app. Runs off the main actor (hdiutil/ditto/codesign take seconds).
    nonisolated static func prepare(image: Data, signature: Data, release: AvailableRelease,
                                    configuration: Configuration) throws -> URL {
        try verify(image: image, signature: signature, publicKey: configuration.publicKey)
        let fm = FileManager.default
        let work = configuration.workDirectory.appendingPathComponent(release.version.description,
                                                                      isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let imageURL = work.appendingPathComponent("update.dmg")
        try image.write(to: imageURL)
        defer { try? fm.removeItem(at: imageURL) }
        let staged = try extractApp(fromImage: imageURL, into: work)
        try validate(app: staged, bundleIdentifier: configuration.bundleIdentifier,
                     version: release.version)
        return staged
    }

    nonisolated static func verify(image: Data, signature: Data,
                                   publicKey: Curve25519.Signing.PublicKey) throws {
        let text = String(decoding: signature, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: text),
              publicKey.isValidSignature(raw, for: image) else {
            throw UpdateError.badSignature
        }
    }

    nonisolated static func extractApp(fromImage image: URL, into directory: URL) throws -> URL {
        let fm = FileManager.default
        let mount = directory.appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly",
                                     "-noautoopen", "-mountpoint", mount.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? fm.removeItem(at: mount)
        }
        guard let app = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.noAppInImage
        }
        let staged = directory.appendingPathComponent(app.lastPathComponent, isDirectory: true)
        try? fm.removeItem(at: staged)
        try run("/usr/bin/ditto", [app.path, staged.path])
        return staged
    }

    nonisolated static func validate(app: URL, bundleIdentifier: String, version: AppVersion) throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let foundID = info?["CFBundleIdentifier"] as? String ?? "unknown"
        guard foundID == bundleIdentifier else { throw UpdateError.wrongBundle(foundID) }
        let foundVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        guard AppVersion(foundVersion) == version else {
            throw UpdateError.versionMismatch(expected: version.description, found: foundVersion)
        }
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        } catch {
            throw UpdateError.codesignFailed
        }
    }

    /// Writable parent and bundle, and not an App Translocation mount.
    nonisolated static func canReplace(_ app: URL) -> Bool {
        let fm = FileManager.default
        return !app.path.contains("/AppTranslocation/")
            && fm.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && fm.isWritableFile(atPath: app.path)
    }

    /// Atomically exchanges the staged and installed bundles (APFS/HFS+
    /// RENAME_SWAP), so there is no moment without an app at the install
    /// path; the old bundle then sits at the staged path and is removed.
    nonisolated static func swapInstall(staged: URL, over target: URL) throws {
        let fm = FileManager.default
        if renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 {
            try? fm.removeItem(at: staged)
            return
        }
        guard errno == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Different volumes: copy beside the target, then swap there.
        let sibling = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).update-\(UUID().uuidString)")
        try run("/usr/bin/ditto", [staged.path, sibling.path])
        guard renamex_np(sibling.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
            let code = errno
            try? fm.removeItem(at: sibling)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        try? fm.removeItem(at: sibling)
        try? fm.removeItem(at: staged)
    }

    /// Opens the new bundle once this process has exited, so the old and
    /// new copies never run (and fight over the core lock) side by side.
    nonisolated static func reopenAfterExit(_ app: URL) {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$1\"",
                            String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? waiter.run()
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.toolFailed(URL(fileURLWithPath: tool).lastPathComponent)
        }
        return data
    }
}
