// SidecarManager owns the whatsapp-core process lifecycle per
// docs/architecture.md §6: spawn → stdout READY handshake (random port +
// bearer token) → serve → crash-restart with capped backoff → SIGTERM on quit.
//
// Exit codes from the core: 0 clean · 2 lock held · 3 storage fatal.
import Foundation
import IOKit.pwr_mgt

protocol SidecarProcess: AnyObject {
    var isRunning: Bool { get }
    var processIdentifier: Int32 { get }

    func run(
        executableURL: URL,
        arguments: [String],
        standardError: Any?,
        onStdout: @escaping (Data) -> Void,
        onTermination: @escaping (Int32) -> Void
    ) throws
    func stopReading()
    func terminate()
    func interrupt()
}

final class FoundationSidecarProcess: SidecarProcess {
    private let process = Process()
    private var stdoutPipe: Pipe?

    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    func run(
        executableURL: URL,
        arguments: [String],
        standardError: Any?,
        onStdout: @escaping (Data) -> Void,
        onTermination: @escaping (Int32) -> Void
    ) throws {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardError = standardError
        let out = Pipe()
        stdoutPipe = out
        process.standardOutput = out
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { onStdout(data) }
        }
        process.terminationHandler = { process in
            onTermination(process.terminationStatus)
        }
        try process.run()
    }

    func stopReading() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
    }

    func terminate() { process.terminate() }
    func interrupt() { process.interrupt() }
}

protocol SidecarOrphanReclaimOperation: AnyObject {
    func start(dataDirectory: URL, onCompletion: @escaping () -> Void) throws
}

final class FoundationSidecarOrphanReclaimOperation: SidecarOrphanReclaimOperation {
    private let process = Process()

    func start(dataDirectory: URL, onCompletion: @escaping () -> Void) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "whatsapp-core --data-dir \(dataDirectory.path)"]
        process.terminationHandler = { _ in onCompletion() }
        try process.run()
    }
}

struct CoreHandshake: Codable {
    let event: String
    let port: UInt16
    let token: String
    let pid: Int32
    let version: String
}

enum CoreError: LocalizedError {
    case notBundled
    case handshakeTimeout
    case lockHeld
    case crashed(exitCode: Int32)

    var errorDescription: String? {
        switch self {
        case .notBundled: return "whatsapp-core binary missing from the app bundle"
        case .handshakeTimeout: return "core did not report READY in time"
        case .lockHeld: return "another core instance holds the lock"
        case .crashed(let code): return "core exited with code \(code)"
        }
    }
}

final class SidecarManager: ObservableObject {
    enum Phase: Equatable {
        case idle            // not started
        case starting
        case running(version: String)
        case restarting(afterSeconds: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var handshake: CoreHandshake?

    /// Internal phase state, confined to `queue`; `phase` is its main-actor
    /// mirror for SwiftUI. Reading `phase` from the queue raced the mirror.
    private var state: Phase = .idle

    private var process: (any SidecarProcess)?
    private var stderrHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var powerAssertion: IOPMAssertionID = 0
    private let acquirePowerAssertionAction: () -> UInt32
    private let releasePowerAssertionAction: (UInt32) -> Void
    private let scheduleSleepCapAction: (
        DispatchQueue,
        TimeInterval,
        @escaping () -> Void
    ) -> Void
    private let processFactoryAction: () -> any SidecarProcess
    private let orphanReclaimFactoryAction: () -> any SidecarOrphanReclaimOperation
    private let binaryURLAction: (() throws -> URL)?
    private let dataDirectoryAction: (() throws -> URL)?
    private let scheduleLifecycleAction: (
        DispatchQueue,
        TimeInterval,
        @escaping () -> Void
    ) -> Void
    /// Lifecycle intent and ownership are confined to `queue`. Every process
    /// callback carries both the object identity and the generation assigned
    /// at spawn, so work from an older child cannot mutate a replacement.
    private var desiredRunning = false
    private var lifecycleGeneration: UInt64 = 0
    private var pendingRestartOwner: ObjectIdentifier?
    private var orphanReclaimOperation: (any SidecarOrphanReclaimOperation)?
    private var orphanReclaimGeneration: UInt64 = 0
    /// A drained orphan reclaim still needs a short lock-release grace period
    /// before another child may open the shared database. This token is
    /// independent of process generations so start/restart can update intent
    /// without bypassing the in-flight barrier.
    private var lockReleaseBarrierGeneration: UInt64 = 0
    private var activeLockReleaseBarrier: UInt64?
    private var terminatingProcessGenerations: [ObjectIdentifier: UInt64] = [:]
    private var restartAttempts = 0
    private static let queueKey = DispatchSpecificKey<Bool>()
    private let queue: DispatchQueue = {
        let q = DispatchQueue(label: "sidecar.manager")
        q.setSpecific(key: SidecarManager.queueKey, value: true)
        return q
    }()

    private static let maxBackoffSeconds: Int = 60

    init() {
        acquirePowerAssertionAction = {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "WhatsAppWork sync" as CFString,
                &id
            )
            return result == kIOReturnSuccess ? id : 0
        }
        releasePowerAssertionAction = { IOPMAssertionRelease($0) }
        scheduleSleepCapAction = { queue, delay, operation in
            queue.asyncAfter(deadline: .now() + delay, execute: operation)
        }
        processFactoryAction = { FoundationSidecarProcess() }
        orphanReclaimFactoryAction = { FoundationSidecarOrphanReclaimOperation() }
        binaryURLAction = nil
        dataDirectoryAction = nil
        scheduleLifecycleAction = { queue, delay, operation in
            queue.asyncAfter(deadline: .now() + delay, execute: operation)
        }
    }

