import Foundation
import os

/// Low-overhead lifecycle for the UI intervals consumed by Instruments.
/// The observer receives metric names, opaque interval IDs, and outcomes only;
/// message text, account identifiers, JIDs, and bearer tokens never cross the
/// instrumentation boundary.
@MainActor
final class PerformanceSignpostLifecycle {
    struct Limits {
        var chatSwitches = 16
        var pendingRows = 256
        var activeIntervals = 320
    }

    enum Metric: Equatable {
        case appStateLaunch
        case loadedChatListRunLoopProxy
        case chatSwitch
        case incomingToVisible
        case optimisticToVisible
        case messagePage
        case syncRefresh

        fileprivate var name: StaticString {
            switch self {
            case .appStateLaunch: "AppState Init to Loaded Chat-List Run-Loop Proxy"
            case .loadedChatListRunLoopProxy: "Loaded Chat-List Run-Loop Proxy"
            case .chatSwitch: "Chat Switch to Selected Page View-Update Proxy"
            case .incomingToVisible: "Incoming Insert to Row onAppear Proxy"
            case .optimisticToVisible: "Send Insert to Row onAppear Proxy"
            case .messagePage: "Message Page Fetch Decode Merge"
            case .syncRefresh: "Sync Refresh"
            }
        }
    }

    enum Outcome: Equatable {
        case completed
        case cancelled
        case failed
    }

    enum Phase: Equatable {
        case began
        case ended(Outcome)
        case event
    }

    struct Event: Equatable {
        let metric: Metric
        let phase: Phase
        let intervalID: UInt64?
    }

    struct Operation: Equatable {
        fileprivate let id: UInt64
        fileprivate let metric: Metric
    }

    private struct ActiveInterval {
        let operation: Operation
        let state: OSSignpostIntervalState
    }

    private struct PendingRow {
        let operation: Operation
        let chatKey: String?
    }

    private let signposter: OSSignposter
    private let limits: Limits
    private let observer: ((Event) -> Void)?
    private var nextIntervalID: UInt64 = 0
    private var activeIntervals: [UInt64: ActiveInterval] = [:]
    private var launch: Operation?
    private var chatSwitches: [String: Operation] = [:]
    private var pendingRows: [Int64: PendingRow] = [:]
    private var emittedLoadedChatListProxy = false

    init(
        limits: Limits = Limits(),
        observer: ((Event) -> Void)? = nil,
        subsystem: String = Bundle.main.bundleIdentifier ?? "dev.whatsappwork.WhatsAppWork"
    ) {
        self.limits = Limits(
            chatSwitches: max(0, limits.chatSwitches),
            pendingRows: max(0, limits.pendingRows),
            activeIntervals: max(0, limits.activeIntervals)
        )
        self.observer = observer
        signposter = OSSignposter(subsystem: subsystem, category: "UI Performance")
    }

    func beginLaunch() {
        guard launch == nil else { return }
        launch = begin(.appStateLaunch)
    }

    func endLaunchAtLoadedChatListRunLoopProxy() {
        if let launch {
            finish(launch, outcome: .completed)
            self.launch = nil
        }
        guard !emittedLoadedChatListProxy else { return }
        emittedLoadedChatListProxy = true
        signposter.emitEvent(Metric.loadedChatListRunLoopProxy.name)
        observer?(Event(metric: .loadedChatListRunLoopProxy, phase: .event, intervalID: nil))
    }

    @discardableResult
    func beginChatSwitch(chatKey: String) -> Operation? {
        if let previous = chatSwitches.removeValue(forKey: chatKey) {
            finish(previous, outcome: .cancelled)
        }
        guard chatSwitches.count < limits.chatSwitches,
              let operation = begin(.chatSwitch) else { return nil }
        chatSwitches[chatKey] = operation
        return operation
    }

    func endChatSwitch(chatKey: String, outcome: Outcome) {
        guard let operation = chatSwitches.removeValue(forKey: chatKey) else { return }
        finish(operation, outcome: outcome)
    }

    func endChatSwitch(chatKey: String, operation: Operation?, outcome: Outcome) {
        guard let operation, chatSwitches[chatKey] == operation else { return }
        chatSwitches.removeValue(forKey: chatKey)
        finish(operation, outcome: outcome)
    }

    func cancelChatSwitch(chatKey: String) {
        endChatSwitch(chatKey: chatKey, outcome: .cancelled)
    }

    func beginIncoming(rowID: Int64, chatKey: String? = nil) {
        beginRow(.incomingToVisible, rowID: rowID, chatKey: chatKey)
    }

    func beginOptimistic(rowID: Int64, chatKey: String? = nil) {
        beginRow(.optimisticToVisible, rowID: rowID, chatKey: chatKey)
    }

    func endVisibleRow(rowID: Int64) {
        guard let pending = pendingRows.removeValue(forKey: rowID) else { return }
        finish(pending.operation, outcome: .completed)
    }

    func cancelVisibleRow(rowID: Int64) {
        guard let pending = pendingRows.removeValue(forKey: rowID) else { return }
        finish(pending.operation, outcome: .cancelled)
    }

    func cancelPendingRows(chatKey: String) {
        let rowIDs = pendingRows.compactMap { rowID, pending in
            pending.chatKey == chatKey ? rowID : nil
        }
        for rowID in rowIDs { cancelVisibleRow(rowID: rowID) }
    }

