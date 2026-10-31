import CryptoKit
import XCTest
@testable import WhatsAppWork

final class AppVersionTests: XCTestCase {
    func testOrderingIsNumericPerComponent() throws {
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.9.9")), try XCTUnwrap(AppVersion("0.10.0")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.1.0")), try XCTUnwrap(AppVersion("v0.2.0")))
        XCTAssertEqual(try XCTUnwrap(AppVersion("0.1")), try XCTUnwrap(AppVersion("0.1.0")))
        XCTAssertFalse(try XCTUnwrap(AppVersion("1.0.0")) < XCTUnwrap(AppVersion("1.0")))
    }

    func testNonNumericTagsAreRejected() {
        XCTAssertNil(AppVersion("v1.2-beta"))
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNil(AppVersion("latest"))
    }
}

@MainActor
final class UpdateManagerTests: XCTestCase {
    private let bundleID = "dev.whatsappwork.WhatsAppWork"
    private let feed = URL(string: "https://example.invalid/releases/latest")!
    private let imageURL = URL(string: "https://example.invalid/dl/WhatsAppWork-0.2.0-universal.dmg")!
    private let signatureURL = URL(string: "https://example.invalid/dl/WhatsAppWork-0.2.0-universal.dmg.sig")!
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A read-only fixture directory must be writable again to delete.
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: root.appendingPathComponent("ro").path)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: parsing and signature

    func testReleaseParsingPicksTheImageAndItsSignature() throws {
        let release = try AvailableRelease.parse(releaseJSON(tag: "v0.2.0"))
        XCTAssertEqual(release.version.description, "0.2.0")
        XCTAssertEqual(release.imageURL, imageURL)
        XCTAssertEqual(release.signatureURL, signatureURL)
    }

    func testUnsignedNewerReleaseIsRefusedWithoutDownloading() async throws {
        let fetch = FetchStub([feed: releaseJSON(tag: "v0.2.0", signed: false)])
        let updater = UpdateManager(configuration: configuration(Curve25519.Signing.PrivateKey(),
                                                                 try makeInstalledApp()),
                                    fetch: fetch.fetch)

        await updater.checkNow(userInitiated: false)

        XCTAssertEqual(updater.status, .failed(UpdateError.missingSignature.localizedDescription))
        XCTAssertEqual(fetch.requested, [feed])
    }

    func testUnsignedReleaseThatIsNotNewerIsJustUpToDate() async throws {
        // The live feed today: v0.1.0 predates release signing.
        let fetch = FetchStub([feed: releaseJSON(tag: "v0.1.0", signed: false)])
        let updater = UpdateManager(configuration: configuration(Curve25519.Signing.PrivateKey(),
                                                                 try makeInstalledApp()),
                                    fetch: fetch.fetch)

        await updater.checkNow(userInitiated: false)

        XCTAssertEqual(updater.status, .upToDate)
    }

    func testMalformedReleasesAreRejected() {
        XCTAssertThrowsError(try AvailableRelease.parse(releaseJSON(tag: "nightly"))) {
            guard case .malformedRelease = $0 as? UpdateError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try AvailableRelease.parse(Data("{}".utf8)))
    }

    func testSignatureMustMatchTheImageAndTheKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let image = Data("disk image bytes".utf8)
        let good = Data(try key.signature(for: image).base64EncodedString().utf8)
        XCTAssertNoThrow(try UpdateManager.verify(image: image, signature: good + Data("\n".utf8),
                                                  publicKey: key.publicKey))
        let cases: [(Data, Data, Curve25519.Signing.PublicKey)] = [
            (Data("tampered bytes".utf8), good, key.publicKey),
            (image, good, Curve25519.Signing.PrivateKey().publicKey),
            (image, Data("not base64!".utf8), key.publicKey),
        ]
        for (data, signature, publicKey) in cases {
            XCTAssertThrowsError(try UpdateManager.verify(image: data, signature: signature,
                                                          publicKey: publicKey)) {
                XCTAssertEqual($0 as? UpdateError, .badSignature)
            }
        }
    }

    // MARK: whole pipeline (real DMG, hdiutil, codesign, swap)

    func testVerifiedUpdateIsStagedThenSwappedInAtQuit() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let installed = try makeInstalledApp()
        let image = try makeImage(bundleID: bundleID, version: "0.2.0")
        let fetch = FetchStub([feed: releaseJSON(tag: "v0.2.0"), imageURL: image,
                               signatureURL: sign(image, with: key)])
        let updater = UpdateManager(configuration: configuration(key, installed), fetch: fetch.fetch)
        var messages: [String] = []
        updater.onMessage = { messages.append($0) }

        await updater.checkNow(userInitiated: true)

        XCTAssertEqual(updater.status, .ready("0.2.0"))
        XCTAssertEqual(messages.last, "WhatsApp Work 0.2.0 is ready — restart to install it")
        XCTAssertEqual(try version(of: installed), "0.1.0", "nothing is installed before quit")

        updater.installPendingUpdate()

        XCTAssertEqual(try version(of: installed), "0.2.0")
        let staged = root.appendingPathComponent("work/0.2.0/WhatsApp Work.app")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "old bundle removed after the swap")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("work/0.2.0/update.dmg").path))
    }

    func testBadSignatureNeverStagesOrInstalls() async throws {
        let installed = try makeInstalledApp()
        let image = try makeImage(bundleID: bundleID, version: "0.2.0")
        // Signed by someone else's key.
        let fetch = FetchStub([feed: releaseJSON(tag: "v0.2.0"), imageURL: image,
                               signatureURL: sign(image, with: Curve25519.Signing.PrivateKey())])
        let updater = UpdateManager(configuration: configuration(Curve25519.Signing.PrivateKey(), installed),
                                    fetch: fetch.fetch)

        await updater.checkNow(userInitiated: false)
        updater.installPendingUpdate()

        XCTAssertEqual(updater.status, .failed(UpdateError.badSignature.localizedDescription))
        XCTAssertEqual(try version(of: installed), "0.1.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("work/0.2.0").path),
                       "nothing is unpacked before the signature verifies")
    }

    func testSignedImageForAnotherAppOrVersionIsRejected() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let installed = try makeInstalledApp()
        let cases: [(String, String, UpdateError)] = [
            ("com.example.Other", "0.2.0", .wrongBundle("com.example.Other")),
            // An older signed image replayed under a newer tag.
            (bundleID, "0.1.5", .versionMismatch(expected: "0.2.0", found: "0.1.5")),
        ]
        for (otherID, otherVersion, expected) in cases {
            let image = try makeImage(bundleID: otherID, version: otherVersion)
            let fetch = FetchStub([feed: releaseJSON(tag: "v0.2.0"), imageURL: image,
                                   signatureURL: sign(image, with: key)])
            let updater = UpdateManager(configuration: configuration(key, installed), fetch: fetch.fetch)

            await updater.checkNow(userInitiated: false)
            updater.installPendingUpdate()

            XCTAssertEqual(updater.status, .failed(expected.localizedDescription))
            XCTAssertEqual(try version(of: installed), "0.1.0")
        }
    }

    func testUpToDateDownloadsNothing() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let fetch = FetchStub([feed: releaseJSON(tag: "v0.1.0")])
        let updater = UpdateManager(configuration: configuration(key, try makeInstalledApp()),
                                    fetch: fetch.fetch)
        var messages: [String] = []
        updater.onMessage = { messages.append($0) }

        await updater.checkNow(userInitiated: true)

        XCTAssertEqual(updater.status, .upToDate)
        XCTAssertEqual(messages, ["You're on the latest version (0.1.0)"])
        XCTAssertEqual(fetch.requested, [feed])
    }

    func testCopyThatCannotReplaceItselfOffersTheReleasePage() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let readOnly = root.appendingPathComponent("ro", isDirectory: true)
        let installed = try makeInstalledApp(in: readOnly)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        let fetch = FetchStub([feed: releaseJSON(tag: "v0.2.0")])
        let updater = UpdateManager(configuration: configuration(key, installed), fetch: fetch.fetch)

        await updater.checkNow(userInitiated: false)

        XCTAssertEqual(updater.status,
                       .manualOnly("0.2.0", URL(string: "https://example.invalid/releases/tag/v0.2.0")!))
        XCTAssertEqual(fetch.requested, [feed], "no download for a copy that can't install it")
    }

    func testFailedFeedIsReported() async throws {
        let updater = UpdateManager(configuration: configuration(Curve25519.Signing.PrivateKey(),
                                                                 try makeInstalledApp()),
                                    fetch: FetchStub([:]).fetch)
        var messages: [String] = []
        updater.onMessage = { messages.append($0) }

        await updater.checkNow(userInitiated: true)

        XCTAssertEqual(updater.status, .failed(UpdateError.http(404).localizedDescription))
        XCTAssertEqual(messages, ["Update failed: GitHub answered HTTP 404"])
    }

    // MARK: fixtures

    private func configuration(_ key: Curve25519.Signing.PrivateKey,
                               _ installed: URL) -> UpdateManager.Configuration {
        UpdateManager.Configuration(feedURL: feed, publicKey: key.publicKey,
                                    currentVersion: AppVersion("0.1.0")!, bundleIdentifier: bundleID,
                                    installedAppURL: installed,
                                    workDirectory: root.appendingPathComponent("work", isDirectory: true))
    }

    private func releaseJSON(tag: String, signed: Bool = true) -> Data {
        var assets: [[String: Any]] = [
            ["name": "notes.txt", "browser_download_url": "https://example.invalid/dl/notes.txt", "size": 10],
            ["name": imageURL.lastPathComponent, "browser_download_url": imageURL.absoluteString, "size": 1000],
        ]
        if signed {
            assets.append(["name": signatureURL.lastPathComponent,
                           "browser_download_url": signatureURL.absoluteString, "size": 89])
        }
        let payload: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://example.invalid/releases/tag/\(tag)",
            "assets": assets,
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey) -> Data {
        Data(try! key.signature(for: data).base64EncodedString().utf8)
    }

    private func makeInstalledApp(in directory: URL? = nil) throws -> URL {
        let dir = directory ?? root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = dir.appendingPathComponent("WhatsApp Work.app", isDirectory: true)
        try makeApp(at: app, bundleID: bundleID, version: "0.1.0")
        return app
    }

    /// A real UDZO image holding an ad-hoc-signed app, as scripts/release.sh builds it.
    private func makeImage(bundleID: String, version: String) throws -> Data {
        let source = root.appendingPathComponent("image-\(UUID().uuidString)", isDirectory: true)
        try makeApp(at: source.appendingPathComponent("WhatsApp Work.app"), bundleID: bundleID, version: version)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Applications"),
                                                   withDestinationURL: URL(fileURLWithPath: "/Applications"))
        let dmg = root.appendingPathComponent("\(UUID().uuidString).dmg")
        try UpdateManager.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", source.path,
                                                   "-format", "UDZO", "-ov", dmg.path])
        return try Data(contentsOf: dmg)
    }

    private func makeApp(at app: URL, bundleID: String, version: String) throws {
        let fm = FileManager.default
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Fake"))
        let info: NSDictionary = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "Fake",
            "CFBundlePackageType": "APPL",
        ]
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try UpdateManager.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    }

    private func version(of app: URL) throws -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }
}

/// Serves canned bodies by URL; anything else answers 404.
private final class FetchStub: @unchecked Sendable {
    private let lock = NSLock()
    private let bodies: [URL: Data]
    private var urls: [URL] = []

    init(_ bodies: [URL: Data]) { self.bodies = bodies }

    var requested: [URL] { lock.withLock { urls } }

    var fetch: UpdateManager.Fetch {
        { [self] request in
            let url = request.url!
            lock.withLock { urls.append(url) }
            let body = bodies[url]
            let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200,
                                           httpVersion: nil, headerFields: nil)!
            return (body ?? Data(), response)
        }
    }
}