    init(
        acquirePowerAssertion: @escaping () -> UInt32,
        releasePowerAssertion: @escaping (UInt32) -> Void,
        scheduleSleepCap: @escaping (
            DispatchQueue,
            TimeInterval,
            @escaping () -> Void
        ) -> Void,
        processFactory: @escaping () -> any SidecarProcess = { FoundationSidecarProcess() },
        orphanReclaimFactory: @escaping () -> any SidecarOrphanReclaimOperation = {
            FoundationSidecarOrphanReclaimOperation()
        },
        binaryURL: (() throws -> URL)? = nil,
        dataDirectory: (() throws -> URL)? = nil,
        scheduleLifecycle: @escaping (
            DispatchQueue,
            TimeInterval,
            @escaping () -> Void
        ) -> Void = { queue, delay, operation in
            queue.asyncAfter(deadline: .now() + delay, execute: operation)
        }
    ) {
        acquirePowerAssertionAction = acquirePowerAssertion
        releasePowerAssertionAction = releasePowerAssertion
        scheduleSleepCapAction = scheduleSleepCap
        processFactoryAction = processFactory
        orphanReclaimFactoryAction = orphanReclaimFactory
        binaryURLAction = binaryURL
        dataDirectoryAction = dataDirectory
        scheduleLifecycleAction = scheduleLifecycle
    }

    var apiBase: URL? {
        handshake.map { URL(string: "http://127.0.0.1:\($0.port)")! }
    }
    var authToken: String? { handshake?.token }