    func beginMessagePage() -> Operation? {
        begin(.messagePage)
    }

    func endMessagePage(_ operation: Operation?, outcome: Outcome) {
        finish(operation, outcome: outcome)
    }

    func beginSyncRefresh() -> Operation? {
        begin(.syncRefresh)
    }

    func endSyncRefresh(_ operation: Operation?, outcome: Outcome) {
        finish(operation, outcome: outcome)
    }

    func clearPending() {
        let operations = activeIntervals.values.map(\.operation)
        launch = nil
        chatSwitches.removeAll(keepingCapacity: false)
        pendingRows.removeAll(keepingCapacity: false)
        for operation in operations { finish(operation, outcome: .cancelled) }
    }

    private func beginRow(_ metric: Metric, rowID: Int64, chatKey: String?) {
        if let previous = pendingRows.removeValue(forKey: rowID) {
            finish(previous.operation, outcome: .cancelled)
        }
        guard pendingRows.count < limits.pendingRows,
              let operation = begin(metric) else { return }
        pendingRows[rowID] = PendingRow(operation: operation, chatKey: chatKey)
    }

    private func begin(_ metric: Metric) -> Operation? {
        guard activeIntervals.count < limits.activeIntervals else { return nil }
        nextIntervalID &+= 1
        if nextIntervalID == 0 { nextIntervalID &+= 1 }
        let operation = Operation(id: nextIntervalID, metric: metric)
        let state = signposter.beginInterval(metric.name, id: signposter.makeSignpostID())
        activeIntervals[operation.id] = ActiveInterval(operation: operation, state: state)
        observer?(Event(metric: metric, phase: .began, intervalID: operation.id))
        return operation
    }

    private func finish(_ operation: Operation?, outcome: Outcome) {
        guard let operation,
              let active = activeIntervals.removeValue(forKey: operation.id),
              active.operation.metric == operation.metric else { return }
        switch outcome {
        case .completed:
            signposter.endInterval(operation.metric.name, active.state, "result=completed")
        case .cancelled:
            signposter.endInterval(operation.metric.name, active.state, "result=cancelled")
        case .failed:
            signposter.endInterval(operation.metric.name, active.state, "result=failed")
        }
        observer?(Event(metric: operation.metric, phase: .ended(outcome), intervalID: operation.id))
    }
}

/// Process-wide facade used by AppState and the SwiftUI visibility hooks.
/// All mutable state is main-actor isolated; ordinary row appearances perform
/// one bounded dictionary lookup and return immediately when uninstrumented.
@MainActor
enum PerformanceSignposts {
    static let sharedLifecycle = PerformanceSignpostLifecycle()

    static func beginLaunch() { sharedLifecycle.beginLaunch() }
    static func endLaunchAtLoadedChatListRunLoopProxy() {
        sharedLifecycle.endLaunchAtLoadedChatListRunLoopProxy()
    }
    static func beginChatSwitch(chatKey: String) -> PerformanceSignpostLifecycle.Operation? {
        sharedLifecycle.beginChatSwitch(chatKey: chatKey)
    }
    static func endChatSwitch(chatKey: String, outcome: PerformanceSignpostLifecycle.Outcome) {
        sharedLifecycle.endChatSwitch(chatKey: chatKey, outcome: outcome)
    }
    static func endChatSwitch(
        chatKey: String,
        operation: PerformanceSignpostLifecycle.Operation?,
        outcome: PerformanceSignpostLifecycle.Outcome
    ) {
        sharedLifecycle.endChatSwitch(chatKey: chatKey, operation: operation, outcome: outcome)
    }
    static func cancelChatSwitch(chatKey: String) {
        sharedLifecycle.cancelChatSwitch(chatKey: chatKey)
    }
    static func beginIncoming(rowID: Int64, chatKey: String) {
        sharedLifecycle.beginIncoming(rowID: rowID, chatKey: chatKey)
    }
    static func beginOptimistic(rowID: Int64, chatKey: String) {
        sharedLifecycle.beginOptimistic(rowID: rowID, chatKey: chatKey)
    }
    static func endVisibleRow(rowID: Int64) { sharedLifecycle.endVisibleRow(rowID: rowID) }
    static func cancelVisibleRow(rowID: Int64) {
        sharedLifecycle.cancelVisibleRow(rowID: rowID)
    }
    static func cancelPendingRows(chatKey: String) {
        sharedLifecycle.cancelPendingRows(chatKey: chatKey)
    }
    static func beginMessagePage() -> PerformanceSignpostLifecycle.Operation? {
        sharedLifecycle.beginMessagePage()
    }
    static func endMessagePage(
        _ operation: PerformanceSignpostLifecycle.Operation?,
        outcome: PerformanceSignpostLifecycle.Outcome
    ) {
        sharedLifecycle.endMessagePage(operation, outcome: outcome)
    }
    static func beginSyncRefresh() -> PerformanceSignpostLifecycle.Operation? {
        sharedLifecycle.beginSyncRefresh()
    }
    static func endSyncRefresh(
        _ operation: PerformanceSignpostLifecycle.Operation?,
        outcome: PerformanceSignpostLifecycle.Outcome
    ) {
        sharedLifecycle.endSyncRefresh(operation, outcome: outcome)
    }
    static func clearPending() { sharedLifecycle.clearPending() }
}