    // MARK: lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.desiredRunning = true
            guard self.process == nil,
                  self.state == .idle || self.isTerminal else { return }
            self.spawn(restart: false)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.desiredRunning = false
            self.terminateProcess()
            self.setPhase(.idle)
        }
    }

    /// Synchronous stop for app termination: the process must receive its
    /// SIGTERM before the app exits, or it stays alive holding the DB lock.
    func stopBlocking() {
        let block = {
            self.desiredRunning = false
            // Capture the live process before terminateProcess clears the
            // reference: app quit must not rely on queue-scheduled
            // escalations — the app process (and its dispatch queue) can
            // be gone within milliseconds of this returning.
            let dying = self.process
            self.terminateProcess()
            if let dying, dying.isRunning {
                let deadline = Date().addingTimeInterval(2)
                while dying.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if dying.isRunning {
                    kill(dying.processIdentifier, SIGKILL)
                }
            }
            self.setPhase(.idle)
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) == true {
            block()
        } else {
            queue.sync { block() }
        }
    }

    /// Kill and relaunch immediately (developer action / after logout wipe).
    func restartNow() {
        queue.async { [weak self] in
            guard let self else { return }
            self.desiredRunning = true
            self.terminateProcess()
            self.spawn(restart: true)
        }
    }

    // MARK: internals

    private var isTerminal: Bool {
        if case .failed = state { return true }
        if case .restarting = state { return true }
        return false
    }

    /// Updates the queue-confined state and its main-actor published mirror.
    /// Safe to call from the queue or from main.
    private func setPhase(_ p: Phase) {
        if DispatchQueue.getSpecific(key: Self.queueKey) == true {
            state = p
            DispatchQueue.main.async { self.phase = p }
        } else {
            queue.async { self.setPhase(p) }
        }
    }

    private func coreBinaryURL() throws -> URL {
        // Bundled sidecar first; fall back to the repo dist build during M2 dev.
        let bundle = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/whatsapp-core", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: bundle.path) {
            return bundle
        }
        let dev = bundle.deletingLastPathComponent() // .../dist/whatsapp-core
            .deletingLastPathComponent()
            .appendingPathComponent("dist/whatsapp-core", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: dev.path) {
            return dev
        }
        throw CoreError.notBundled
    }

    private func dataDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhatsAppWork", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func spawn(restart: Bool) {
        guard desiredRunning,
              process == nil else { return }
        if activeLockReleaseBarrier != nil {
            setPhase(.restarting(afterSeconds: 2))
            return
        }
        guard orphanReclaimOperation == nil else {
            setPhase(.restarting(afterSeconds: 2))
            return
        }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        pendingRestartOwner = nil
        applySleepSignal(.spawn)
        setPhase(.starting)
        do {
            let binary = try binaryURLAction?() ?? coreBinaryURL()
            let dataDir = try dataDirEnsure()

            let p = processFactoryAction()
            let processID = ObjectIdentifier(p)
            // Core stderr → rotating-ish log file (tail-able for support).
            let logURL = dataDir.appendingPathComponent("core.log")
            let fm = FileManager.default
            if !fm.fileExists(atPath: logURL.path) {
                fm.createFile(atPath: logURL.path, contents: nil)
            }
            if let h = try? FileHandle(forWritingTo: logURL) {
                _ = try? h.seekToEnd()
                stderrHandle = h
            }
            // Newline-framed buffering: pipe chunks are NOT lines; the READY
            // JSON must survive arbitrary chunk boundaries.
            stdoutBuffer = Data()
            try p.run(
                executableURL: binary,
                arguments: ["--data-dir", dataDir.path],
                standardError: stderrHandle ?? FileHandle.nullDevice,
                onStdout: { [weak self] data in
                    self?.queue.async {
                        self?.handleStdoutChunk(
                            data,
                            processID: processID,
                            generation: generation
                        )
                    }
                },
                onTermination: { [weak self] code in
                    self?.queue.async {
                        self?.handleTermination(
                            processID: processID,
                            generation: generation,
                            code: code
                        )
                    }
                }
            )
            guard desiredRunning, lifecycleGeneration == generation,
                  process == nil else {
                p.stopReading()
                if p.isRunning { p.terminate() }
                return
            }
            process = p
            armHandshakeTimeout(processID: processID, generation: generation)
        } catch {
            if desiredRunning, lifecycleGeneration == generation {
                try? stderrHandle?.close()
                stderrHandle = nil
                setPhase(.failed(error.localizedDescription))
            }
        }
    }

    private func dataDirEnsure() throws -> URL {
        let dir = try resolvedDataDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func resolvedDataDir() throws -> URL {
        if let dataDirectoryAction { return try dataDirectoryAction() }
        return dataDir()
    }

    private func armHandshakeTimeout(processID: ObjectIdentifier, generation: UInt64) {
        // Generous: schema migrations run before READY on first launch after
        // an upgrade and can take tens of seconds on large histories.
        scheduleLifecycleAction(queue, 90) { [weak self] in
            guard let self,
                  self.owns(processID: processID, generation: generation),
                  case .starting = self.state else { return }
            self.terminateProcess()
            self.setPhase(.failed(CoreError.handshakeTimeout.localizedDescription))
        }
    }

    private func handleStdoutChunk(
        _ data: Data,
        processID: ObjectIdentifier,
        generation: UInt64
    ) {
        guard owns(processID: processID, generation: generation) else { return }
        stdoutBuffer.append(data)
        // Extract every complete newline-terminated line; keep the remainder.
        while let nl = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<nl]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard let line = String(data: Data(lineData), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty
            else { continue }
            handleLine(line, processID: processID, generation: generation)
        }
    }

    private func handleLine(
        _ line: String,
        processID: ObjectIdentifier,
        generation: UInt64
    ) {
        guard owns(processID: processID, generation: generation),
              case .starting = state,
              line.contains("\"event\":\"ready\""),
              let hs = try? JSONDecoder().decode(CoreHandshake.self, from: Data(line.utf8))
        else { return }
        DispatchQueue.main.async { self.handshake = hs } // @Published: main only
        process?.stopReading()
        restartAttempts = 0
        setPhase(.running(version: hs.version))
        armStableReset(processID: processID, generation: generation)
    }

    /// Backoff reset after 5 stable minutes. GCD, not Timer: the queue's
    /// thread has no run loop, so a scheduledTimer there never fired.
    private func armStableReset(processID: ObjectIdentifier, generation: UInt64) {
        scheduleLifecycleAction(queue, 300) { [weak self] in
            guard let self,
                  self.owns(processID: processID, generation: generation) else { return }
            self.restartAttempts = 0
        }
    }

    private func handleTermination(
        processID: ObjectIdentifier,
        generation: UInt64,
        code: Int32
    ) {
        guard owns(processID: processID, generation: generation),
              let currentProcess = process else { return }
        currentProcess.stopReading()
        process = nil
        try? stderrHandle?.close()
        stderrHandle = nil
        applySleepSignal(.termination)
        DispatchQueue.main.async { self.handshake = nil }

        guard code != 0 else {
            desiredRunning = false
            lifecycleGeneration &+= 1
            pendingRestartOwner = nil
            setPhase(.idle)
            return
        }
        pendingRestartOwner = processID
        if code == 2 {
            // A previous core holds the lock (orphan) — or the Go runtime
            // exited 2 on a panic; the two are indistinguishable here.
            // Count it like a crash: otherwise a panic-loop respawns every
            // ~4 s forever with no cap and no user-visible failure.
            restartAttempts += 1
            if restartAttempts > 8 {
                desiredRunning = false
                lifecycleGeneration &+= 1
                pendingRestartOwner = nil
                setPhase(.failed("core keeps exiting with code 2 — check core.log in the data directory"))
                return
            }
            // The holder shares our exact data dir — safe to reclaim.
            recoverFromOrphan()
            return
        }
        scheduleRestart(processID: processID, generation: generation)
    }

    /// Kills any whatsapp-core bound to OUR data dir (they are by definition
    /// orphans — the app is single-instance), then respawns.
    private func recoverFromOrphan() {
        guard orphanReclaimOperation == nil else { return }
        setPhase(.restarting(afterSeconds: 2))
        let operation = orphanReclaimFactoryAction()
        let operationID = ObjectIdentifier(operation)
        orphanReclaimGeneration &+= 1
        let reclaimGeneration = orphanReclaimGeneration
        orphanReclaimOperation = operation
        let dir = (try? resolvedDataDir()) ?? dataDir()
        do {
            try operation.start(dataDirectory: dir) { [weak self] in
                self?.queue.async {
                    self?.finishOrphanReclaim(
                        operationID: operationID,
                        generation: reclaimGeneration
                    )
                }
            }
        } catch {
            finishOrphanReclaim(
                operationID: operationID,
                generation: reclaimGeneration
            )
        }
    }

    private func finishOrphanReclaim(
        operationID: ObjectIdentifier,
        generation: UInt64
    ) {
        guard orphanReclaimGeneration == generation,
              let current = orphanReclaimOperation,
              ObjectIdentifier(current) == operationID else { return }
        orphanReclaimOperation = nil
        pendingRestartOwner = nil
        armLockReleaseBarrier()
    }

    private func armLockReleaseBarrier() {
        guard activeLockReleaseBarrier == nil else { return }
        lockReleaseBarrierGeneration &+= 1
        let barrierGeneration = lockReleaseBarrierGeneration
        activeLockReleaseBarrier = barrierGeneration
        setPhase(desiredRunning ? .restarting(afterSeconds: 2) : .idle)
        scheduleLifecycleAction(queue, 2) { [weak self] in
            self?.finishLockReleaseBarrier(generation: barrierGeneration)
        }
    }

    private func finishLockReleaseBarrier(generation: UInt64) {
        guard activeLockReleaseBarrier == generation else { return }
        activeLockReleaseBarrier = nil
        guard desiredRunning else {
            setPhase(.idle)
            return
        }
        guard process == nil,
              orphanReclaimOperation == nil else { return }
        // `spawn` advances from the lifecycle generation current when the
        // grace period ends, never the generation of the terminated child.
        spawn(restart: true)
    }

    private func scheduleRestart(processID: ObjectIdentifier, generation: UInt64) {
        let delay = min(1 << min(restartAttempts, 6), Self.maxBackoffSeconds)
        restartAttempts += 1
        setPhase(.restarting(afterSeconds: delay))
        scheduleLifecycleAction(queue, Double(delay)) { [weak self] in
            guard let self,
                  self.canRestart(processID: processID, generation: generation) else { return }
            self.spawn(restart: true)
        }
    }

    private func terminateProcess() {
        lifecycleGeneration &+= 1
        let terminationGeneration = lifecycleGeneration
        pendingRestartOwner = nil
        applySleepSignal(.termination)
        process?.stopReading()
        try? stderrHandle?.close()
        stderrHandle = nil
        DispatchQueue.main.async { self.handshake = nil }
        guard let p = process, p.isRunning else {
            process = nil
            return
        }
        let processID = ObjectIdentifier(p)
        terminatingProcessGenerations[processID] = terminationGeneration
        p.terminate() // SIGTERM; core exits cleanly
        // Escalation closures capture THIS process: reading self.process
        // again could hit a freshly respawned core (restartNow path).
        scheduleLifecycleAction(queue, 2) { [weak self] in
            guard let self,
                  self.terminatingProcessGenerations[processID] == terminationGeneration
            else { return }
            if p.isRunning { p.interrupt() } // SIGINT
            if !p.isRunning {
                self.terminatingProcessGenerations.removeValue(forKey: processID)
            }
        }
        scheduleLifecycleAction(queue, 4) { [weak self] in
            guard let self,
                  self.terminatingProcessGenerations[processID] == terminationGeneration
            else { return }
            defer { self.terminatingProcessGenerations.removeValue(forKey: processID) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        process = nil
    }

    private func owns(processID: ObjectIdentifier, generation: UInt64) -> Bool {
        guard desiredRunning,
              lifecycleGeneration == generation,
              let currentProcess = process else { return false }
        return ObjectIdentifier(currentProcess) == processID
    }

    private func canRestart(processID: ObjectIdentifier, generation: UInt64) -> Bool {
        guard desiredRunning,
              lifecycleGeneration == generation,
              pendingRestartOwner == processID,
              process == nil else { return false }
        if case .restarting = state { return true }
        return false
    }

    // Keep the Mac awake only while history sync is active. The policy,
    // generation, and IOKit assertion id are all confined to `queue`.
    private var sleepPolicy = SleepPreventionPolicy()
    private var sleepCapGeneration: UInt64 = 0

    func handleSleepSignal(_ signal: SleepPreventionSignal) {
        if DispatchQueue.getSpecific(key: Self.queueKey) == true {
            applySleepSignal(signal)
        } else {
            queue.async { [weak self] in self?.applySleepSignal(signal) }
        }
    }

    private func applySleepSignal(_ signal: SleepPreventionSignal) {
        let wasActive = sleepPolicy.active
        let isActive = sleepPolicy.apply(signal)
        if isActive && !wasActive {
            sleepCapGeneration &+= 1
            let generation = sleepCapGeneration
            holdPowerAssertion()
            scheduleSleepCapAction(queue, 600) { [weak self] in
                guard let self, self.sleepCapGeneration == generation else { return }
                self.applySleepSignal(.capExpired)
            }
        } else if !isActive {
            sleepCapGeneration &+= 1
            releasePowerAssertion()
        }
    }

    private func holdPowerAssertion() {
        guard powerAssertion == 0 else { return }
        powerAssertion = acquirePowerAssertionAction()
    }

    private func releasePowerAssertion() {
        guard powerAssertion != 0 else { return }
        let id = powerAssertion
        powerAssertion = 0
        releasePowerAssertionAction(id)
    }
}
