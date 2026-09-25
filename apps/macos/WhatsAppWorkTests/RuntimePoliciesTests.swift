import Foundation
import XCTest
@testable import WhatsAppWork

final class RuntimePoliciesTests: XCTestCase {
    @MainActor
    func testCoordinatorExecutesEachPlanStepOnceInOrder() async {
        let client = RuntimeRefreshClient()
        let coordinator = ConnectionRefreshCoordinator<RuntimeRefreshClient>(sleep: { _ in })
        coordinator.install(client)
        var calls: [ConnectionRefreshStep] = []

        let task = coordinator.start(.reconnect, client: client) { step, _ in
            calls.append(step)
            return .success
        }
        await task.value

        XCTAssertEqual(calls, [.events, .session, .chats, .openTranscript])
        XCTAssertFalse(coordinator.isRefreshing)
    }

    @MainActor
    func testCoordinatorCancelsBlockedGenerationBeforeAnyLaterStep() async {
        let first = RuntimeRefreshClient()
        let replacement = RuntimeRefreshClient()
        let gate = RuntimeStepGate()
        let coordinator = ConnectionRefreshCoordinator<RuntimeRefreshClient>(sleep: { _ in })
        coordinator.install(first)
        var firstCalls: [ConnectionRefreshStep] = []
        let firstTask = coordinator.start(.initial, client: first) { step, _ in
            firstCalls.append(step)
            await gate.block(step)
            return .success
        }
        await gate.waitUntilBlocked(on: .session)

        coordinator.install(replacement)
        await gate.release(.session)
        await firstTask.value

        XCTAssertEqual(firstCalls, [.session])
        XCTAssertFalse(coordinator.isCurrent(first))
        XCTAssertTrue(coordinator.isCurrent(replacement))
    }

    @MainActor
    func testCancellationAfterEachReconnectAwaitPreventsLaterRequests() async {
        let plan = ConnectionRefreshPlan.steps(for: .reconnect)
        for blockedStep in plan {
            let client = RuntimeRefreshClient()
            let gate = RuntimeStepGate()
            let coordinator = ConnectionRefreshCoordinator<RuntimeRefreshClient>(sleep: { _ in })
            coordinator.install(client)
            var calls: [ConnectionRefreshStep] = []
            let task = coordinator.start(.reconnect, client: client) { step, _ in
                calls.append(step)
                if step == blockedStep { await gate.block(step) }
                return .success
            }
            await gate.waitUntilBlocked(on: blockedStep)

            coordinator.cancel()
            await gate.release(blockedStep)
            await task.value

            let last = plan.firstIndex(of: blockedStep)!
            XCTAssertEqual(calls, Array(plan[...last]), "cancelled after \(blockedStep)")
        }
    }

    @MainActor
    func testImmediateReplacementRefreshPreventsStalePlanFromContinuing() async {
        let client = RuntimeRefreshClient()
        let gate = RuntimeStepGate()
        let coordinator = ConnectionRefreshCoordinator<RuntimeRefreshClient>(sleep: { _ in })
        coordinator.install(client)
        var calls: [String] = []
        let firstTask = coordinator.start(.initial, client: client) { step, _ in
            calls.append("first:\(step)")
            if step == .events { await gate.block(step) }
            return .success
        }
        await gate.waitUntilBlocked(on: .events)

        let replacementTask = coordinator.start(.reconnect, client: client) { step, _ in
            calls.append("replacement:\(step)")
            return .success
        }
        await gate.release(.events)
        await firstTask.value
        await replacementTask.value

        XCTAssertEqual(calls, ["first:session", "first:events", "replacement:events", "replacement:session", "replacement:chats", "replacement:openTranscript"])
    }

    @MainActor
    func testContactsStartOnceWhenCurrentClientFirstConnectsAndUseOnlyBoundedDelays() async {
        let client = RuntimeRefreshClient()
        let clock = RuntimeClock()
        let coordinator = ConnectionRefreshCoordinator<RuntimeRefreshClient>(sleep: { delay in
            await clock.sleep(for: delay)
        })
        coordinator.install(client)
        var loads = 0

        coordinator.activateContactsIfNeeded(for: client, isConnected: true) { _ in loads += 1 }
        coordinator.activateContactsIfNeeded(for: client, isConnected: true) { _ in loads += 1 }
        await clock.waitUntilSleeping(for: 45)
        await clock.waitUntilSleeping(for: 180)
        XCTAssertEqual(loads, 1)

        await clock.advance(45)
        XCTAssertEqual(loads, 2)
        await clock.advance(180)
        XCTAssertEqual(loads, 3)
    }

    @MainActor
    func testContactTasksCancelForSessionClearRestartAndClientReplacement() async {
        for action in ["clear", "restart", "replace"] {
            let client = RuntimeRefreshClient()
            let replacement = RuntimeRefreshClient()
            let clock = RuntimeClock()
            let coordinator = ConnectionRefreshCoordinator<RuntimeRefreshClient>(sleep: { delay in
                await clock.sleep(for: delay)
            })
            coordinator.install(client)
            var loads = 0
            coordinator.activateContactsIfNeeded(for: client, isConnected: true) { _ in loads += 1 }
            await clock.waitUntilSleeping(for: 45)

            switch action {
            case "clear", "restart": coordinator.cancel()
            default: coordinator.install(replacement)
            }
            await clock.advance(45)
            await clock.advance(180)
            XCTAssertEqual(loads, 1, "\(action) must cancel follow-ups")
        }
    }

    @MainActor
    func testContactsDoNotStartUntilConnectedForCurrentClient() async {
        let client = RuntimeRefreshClient()
        let clock = RuntimeClock()
        let coordinator = ConnectionRefreshCoordinator<RuntimeRefreshClient>(sleep: { delay in
            await clock.sleep(for: delay)
        })
        coordinator.install(client)
        var loads = 0

        coordinator.activateContactsIfNeeded(for: client, isConnected: false) { _ in loads += 1 }
        await Task.yield()
        XCTAssertEqual(loads, 0)

        coordinator.activateContactsIfNeeded(for: client, isConnected: true) { _ in loads += 1 }
        await clock.waitUntilSleeping(for: 45)
        await clock.waitUntilSleeping(for: 180)
        XCTAssertEqual(loads, 1)
    }

    @MainActor
    func testExternalRefreshIsCoalescedWhilePlanOwnsChatFetch() async {
        let client = RuntimeRefreshClient()
        let gate = RuntimeStepGate()
        let coordinator = ConnectionRefreshCoordinator<RuntimeRefreshClient>(sleep: { _ in })
        coordinator.install(client)
        let task = coordinator.start(.initial, client: client) { step, _ in
            if step == .session { await gate.block(step) }
            return .success
        }
        await gate.waitUntilBlocked(on: .session)
        XCTAssertTrue(coordinator.coalescesExternalChatRefresh)
        await gate.release(.session)
        await task.value
        XCTAssertFalse(coordinator.coalescesExternalChatRefresh)
    }

    @MainActor
    func testSessionClearCancelsWorkButRetainsClientForRelink() {
        let client = RuntimeRefreshClient()
        let coordinator = ConnectionRefreshCoordinator<RuntimeRefreshClient>(sleep: { _ in })
        coordinator.install(client)

        coordinator.cancelWorkKeepingClient()

        XCTAssertTrue(coordinator.isCurrent(client))
    }

    @MainActor
    func testReconnectBackoffCoalescesExternalChatRefresh() {
        let coordinator = ConnectionRefreshCoordinator<RuntimeRefreshClient>(sleep: { _ in })

        let epoch = coordinator.beginReconnectBackoff()
        XCTAssertTrue(coordinator.coalescesExternalChatRefresh)
        coordinator.endReconnectBackoff(epoch)
        XCTAssertTrue(coordinator.coalescesExternalChatRefresh, "the refresh epoch must outlive backoff")
        coordinator.cancel()
        XCTAssertFalse(coordinator.coalescesExternalChatRefresh)
    }

    func testConnectionRefreshPlansContainOneChatFetch() {
        // .initial includes openTranscript: a sidecar crash-restart lands on
        // a core that already ingested catch-up before our WS resubscribed.
        XCTAssertEqual(ConnectionRefreshPlan.steps(for: .initial),
                       [.session, .events, .chats, .openTranscript])
        XCTAssertEqual(ConnectionRefreshPlan.steps(for: .reconnect),
                       [.events, .session, .chats, .openTranscript])
        for reason in [ConnectionRefreshReason.initial, .reconnect] {
            XCTAssertEqual(ConnectionRefreshPlan.steps(for: reason).filter { $0 == .chats }.count, 1)
        }
    }

    func testContactFollowUpsAreBoundedAndNonRepeating() {
        XCTAssertEqual(ContactFollowUpPolicy.delays, [45, 180])
    }

    func testSleepPreventionOnlyTracksActiveSyncAndCap() {
        var policy = SleepPreventionPolicy()

        XCTAssertFalse(policy.apply(.spawn))
        XCTAssertFalse(policy.apply(.qr))
        XCTAssertTrue(policy.apply(.syncProgress(stage: "history")))
        XCTAssertTrue(policy.apply(.syncProgress(stage: "contacts")))
        XCTAssertFalse(policy.apply(.syncProgress(stage: "done")))
        XCTAssertTrue(policy.apply(.syncProgress(stage: "history")))
        XCTAssertFalse(policy.apply(.capExpired))
        XCTAssertFalse(policy.apply(.termination))
        XCTAssertFalse(policy.apply(.logout))
    }

    func testSleepPreventionCapCannotBeRearmedUntilSyncResets() {
        var policy = SleepPreventionPolicy()

        XCTAssertTrue(policy.apply(.syncProgress(stage: "history")))
        XCTAssertFalse(policy.apply(.capExpired))
        XCTAssertFalse(policy.apply(.syncProgress(stage: "contacts")))
        XCTAssertFalse(policy.apply(.syncProgress(stage: "history")))

        XCTAssertFalse(policy.apply(.syncProgress(stage: "done")))
        XCTAssertTrue(policy.apply(.syncProgress(stage: "history")))
    }

    func testSleepPreventionTerminalSignalsAreIdempotentAndResetTheCap() {
        for signal in [
            SleepPreventionSignal.spawn,
            .qr,
            .termination,
            .logout,
            .syncProgress(stage: "done"),
        ] {
            var policy = SleepPreventionPolicy()

            XCTAssertFalse(policy.apply(signal))
            XCTAssertFalse(policy.apply(signal))
            XCTAssertTrue(policy.apply(.syncProgress(stage: "history")))
            XCTAssertFalse(policy.apply(signal))
            XCTAssertFalse(policy.apply(signal))
        }
    }

    func testSidecarSleepBoundaryAcquiresOnceWithoutRearmingAndReleasesOnce() async {
        let probe = SleepAssertionProbe()
        let sidecar = makeSleepTestSidecar(probe)
        let acquired = expectation(description: "assertion acquired")
        let capScheduled = expectation(description: "hard cap scheduled")
        let released = expectation(description: "assertion released")
        probe.expectAcquire(1, acquired)
        probe.expectSchedule(1, capScheduled)
        probe.expectRelease(1, released)

        sidecar.handleSleepSignal(.spawn)
        sidecar.handleSleepSignal(.qr)
        sidecar.handleSleepSignal(.logout)
        sidecar.handleSleepSignal(.syncProgress(stage: "history"))
        await fulfillment(of: [acquired, capScheduled], timeout: 2)
        sidecar.handleSleepSignal(.syncProgress(stage: "contacts"))
        sidecar.handleSleepSignal(.syncProgress(stage: "history"))
        sidecar.handleSleepSignal(.syncProgress(stage: "done"))
        await fulfillment(of: [released], timeout: 2)

        sidecar.handleSleepSignal(.syncProgress(stage: "done"))
        sidecar.handleSleepSignal(.logout)
        sidecar.stopBlocking()
        XCTAssertEqual(probe.acquireCount, 1)
        XCTAssertEqual(probe.releaseCount, 1)
        XCTAssertEqual(probe.scheduledDelays, [600])
    }

    func testSidecarSleepBoundaryIgnoresStaleCapGeneration() async {
        let probe = SleepAssertionProbe()
        let sidecar = makeSleepTestSidecar(probe)
        let firstAcquire = expectation(description: "first assertion acquired")
        let firstSchedule = expectation(description: "first cap scheduled")
        let firstRelease = expectation(description: "first assertion released")
        probe.expectAcquire(1, firstAcquire)
        probe.expectSchedule(1, firstSchedule)
        probe.expectRelease(1, firstRelease)

        sidecar.handleSleepSignal(.syncProgress(stage: "history"))
        await fulfillment(of: [firstAcquire, firstSchedule], timeout: 2)
        sidecar.handleSleepSignal(.syncProgress(stage: "done"))
        await fulfillment(of: [firstRelease], timeout: 2)

        let secondAcquire = expectation(description: "second assertion acquired")
        let secondSchedule = expectation(description: "second cap scheduled")
        probe.expectAcquire(2, secondAcquire)
        probe.expectSchedule(2, secondSchedule)
        sidecar.handleSleepSignal(.syncProgress(stage: "history"))
        await fulfillment(of: [secondAcquire, secondSchedule], timeout: 2)

        probe.fireCap(at: 0)
        XCTAssertEqual(probe.releaseCount, 1, "the first sync cap cannot release a later assertion")

        probe.fireCap(at: 1)
        XCTAssertEqual(probe.releaseCount, 2)
        sidecar.handleSleepSignal(.syncProgress(stage: "contacts"))
        sidecar.stopBlocking()
        XCTAssertEqual(probe.acquireCount, 2, "post-cap progress cannot re-arm the same sync")
        XCTAssertEqual(probe.releaseCount, 2)
    }

    func testSidecarSleepBoundaryResetsAcrossRestartLogoutAndTermination() async {
        let probe = SleepAssertionProbe()
        let sidecar = makeSleepTestSidecar(probe)

        for (index, terminal) in [
            SleepPreventionSignal.termination,
            .spawn,
            .logout,
        ].enumerated() {
            let acquired = expectation(description: "assertion acquired for cycle \(index)")
            let released = expectation(description: "assertion released for cycle \(index)")
            probe.expectAcquire(index + 1, acquired)
            probe.expectRelease(index + 1, released)

            sidecar.handleSleepSignal(.syncProgress(stage: "history"))
            await fulfillment(of: [acquired], timeout: 2)
            sidecar.handleSleepSignal(terminal)
            await fulfillment(of: [released], timeout: 2)
            sidecar.handleSleepSignal(terminal)
        }

        let acquired = expectation(description: "assertion acquired before app termination")
        let released = expectation(description: "blocking stop releases assertion")
        probe.expectAcquire(4, acquired)
        probe.expectRelease(4, released)
        sidecar.handleSleepSignal(.syncProgress(stage: "history"))
        await fulfillment(of: [acquired], timeout: 2)
        sidecar.stopBlocking()
        await fulfillment(of: [released], timeout: 2)
        sidecar.stopBlocking()
        XCTAssertEqual(probe.acquireCount, 4)
        XCTAssertEqual(probe.releaseCount, 4)
    }

    func testSidecarLifecycleRejectsHandshakeTimeoutFromReplacedProcess() async {
        let assertions = SleepAssertionProbe()
        let lifecycle = SidecarLifecycleProbe()
        let sidecar = makeLifecycleTestSidecar(lifecycle, assertions: assertions)
        let firstProcess = expectation(description: "first process spawned")
        let firstTimeout = expectation(description: "first handshake timeout armed")
        lifecycle.expectProcess(1, firstProcess)
        lifecycle.expectSchedule(after: 90, count: 1, firstTimeout)

        sidecar.start()
        await fulfillment(of: [firstProcess, firstTimeout], timeout: 2)
        let processA = lifecycle.process(at: 0)
        let firstAcquire = expectation(description: "first process sync acquired")
        assertions.expectAcquire(1, firstAcquire)
        sidecar.handleSleepSignal(.syncProgress(stage: "history"))
        await fulfillment(of: [firstAcquire], timeout: 2)

        let secondProcess = expectation(description: "replacement process spawned")
        let secondTimeout = expectation(description: "replacement handshake timeout armed")
        let firstRelease = expectation(description: "restart releases first assertion")
        lifecycle.expectProcess(2, secondProcess)
        lifecycle.expectSchedule(after: 90, count: 2, secondTimeout)
        assertions.expectRelease(1, firstRelease)
        sidecar.restartNow()
        await fulfillment(of: [secondProcess, secondTimeout, firstRelease], timeout: 2)
        let processB = lifecycle.process(at: 1)
        let secondAcquire = expectation(description: "replacement sync acquired")
        assertions.expectAcquire(2, secondAcquire)
        sidecar.handleSleepSignal(.syncProgress(stage: "history"))
        await fulfillment(of: [secondAcquire], timeout: 2)

        lifecycle.fire(after: 90, occurrence: 0)

        XCTAssertEqual(processA.terminateCount, 1)
        XCTAssertEqual(processB.terminateCount, 0, "process A's timeout must not terminate B")
        XCTAssertEqual(assertions.releaseCount, 1, "process A's timeout must not release B's assertion")
        sidecar.stopBlocking()
        XCTAssertEqual(processB.terminateCount, 1)
        XCTAssertEqual(assertions.releaseCount, 2)
    }

    func testSidecarLifecycleRejectsOldStdoutAndTerminationBeforeCurrentTimeout() async {
        let assertions = SleepAssertionProbe()
        let lifecycle = SidecarLifecycleProbe()
        let sidecar = makeLifecycleTestSidecar(lifecycle, assertions: assertions)
        let firstProcess = expectation(description: "first process spawned")
        let firstTimeout = expectation(description: "first timeout armed")
        lifecycle.expectProcess(1, firstProcess)
        lifecycle.expectSchedule(after: 90, count: 1, firstTimeout)
        sidecar.start()
        await fulfillment(of: [firstProcess, firstTimeout], timeout: 2)
        let processA = lifecycle.process(at: 0)

        let firstAcquire = expectation(description: "first sync acquired")
        assertions.expectAcquire(1, firstAcquire)
        sidecar.handleSleepSignal(.syncProgress(stage: "history"))
        await fulfillment(of: [firstAcquire], timeout: 2)

        let secondProcess = expectation(description: "second process spawned")
        let secondTimeout = expectation(description: "second timeout armed")
        let firstRelease = expectation(description: "first sync released")
        lifecycle.expectProcess(2, secondProcess)
        lifecycle.expectSchedule(after: 90, count: 2, secondTimeout)
        assertions.expectRelease(1, firstRelease)
        sidecar.restartNow()
        await fulfillment(of: [secondProcess, secondTimeout, firstRelease], timeout: 2)
        let processB = lifecycle.process(at: 1)

        let secondAcquire = expectation(description: "second sync acquired")
        assertions.expectAcquire(2, secondAcquire)
        sidecar.handleSleepSignal(.syncProgress(stage: "history"))
        await fulfillment(of: [secondAcquire], timeout: 2)

        processA.emitQueuedStdout(#"{"event":"ready","port":1111,"token":"old","pid":1,"version":"old"}"# + "\n")
        processA.emitTermination(code: 1)
        lifecycle.syncManagerQueue()
        XCTAssertEqual(assertions.releaseCount, 1, "old termination cannot release B")

        lifecycle.fire(after: 90, occurrence: 1)

        XCTAssertEqual(processB.terminateCount, 1, "old stdout cannot make B appear ready")
        XCTAssertEqual(assertions.releaseCount, 2, "B timeout releases B's assertion exactly once")
        sidecar.stopBlocking()
        XCTAssertEqual(assertions.releaseCount, 2)
    }

    func testSidecarLifecycleRejectsStaleCrashRestartAfterManualRestartAndStop() async {
        for manuallyRestart in [true, false] {
            let assertions = SleepAssertionProbe()
            let lifecycle = SidecarLifecycleProbe()
            let sidecar = makeLifecycleTestSidecar(lifecycle, assertions: assertions)
            let firstProcess = expectation(description: "first process spawned")
            let firstTimeout = expectation(description: "first timeout armed")
            lifecycle.expectProcess(1, firstProcess)
            lifecycle.expectSchedule(after: 90, count: 1, firstTimeout)
            sidecar.start()
            await fulfillment(of: [firstProcess, firstTimeout], timeout: 2)
            let processA = lifecycle.process(at: 0)

            let acquired = expectation(description: "first sync acquired")
            let released = expectation(description: "crash releases first sync")
            let crashRestart = expectation(description: "crash restart scheduled")
            assertions.expectAcquire(1, acquired)
            sidecar.handleSleepSignal(.syncProgress(stage: "history"))
            await fulfillment(of: [acquired], timeout: 2)
            assertions.expectRelease(1, released)
            lifecycle.expectSchedule(after: 1, count: 1, crashRestart)
            processA.emitTermination(code: 1)
            await fulfillment(of: [released, crashRestart], timeout: 2)

            if manuallyRestart {
                let secondProcess = expectation(description: "manual replacement spawned")
                lifecycle.expectProcess(2, secondProcess)
                sidecar.restartNow()
                await fulfillment(of: [secondProcess], timeout: 2)
                let processB = lifecycle.process(at: 1)
                let secondAcquire = expectation(description: "replacement sync acquired")
                assertions.expectAcquire(2, secondAcquire)
                sidecar.handleSleepSignal(.syncProgress(stage: "history"))
                await fulfillment(of: [secondAcquire], timeout: 2)

                lifecycle.fire(after: 1, occurrence: 0)
                XCTAssertEqual(lifecycle.processCount, 2, "stale backoff cannot spawn over B")
                XCTAssertEqual(assertions.releaseCount, 1, "stale backoff cannot reset B sleep state")
                sidecar.stopBlocking()
                XCTAssertEqual(processB.terminateCount, 1, "B must remain tracked until stop")
                XCTAssertEqual(assertions.releaseCount, 2)
            } else {
                sidecar.stop()
                lifecycle.syncManagerQueue()
                lifecycle.fire(after: 1, occurrence: 0)
                XCTAssertEqual(lifecycle.processCount, 1, "stale backoff cannot resurrect after stop")
                XCTAssertEqual(assertions.acquireCount, 1)
                XCTAssertEqual(assertions.releaseCount, 1)
                sidecar.stopBlocking()
            }
        }
    }

    func testSidecarLifecycleDefersManualRestartThroughReclaimAndReleaseBarrier() async {
        let assertions = SleepAssertionProbe()
        let lifecycle = SidecarLifecycleProbe()
        let sidecar = makeLifecycleTestSidecar(lifecycle, assertions: assertions)
        let firstProcess = expectation(description: "first process spawned")
        let firstTimeout = expectation(description: "first timeout armed")
        lifecycle.expectProcess(1, firstProcess)
        lifecycle.expectSchedule(after: 90, count: 1, firstTimeout)
        sidecar.start()
        await fulfillment(of: [firstProcess, firstTimeout], timeout: 2)
        let processA = lifecycle.process(at: 0)

        let reclaimStarted = expectation(description: "orphan reclaim started")
        lifecycle.expectReclaim(1, reclaimStarted)
        processA.emitTermination(code: 2)
        await fulfillment(of: [reclaimStarted], timeout: 2)
        let reclaim = lifecycle.reclaim(at: 0)

        sidecar.restartNow()
        sidecar.stop()
        sidecar.start()
        lifecycle.syncManagerQueue()
        await flushSidecarPublishedState()
        XCTAssertEqual(
            lifecycle.processCount,
            1,
            "a replacement cannot exist while broad reclaim can still match it"
        )
        XCTAssertEqual(
            sidecar.phase,
            .restarting(afterSeconds: 2),
            "running intent held behind reclaim must not remain published as idle"
        )

        sidecar.stop()
        lifecycle.syncManagerQueue()
        await flushSidecarPublishedState()
        XCTAssertEqual(sidecar.phase, .idle, "stop during reclaim must publish stopped intent")
        XCTAssertEqual(lifecycle.processCount, 1)

        sidecar.restartNow()
        lifecycle.syncManagerQueue()
        await flushSidecarPublishedState()
        XCTAssertEqual(
            sidecar.phase,
            .restarting(afterSeconds: 2),
            "restart during reclaim must republish recovery without spawning"
        )
        XCTAssertEqual(lifecycle.processCount, 1)

        sidecar.stopBlocking()
        lifecycle.syncManagerQueue()
        await flushSidecarPublishedState()
        XCTAssertEqual(
            sidecar.phase,
            .idle,
            "blocking stop during reclaim must publish stopped intent"
        )

        sidecar.start()
        lifecycle.syncManagerQueue()
        await flushSidecarPublishedState()
        XCTAssertEqual(
            sidecar.phase,
            .restarting(afterSeconds: 2),
            "a later start must retain recovery intent until reclaim drains"
        )
        XCTAssertEqual(lifecycle.processCount, 1, "a held reclaim remains fail-closed")
        XCTAssertEqual(
            lifecycle.scheduledCount(after: 2),
            0,
            "the lock-release barrier cannot begin before the reclaim really drains"
        )

        let releaseBarrier = expectation(description: "lock-release barrier armed after drain")
        lifecycle.expectSchedule(after: 2, count: 1, releaseBarrier)
        reclaim.complete()
        await fulfillment(of: [releaseBarrier], timeout: 2)
        XCTAssertEqual(lifecycle.processCount, 1, "reclaim drain alone cannot create B")

        sidecar.restartNow()
        sidecar.stop()
        sidecar.start()
        lifecycle.syncManagerQueue()
        await flushSidecarPublishedState()
        XCTAssertEqual(lifecycle.processCount, 1, "manual intent cannot bypass release barrier")
        XCTAssertEqual(
            sidecar.phase,
            .restarting(afterSeconds: 2),
            "start during a retained barrier must publish current running intent"
        )

        let secondProcess = expectation(description: "one replacement after barrier")
        let secondTimeout = expectation(description: "replacement timeout armed")
        lifecycle.expectProcess(2, secondProcess)
        lifecycle.expectSchedule(after: 90, count: 2, secondTimeout)
        guard lifecycle.fireIfScheduled(after: 2, occurrence: 0) else {
            XCTFail("release barrier was not retained")
            return
        }
        await fulfillment(of: [secondProcess, secondTimeout], timeout: 2)
        let processB = lifecycle.process(at: 1)

        reclaim.complete()
        XCTAssertTrue(lifecycle.fireIfScheduled(after: 2, occurrence: 0))
        lifecycle.fire(after: 90, occurrence: 0)
        XCTAssertEqual(lifecycle.processCount, 2, "stale completion or barrier cannot replace B")
        XCTAssertEqual(processB.terminateCount, 0, "stale A work cannot terminate B")
        sidecar.stopBlocking()
        XCTAssertEqual(processB.terminateCount, 1, "B remains the tracked current process")
    }

    func testSidecarLifecycleStopDuringReclaimOrBarrierPreventsRespawn() async {
        for stopBeforeDrain in [true, false] {
            let assertions = SleepAssertionProbe()
            let lifecycle = SidecarLifecycleProbe()
            let sidecar = makeLifecycleTestSidecar(lifecycle, assertions: assertions)
            let firstProcess = expectation(description: "first process spawned")
            let firstTimeout = expectation(description: "first timeout armed")
            lifecycle.expectProcess(1, firstProcess)
            lifecycle.expectSchedule(after: 90, count: 1, firstTimeout)
            sidecar.start()
            await fulfillment(of: [firstProcess, firstTimeout], timeout: 2)

            let reclaimStarted = expectation(description: "orphan reclaim started")
            lifecycle.expectReclaim(1, reclaimStarted)
            lifecycle.process(at: 0).emitTermination(code: 2)
            await fulfillment(of: [reclaimStarted], timeout: 2)
            let reclaim = lifecycle.reclaim(at: 0)

            if stopBeforeDrain {
                sidecar.stopBlocking()
                lifecycle.syncManagerQueue()
                await flushSidecarPublishedState()
                XCTAssertEqual(sidecar.phase, .idle)
            }
            let releaseBarrier = expectation(description: "release barrier armed")
            lifecycle.expectSchedule(after: 2, count: 1, releaseBarrier)
            reclaim.complete()
            await fulfillment(of: [releaseBarrier], timeout: 2)
            lifecycle.syncManagerQueue()
            await flushSidecarPublishedState()
            if stopBeforeDrain {
                XCTAssertEqual(
                    sidecar.phase,
                    .idle,
                    "reclaim drain must not publish restarting after stop"
                )
            } else {
                XCTAssertEqual(sidecar.phase, .restarting(afterSeconds: 2))
            }
            if !stopBeforeDrain {
                sidecar.stop()
                lifecycle.syncManagerQueue()
                await flushSidecarPublishedState()
                XCTAssertEqual(sidecar.phase, .idle)
            }

            guard lifecycle.fireIfScheduled(after: 2, occurrence: 0) else {
                XCTFail("release barrier was not retained")
                return
            }
            reclaim.complete()
            XCTAssertTrue(lifecycle.fireIfScheduled(after: 2, occurrence: 0))
            await flushSidecarPublishedState()
            XCTAssertEqual(lifecycle.processCount, 1, "stop cannot be undone by drain or barrier")
            XCTAssertEqual(sidecar.phase, .idle, "barrier expiry must preserve stopped intent")
            sidecar.stopBlocking()
        }
    }

    func testSidecarLifecycleStartThenStopDuringBarrierRemainsIdleWithoutRespawn() async {
        let assertions = SleepAssertionProbe()
        let lifecycle = SidecarLifecycleProbe()
        let sidecar = makeLifecycleTestSidecar(lifecycle, assertions: assertions)
        let firstProcess = expectation(description: "first process spawned")
        let firstTimeout = expectation(description: "first timeout armed")
        lifecycle.expectProcess(1, firstProcess)
        lifecycle.expectSchedule(after: 90, count: 1, firstTimeout)
        sidecar.start()
        await fulfillment(of: [firstProcess, firstTimeout], timeout: 2)

        let reclaimStarted = expectation(description: "orphan reclaim started")
        lifecycle.expectReclaim(1, reclaimStarted)
        lifecycle.process(at: 0).emitTermination(code: 2)
        await fulfillment(of: [reclaimStarted], timeout: 2)
        let reclaim = lifecycle.reclaim(at: 0)

        sidecar.stop()
        lifecycle.syncManagerQueue()
        let releaseBarrier = expectation(description: "release barrier armed while stopped")
        lifecycle.expectSchedule(after: 2, count: 1, releaseBarrier)
        reclaim.complete()
        await fulfillment(of: [releaseBarrier], timeout: 2)
        lifecycle.syncManagerQueue()
        await flushSidecarPublishedState()
        XCTAssertEqual(sidecar.phase, .idle)

        sidecar.start()
        lifecycle.syncManagerQueue()
        await flushSidecarPublishedState()
        XCTAssertEqual(sidecar.phase, .restarting(afterSeconds: 2))
        XCTAssertEqual(lifecycle.processCount, 1, "start cannot bypass the retained barrier")

        sidecar.stop()
        lifecycle.syncManagerQueue()
        await flushSidecarPublishedState()
        XCTAssertEqual(sidecar.phase, .idle)

        guard lifecycle.fireIfScheduled(after: 2, occurrence: 0) else {
            XCTFail("release barrier was not retained")
            return
        }
        await flushSidecarPublishedState()
        XCTAssertEqual(lifecycle.processCount, 1, "stop after start must suppress barrier respawn")
        XCTAssertEqual(sidecar.phase, .idle)

        reclaim.complete()
        XCTAssertTrue(lifecycle.fireIfScheduled(after: 2, occurrence: 0))
        await flushSidecarPublishedState()
        XCTAssertEqual(lifecycle.processCount, 1, "duplicate callbacks must remain no-ops")
        XCTAssertEqual(sidecar.phase, .idle)
        sidecar.stopBlocking()
    }

    func testSidecarLifecycleReclaimLaunchFailureUsesBarrierWithoutTightLoop() async {
        let assertions = SleepAssertionProbe()
        let lifecycle = SidecarLifecycleProbe(reclaimStartFails: true)
        let sidecar = makeLifecycleTestSidecar(lifecycle, assertions: assertions)
        let firstProcess = expectation(description: "first process spawned")
        let firstTimeout = expectation(description: "first timeout armed")
        lifecycle.expectProcess(1, firstProcess)
        lifecycle.expectSchedule(after: 90, count: 1, firstTimeout)
        sidecar.start()
        await fulfillment(of: [firstProcess, firstTimeout], timeout: 2)

        let firstReclaim = expectation(description: "first reclaim attempted")
        let firstBarrier = expectation(description: "first failure barrier armed")
        lifecycle.expectReclaim(1, firstReclaim)
        lifecycle.expectSchedule(after: 2, count: 1, firstBarrier)
        lifecycle.process(at: 0).emitTermination(code: 2)
        await fulfillment(of: [firstReclaim, firstBarrier], timeout: 2)
        XCTAssertEqual(lifecycle.processCount, 1, "launch failure cannot respawn immediately")

        let secondProcess = expectation(description: "second process after first barrier")
        lifecycle.expectProcess(2, secondProcess)
        guard lifecycle.fireIfScheduled(after: 2, occurrence: 0) else {
            XCTFail("launch failure did not retain a barrier")
            return
        }
        await fulfillment(of: [secondProcess], timeout: 2)

        let secondReclaim = expectation(description: "second reclaim attempted")
        let secondBarrier = expectation(description: "second failure barrier armed")
        lifecycle.expectReclaim(2, secondReclaim)
        lifecycle.expectSchedule(after: 2, count: 2, secondBarrier)
        lifecycle.process(at: 1).emitTermination(code: 2)
        await fulfillment(of: [secondReclaim, secondBarrier], timeout: 2)
        XCTAssertEqual(lifecycle.processCount, 2, "repeated code 2 cannot form a tight loop")

        let thirdProcess = expectation(description: "third process after second barrier")
        lifecycle.expectProcess(3, thirdProcess)
        guard lifecycle.fireIfScheduled(after: 2, occurrence: 1) else {
            XCTFail("repeated code 2 did not retain its barrier")
            return
        }
        await fulfillment(of: [thirdProcess], timeout: 2)
        sidecar.stopBlocking()
    }

    @MainActor
    func testAppStateRoutesCoreSleepSignalsAndExplicitLogout() async {
        let probe = SleepAssertionProbe()
        let sidecar = makeSleepTestSidecar(probe)
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client, sidecar: sidecar)
        let refresh = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)

        let firstAcquire = expectation(description: "sync event acquires")
        let firstRelease = expectation(description: "QR event releases")
        probe.expectAcquire(1, firstAcquire)
        probe.expectRelease(1, firstRelease)
        endpoints.emitEvent(.syncProgress(stage: "history", progress: 0.2))
        await fulfillment(of: [firstAcquire], timeout: 2)
        endpoints.emitEvent(.qr(code: "qr", expires: 1))
        await fulfillment(of: [firstRelease], timeout: 2)

        let secondAcquire = expectation(description: "next sync acquires")
        let secondRelease = expectation(description: "logged-out event releases")
        probe.expectAcquire(2, secondAcquire)
        probe.expectRelease(2, secondRelease)
        endpoints.emitEvent(.syncProgress(stage: "history", progress: 0.3))
        await fulfillment(of: [secondAcquire], timeout: 2)
        endpoints.emitEvent(.connectionChanged(state: "logged_out", reason: nil))
        await fulfillment(of: [secondRelease], timeout: 2)

        let thirdAcquire = expectation(description: "reordered progress acquires")
        let thirdRelease = expectation(description: "explicit logout releases")
        probe.expectAcquire(3, thirdAcquire)
        probe.expectRelease(3, thirdRelease)
        endpoints.emitEvent(.syncProgress(stage: "history", progress: 0.4))
        await fulfillment(of: [thirdAcquire], timeout: 2)
        await state.logout(restartSidecar: {})
        await fulfillment(of: [thirdRelease], timeout: 2)

        endpoints.completeChat(0, with: [])
        await refresh.value
        XCTAssertEqual(probe.acquireCount, 3)
        XCTAssertEqual(probe.releaseCount, 3)
        XCTAssertEqual(probe.scheduledDelays, [600, 600, 600])
    }

    @MainActor
    func testAppStateRoutesAuthoritativeRESTSyncSnapshots() async {
        let probe = SleepAssertionProbe()
        let sidecar = makeSleepTestSidecar(probe)
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client, sidecar: sidecar)
        let acquired = expectation(description: "REST sync acquires")
        let capScheduled = expectation(description: "REST sync schedules one cap")
        let released = expectation(description: "REST done releases")
        probe.expectAcquire(1, acquired)
        probe.expectSchedule(1, capScheduled)
        probe.expectRelease(1, released)

        endpoints.session = SessionInfo(
            state: "connected",
            account: "self@s.whatsapp.net",
            qr: nil,
            sync: .init(stage: "history", progress: 0.2)
        )
        let historyResult = await state.refreshSession(includeChats: false)
        XCTAssertTrue(historyResult)
        await fulfillment(of: [acquired, capScheduled], timeout: 2)

        endpoints.session.sync = .init(stage: "contacts", progress: 0.8)
        let contactsResult = await state.refreshSession(includeChats: false)
        XCTAssertTrue(contactsResult)
        endpoints.session.sync = .init(stage: "done", progress: 1)
        let doneResult = await state.refreshSession(includeChats: false)
        XCTAssertTrue(doneResult)
        await fulfillment(of: [released], timeout: 2)

        sidecar.stopBlocking()
        XCTAssertEqual(probe.acquireCount, 1)
        XCTAssertEqual(probe.releaseCount, 1)
        XCTAssertEqual(probe.scheduledDelays, [600])
    }

    func testFreshConnectedWebSocketSuppressesPoll() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(WebSocketFreshnessPolicy.shouldPoll(
            now: now,
            lastActivityAt: now.addingTimeInterval(-59),
            connectionState: "connected"
        ))
    }

    func testExactlySixtySecondOldConnectedWebSocketAllowsRecoveryPoll() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(WebSocketFreshnessPolicy.shouldPoll(
            now: now,
            lastActivityAt: now.addingTimeInterval(-60),
            connectionState: "connected"
        ))
    }

    func testStaleOrUnprovenWebSocketAllowsRecoveryPoll() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(WebSocketFreshnessPolicy.shouldPoll(
            now: now,
            lastActivityAt: now.addingTimeInterval(-61),
            connectionState: "connected"
        ))
        XCTAssertTrue(WebSocketFreshnessPolicy.shouldPoll(
            now: now,
            lastActivityAt: nil,
            connectionState: "connected"
        ))
        XCTAssertTrue(WebSocketFreshnessPolicy.shouldPoll(
            now: now,
            lastActivityAt: now,
            connectionState: "offline"
        ))
    }

    func testEveryNonConnectedStateAllowsFallbackPoll() {
        let now = Date(timeIntervalSince1970: 1_000)

        for state in ["logged_out", "linking", "connecting", "offline", "unexpected"] {
            XCTAssertTrue(WebSocketFreshnessPolicy.shouldPoll(
                now: now,
                lastActivityAt: now,
                connectionState: state
            ), "\(state) must not borrow WebSocket freshness")
        }
    }

    func testTranscriptRetentionUsesDeterministicRecencyAndSkipsActiveAndPending() {
        var retention = TranscriptRetention(limit: 3)
        ["a", "b", "c", "a", "d"].forEach { retention.touch($0) }

        XCTAssertEqual(
            retention.evictionCandidates(
                loaded: Set(["a", "b", "c", "d"]),
                active: "a",
                protected: Set(["c"])
            ),
            ["b"]
        )
    }

    func testTranscriptRetentionAllowsProtectedOverflowThenEvictsWhenProtectionEnds() {
        var retention = TranscriptRetention(limit: 2)
        ["a", "b", "c"].forEach { retention.touch($0) }

        XCTAssertEqual(
            retention.evictionCandidates(
                loaded: Set(["a", "b", "c"]),
                active: "c",
                protected: Set(["a", "b"])
            ),
            []
        )
        XCTAssertEqual(
            retention.evictionCandidates(
                loaded: Set(["a", "b", "c"]),
                active: "c",
                protected: Set(["b"])
            ),
            ["a"]
        )
    }

    func testTranscriptRetentionPrunesRemovedAndEvictedMetadata() {
        var retention = TranscriptRetention(limit: 2)
        ["stale-a", "stale-b", "live-a", "live-b", "live-c"].forEach {
            retention.touch($0)
        }

        XCTAssertEqual(
            retention.evictionCandidates(
                loaded: Set(["live-a", "live-b", "live-c"]),
                active: "live-c",
                protected: []
            ),
            ["live-a"]
        )
        XCTAssertEqual(retention.trackedCount, 2)

        retention.remove("live-b")
        XCTAssertEqual(retention.trackedCount, 1)
        retention.reset()
        XCTAssertEqual(retention.trackedCount, 0)
    }

    func testTranscriptWindowKeepsEqualTimestampPendingRowAndStableNewestDurableOrder() {
        let chat = "equal-timestamp@s.whatsapp.net"
        let rows = [runtimeMessage(
            id: -1,
            chat: chat,
            text: "pending",
            fromMe: true,
            timestamp: 42
        )] + (1...300).map {
            runtimeMessage(id: Int64($0), chat: chat, text: "durable-\($0)", timestamp: 42)
        }

        let retained = TranscriptWindowPolicy.retained(rows, limit: 300)

        XCTAssertEqual(retained.count, 300)
        XCTAssertEqual(retained.first?.id, -1)
        XCTAssertEqual(retained.dropFirst().map(\.id), (2...300).map(Int64.init))
    }

    func testTranscriptWindowKeepsEveryPendingRowWhenPendingExceedsNormalWindow() {
        let chat = "pending-overflow@s.whatsapp.net"
        let durable = (1...5).map {
            runtimeMessage(id: Int64($0), chat: chat, text: "durable-\($0)", timestamp: 1)
        }
        let pending = (1...301).map {
            runtimeMessage(
                id: -Int64($0),
                chat: chat,
                text: "pending-\($0)",
                fromMe: true,
                timestamp: 2
            )
        }

        let retained = TranscriptWindowPolicy.retained(durable + pending, limit: 300)

        XCTAssertEqual(retained.map(\.id), pending.map(\.id))
    }

    func testEveryCoreEventDeliberatelyClassifiesDockBadgeInvalidation() {
        let incoming = runtimeMessage(id: 1, chat: "a@s.whatsapp.net", text: "incoming")
        let own = runtimeMessage(
            id: 2,
            chat: "a@s.whatsapp.net",
            text: "own",
            fromMe: true
        )
        let media = MessageMedia(
            id: "media",
            kind: "image",
            mime: "image/png",
            size: 1,
            filename: nil,
            state: "downloaded",
            local_path: nil
        )
        let cases: [(CoreEvent, Bool)] = [
            (.connectionChanged(state: "connected", reason: nil), false),
            (.qr(code: "code", expires: 1), false),
            (.syncProgress(stage: "history", progress: 0.5), false),
            (.messageReceived(incoming), true),
            (.messageReceived(own), false),
            (.messageUpdated(incoming), false),
            (.chatUpdated(runtimeChat("a@s.whatsapp.net")), true),
            (.chatRemoved("a@s.whatsapp.net"), true),
            (.contactsUpdated(changed: 1), false),
            (.inboxChanged(reason: "changed"), false),
            (.reaction(rowid: 1, emoji: "thumb"), false),
            (.mediaUpdated(rowid: 1, chat: "a@s.whatsapp.net", media: media), false),
            (.ping, false),
        ]

        for (event, expected) in cases {
            XCTAssertEqual(event.affectsDockBadge, expected, "unexpected classification for \(event)")
        }
    }

    @MainActor
    func testAppStateOpeningTwentyFiveChatsRetainsActivePlusNineAndTrimsInactiveRows() async {
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let chats = (0..<25).map { "chat-\($0)@s.whatsapp.net" }
        for (chatIndex, chat) in chats.enumerated() {
            endpoints.messagePages[chat] = (0..<301).map { row in
                runtimeMessage(
                    id: Int64(chatIndex * 1_000 + row + 1),
                    chat: chat,
                    text: "row-\(row)"
                )
            }
            await state.previewChat(chat)
        }

        XCTAssertEqual(state.selectedChat, chats.last)
        XCTAssertEqual(state.messagesByChat.count, 10)
        XCTAssertEqual(Set(state.messagesByChat.keys), Set(chats.suffix(10)))
        XCTAssertNotNil(state.messagesByChat[chats.last!], "the active transcript cannot be evicted")
        XCTAssertEqual(state.messagesByChat[chats.last!]?.count, 301)
        XCTAssertTrue(
            state.messagesByChat.allSatisfy { chat, rows in
                chat == state.selectedChat || rows.count <= 300
            },
            "every retained non-open transcript must keep only its newest 300 rows"
        )
        let offeredRows = endpoints.messagePages.values.reduce(0) { $0 + $1.count }
        let retainedRows = state.messagesByChat.values.reduce(0) { $0 + $1.count }
        XCTAssertEqual(offeredRows, 7_525)
        XCTAssertEqual(retainedRows, 3_001)
        print("TASK5_RETENTION_PROXY offered_chats=25 offered_rows=7525 retained_chats=\(state.messagesByChat.count) retained_rows=\(retainedRows)")

        state.handleConnectionState("logged_out")
        XCTAssertTrue(state.messagesByChat.isEmpty)
        XCTAssertNil(state.selectedChat)
    }

    @MainActor
    func testRowTapReloadsEmptyTranscriptOfAlreadySelectedChat() async {
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockMessageLoads = true
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let chat = "dead@s.whatsapp.net"
        // Selection landed earlier but the page load was dropped or failed:
        // the transcript is empty and a same-row tap cannot rely on a
        // selection change firing loadSelectedChat again.
        state.selectedChat = chat
        XCTAssertEqual(state.messagesByChat[chat] ?? [], [])

        let tap = Task { await state.openChatRow(chat, source: .mouse) }
        await endpoints.waitForMessageRequests(1)
        endpoints.completeMessage(0, with: [
            runtimeMessage(id: 1, chat: chat, text: "recovered")
        ])
        await tap.value

        XCTAssertEqual(state.selectedChat, chat)
        XCTAssertEqual(state.messagesByChat[chat]?.map(\.id), [1])
    }

    @MainActor
    func testRowTapReassertsDroppedSelectionWriteAndCommitsRead() async {
        let endpoints = RuntimeEndpointProbe()
        let chat = "target@s.whatsapp.net"
        endpoints.messagePages[chat] = [runtimeMessage(id: 7, chat: chat, text: "page")]
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        state.chats = [Chat(jid: chat, kind: "direct", display_name: "Target",
                            last_message_ts: 1, last_preview: nil, unread_count: 2,
                            mentioned_unread: 0, is_pinned: false, is_muted: false)]
        state.selectedChat = "other@s.whatsapp.net"

        await state.openChatRow(chat, source: .mouse)

        XCTAssertEqual(
            state.selectedChat,
            chat,
            "a row tap must restore selection the List binding failed to write"
        )
        XCTAssertEqual(state.messagesByChat[chat]?.map(\.id), [7])
        XCTAssertEqual(endpoints.markReadChats, [chat])
    }

    @MainActor
    func testRowTapDoesNotRefetchTranscriptTheSelectionLoadAlreadyFilled() async {
        let endpoints = RuntimeEndpointProbe()
        let chat = "coalesce@s.whatsapp.net"
        endpoints.messagePages[chat] = [runtimeMessage(id: 9, chat: chat, text: "page")]
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        state.selectedChat = chat

        // The selection observer's load finishes before the tap gesture's
        // task runs: the tap must not issue a second page request.
        let selectionDriven = Task { await state.loadSelectedChat(chat) }
        await selectionDriven.value
        await state.openChatRow(chat, source: .mouse)

        XCTAssertEqual(endpoints.messageChats.filter { $0 == chat }.count, 1)
        XCTAssertEqual(state.messagesByChat[chat]?.count, 1)
        XCTAssertEqual(endpoints.markReadChats, [])
    }

    @MainActor
    func testAppStateProtectsPendingAndFailedChatsUntilRetrySucceeds() async {
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockTextSend = true
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let protectedChats = (0..<11).map { "pending-\($0)@s.whatsapp.net" }
        var sends: [Task<Void, Never>] = []

        for (index, chat) in protectedChats.enumerated() {
            await state.previewChat(chat)
            sends.append(Task { await state.send("pending-\(index)", in: chat) })
            await endpoints.waitForTextRequests(index + 1)
            guard endpoints.textRequests.count == index + 1 else { return }
        }
        let active = "active@s.whatsapp.net"
        await state.previewChat(active)

        XCTAssertEqual(state.messagesByChat.count, 12, "protected overflow may exceed ten")
        XCTAssertEqual(
            state.messagesByChat.keys.filter { state.messagesByChat[$0]?.contains { $0.id < 0 } == true }.count,
            11
        )
        XCTAssertNotNil(state.messagesByChat[active])

        endpoints.completeText(0, completion: .success)
        await sends[0].value
        XCTAssertNil(state.messagesByChat[protectedChats[0]], "successful reconciliation must revisit eviction")
        XCTAssertEqual(state.messagesByChat.count, 11)

        endpoints.completeText(1, completion: .failure)
        await sends[1].value
        XCTAssertEqual(state.messagesByChat[protectedChats[1]]?.first?.receipt_status, "failed")
        XCTAssertEqual(state.messagesByChat.count, 11, "failed negative rows retain the user's retry path")
        if let failed = state.messagesByChat[protectedChats[1]]?.first {
            let retry = Task { await state.retrySend(failed) }
            await endpoints.waitForTextRequests(12)
            endpoints.completeText(11, completion: .success)
            await retry.value
            XCTAssertEqual(state.messagesByChat.count, 10)
            XCTAssertFalse(state.messagesByChat[protectedChats[1]]?.contains { $0.id < 0 } ?? false)
        }
        XCTAssertNotNil(state.messagesByChat[active], "the active transcript cannot be evicted")

        for index in 2..<protectedChats.count {
            endpoints.completeText(index, completion: .success)
        }
        for send in sends.dropFirst(2) { await send.value }
    }

    @MainActor
    func testNonOpenTrimAndLRUPreserveFailedRowsUntilExplicitRemoval() async {
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockTextSend = true
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [])
        await initial.value

        let protectedChats = [
            "echo@s.whatsapp.net",
            "success@s.whatsapp.net",
            "failure@s.whatsapp.net",
        ]
        var sends: [Task<Void, Never>] = []
        for (index, chat) in protectedChats.enumerated() {
            endpoints.messagePages[chat] = (1...300).map {
                runtimeMessage(
                    id: Int64(index * 1_000 + $0),
                    chat: chat,
                    text: "future-\($0)",
                    timestamp: 4_000_000_000
                )
            }
            await state.previewChat(chat)
            sends.append(Task { await state.send(["echo", "success", "failure"][index], in: chat) })
            await endpoints.waitForTextRequests(index + 1)
        }
        await state.previewChat("active@s.whatsapp.net")

        for chat in protectedChats {
            XCTAssertEqual(
                state.messagesByChat[chat]?.filter { $0.id < 0 }.count,
                1,
                "switching away must not trim the active optimistic row for \(chat)"
            )
        }

        endpoints.emitEvent(.messageReceived(runtimeMessage(
            id: 90_001,
            chat: protectedChats[0],
            text: "echo",
            fromMe: true
        )))
        for _ in 0..<20 { await Task.yield() }
        endpoints.completeText(1, completion: .success)
        endpoints.completeText(2, completion: .failure)
        await sends[1].value
        await sends[2].value
        endpoints.completeText(0, completion: .failure)
        await sends[0].value

        XCTAssertFalse(state.messagesByChat[protectedChats[0]]?.contains { $0.id < 0 } ?? true)
        XCTAssertFalse(state.messagesByChat[protectedChats[1]]?.contains { $0.id < 0 } ?? true)
        XCTAssertEqual(
            state.messagesByChat[protectedChats[2]]?.filter { $0.id < 0 && $0.receipt_status == "failed" }.count,
            1
        )

        for index in 0..<10 {
            await state.previewChat("replacement-\(index)@s.whatsapp.net")
        }
        XCTAssertEqual(state.messagesByChat.count, 10)
        for chat in protectedChats.prefix(2) {
            XCTAssertNil(state.messagesByChat[chat], "reconciled rows permit deterministic eviction")
        }
        XCTAssertEqual(state.messagesByChat[protectedChats[2]]?.filter { $0.id < 0 }.count, 1)
        endpoints.emitEvent(.chatRemoved(protectedChats[2]))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(state.messagesByChat[protectedChats[2]])
    }

    @MainActor
    func testLateEchoForFailedRowDoesNotConsumeAnotherRowsProtection() async {
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockTextSend = true
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [])
        await initial.value
        let chat = "late-echo@s.whatsapp.net"

        await state.previewChat(chat)
        let failedSend = Task { await state.send("already failed", in: chat) }
        await endpoints.waitForTextRequests(1)
        endpoints.completeText(0, completion: .failure)
        await failedSend.value

        let pendingSend = Task { await state.send("still pending", in: chat) }
        await endpoints.waitForTextRequests(2)
        await state.previewChat("late-echo-active@s.whatsapp.net")
        endpoints.emitEvent(.messageReceived(runtimeMessage(
            id: 91_001,
            chat: chat,
            text: "already failed",
            fromMe: true
        )))
        for _ in 0..<20 { await Task.yield() }

        for index in 0..<10 {
            await state.previewChat("late-echo-replacement-\(index)@s.whatsapp.net")
        }
        XCTAssertEqual(state.messagesByChat.count, 10)
        XCTAssertEqual(
            state.messagesByChat[chat]?.filter { $0.id < 0 && $0.receipt_status != "failed" }.count,
            1,
            "late failed-row echo must leave the other negative row protected"
        )

        endpoints.completeText(1, completion: .success)
        await pendingSend.value
        await state.previewChat("late-echo-post-success@s.whatsapp.net")
        XCTAssertEqual(state.messagesByChat.count, 10)
        XCTAssertNil(state.messagesByChat[chat])
    }

    /// Group-mention sends put display text ("@Ann") in the temp row but
    /// wire text ("@<digits>") on the bus. The WS echo carries the wire
    /// form — it must still consume the display-form temp row (audit W1:
    /// the strict text match left a phantom failed bubble and a double
    /// send on retry).
    @MainActor
    func testMentionWireEchoReconcilesDisplayTempRow() async {
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [])
        await initial.value
        let chat = "1234-5678@g.us"
        let pn = "254799000111@s.whatsapp.net"

        await state.previewChat(chat)
        state.mentionTargetStore[chat] = [pn: "Ann"]
        state.chatMembers[chat] = [
            APIClient.GroupMember(jid: pn, display_name: "Ann", role: "member", lid: nil),
        ]

        let sendTask = Task { await state.send("hey @Ann", in: chat) }
        await endpoints.waitForTextRequests(1)

        endpoints.emitEvent(.messageReceived(runtimeMessage(
            id: 91_100,
            chat: chat,
            text: "hey @254799000111",
            fromMe: true
        )))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(
            state.messagesByChat[chat]?.filter { $0.id < 0 }.count,
            0,
            "wire-form echo must consume the display-form temp row"
        )
        XCTAssertEqual(
            state.messagesByChat[chat]?.filter { $0.id == 91_100 }.count,
            1,
            "the durable echo row must be present"
        )

        endpoints.completeText(0, completion: .success)
        await sendTask.value
    }

    @MainActor
    func testSameTextFailedAndLiveEchoKeepsOnlyUnreconciledNegativeProtection() async {
        for completion in [RuntimeCompletion.success, .failure] {
            let endpoints = RuntimeEndpointProbe()
            endpoints.blockTextSend = true
            let client = makeAppRuntimeClient(endpoints)
            let state = AppState(
                runtimeClient: client,
                pendingMessageTimestamp: { 42 }
            )
            let initial = state.startConnectionRefresh(.initial, client: client)
            await endpoints.waitForChatRequests(1)
            endpoints.completeChat(0, with: [])
            await initial.value
            let suffix: String
            switch completion {
            case .success: suffix = "success"
            case .failure: suffix = "failure"
            }
            let chat = "same-text-failed-\(suffix)@s.whatsapp.net"

            await state.previewChat(chat)
            let failed = Task { await state.send("identical", in: chat) }
            await endpoints.waitForTextRequests(1)
            endpoints.completeText(0, completion: .failure)
            await failed.value
            let live = Task { await state.send("identical", in: chat) }
            await endpoints.waitForTextRequests(2)
            await state.previewChat("same-text-active-\(suffix)@s.whatsapp.net")

            let echo = runtimeMessage(
                id: 92_001,
                chat: chat,
                text: "identical",
                fromMe: true,
                timestamp: 42,
                messageID: "failed-echo-\(suffix)"
            )
            endpoints.emitEvent(.messageReceived(echo))
            endpoints.emitEvent(.messageReceived(runtimeMessage(
                id: 92_002,
                chat: chat,
                text: "identical",
                fromMe: true,
                timestamp: 42,
                messageID: echo.message_id
            )))
            for _ in 0..<20 { await Task.yield() }

            XCTAssertEqual(state.messagesByChat[chat]?.filter { $0.id < 0 }.map(\.id), [-2])
            XCTAssertEqual(state.messagesByChat[chat]?.filter { $0.message_id == echo.message_id }.count, 1)
            for index in 0..<10 {
                await state.previewChat("same-text-pressure-\(suffix)-\(index)@s.whatsapp.net")
            }
            XCTAssertEqual(state.messagesByChat.count, 10)
            XCTAssertNotNil(state.messagesByChat[chat], "the exact live -2 row must remain protected")

            switch completion {
            case .success:
                endpoints.completeText(1, with: runtimeMessage(
                    id: 92_003,
                    chat: chat,
                    text: "identical",
                    fromMe: true,
                    timestamp: 42,
                    messageID: "live-success"
                ))
            case .failure:
                endpoints.completeText(1, completion: .failure)
            }
            await live.value
            switch completion {
            case .success:
                XCTAssertFalse(state.messagesByChat[chat]?.contains { $0.id < 0 } ?? true)
            case .failure:
                XCTAssertEqual(
                    state.messagesByChat[chat]?.filter { $0.id == -2 && $0.receipt_status == "failed" }.count,
                    1
                )
            }
            await state.previewChat("same-text-post-\(suffix)@s.whatsapp.net")
            XCTAssertEqual(state.messagesByChat.count, 10)
            switch completion {
            case .success:
                XCTAssertNil(state.messagesByChat[chat], "successful exact reconciliation releases protection")
            case .failure:
                XCTAssertEqual(state.messagesByChat[chat]?.filter { $0.id < 0 }.map(\.id), [-2],
                    "failure retains the exact negative row under LRU pressure")
            }
        }
    }

    @MainActor
    func testSameTextLiveEchoOwnsOldestTempAndDuplicateCannotConsumeNewerPending() async {
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockTextSend = true
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(
            runtimeClient: client,
            pendingMessageTimestamp: { 42 }
        )
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [])
        await initial.value
        let chat = "same-text-live@s.whatsapp.net"
        await state.previewChat(chat)

        let oldest = Task { await state.send("identical", in: chat) }
        await endpoints.waitForTextRequests(1)
        let newer = Task { await state.send("identical", in: chat) }
        await endpoints.waitForTextRequests(2)
        await state.previewChat("same-text-live-active@s.whatsapp.net")
        let oldestEcho = runtimeMessage(
            id: 93_001,
            chat: chat,
            text: "identical",
            fromMe: true,
            timestamp: 42,
            messageID: "durable-oldest"
        )
        endpoints.emitEvent(.messageReceived(oldestEcho))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(state.messagesByChat[chat]?.filter { $0.id < 0 }.map(\.id), [-2])
        endpoints.emitEvent(.messageReceived(runtimeMessage(
            id: 93_002,
            chat: chat,
            text: "identical",
            fromMe: true,
            timestamp: 42,
            messageID: oldestEcho.message_id
        )))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(state.messagesByChat[chat]?.filter { $0.id < 0 }.map(\.id), [-2])
        XCTAssertEqual(state.messagesByChat[chat]?.filter { $0.message_id == oldestEcho.message_id }.count, 1)

        for index in 0..<10 {
            await state.previewChat("same-text-live-pressure-\(index)@s.whatsapp.net")
        }
        XCTAssertNotNil(state.messagesByChat[chat])
        let newerDurable = runtimeMessage(
            id: 93_003,
            chat: chat,
            text: "identical",
            fromMe: true,
            timestamp: 42,
            messageID: "durable-newer"
        )
        endpoints.completeText(1, with: newerDurable)
        await newer.value
        endpoints.completeText(0, with: oldestEcho)
        await oldest.value

        XCTAssertFalse(state.messagesByChat[chat]?.contains { $0.id < 0 } ?? true)
        XCTAssertEqual(state.messagesByChat[chat]?.filter { $0.message_id == oldestEcho.message_id }.count, 1)
        XCTAssertEqual(state.messagesByChat[chat]?.filter { $0.message_id == newerDurable.message_id }.count, 1)
        await state.previewChat("same-text-live-post@s.whatsapp.net")
        XCTAssertEqual(state.messagesByChat.count, 10)
        XCTAssertNil(state.messagesByChat[chat], "both exact live protections must be cleared once")
        print("TASK5_FIX2_SAME_TEXT temps=2 duplicate_echoes=1 durable_rows=2 retained_after_pressure=10")
    }

    @MainActor
    func testNewerFirstSameTextEchoRepairsOwnershipAcrossMixedHTTPCompletionOrders() async {
        for olderCompletesFirst in [true, false] {
            let endpoints = RuntimeEndpointProbe()
            endpoints.blockTextSend = true
            let client = makeAppRuntimeClient(endpoints)
            let state = AppState(
                runtimeClient: client,
                pendingMessageTimestamp: { 42 }
            )
            let initial = state.startConnectionRefresh(.initial, client: client)
            await endpoints.waitForChatRequests(1)
            endpoints.completeChat(0, with: [])
            await initial.value
            let order = olderCompletesFirst ? "older-first" : "newer-first"
            let chat = "same-text-repair-\(order)@s.whatsapp.net"
            await state.previewChat(chat)

            let older = Task { await state.send("identical", in: chat) }
            await endpoints.waitForTextRequests(1)
            let newer = Task { await state.send("identical", in: chat) }
            await endpoints.waitForTextRequests(2)
            await state.previewChat("same-text-repair-active-\(order)@s.whatsapp.net")

            let newerEcho = runtimeMessage(
                id: 94_001,
                chat: chat,
                text: "identical",
                fromMe: true,
                timestamp: 42,
                messageID: "durable-newer-\(order)",
                senderJID: "self-device@s.whatsapp.net"
            )
            let olderDurable = runtimeMessage(
                id: 94_002,
                chat: chat,
                text: "identical",
                fromMe: true,
                timestamp: 42,
                messageID: "durable-older-\(order)",
                senderJID: "self@s.whatsapp.net"
            )
            endpoints.emitEvent(.messageReceived(newerEcho))
            for _ in 0..<20 { await Task.yield() }

            for index in 0..<10 {
                await state.previewChat("same-text-repair-pressure-\(order)-\(index)@s.whatsapp.net")
            }
            XCTAssertNotNil(state.messagesByChat[chat], "the unresolved second send remains protected")

            if olderCompletesFirst {
                endpoints.completeText(0, with: olderDurable)
                await older.value
                endpoints.completeText(1, completion: .failure)
                await newer.value
            } else {
                endpoints.completeText(1, completion: .failure)
                await newer.value
                endpoints.completeText(0, with: olderDurable)
                await older.value
            }

            let rows = state.messagesByChat[chat] ?? []
            XCTAssertFalse(rows.contains { $0.id < 0 }, "the newer echo proves its failed HTTP send landed")
            XCTAssertEqual(rows.filter { $0.message_id == newerEcho.message_id }.count, 1)
            XCTAssertEqual(rows.filter { $0.message_id == olderDurable.message_id }.count, 1)
            await state.previewChat("same-text-repair-post-\(order)@s.whatsapp.net")
            XCTAssertEqual(state.messagesByChat.count, 10)
            XCTAssertNil(state.messagesByChat[chat], "both exact optimistic protections must clear once")
        }
        print("TASK5_FIX3_OWNERSHIP completion_orders=2 durable_rows_per_order=2 pending_rows=0 retained_after_pressure=10")
    }

    @MainActor
    func testFailedSiblingBeforeEchoIsRestoredWhenExactOtherAckClaimsEcho() async {
        for successfulRequest in 0..<2 {
            let endpoints = RuntimeEndpointProbe()
            endpoints.blockTextSend = true
            let client = makeAppRuntimeClient(endpoints)
            let state = AppState(
                runtimeClient: client,
                pendingMessageTimestamp: { 42 }
            )
            let initial = state.startConnectionRefresh(.initial, client: client)
            await endpoints.waitForChatRequests(1)
            endpoints.completeChat(0, with: [])
            await initial.value
            let chat = "failed-before-echo-two-\(successfulRequest)@s.whatsapp.net"
            await state.previewChat(chat)

            let first = Task { await state.send("identical", in: chat) }
            await endpoints.waitForTextRequests(1)
            let second = Task { await state.send("identical", in: chat) }
            await endpoints.waitForTextRequests(2)
            let sends = [first, second]
            let failedRequest = successfulRequest == 0 ? 1 : 0
            endpoints.completeText(failedRequest, completion: .failure)
            await sends[failedRequest].value

            let echo = runtimeMessage(
                id: 97_000 + Int64(successfulRequest),
                chat: chat,
                text: "identical",
                fromMe: true,
                timestamp: 42,
                messageID: "failed-before-echo-two-\(successfulRequest)",
                senderJID: "self-device@s.whatsapp.net"
            )
            endpoints.emitEvent(.messageReceived(echo))
            for _ in 0..<20 { await Task.yield() }
            endpoints.completeText(successfulRequest, with: echo)
            await sends[successfulRequest].value

            let rows = state.messagesByChat[chat] ?? []
            let failedTempID: Int64 = failedRequest == 0 ? -1 : -2
            XCTAssertEqual(rows.filter { $0.id > 0 }.map(\.message_id), [echo.message_id])
            XCTAssertEqual(
                rows.filter { $0.id < 0 && $0.receipt_status == "failed" }.map(\.id),
                [failedTempID],
                "an exact sibling ack must restore the definitively failed row consumed by the ambiguous echo"
            )
            XCTAssertEqual(rows.count, 2)
        }
    }

    @MainActor
    func testTwoFailuresBeforeEchoAreRestoredForEveryThreeSendOwnerAndFailureOrder() async {
        for successfulRequest in 0..<3 {
            let failedRequests = (0..<3).filter { $0 != successfulRequest }
            for failureOrder in [failedRequests, Array(failedRequests.reversed())] {
                let endpoints = RuntimeEndpointProbe()
                endpoints.blockTextSend = true
                let client = makeAppRuntimeClient(endpoints)
                let state = AppState(
                    runtimeClient: client,
                    pendingMessageTimestamp: { 42 }
                )
                let initial = state.startConnectionRefresh(.initial, client: client)
                await endpoints.waitForChatRequests(1)
                endpoints.completeChat(0, with: [])
                await initial.value
                let order = failureOrder.map(String.init).joined()
                let chat = "failed-before-echo-three-\(successfulRequest)-\(order)@s.whatsapp.net"
                await state.previewChat(chat)

                var sends: [Task<Void, Never>] = []
                for request in 0..<3 {
                    sends.append(Task { await state.send("identical", in: chat) })
                    await endpoints.waitForTextRequests(request + 1)
                }
                for failedRequest in failureOrder {
                    endpoints.completeText(failedRequest, completion: .failure)
                    await sends[failedRequest].value
                }

                let echo = runtimeMessage(
                    id: 98_000 + Int64(successfulRequest * 10 + failureOrder[0]),
                    chat: chat,
                    text: "identical",
                    fromMe: true,
                    timestamp: 42,
                    messageID: "failed-before-echo-three-\(successfulRequest)-\(order)",
                    senderJID: "self-device@s.whatsapp.net"
                )
                endpoints.emitEvent(.messageReceived(echo))
                for _ in 0..<20 { await Task.yield() }
                endpoints.completeText(successfulRequest, with: echo)
                await sends[successfulRequest].value

                let rows = state.messagesByChat[chat] ?? []
                let expectedFailedIDs = Set(failedRequests.map { -Int64($0 + 1) })
                XCTAssertEqual(rows.filter { $0.id > 0 }.map(\.message_id), [echo.message_id])
                XCTAssertEqual(
                    Set(rows.filter { $0.id < 0 && $0.receipt_status == "failed" }.map(\.id)),
                    expectedFailedIDs,
                    "all definitively failed siblings must survive owner \(successfulRequest), order \(order)"
                )
                XCTAssertEqual(rows.count, 3)
            }
        }
    }

    @MainActor
    func testEchoOwnerFailureRemainsReversibleUntilExactSiblingAckInBothCallbackOrders() async {
        for failedCompletesFirst in [true, false] {
            let endpoints = RuntimeEndpointProbe()
            endpoints.blockTextSend = true
            let client = makeAppRuntimeClient(endpoints)
            let state = AppState(
                runtimeClient: client,
                pendingMessageTimestamp: { 42 }
            )
            let initial = state.startConnectionRefresh(.initial, client: client)
            await endpoints.waitForChatRequests(1)
            endpoints.completeChat(0, with: [])
            await initial.value
            let order = failedCompletesFirst ? "failure-first" : "exact-first"
            let chat = "echo-owner-failure-\(order)@s.whatsapp.net"
            await state.previewChat(chat)

            let provisionalOwner = Task { await state.send("identical", in: chat) }
            await endpoints.waitForTextRequests(1)
            let exactOwner = Task { await state.send("identical", in: chat) }
            await endpoints.waitForTextRequests(2)
            let echo = runtimeMessage(
                id: failedCompletesFirst ? 98_100 : 98_101,
                chat: chat,
                text: "identical",
                fromMe: true,
                timestamp: 42,
                messageID: "echo-owner-failure-\(order)",
                senderJID: "self-device@s.whatsapp.net"
            )
            endpoints.emitEvent(.messageReceived(echo))
            for _ in 0..<20 { await Task.yield() }

            if failedCompletesFirst {
                endpoints.completeText(0, completion: .failure)
                await provisionalOwner.value
                endpoints.completeText(1, with: echo)
                await exactOwner.value
            } else {
                endpoints.completeText(1, with: echo)
                await exactOwner.value
                endpoints.completeText(0, completion: .failure)
                await provisionalOwner.value
            }

            let rows = state.messagesByChat[chat] ?? []
            XCTAssertEqual(rows.filter { $0.id > 0 }.map(\.message_id), [echo.message_id])
            XCTAssertEqual(
                rows.filter { $0.id == -1 && $0.receipt_status == "failed" }.count,
                1,
                "the provisional owner must be restored when the sibling's exact ack claims the echo"
            )
            XCTAssertEqual(rows.count, 2)
        }
    }

    @MainActor
    func testMultipleFailuresWithCrossedEchoesPreserveCardinalityAndRetry() async {
        // Request 1 lands despite HTTP failure; request 2 truly fails. Request
        // 0's exact ack must leave one retryable row, including when all
        // remaining active owners have already become provisional evidence.
        for count in [3, 4] {
            for failureOrder in [[1, 2], [2, 1]] {
                for failurePhase in 0..<4 {
                    for reverseAcks in (count == 3 ? [false] : [false, true]) {
                        let endpoints = RuntimeEndpointProbe()
                        endpoints.blockTextSend = true
                        let client = makeAppRuntimeClient(endpoints)
                        let state = AppState(runtimeClient: client, pendingMessageTimestamp: { 42 })
                        let initial = state.startConnectionRefresh(.initial, client: client)
                        await endpoints.waitForChatRequests(1)
                        endpoints.completeChat(0, with: [])
                        await initial.value
                        let chat = "multiple-failures@s.whatsapp.net"
                        await state.previewChat(chat)
                        var sends: [Task<Void, Never>] = []
                        for request in 0..<count {
                            sends.append(Task { await state.send("identical", in: chat) })
                            await endpoints.waitForTextRequests(request + 1)
                        }
                        let echoes = (0..<count).map { request in
                            runtimeMessage(id: Int64(99_000 + request), chat: chat,
                                text: "identical", fromMe: true, timestamp: 42,
                                messageID: "multi-echo-\(request)")
                        }
                        for phase in 0..<3 {
                            if failurePhase == phase {
                                for request in failureOrder {
                                    endpoints.completeText(request, completion: .failure)
                                    await sends[request].value
                                }
                            }
                            if phase == 0 {
                                endpoints.emitEvent(.messageReceived(echoes[1]))
                            } else if phase == 1 {
                                if count == 4 { endpoints.emitEvent(.messageReceived(echoes[3])) }
                                endpoints.emitEvent(.messageReceived(echoes[0]))
                            }
                            for _ in 0..<20 { await Task.yield() }
                        }
                        let ackOrder = count == 3 ? [0] : (reverseAcks ? [3, 0] : [0, 3])
                        for request in ackOrder {
                            endpoints.completeText(request, with: echoes[request])
                            await sends[request].value
                        }
                        if failurePhase == 3 {
                            for request in failureOrder {
                                endpoints.completeText(request, completion: .failure)
                                await sends[request].value
                            }
                        }
                        let rows = state.messagesByChat[chat] ?? []
                        let failed = rows.filter { $0.id < 0 && $0.receipt_status == "failed" }
                        let context = "count=\(count), failureOrder=\(failureOrder), phase=\(failurePhase), ackOrder=\(ackOrder)"
                        XCTAssertEqual(rows.count, count, context)
                        XCTAssertEqual(failed.count, 1, context)
                        XCTAssertEqual(Set(rows.filter { $0.id > 0 }.map(\.id)),
                            Set((count == 3 ? [99_000, 99_001] : [99_000, 99_001, 99_003]).map(Int64.init)), context)
                        if let failed = failed.first {
                            let retry = Task { await state.retrySend(failed) }
                            await endpoints.waitForTextRequests(count + 1)
                            endpoints.completeText(count, completion: .success)
                            await retry.value
                            XCTAssertEqual(state.messagesByChat[chat]?.count, count, context)
                            XCTAssertFalse(state.messagesByChat[chat]?.contains { $0.id < 0 } ?? true, context)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func testOlderPageProductionMergeKeepsWebSocketPendingAndAuthoritativeRows() async throws {
        let chat = "older-page@s.whatsapp.net"
        let older = [
            runtimeMessage(id: 102, chat: chat, text: "rest owner", timestamp: 42),
            runtimeMessage(id: 101, chat: chat, text: "older equal second", timestamp: 42),
            runtimeMessage(id: 100, chat: chat, text: "oldest", timestamp: 40),
        ]
        let started = expectation(description: "older HTTP page held")
        let transport = MediaCaptureURLProtocol.state
        let encodedRows = try JSONEncoder().encode(older)
        var response = Data("{\"messages\":".utf8)
        response.append(encodedRows)
        response.append(Data("}".utf8))
        transport.prepare(responseData: response, started: started)
        defer { transport.release() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaCaptureURLProtocol.self]
        let api = APIClient(base: try XCTUnwrap(URL(string: "http://127.0.0.1:43123")),
            token: "page-test", sessionConfiguration: configuration)
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockTextSend = true
        endpoints.messagePages[chat] = [
            runtimeMessage(id: 103, chat: chat, text: "current", timestamp: 42),
            runtimeMessage(id: 102, chat: chat, text: "stale owner", timestamp: 42),
        ]
        let client = makeAppRuntimeClient(endpoints, api: api)
        let state = AppState(runtimeClient: client, pendingMessageTimestamp: { 43 })
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [])
        await initial.value
        await state.previewChat(chat)
        let send = Task { await state.send("local pending", in: chat) }
        await endpoints.waitForTextRequests(1)
        let load = Task { await state.loadOlderMessages(for: chat) }
        await fulfillment(of: [started], timeout: 2)
        endpoints.emitEvent(.messageReceived(runtimeMessage(id: 104, chat: chat, text: "ws newer", timestamp: 42)))
        for _ in 0..<20 { await Task.yield() }
        transport.release()
        await load.value
        let rows = state.messagesByChat[chat] ?? []
        XCTAssertEqual(rows.map(\.id), [100, 101, 102, 103, 104, -1])
        XCTAssertEqual(rows.first { $0.id == 102 }?.text, "rest owner")
        XCTAssertEqual(rows.last?.text, "local pending")
        let request = try XCTUnwrap(transport.capturedRequest)
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "before" }?.value, "42,102")
        endpoints.completeText(0, completion: .failure)
        await send.value
    }

    func testOlderPageMergePerformanceComparison() {
        for count in [300, 10_000] {
            for pageCount in [50, 200] {
                let chat = "merge-benchmark@s.whatsapp.net"
                var current = (1...count).map {
                    runtimeMessage(id: Int64($0 + pageCount), chat: chat, text: "row", timestamp: Int64(($0 + pageCount) / 5))
                }
                current.append(runtimeMessage(id: -1, chat: chat, text: "pending", fromMe: true, timestamp: Int64(count + pageCount)))
                let page = (1...pageCount).reversed().map {
                    runtimeMessage(id: Int64($0), chat: chat, text: "older", timestamp: Int64($0 / 5))
                }
                let iterations = count == 300 ? 100 : 20
                var before: [Double] = []
                var after: [Double] = []
                var checksum = 0
                for sample in 0..<7 {
                    // Alternate order within each pair to reduce thermal/order bias.
                    for linear in (sample.isMultiple(of: 2) ? [false, true] : [true, false]) {
                        let start = ContinuousClock.now
                        for _ in 0..<iterations {
                            let rows: [Message]
                            if linear {
                                rows = MessageTimelineOrder.mergingOlderPage(page, into: current)
                            } else {
                                let pageIDs = Set(page.map(\.id))
                                let kept = current.filter { !pageIDs.contains($0.id) }
                                rows = MessageTimelineOrder.ordered(page + kept)
                            }
                            checksum += rows.count
                            XCTAssertEqual(rows.first?.id, 1)
                            XCTAssertEqual(rows.last?.id, -1)
                        }
                        let elapsed = start.duration(to: .now)
                        let milliseconds = (Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15) / Double(iterations)
                        if linear { after.append(milliseconds) } else { before.append(milliseconds) }
                    }
                }
                XCTAssertEqual(checksum, 14 * iterations * (count + pageCount + 1))
                XCTAssertEqual(MessageTimelineOrder.mergingOlderPage(page, into: current),
                    MessageTimelineOrder.ordered(page + current))
                print("FINAL_FIX_MERGE_PAIRED window=\(count) page=\(pageCount) iterations=\(iterations) before_median_ms=\(before.sorted()[3]) after_median_ms=\(after.sorted()[3]) before_samples_ms=\(before) after_samples_ms=\(after)")
            }
        }
    }

    @MainActor
    func testPreviewMergeRetainsNewerSameSecondWebSocketRow() async {
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [])
        await initial.value
        let chat = "same-second@s.whatsapp.net"
        endpoints.blockMessageLoads = true
        let preview = Task { await state.previewChat(chat) }
        await endpoints.waitForMessageRequests(1)
        endpoints.emitEvent(.messageReceived(runtimeMessage(id: 102, chat: chat, text: "ws newer", timestamp: 42)))
        endpoints.emitEvent(.messageReceived(runtimeMessage(id: 99, chat: chat, text: "stale local", timestamp: 42)))
        for _ in 0..<20 { await Task.yield() }
        endpoints.completeMessage(0, with: [runtimeMessage(id: 101, chat: chat, text: "rest", timestamp: 42)])
        await preview.value
        XCTAssertEqual(state.messagesByChat[chat]?.map(\.id), [101, 102])
        XCTAssertEqual(state.messagesByChat[chat]?.map(\.text), ["rest", "ws newer"])
    }

    @MainActor
    func testThreeSendEchoFirstThenTwoFailuresStillRestoresBothFailedRows() async {
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockTextSend = true
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(
            runtimeClient: client,
            pendingMessageTimestamp: { 42 }
        )
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [])
        await initial.value
        let chat = "echo-first-three-failures@s.whatsapp.net"
        await state.previewChat(chat)

        var sends: [Task<Void, Never>] = []
        for request in 0..<3 {
            sends.append(Task { await state.send("identical", in: chat) })
            await endpoints.waitForTextRequests(request + 1)
        }
        let echo = runtimeMessage(
            id: 98_102,
            chat: chat,
            text: "identical",
            fromMe: true,
            timestamp: 42,
            messageID: "echo-first-three-failures",
            senderJID: "self-device@s.whatsapp.net"
        )
        endpoints.emitEvent(.messageReceived(echo))
        for _ in 0..<20 { await Task.yield() }
        endpoints.completeText(0, completion: .failure)
        await sends[0].value
        endpoints.completeText(1, completion: .failure)
        await sends[1].value
        endpoints.completeText(2, with: echo)
        await sends[2].value

        let rows = state.messagesByChat[chat] ?? []
        XCTAssertEqual(rows.filter { $0.id > 0 }.map(\.message_id), [echo.message_id])
        XCTAssertEqual(
            Set(rows.filter { $0.id < 0 && $0.receipt_status == "failed" }.map(\.id)),
            Set([-1, -2])
        )
        XCTAssertEqual(rows.count, 3)
    }

    @MainActor
    func testCrossedTwoEchoesPreserveTheUnlandedThirdFailureInBothTerminalOrders() async {
        for firstAckRequest in 0..<2 {
            for failureCompletesFirst in [true, false] {
                let endpoints = RuntimeEndpointProbe()
                endpoints.blockTextSend = true
                let client = makeAppRuntimeClient(endpoints)
                let state = AppState(
                    runtimeClient: client,
                    pendingMessageTimestamp: { 42 }
                )
                let initial = state.startConnectionRefresh(.initial, client: client)
                await endpoints.waitForChatRequests(1)
                endpoints.completeChat(0, with: [])
                await initial.value
                let order = failureCompletesFirst ? "failure-first" : "ack-first"
                let chat = "crossed-two-echoes-\(firstAckRequest)-\(order)@s.whatsapp.net"
                await state.previewChat(chat)

                var sends: [Task<Void, Never>] = []
                for request in 0..<3 {
                    sends.append(Task { await state.send("identical", in: chat) })
                    await endpoints.waitForTextRequests(request + 1)
                }
                let echoB = runtimeMessage(
                    id: 98_200 + Int64(firstAckRequest * 20 + (failureCompletesFirst ? 0 : 10)),
                    chat: chat,
                    text: "identical",
                    fromMe: true,
                    timestamp: 42,
                    messageID: "crossed-b-\(firstAckRequest)-\(order)",
                    senderJID: "self-device@s.whatsapp.net"
                )
                let echoA = runtimeMessage(
                    id: 98_201 + Int64(firstAckRequest * 20 + (failureCompletesFirst ? 0 : 10)),
                    chat: chat,
                    text: "identical",
                    fromMe: true,
                    timestamp: 42,
                    messageID: "crossed-a-\(firstAckRequest)-\(order)",
                    senderJID: "self-device@s.whatsapp.net"
                )
                endpoints.emitEvent(.messageReceived(echoB))
                endpoints.emitEvent(.messageReceived(echoA))
                for _ in 0..<20 { await Task.yield() }

                let exactMessages = [echoA, echoB]
                let remainingAckRequest = firstAckRequest == 0 ? 1 : 0
                endpoints.completeText(firstAckRequest, with: exactMessages[firstAckRequest])
                await sends[firstAckRequest].value
                if failureCompletesFirst {
                    endpoints.completeText(2, completion: .failure)
                    await sends[2].value
                    endpoints.completeText(remainingAckRequest, with: exactMessages[remainingAckRequest])
                    await sends[remainingAckRequest].value
                } else {
                    endpoints.completeText(remainingAckRequest, with: exactMessages[remainingAckRequest])
                    await sends[remainingAckRequest].value
                    endpoints.completeText(2, completion: .failure)
                    await sends[2].value
                }

                let rows = state.messagesByChat[chat] ?? []
                XCTAssertEqual(
                    Set(rows.filter { $0.id > 0 }.map(\.message_id)),
                    Set([echoA.message_id, echoB.message_id])
                )
                XCTAssertEqual(
                    rows.filter { $0.id == -3 && $0.receipt_status == "failed" }.count,
                    1,
                    "crossed provisional ownership must not consume the only unlanded send"
                )
                XCTAssertEqual(rows.count, 3)
            }
        }
    }

    @MainActor
    func testFourSendCrossedEchoChainPreservesTheOnlyUnlandedFailure() async {
        for failureCompletesFirst in [true, false] {
            let endpoints = RuntimeEndpointProbe()
            endpoints.blockTextSend = true
            let client = makeAppRuntimeClient(endpoints)
            let state = AppState(
                runtimeClient: client,
                pendingMessageTimestamp: { 42 }
            )
            let initial = state.startConnectionRefresh(.initial, client: client)
            await endpoints.waitForChatRequests(1)
            endpoints.completeChat(0, with: [])
            await initial.value
            let order = failureCompletesFirst ? "failure-first" : "ack-first"
            let chat = "crossed-four-\(order)@s.whatsapp.net"
            await state.previewChat(chat)

            var sends: [Task<Void, Never>] = []
            for request in 0..<4 {
                sends.append(Task { await state.send("identical", in: chat) })
                await endpoints.waitForTextRequests(request + 1)
            }
            let echoB = runtimeMessage(
                id: failureCompletesFirst ? 98_300 : 98_310,
                chat: chat,
                text: "identical",
                fromMe: true,
                timestamp: 42,
                messageID: "crossed-four-b-\(order)"
            )
            let echoC = runtimeMessage(
                id: failureCompletesFirst ? 98_301 : 98_311,
                chat: chat,
                text: "identical",
                fromMe: true,
                timestamp: 42,
                messageID: "crossed-four-c-\(order)"
            )
            let echoA = runtimeMessage(
                id: failureCompletesFirst ? 98_302 : 98_312,
                chat: chat,
                text: "identical",
                fromMe: true,
                timestamp: 42,
                messageID: "crossed-four-a-\(order)"
            )
            endpoints.emitEvent(.messageReceived(echoB))
            endpoints.emitEvent(.messageReceived(echoC))
            endpoints.emitEvent(.messageReceived(echoA))
            for _ in 0..<20 { await Task.yield() }

            if failureCompletesFirst {
                endpoints.completeText(3, completion: .failure)
                await sends[3].value
            }
            endpoints.completeText(0, with: echoA)
            await sends[0].value
            endpoints.completeText(1, with: echoB)
            await sends[1].value
            endpoints.completeText(2, with: echoC)
            await sends[2].value
            if !failureCompletesFirst {
                endpoints.completeText(3, completion: .failure)
                await sends[3].value
            }

            let rows = state.messagesByChat[chat] ?? []
            XCTAssertEqual(
                Set(rows.filter { $0.id > 0 }.map(\.message_id)),
                Set([echoA.message_id, echoB.message_id, echoC.message_id])
            )
            XCTAssertEqual(
                rows.filter { $0.id == -4 && $0.receipt_status == "failed" }.count,
                1
            )
            XCTAssertEqual(rows.count, 4)
        }
    }

    @MainActor
    func testChatRemovalTombstonesLateSuccessWithoutDeletingANewerSameChatSend() async {
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockTextSend = true
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [])
        await initial.value
        let chat = "removed-success@s.whatsapp.net"
        await state.previewChat(chat)

        let removedSend = Task { await state.send("removed operation", in: chat) }
        await endpoints.waitForTextRequests(1)
        endpoints.emitEvent(.chatRemoved(chat))
        await waitUntil { state.messagesByChat[chat] == nil }

        let currentSend = Task { await state.send("current operation", in: chat) }
        await endpoints.waitForTextRequests(2)
        XCTAssertEqual(state.messagesByChat[chat]?.filter { $0.id < 0 }.map(\.id), [-2])

        let removedDurable = runtimeMessage(
            id: 98_400,
            chat: chat,
            text: "removed operation",
            fromMe: true,
            messageID: "removed-success-old"
        )
        endpoints.completeText(0, with: removedDurable)
        await removedSend.value
        XCTAssertEqual(state.messagesByChat[chat]?.filter { $0.id < 0 }.map(\.id), [-2])
        XCTAssertFalse(state.messagesByChat[chat]?.contains { $0.id == removedDurable.id } ?? false)
        XCTAssertEqual(state.chats.first { $0.jid == chat }?.last_preview, "current operation")
        XCTAssertNil(state.toast)

        let currentDurable = runtimeMessage(
            id: 98_401,
            chat: chat,
            text: "current operation",
            fromMe: true,
            messageID: "removed-success-current"
        )
        endpoints.completeText(1, with: currentDurable)
        await currentSend.value
        XCTAssertEqual(state.messagesByChat[chat]?.map(\.id), [currentDurable.id])
    }

    @MainActor
    func testChatRemovalTombstonesLateSuccessBeforeItCanResurrectChat() async {
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockTextSend = true
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [])
        await initial.value
        let chat = "removed-resurrection@s.whatsapp.net"
        await state.previewChat(chat)

        let send = Task { await state.send("removed operation", in: chat) }
        await endpoints.waitForTextRequests(1)
        endpoints.emitEvent(.chatRemoved(chat))
        await waitUntil {
            !state.chats.contains { $0.jid == chat } && state.messagesByChat[chat] == nil
        }
        endpoints.completeText(0, with: runtimeMessage(
            id: 98_402,
            chat: chat,
            text: "removed operation",
            fromMe: true,
            messageID: "removed-resurrection"
        ))
        await send.value

        XCTAssertFalse(state.chats.contains { $0.jid == chat })
        XCTAssertNil(state.messagesByChat[chat])
        XCTAssertNil(state.toast)
    }

    @MainActor
    func testChatRemovalTombstonesLateFailureWithoutPublishingToast() async {
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockTextSend = true
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [])
        await initial.value
        let chat = "removed-failure@s.whatsapp.net"
        await state.previewChat(chat)

        let removedSend = Task { await state.send("removed operation", in: chat) }
        await endpoints.waitForTextRequests(1)
        endpoints.emitEvent(.chatRemoved(chat))
        await waitUntil { state.messagesByChat[chat] == nil }
        endpoints.completeText(0, completion: .failure)
        await removedSend.value

        XCTAssertFalse(state.chats.contains { $0.jid == chat })
        XCTAssertNil(state.messagesByChat[chat])
        XCTAssertNil(state.toast, "a removed operation's late failure must stay silent")
    }

    @MainActor
    func testFoldedLIDRemovalTombstonesPhoneAliasTextOperation() async {
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockTextSend = true
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [])
        await initial.value
        let phone = "15551234567@s.whatsapp.net"
        let lid = "123456789012345@lid"
        endpoints.emitEvent(.chatUpdated(runtimeChat(phone, preview: "before send", lid: lid)))
        await waitUntil { state.lid(forChat: phone) == lid }
        await state.previewChat(phone)

        let send = Task { await state.send("folded operation", in: phone) }
        await endpoints.waitForTextRequests(1)
        endpoints.emitEvent(.chatRemoved(lid))
        await waitUntil {
            !(state.messagesByChat[phone]?.contains { $0.id < 0 } ?? false)
        }
        endpoints.completeText(0, with: runtimeMessage(
            id: 98_500,
            chat: phone,
            text: "folded operation",
            fromMe: true,
            messageID: "folded-late-success"
        ))
        await send.value

        XCTAssertFalse(state.messagesByChat[phone]?.contains { $0.id == 98_500 } ?? false)
        XCTAssertNil(state.toast)
    }

    @MainActor
    func testLateTextSuccessAfterExplicitLogoutCannotRepublishClearedSession() async {
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockTextSend = true
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let chat = "stale-success@s.whatsapp.net"
        await state.previewChat(chat)
        let send = Task { await state.send("old account", in: chat) }
        await endpoints.waitForTextRequests(1)

        await state.logout(restartSidecar: {})
        XCTAssertTrue(state.chats.isEmpty)
        XCTAssertTrue(state.messagesByChat.isEmpty)
        endpoints.completeText(0, with: runtimeMessage(
            id: 99_001,
            chat: chat,
            text: "old account",
            fromMe: true,
            messageID: "stale-success"
        ))
        await send.value

        XCTAssertTrue(state.chats.isEmpty, "a stale success must not recreate an old-account chat")
        XCTAssertTrue(state.messagesByChat.isEmpty)
        XCTAssertNil(state.toast)
    }

    @MainActor
    func testLateTextFailureAfterExplicitLogoutCannotPublishToastOrState() async {
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockTextSend = true
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let chat = "stale-failure@s.whatsapp.net"
        await state.previewChat(chat)
        let send = Task { await state.send("old account", in: chat) }
        await endpoints.waitForTextRequests(1)

        await state.logout(restartSidecar: {})
        endpoints.completeText(0, completion: .failure)
        await send.value

        XCTAssertTrue(state.chats.isEmpty)
        XCTAssertTrue(state.messagesByChat.isEmpty)
        XCTAssertNil(state.toast, "a stale failure must not surface in the logged-out session")
    }

    @MainActor
    func testCancelledTextSendCompletingAfterExplicitLogoutCannotPublish() async {
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockTextSend = true
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let chat = "stale-cancelled@s.whatsapp.net"
        await state.previewChat(chat)
        let send = Task { await state.send("old account", in: chat) }
        await endpoints.waitForTextRequests(1)

        send.cancel()
        await state.logout(restartSidecar: {})
        endpoints.completeText(0, with: runtimeMessage(
            id: 99_002,
            chat: chat,
            text: "old account",
            fromMe: true,
            messageID: "stale-cancelled"
        ))
        await send.value

        XCTAssertTrue(state.chats.isEmpty)
        XCTAssertTrue(state.messagesByChat.isEmpty)
        XCTAssertNil(state.toast)
    }

    @MainActor
    func testCancelledTextSendInCurrentSessionDiscardsExactTempAndProtection() async {
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockTextSend = true
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let chat = "cancelled-current@s.whatsapp.net"
        await state.previewChat(chat)
        let send = Task { await state.send("cancel me", in: chat) }
        await endpoints.waitForTextRequests(1)

        send.cancel()
        endpoints.completeText(0, with: runtimeMessage(
            id: 99_003,
            chat: chat,
            text: "cancel me",
            fromMe: true,
            messageID: "cancelled-current"
        ))
        await send.value

        XCTAssertFalse(state.messagesByChat[chat]?.contains { $0.id < 0 } ?? false)
        XCTAssertFalse(state.messagesByChat[chat]?.contains { $0.id == 99_003 } ?? false)
        XCTAssertNil(state.toast)
        await state.previewChat("cancelled-current-active@s.whatsapp.net")
        for index in 0..<10 {
            await state.previewChat("cancelled-current-pressure-\(index)@s.whatsapp.net")
        }
        XCTAssertNil(state.messagesByChat[chat], "cancellation must release exact cache protection")
    }

    @MainActor
    func testSameClientSessionClearGenerationRejectsLateTextCallbacks() async {
        for completion in [RuntimeCompletion.success, .failure] {
            let endpoints = RuntimeEndpointProbe()
            endpoints.blockTextSend = true
            let client = makeAppRuntimeClient(endpoints)
            let state = AppState(runtimeClient: client)
            let oldChat = "same-client-old@s.whatsapp.net"
            await state.previewChat(oldChat)
            let send = Task { await state.send("old account", in: oldChat) }
            await endpoints.waitForTextRequests(1)

            state.handleConnectionState("logged_out")
            let replacementChat = "same-client-replacement@s.whatsapp.net"
            let replacementRow = runtimeMessage(
                id: 99_200,
                chat: replacementChat,
                text: "replacement account"
            )
            state.chats = [runtimeChat(replacementChat, preview: "replacement account")]
            state.messagesByChat = [replacementChat: [replacementRow]]
            state.toast = nil

            switch completion {
            case .success:
                endpoints.completeText(0, with: runtimeMessage(
                    id: 99_201,
                    chat: oldChat,
                    text: "old account",
                    fromMe: true,
                    messageID: "same-client-stale"
                ))
            case .failure:
                endpoints.completeText(0, completion: .failure)
            }
            await send.value

            XCTAssertEqual(state.chats.map(\.jid), [replacementChat])
            XCTAssertEqual(state.messagesByChat, [replacementChat: [replacementRow]])
            XCTAssertNil(state.toast)
        }
    }

    @MainActor
    func testTextCallbacksFromReplacedClientCannotContaminateReplacementSession() async {
        for completion in [RuntimeCompletion.success, .failure] {
            let oldEndpoints = RuntimeEndpointProbe()
            oldEndpoints.blockTextSend = true
            let oldClient = makeAppRuntimeClient(oldEndpoints)
            let state = AppState(runtimeClient: oldClient)
            let oldChat = "old-client@s.whatsapp.net"
            await state.previewChat(oldChat)
            let send = Task { await state.send("old account", in: oldChat) }
            await oldEndpoints.waitForTextRequests(1)

            let replacementClient = makeAppRuntimeClient(RuntimeEndpointProbe())
            state.installRuntimeClient(replacementClient)
            XCTAssertFalse(
                state.messagesByChat[oldChat]?.contains { $0.id < 0 } ?? false,
                "replacement must prune old-client optimistic rows immediately"
            )
            let replacementChat = "replacement@s.whatsapp.net"
            let replacementRow = runtimeMessage(
                id: 99_100,
                chat: replacementChat,
                text: "replacement account"
            )
            state.chats = [runtimeChat(replacementChat, preview: "replacement account")]
            state.messagesByChat = [replacementChat: [replacementRow]]
            state.toast = nil

            switch completion {
            case .success:
                oldEndpoints.completeText(0, with: runtimeMessage(
                    id: 99_101,
                    chat: oldChat,
                    text: "old account",
                    fromMe: true,
                    messageID: "old-client-success"
                ))
            case .failure:
                oldEndpoints.completeText(0, completion: .failure)
            }
            await send.value

            XCTAssertEqual(state.chats.map(\.jid), [replacementChat])
            XCTAssertEqual(state.messagesByChat, [replacementChat: [replacementRow]])
            XCTAssertNil(state.toast)
        }
    }

    @MainActor
    func testDurableIdentityKeepsSameProtocolIDFromDistinctGroupSenders() async {
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [])
        await initial.value
        let chat = "identity-collision@g.us"
        await state.previewChat(chat)

        endpoints.emitEvent(.messageReceived(runtimeMessage(
            id: 95_001,
            chat: chat,
            text: "first",
            messageID: "sender-reused-id",
            senderJID: "111@s.whatsapp.net"
        )))
        endpoints.emitEvent(.messageReceived(runtimeMessage(
            id: 95_002,
            chat: chat,
            text: "second",
            messageID: "sender-reused-id",
            senderJID: "222@s.whatsapp.net"
        )))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(state.messagesByChat[chat]?.map(\.id), [95_001, 95_002])
    }

    @MainActor
    func testOtherSenderProtocolIDCollisionCannotBlockOwnEchoOrBeRemovedByHTTPAck() async {
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockTextSend = true
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(
            runtimeClient: client,
            pendingMessageTimestamp: { 42 }
        )
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [])
        await initial.value
        let chat = "identity-own-collision@g.us"
        await state.previewChat(chat)
        let other = runtimeMessage(
            id: 96_001,
            chat: chat,
            text: "unrelated",
            messageID: "sender-reused-id",
            senderJID: "111@s.whatsapp.net"
        )
        endpoints.emitEvent(.messageReceived(other))
        for _ in 0..<20 { await Task.yield() }

        let send = Task { await state.send("identical", in: chat) }
        await endpoints.waitForTextRequests(1)
        let ownEcho = runtimeMessage(
            id: 96_002,
            chat: chat,
            text: "identical",
            fromMe: true,
            timestamp: 42,
            messageID: other.message_id,
            senderJID: "self-device@s.whatsapp.net"
        )
        endpoints.emitEvent(.messageReceived(ownEcho))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(state.messagesByChat[chat]?.contains { $0.id < 0 } ?? true)
        XCTAssertEqual(Set(state.messagesByChat[chat]?.map(\.id) ?? []), Set([96_001, 96_002]))

        let ownHTTP = runtimeMessage(
            id: 96_003,
            chat: chat,
            text: "identical",
            fromMe: true,
            timestamp: 42,
            messageID: other.message_id,
            senderJID: "self-phone@s.whatsapp.net"
        )
        endpoints.completeText(0, with: ownHTTP)
        await send.value
        let rows = state.messagesByChat[chat] ?? []
        XCTAssertEqual(rows.filter { $0.id == other.id }.count, 1, "HTTP ack must preserve the unrelated sender")
        XCTAssertEqual(rows.filter { $0.id == ownHTTP.id }.count, 1)
        XCTAssertEqual(rows.filter { $0.from_me && $0.message_id == ownHTTP.message_id }.count, 1)
        XCTAssertEqual(rows.count, 2)
        print("TASK5_FIX3_IDENTITY sender_collision_rows=2 own_temp_rows=0")
    }

    @MainActor
    func testMoreThanThreeHundredPendingRowsSurviveThenReconciliationShrinksAndUnprotects() async {
        let endpoints = RuntimeEndpointProbe()
        endpoints.blockTextSend = true
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let chat = "pending-overflow@s.whatsapp.net"
        endpoints.messagePages[chat] = (10_001...10_005).map {
            runtimeMessage(id: Int64($0), chat: chat, text: "durable-\($0)")
        }
        await state.previewChat(chat)

        var sends: [Task<Void, Never>] = []
        for index in 0..<301 {
            sends.append(Task { await state.send("pending-\(index)", in: chat) })
            await endpoints.waitForTextRequests(index + 1)
        }
        await state.previewChat("overflow-active@s.whatsapp.net")

        XCTAssertEqual(state.messagesByChat[chat]?.filter { $0.id < 0 }.count, 301)
        XCTAssertEqual(state.messagesByChat[chat]?.count, 301)

        for index in 0..<301 {
            endpoints.completeText(index, completion: .success)
        }
        for send in sends { await send.value }

        XCTAssertEqual(state.messagesByChat[chat]?.count, 300)
        XCTAssertFalse(state.messagesByChat[chat]?.contains { $0.id < 0 } ?? true)
        for index in 0..<10 {
            await state.previewChat("post-overflow-\(index)@s.whatsapp.net")
        }
        XCTAssertEqual(state.messagesByChat.count, 10)
        XCTAssertNil(state.messagesByChat[chat], "all 301 protection entries must be cleared")
        print("TASK5_FIX1_PENDING_OVERFLOW pending_before=301 rows_after_reconcile=300 retained_chats_after_pressure=10")
    }

    @MainActor
    func testBlockedFailedPreviewsWithSelectedIncomingStayBoundedAndKeepDeterministicRecency() async {
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [])
        await initial.value
        endpoints.blockMessageLoads = true

        let chats = (0..<15).map { "blocked-\($0)@s.whatsapp.net" }
        var previews: [Task<Void, Never>] = []
        for (index, chat) in chats.enumerated() {
            previews.append(Task { await state.previewChat(chat) })
            await endpoints.waitForMessageRequests(index + 1)
            endpoints.emitEvent(.messageReceived(runtimeMessage(
                id: Int64(index + 1),
                chat: chat,
                text: "selected incoming"
            )))
            for _ in 0..<20 { await Task.yield() }
            XCTAssertNotNil(state.messagesByChat[chat])
        }

        XCTAssertEqual(state.messagesByChat.count, 10)
        XCTAssertEqual(Set(state.messagesByChat.keys), Set(chats.suffix(10)))
        XCTAssertNotNil(state.messagesByChat[chats.last!], "the selected chat cannot be evicted")
        for index in previews.indices { endpoints.failMessage(index) }
        for preview in previews { await preview.value }

        let oldestRetained = chats[5]
        let retouch = Task { await state.previewChat(oldestRetained) }
        await endpoints.waitForMessageRequests(16)
        endpoints.failMessage(15)
        await retouch.value

        for index in 16..<26 {
            let empty = Task { await state.previewChat("empty-failure-\(index)@s.whatsapp.net") }
            await endpoints.waitForMessageRequests(index + 1)
            endpoints.failMessage(index)
            await empty.value
        }

        let newest = "blocked-15@s.whatsapp.net"
        let newestPreview = Task { await state.previewChat(newest) }
        await endpoints.waitForMessageRequests(27)
        endpoints.emitEvent(.messageReceived(runtimeMessage(
            id: 16,
            chat: newest,
            text: "new selected incoming"
        )))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(state.messagesByChat.count, 10)
        XCTAssertNotNil(state.messagesByChat[oldestRetained], "reselecting a loaded chat must retouch it")
        XCTAssertNil(state.messagesByChat[chats[6]], "failed empty previews must not perturb LRU order")
        XCTAssertNotNil(state.messagesByChat[newest], "the selected allocation cannot be evicted")
        print("TASK5_FIX1_SELECTION_PROXY selected_incoming_chats=15 retained_chats=10 empty_failed_previews=10 deterministic_victim=blocked-6")
        endpoints.failMessage(26)
        await newestPreview.value
    }

    @MainActor
    func testPositiveEventsForNeverLoadedNonSelectedChatDoNotAllocateTranscript() async {
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        let muted = runtimeChat("unloaded@s.whatsapp.net", muted: true)
        endpoints.completeChat(0, with: [muted])
        await initial.value

        let message = runtimeMessage(
            id: 9,
            chat: muted.jid,
            text: "must not allocate"
        )
        endpoints.emitEvent(.messageReceived(message))
        endpoints.emitEvent(.messageUpdated(message))
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertNil(state.messagesByChat[muted.jid])
    }

    @MainActor
    func testProductionBadgeSinkRunsForSuccessfulRefreshReadFocusFilterAndClearOnly() async {
        let endpoints = RuntimeEndpointProbe()
        let badge = DockBadgeProbe()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client, dockBadgeSink: { badge.record($0) })
        let originalFocusMode = state.focusMode
        defer { state.focusMode = originalFocusMode }
        state.focusMode = false

        let first = Task { await state.refreshChats() }
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [runtimeChat("read@s.whatsapp.net", unread: 3)])
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
        XCTAssertEqual(badge.labels, ["3"])

        let failed = Task { await state.refreshChats() }
        await endpoints.waitForChatRequests(2)
        endpoints.failChat(1)
        let failedResult = await failed.value
        XCTAssertFalse(failedResult)
        XCTAssertEqual(badge.labels, ["3"], "failed authoritative refresh must not reduce the badge")

        await state.commitRead("read@s.whatsapp.net", source: .mouse)
        XCTAssertEqual(endpoints.markReadChats, ["read@s.whatsapp.net"])
        XCTAssertEqual(badge.labels, ["3", nil])

        state.toggleFocusMode()
        XCTAssertEqual(badge.labels.count, 3)

        let filtered = Task { await state.applyFilter("unread") }
        await endpoints.waitForChatRequests(3)
        endpoints.completeChat(2, with: [])
        await filtered.value
        XCTAssertEqual(badge.labels.count, 4)

        state.handleConnectionState("logged_out")
        XCTAssertEqual(badge.labels, ["3", nil, nil, nil, nil])
    }

    @MainActor
    func testProductionApplyConsumesBadgeClassificationAndIrrelevantStormCostsZeroCalls() async {
        let endpoints = RuntimeEndpointProbe()
        let badge = DockBadgeProbe()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client, dockBadgeSink: { badge.record($0) })
        let originalFocusMode = state.focusMode
        defer { state.focusMode = originalFocusMode }
        state.focusMode = false
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [runtimeChat("a@s.whatsapp.net", unread: 1)])
        await initial.value
        badge.reset()

        let message = runtimeMessage(id: 1, chat: "a@s.whatsapp.net", text: "receipt")
        let media = MessageMedia(
            id: "media",
            kind: "image",
            mime: "image/png",
            size: 1,
            filename: nil,
            state: "downloaded",
            local_path: nil
        )
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            for index in 0..<1_000 {
                switch index % 3 {
                case 0: endpoints.emitEvent(.messageUpdated(message))
                case 1: endpoints.emitEvent(.reaction(rowid: 1, emoji: "thumb"))
                default:
                    endpoints.emitEvent(.mediaUpdated(
                        rowid: 1,
                        chat: "a@s.whatsapp.net",
                        media: media
                    ))
                }
            }
            for _ in 0..<40 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(150))
        }
        XCTAssertEqual(badge.labels.count, 0)
        XCTAssertNil(state.messagesByChat[message.chat_jid])
        print("TASK5_BADGE_STORM events=1000 badge_calls=\(badge.labels.count) elapsed=\(elapsed)")

        state.selectedChat = message.chat_jid
        endpoints.emitEvent(.messageReceived(message))
        await waitUntil { badge.labels.count == 1 }
        endpoints.emitEvent(.messageReceived(runtimeMessage(
            id: 2,
            chat: message.chat_jid,
            text: "own",
            fromMe: true
        )))
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(badge.labels.count, 1)

        endpoints.emitEvent(.chatUpdated(runtimeChat(message.chat_jid, unread: 2)))
        endpoints.emitEvent(.chatRemoved(message.chat_jid))
        await waitUntil { badge.labels.count == 3 }
        XCTAssertEqual(badge.labels, ["1", "2", nil])
    }

    @MainActor
    func testIncomingEventDuringAuthoritativeRefreshKeepsNewestUnreadBadgeState() async {
        let endpoints = RuntimeEndpointProbe()
        let badge = DockBadgeProbe()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client, dockBadgeSink: { badge.record($0) })
        let originalFocusMode = state.focusMode
        defer { state.focusMode = originalFocusMode }
        state.focusMode = false
        let chat = "interleave@s.whatsapp.net"
        state.selectedChat = chat

        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.emitEvent(.messageReceived(runtimeMessage(
            id: 10,
            chat: chat,
            text: "arrived during fetch"
        )))
        await waitUntil { badge.labels.count == 1 }

        endpoints.completeChat(0, with: [runtimeChat(chat, unread: 0, preview: "stale")])
        await initial.value

        XCTAssertEqual(state.chats.first?.unread_count, 1)
        XCTAssertEqual(badge.labels, ["1", "1"])
    }

    func testPongSendCompletesBeforeHeartbeatAndNextReceive() async {
        let probe = SocketProbe()
        let task = FakeWebSocketTask(
            frames: [.success(.text(#"{"type":"ping"}"#)), .failure(FakeSocketError.finished)],
            probe: probe
        )
        let pump = WebSocketEventPump(
            task: task,
            onEvent: { _ in await probe.record("event") },
            onHeartbeat: { await probe.record("heartbeat") },
            onDisconnect: { await probe.record("disconnect") }
        )

        let completion = await pump.start()
        await completion.value
        let entries = await probe.entries()

        XCTAssertEqual(entries, ["start", "receive", "send:pong", "heartbeat", "receive", "cancel", "disconnect"])
    }

    func testPumpStartsTransportOnceBeforeItsFirstReceive() async {
        let probe = SocketProbe()
        let task = FakeWebSocketTask(
            frames: [.failure(FakeSocketError.finished)],
            probe: probe
        )
        let pump = WebSocketEventPump(
            task: task,
            onEvent: { _ in await probe.record("event") },
            onHeartbeat: { await probe.record("heartbeat") },
            onDisconnect: { await probe.record("disconnect") }
        )

        let firstCompletion = await pump.start()
        let secondCompletion = await pump.start()
        await firstCompletion.value
        await secondCompletion.value

        let entries = await probe.entries()
        XCTAssertEqual(entries, ["start", "receive", "cancel", "disconnect"])
    }

    func testFailedPongCancelsOnceDisconnectsOnceAndDoesNotReceiveAgain() async {
        let probe = SocketProbe()
        let task = FakeWebSocketTask(
            frames: [.success(.text(#"{"type":"ping"}"#)), .success(.text(#"{"type":"ping"}"#))],
            failsSend: true,
            probe: probe
        )
        let pump = WebSocketEventPump(
            task: task,
            onEvent: { _ in await probe.record("event") },
            onHeartbeat: { await probe.record("heartbeat") },
            onDisconnect: { await probe.record("disconnect") }
        )

        let completion = await pump.start()
        await completion.value
        let entries = await probe.entries()

        XCTAssertEqual(entries, ["start", "receive", "send:pong", "cancel", "disconnect"])
    }

    func testLifecycleCoalescesDuplicateDisconnectsForCurrentGeneration() {
        var lifecycle = WebSocketLifecycle()
        let generation = lifecycle.replaceConnection()

        XCTAssertTrue(lifecycle.shouldScheduleReconnect(for: generation))
        XCTAssertFalse(lifecycle.shouldScheduleReconnect(for: generation))
    }

    func testLifecycleRejectsStaleGenerationActivityAndDisconnect() {
        var lifecycle = WebSocketLifecycle()
        let oldGeneration = lifecycle.replaceConnection()
        let currentGeneration = lifecycle.replaceConnection()

        XCTAssertFalse(lifecycle.acceptsActivity(for: oldGeneration))
        XCTAssertFalse(lifecycle.shouldScheduleReconnect(for: oldGeneration))
        XCTAssertTrue(lifecycle.acceptsActivity(for: currentGeneration))
    }

    func testDisconnectInvalidatesBlockedReplacementBeforeItCanInstall() async {
        let first = ControlledWebSocketTask(name: "first")
        let replacement = ControlledWebSocketTask(name: "replacement", blocksStart: true)
        let factory = OrderedWebSocketTaskFactory([first, replacement])
        let client = APIClient(
            base: URL(string: "http://127.0.0.1:9999")!,
            token: "test",
            webSocketTaskFactory: factory.make
        )

        await client.connectEvents(onEvent: { _ in })
        let connecting = Task {
            await client.connectEvents(onEvent: { _ in })
        }
        await replacement.waitUntilStart()

        await client.disconnectEvents()
        await replacement.releaseStart()
        await connecting.value
        await replacement.waitUntilCancel()

        let firstOperations = await first.operations()
        let replacementOperations = await replacement.operations()
        XCTAssertEqual(firstOperations, ["start", "cancel"])
        XCTAssertEqual(replacementOperations, ["start", "cancel"])
        XCTAssertEqual(factory.createdCount, 2)
    }

    @MainActor
    func testReconnectEpochRejectsPreGapChatThatFinishesBeforeOrAfterAuthoritativeStep() async {
        for finishesBeforeAuthoritativeStep in [true, false] {
            let endpoints = RuntimeEndpointProbe()
            let reconnectClock = RuntimeClock()
            let contactClock = RuntimeClock()
            let client = makeAppRuntimeClient(endpoints)
            let state = AppState(
                runtimeClient: client,
                contactSleep: { delay in await contactClock.sleep(for: delay) },
                reconnectSleep: { delay in await reconnectClock.sleep(for: delay) }
            )

            let initial = state.startConnectionRefresh(.initial, client: client)
            await endpoints.waitForChatRequests(1)
            endpoints.completeChat(0, with: [runtimeChat("thread", preview: "initial")])
            await initial.value

            let preGap = Task { await state.refreshChats() }
            await endpoints.waitForChatRequests(2)
            endpoints.emitDisconnect()
            await reconnectClock.waitUntilSleeping(for: 0.5)

            if finishesBeforeAuthoritativeStep {
                endpoints.completeChat(1, with: [runtimeChat("thread", preview: "stale")])
                _ = await preGap.value
                XCTAssertEqual(state.chats.first?.last_preview, "initial")
                await reconnectClock.advance(0.5)
            } else {
                await reconnectClock.advance(0.5)
                await endpoints.waitForSessionRequests(2)
                for _ in 0..<8 { await Task.yield() }
                XCTAssertEqual(endpoints.chatFilters, ["all", "all"])
                endpoints.completeChat(1, with: [runtimeChat("thread", preview: "stale")])
                _ = await preGap.value
            }

            await endpoints.waitForChatRequests(3)
            XCTAssertEqual(state.chats.first?.last_preview, "initial", "pre-gap result must never write")
            endpoints.completeChat(2, with: [runtimeChat("thread", preview: "post-gap")])
            await waitUntil { state.chats.first?.last_preview == "post-gap" }
            XCTAssertEqual(state.chats.first?.last_preview, "post-gap")

            XCTAssertEqual(endpoints.chatFilters, ["all", "all", "all"])
            XCTAssertEqual(
                endpoints.refreshEndpointCalls,
                ["session", "events", "chats:all", "chats:all", "events", "session", "chats:all"]
            )
        }
    }

    @MainActor
    func testStalePollDuringReconnectBackoffQueuesAndSharesAuthoritativeFetch() async {
        let endpoints = RuntimeEndpointProbe()
        let reconnectClock = RuntimeClock()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(
            runtimeClient: client,
            reconnectSleep: { delay in await reconnectClock.sleep(for: delay) }
        )
        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)
        endpoints.completeChat(0, with: [runtimeChat("initial")])
        await initial.value

        endpoints.emitDisconnect()
        await reconnectClock.waitUntilSleeping(for: 0.5)
        let now = Date(timeIntervalSince1970: 20_000)
        state.connectionState = "connected"
        state.lastWSActivityAt = now.addingTimeInterval(-60)

        let action = await state.runRecoveryPoll(now: now)
        XCTAssertEqual(action, .fallback)
        await endpoints.waitForSessionRequests(2)
        XCTAssertEqual(endpoints.chatFilters, ["all"], "poll chat work must wait behind reconnect authority")

        await reconnectClock.advance(0.5)
        await endpoints.waitForChatRequests(2)
        endpoints.completeChat(1, with: [runtimeChat("post-gap")])
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(endpoints.chatFilters, ["all", "all"])
        XCTAssertEqual(
            endpoints.refreshEndpointCalls,
            ["session", "events", "chats:all", "session", "events", "session", "chats:all"]
        )
    }

    @MainActor
    func testFilterChangesDuringChatRequestQueueOnlyLatestFilterAndNeverMisapplyAll() async {
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        state.chats = [runtimeChat("local")]

        let allRequest = Task { await state.refreshChats() }
        await endpoints.waitForChatRequests(1)
        let unreadRequest = Task { await state.applyFilter("unread") }
        await waitUntil { state.chatFilter == "unread" }
        let mentionsRequest = Task { await state.applyFilter("mentions") }
        await waitUntil { state.chatFilter == "mentions" }

        endpoints.completeChat(0, with: [runtimeChat("all-only")])
        _ = await allRequest.value
        await endpoints.waitForChatRequests(2)
        XCTAssertEqual(state.chatFilter, "mentions")
        XCTAssertEqual(state.chats.map(\.jid), ["local"], "an all response cannot populate a filtered view")

        endpoints.completeChat(1, with: [runtimeChat("mention-only", unread: 2)])
        await unreadRequest.value
        await mentionsRequest.value
        await waitUntil { state.chats.map(\.jid) == ["mention-only"] }

        XCTAssertEqual(endpoints.chatFilters, ["all", "mentions"])
        XCTAssertEqual(state.serverChats.keys.sorted(), ["all-only"])
    }

    @MainActor
    func testCompatibleChatRefreshesJoinOneProductionEndpointRequest() async {
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)

        let first = Task { await state.refreshChats() }
        await endpoints.waitForChatRequests(1)
        let second = Task { await state.refreshChats() }
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(endpoints.chatFilters, ["all"])

        endpoints.completeChat(0, with: [runtimeChat("joined")])
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(endpoints.chatFilters, ["all"])
        XCTAssertEqual(state.chats.map(\.jid), ["joined"])
    }

    @MainActor
    func testCompatibleCallerJoinsActiveAuthoritativeRequest() async {
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)
        let authoritative = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)

        var joinedCompleted = false
        let joined = Task {
            let result = await state.refreshChats()
            joinedCompleted = true
            return result
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(joinedCompleted)
        XCTAssertEqual(endpoints.chatFilters, ["all"])
        endpoints.completeChat(0, with: [runtimeChat("authoritative")])
        await authoritative.value
        let joinedResult = await joined.value
        XCTAssertTrue(joinedResult)
        XCTAssertEqual(endpoints.chatFilters, ["all"])
    }

    @MainActor
    func testFinalSyncAfterChatLeaseStartsForcesOneTrailingAuthoritativeResponse() async {
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)

        let initial = state.startConnectionRefresh(.initial, client: client)
        await endpoints.waitForChatRequests(1)

        endpoints.emitEvent(.syncProgress(stage: "done", progress: 1))
        await waitUntil { state.lastWSActivityAt != nil }
        for _ in 0..<8 { await Task.yield() }

        endpoints.completeChat(0, with: [runtimeChat("thread", preview: "old")])
        await endpoints.waitForChatRequests(2)
        XCTAssertEqual(state.chats.first?.last_preview, "old")

        endpoints.completeChat(1, with: [runtimeChat("thread", preview: "new")])
        await initial.value
        await waitUntil { state.chats.first?.last_preview == "new" }
        for _ in 0..<8 { await Task.yield() }

        XCTAssertEqual(endpoints.chatFilters, ["all", "all"])
        XCTAssertEqual(state.chats.first?.last_preview, "new")
    }

    @MainActor
    func testSameFilterFreshnessStormKeepsOneTrailingFetchWhenOrdinaryObserverJoins() async {
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(runtimeClient: client)

        let active = Task { await state.refreshChats() }
        await endpoints.waitForChatRequests(1)
        let now = Date(timeIntervalSince1970: 30_000)
        state.connectionState = "connected"
        state.lastWSActivityAt = now.addingTimeInterval(-60)

        let polls = (0..<3).map { _ in
            Task { await state.runRecoveryPoll(now: now) }
        }
        await endpoints.waitForSessionRequests(3)
        for _ in 0..<8 { await Task.yield() }

        let observer = Task { await state.refreshChats() }
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(endpoints.chatFilters, ["all"])

        endpoints.completeChat(0, with: [runtimeChat("thread", preview: "old")])
        let activeResult = await active.value
        let observerResult = await observer.value
        var pollResults: [RecoveryPollAction] = []
        for poll in polls { pollResults.append(await poll.value) }
        XCTAssertTrue(activeResult)
        XCTAssertTrue(observerResult)
        XCTAssertEqual(pollResults, [.fallback, .fallback, .fallback])

        await endpoints.waitForChatRequests(2)
        endpoints.completeChat(1, with: [runtimeChat("thread", preview: "new")])
        await waitUntil { state.chats.first?.last_preview == "new" }
        for _ in 0..<8 { await Task.yield() }

        XCTAssertEqual(endpoints.chatFilters, ["all", "all"])
        XCTAssertEqual(state.chats.first?.last_preview, "new")
    }

    @MainActor
    func testRuntimeReplacementLogoutAndRestartInvalidateBlockedChatWrites() async {
        let replacementEndpoints = RuntimeEndpointProbe()
        let replacement = makeAppRuntimeClient(replacementEndpoints)
        let oldEndpoints = RuntimeEndpointProbe()
        let old = makeAppRuntimeClient(oldEndpoints)
        let replacementState = AppState(runtimeClient: old)
        replacementState.chats = [runtimeChat("baseline")]

        let oldRequest = Task { await replacementState.refreshChats() }
        await oldEndpoints.waitForChatRequests(1)
        replacementState.installRuntimeClient(replacement)
        let replacementRequest = Task { await replacementState.refreshChats() }
        await replacementEndpoints.waitForChatRequests(1)
        replacementEndpoints.completeChat(0, with: [runtimeChat("replacement")])
        let replacementResult = await replacementRequest.value
        XCTAssertTrue(replacementResult)
        oldEndpoints.completeChat(0, with: [runtimeChat("stale")])
        let oldResult = await oldRequest.value
        XCTAssertFalse(oldResult)
        XCTAssertTrue(replacementState.chats.contains { $0.jid == "replacement" })
        XCTAssertFalse(replacementState.chats.contains { $0.jid == "stale" })

        for lifecycle in [RuntimeCancellation.logout, .restart] {
            let endpoints = RuntimeEndpointProbe()
            let client = makeAppRuntimeClient(endpoints)
            let state = AppState(runtimeClient: client)
            state.chats = [runtimeChat("baseline")]
            let request = Task { await state.refreshChats() }
            await endpoints.waitForChatRequests(1)

            switch lifecycle {
            case .logout:
                await state.logout(restartSidecar: {})
                XCTAssertEqual(endpoints.calls.filter { $0 == "logout" }.count, 1)
                XCTAssertEqual(endpoints.calls.filter { $0 == "disconnectEvents" }.count, 1)
            case .restart:
                state.cancelForUnavailableSidecar()
            }
            endpoints.completeChat(0, with: [runtimeChat("stale")])
            let result = await request.value
            XCTAssertFalse(result)
            XCTAssertFalse(state.chats.contains { $0.jid == "stale" }, "\(lifecycle) accepted a stale write")
            if case .logout = lifecycle {
                XCTAssertTrue(state.chats.isEmpty, "logout must retain its normal state clear")
            } else {
                XCTAssertEqual(state.chats.map(\.jid), ["baseline"])
            }
        }
    }

    @MainActor
    func testCapturedStartLinkCannotWriteAfterRuntimeReplacement() async {
        for result in [RuntimeCompletion.success, .failure] {
            let oldEndpoints = RuntimeEndpointProbe()
            oldEndpoints.blockStartLink = true
            let old = makeAppRuntimeClient(oldEndpoints)
            let replacement = makeAppRuntimeClient(RuntimeEndpointProbe())
            let state = AppState(runtimeClient: old)

            let linking = Task { await state.startLogin() }
            await oldEndpoints.waitForStartLinkRequests(1)
            state.installRuntimeClient(replacement)
            oldEndpoints.completeStartLink(result)
            await linking.value

            XCTAssertEqual(state.connectionState, "logged_out")
            XCTAssertNil(state.toast)
        }
    }

    @MainActor
    func testLoggedOutRelinkThenConnectedStartsOneBoundedContactSequence() async {
        let endpoints = RuntimeEndpointProbe()
        let contactClock = RuntimeClock()
        let client = makeAppRuntimeClient(endpoints)
        let state = AppState(
            runtimeClient: client,
            contactSleep: { delay in await contactClock.sleep(for: delay) }
        )

        state.handleConnectionState("logged_out")
        await state.startLogin()
        XCTAssertEqual(state.connectionState, "linking")
        state.handleConnectionState("connected")
        state.handleConnectionState("connected")
        await endpoints.waitForContactRequests(1)
        await contactClock.waitUntilSleeping(for: 45)
        await contactClock.waitUntilSleeping(for: 180)
        XCTAssertEqual(endpoints.contactRequestCount, 1)

        await contactClock.advance(45)
        await endpoints.waitForContactRequests(2)
        await contactClock.advance(180)
        await endpoints.waitForContactRequests(3)

        XCTAssertEqual(endpoints.contactRequestCount, 3)
        XCTAssertEqual(endpoints.startLinkRequestCount, 1)
        XCTAssertEqual(state.contactNames["1@s.whatsapp.net"], "One")
    }

    @MainActor
    func testFailedOneShotRecoverySuppressesFreshThenFallsBackForStaleUnprovenAndOffline() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let fallbackCases: [(String, Date?)] = [
            ("connected", now.addingTimeInterval(-60)),
            ("connected", nil),
            ("offline", now),
        ]

        for (connectionState, activity) in fallbackCases {
            let endpoints = RuntimeEndpointProbe()
            let client = makeAppRuntimeClient(endpoints)
            let state = AppState(runtimeClient: client)
            let initial = state.startConnectionRefresh(.initial, client: client)
            await endpoints.waitForChatRequests(1)
            endpoints.failChat(0)
            await initial.value

            state.connectionState = "connected"
            state.lastWSActivityAt = now
            let recovery = Task { await state.runRecoveryPoll(now: now) }
            await endpoints.waitForChatRequests(2)
            endpoints.failChat(1)
            let recoveryResult = await recovery.value
            XCTAssertEqual(recoveryResult, .recoveryChat)

            let callsAfterFailure = endpoints.refreshEndpointCalls
            let freshResult = await state.runRecoveryPoll(now: now)
            XCTAssertEqual(freshResult, .suppressed)
            XCTAssertEqual(endpoints.refreshEndpointCalls, callsAfterFailure)

            state.connectionState = connectionState
            state.lastWSActivityAt = activity
            let fallback = Task { await state.runRecoveryPoll(now: now) }
            await endpoints.waitForChatRequests(3)
            endpoints.completeChat(2, with: [runtimeChat("recovered")])
            let fallbackResult = await fallback.value
            XCTAssertEqual(fallbackResult, .fallback)
            XCTAssertEqual(Array(endpoints.refreshEndpointCalls.suffix(2)), ["session", "chats:all"])
        }
    }

    func testAttachmentLoaderReadsFileWithinLimit() throws {
        let fixture = try TemporaryAttachment(bytes: [1, 2, 3, 4])

        XCTAssertEqual(
            try AttachmentLoader.read(url: fixture.url, maxBytes: 5),
            Data([1, 2, 3, 4])
        )
    }

    func testAttachmentLoaderAcceptsExactByteLimit() throws {
        let fixture = try TemporaryAttachment(bytes: [1, 2, 3, 4])

        XCTAssertEqual(
            try AttachmentLoader.read(url: fixture.url, maxBytes: 4),
            Data([1, 2, 3, 4])
        )
    }

    func testAttachmentLoaderRejectsOversizedMetadataBeforeReadingBytes() {
        let probe = AttachmentIOProbe()
        let access = AttachmentFileAccess(
            startSecurityScopedAccess: { _ in false },
            stopSecurityScopedAccess: { _ in },
            resourceFileSize: { _ in
                probe.recordMetadata()
                return 5
            },
            readData: { _ in
                probe.recordRead()
                return Data([1, 2, 3, 4, 5])
            }
        )

        XCTAssertThrowsError(
            try AttachmentLoader.read(
                url: URL(fileURLWithPath: "/oversized.bin"),
                maxBytes: 4,
                fileAccess: access
            )
        ) { error in
            XCTAssertEqual(error as? AttachmentReadError, .tooLarge(actual: 5, limit: 4))
        }
        XCTAssertEqual(probe.metadataCount, 1)
        XCTAssertEqual(probe.readCount, 0, "metadata rejection must avoid byte I/O")
    }

    func testAttachmentLoaderReportsMissingFileAsUnreadable() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        XCTAssertThrowsError(try AttachmentLoader.read(url: missing, maxBytes: 4)) { error in
            XCTAssertEqual(error as? AttachmentReadError, .unreadable)
        }
    }

    func testAttachmentLoaderRechecksActualBytesWhenMetadataLies() {
        let probe = AttachmentIOProbe()
        let access = AttachmentFileAccess(
            startSecurityScopedAccess: { _ in false },
            stopSecurityScopedAccess: { _ in },
            resourceFileSize: { _ in
                probe.recordMetadata()
                return 3
            },
            readData: { _ in
                probe.recordRead()
                return Data([1, 2, 3, 4, 5])
            }
        )

        XCTAssertThrowsError(
            try AttachmentLoader.read(
                url: URL(fileURLWithPath: "/changed-after-metadata.bin"),
                maxBytes: 4,
                fileAccess: access
            )
        ) { error in
            XCTAssertEqual(error as? AttachmentReadError, .tooLarge(actual: 5, limit: 4))
        }
        XCTAssertEqual(probe.metadataCount, 1)
        XCTAssertEqual(probe.readCount, 1)
    }

    @MainActor
    func testAsyncAttachmentLoadRunsResourceLookupAndDataReadOffMainThread() async throws {
        let fixture = try TemporaryAttachment(bytes: [1, 2, 3, 4])
        let probe = AttachmentIOProbe()
        let access = AttachmentFileAccess(
            startSecurityScopedAccess: { _ in
                probe.recordSecurityStart()
                return true
            },
            stopSecurityScopedAccess: { _ in probe.recordSecurityStop() },
            resourceFileSize: { url in
                probe.recordMetadata()
                guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    throw AttachmentReadError.unreadable
                }
                return Int64(size)
            },
            readData: { url in
                probe.recordRead()
                return try Data(contentsOf: url, options: .mappedIfSafe)
            }
        )

        let data = try await AttachmentLoader.load(
            url: fixture.url,
            maxBytes: 4,
            fileAccess: access
        )

        XCTAssertEqual(data, Data([1, 2, 3, 4]))
        XCTAssertEqual(probe.mainThreadPhases, [])
        XCTAssertEqual(probe.securityStartCount, 1)
        XCTAssertEqual(probe.securityStopCount, 1)
        XCTAssertEqual(probe.metadataCount, 1)
        XCTAssertEqual(probe.readCount, 1)
    }

    @MainActor
    func testAsyncAttachmentLoadBalancesSecurityScopeOnMetadataRejection() async {
        let probe = AttachmentIOProbe()
        let access = AttachmentFileAccess(
            startSecurityScopedAccess: { _ in
                probe.recordSecurityStart()
                return true
            },
            stopSecurityScopedAccess: { _ in probe.recordSecurityStop() },
            resourceFileSize: { _ in
                probe.recordMetadata()
                return 5
            },
            readData: { _ in
                probe.recordRead()
                return Data()
            }
        )

        do {
            _ = try await AttachmentLoader.load(
                url: URL(fileURLWithPath: "/oversized-scoped.bin"),
                maxBytes: 4,
                fileAccess: access
            )
            XCTFail("expected metadata rejection")
        } catch {
            XCTAssertEqual(error as? AttachmentReadError, .tooLarge(actual: 5, limit: 4))
        }

        XCTAssertEqual(probe.securityStartCount, 1)
        XCTAssertEqual(probe.securityStopCount, 1)
        XCTAssertEqual(probe.readCount, 0)
        XCTAssertEqual(probe.mainThreadPhases, [])
    }

    @MainActor
    func testAsyncAttachmentLoadForwardsOuterCancellationAndBalancesSecurityScope() async {
        let started = expectation(description: "detached read started")
        let blockedRead = BlockingAttachmentRead(
            data: Data([1, 2, 3, 4]),
            started: started
        )
        let probe = AttachmentIOProbe()
        let access = AttachmentFileAccess(
            startSecurityScopedAccess: { _ in
                probe.recordSecurityStart()
                return true
            },
            stopSecurityScopedAccess: { _ in probe.recordSecurityStop() },
            resourceFileSize: { _ in
                probe.recordMetadata()
                return 4
            },
            readData: { url in
                probe.recordRead()
                return try blockedRead.read(url)
            }
        )
        let outer = Task {
            try await AttachmentLoader.load(
                url: URL(fileURLWithPath: "/cancelled-scoped.bin"),
                maxBytes: 4,
                fileAccess: access
            )
        }
        await fulfillment(of: [started], timeout: 2)

        outer.cancel()
        blockedRead.release()

        do {
            _ = try await outer.value
            XCTFail("cancelled loader must not return bytes")
        } catch is CancellationError {
            // Expected: cancellation reaches the detached production operation.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(probe.securityStartCount, 1)
        XCTAssertEqual(probe.securityStopCount, 1)
        XCTAssertEqual(probe.metadataCount, 1)
        XCTAssertEqual(probe.readCount, 1)
    }

    @MainActor
    func testAsyncAttachmentLoadBalancesSecurityScopeOnReadError() async {
        let probe = AttachmentIOProbe()
        let access = AttachmentFileAccess(
            startSecurityScopedAccess: { _ in
                probe.recordSecurityStart()
                return true
            },
            stopSecurityScopedAccess: { _ in probe.recordSecurityStop() },
            resourceFileSize: { _ in
                probe.recordMetadata()
                return 4
            },
            readData: { _ in
                probe.recordRead()
                throw AttachmentAccessFailure.readFailed
            }
        )

        do {
            _ = try await AttachmentLoader.load(
                url: URL(fileURLWithPath: "/unreadable-scoped.bin"),
                maxBytes: 4,
                fileAccess: access
            )
            XCTFail("expected read failure")
        } catch {
            XCTAssertEqual(error as? AttachmentReadError, .unreadable)
        }
        XCTAssertEqual(probe.securityStartCount, 1)
        XCTAssertEqual(probe.securityStopCount, 1)
        XCTAssertEqual(probe.metadataCount, 1)
        XCTAssertEqual(probe.readCount, 1)
    }

    @MainActor
    func testAsyncAttachmentLoadBalancesSecurityScopeOnPostReadOversize() async {
        let probe = AttachmentIOProbe()
        let access = AttachmentFileAccess(
            startSecurityScopedAccess: { _ in
                probe.recordSecurityStart()
                return true
            },
            stopSecurityScopedAccess: { _ in probe.recordSecurityStop() },
            resourceFileSize: { _ in
                probe.recordMetadata()
                return 4
            },
            readData: { _ in
                probe.recordRead()
                return Data([1, 2, 3, 4, 5])
            }
        )

        do {
            _ = try await AttachmentLoader.load(
                url: URL(fileURLWithPath: "/changed-scoped.bin"),
                maxBytes: 4,
                fileAccess: access
            )
            XCTFail("expected post-read size rejection")
        } catch {
            XCTAssertEqual(error as? AttachmentReadError, .tooLarge(actual: 5, limit: 4))
        }
        XCTAssertEqual(probe.securityStartCount, 1)
        XCTAssertEqual(probe.securityStopCount, 1)
        XCTAssertEqual(probe.metadataCount, 1)
        XCTAssertEqual(probe.readCount, 1)
    }

    @MainActor
    func testAsyncAttachmentLoadReadsWhenSecurityScopeCannotStartWithoutStopping() async throws {
        let probe = AttachmentIOProbe()
        let access = AttachmentFileAccess(
            startSecurityScopedAccess: { _ in
                probe.recordSecurityStart()
                return false
            },
            stopSecurityScopedAccess: { _ in probe.recordSecurityStop() },
            resourceFileSize: { _ in
                probe.recordMetadata()
                return 4
            },
            readData: { _ in
                probe.recordRead()
                return Data([1, 2, 3, 4])
            }
        )

        let data = try await AttachmentLoader.load(
            url: URL(fileURLWithPath: "/unscoped-readable.bin"),
            maxBytes: 4,
            fileAccess: access
        )

        XCTAssertEqual(data, Data([1, 2, 3, 4]))
        XCTAssertEqual(probe.securityStartCount, 1)
        XCTAssertEqual(probe.securityStopCount, 0)
        XCTAssertEqual(probe.metadataCount, 1)
        XCTAssertEqual(probe.readCount, 1)
    }

    @MainActor
    func testAttachmentSendReservesSingleFlightBeforeDetachedRead() async {
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let readStarted = expectation(description: "first detached read started")
        let blockedRead = BlockingAttachmentRead(
            data: Data(count: Int(AttachmentLoader.maximumByteCount)),
            started: readStarted
        )
        let access = AttachmentFileAccess(
            startSecurityScopedAccess: { _ in false },
            stopSecurityScopedAccess: { _ in },
            resourceFileSize: { _ in AttachmentLoader.maximumByteCount },
            readData: { try blockedRead.read($0) }
        )
        let state = AppState(
            runtimeClient: client,
            attachmentLoad: { url, maxBytes in
                try await AttachmentLoader.load(
                    url: url,
                    maxBytes: maxBytes,
                    fileAccess: access
                )
            }
        )
        let first = Task {
            await state.sendAttachment(
                url: URL(fileURLWithPath: "/held-first.bin"),
                caption: "first",
                in: "origin@s.whatsapp.net"
            )
        }
        await fulfillment(of: [readStarted], timeout: 2)
        XCTAssertTrue(state.sendingMedia, "busy state must be set before file I/O awaits")

        let secondFinished = expectation(description: "duplicate send rejected")
        let second = Task {
            let result = await state.sendAttachment(
                url: URL(fileURLWithPath: "/held-second.bin"),
                caption: "second",
                in: "origin@s.whatsapp.net"
            )
            secondFinished.fulfill()
            return result
        }
        await fulfillment(of: [secondFinished], timeout: 2)
        XCTAssertEqual(blockedRead.readCount, 1, "one operation owns the cap-sized buffer")

        blockedRead.release(times: 2)
        let firstResult = await first.value
        let secondResult = await second.value

        XCTAssertTrue(firstResult)
        XCTAssertFalse(secondResult)
        XCTAssertEqual(blockedRead.readCount, 1)
        XCTAssertEqual(endpoints.mediaRequests.count, 1)
        XCTAssertEqual(endpoints.mediaRequests.first?.byteCount, 20 << 20)
        XCTAssertFalse(state.sendingMedia)
    }

    @MainActor
    func testQueuedComposerMediaSubmitActionKeepsFirstCompositionOwner() async throws {
        let chat = "origin@s.whatsapp.net"
        let attachment = URL(fileURLWithPath: "/queued-composer.bin")
        let caption = "original caption"
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let readStarted = expectation(description: "first composer read started")
        let blockedRead = BlockingAttachmentRead(
            data: Data([1, 2, 3]),
            started: readStarted
        )
        let access = AttachmentFileAccess(
            startSecurityScopedAccess: { _ in false },
            stopSecurityScopedAccess: { _ in },
            resourceFileSize: { _ in 3 },
            readData: { try blockedRead.read($0) }
        )
        let state = AppState(
            runtimeClient: client,
            attachmentLoad: { url, maxBytes in
                try await AttachmentLoader.load(
                    url: url,
                    maxBytes: maxBytes,
                    fileAccess: access
                )
            }
        )
        state.selectedChat = chat
        state.draftStore[chat] = caption
        var visibleDraft = caption
        var visibleAttachment: URL? = attachment
        var sendInvocations = 0
        let action = ComposerMediaSubmitAction()
        let send: @MainActor (ComposerMediaSubmitRequest) async -> Bool = { request in
            sendInvocations += 1
            return await state.sendAttachment(
                url: request.attachmentURL,
                caption: request.caption,
                in: request.chatJID
            )
        }
        let completionState: @MainActor () -> ComposerMediaCompositionSnapshot = {
            ComposerMediaCompositionSnapshot(
                ownerDraft: state.draftStore[chat],
                visibleChatJID: state.selectedChat ?? "",
                visibleDraft: visibleDraft,
                visibleAttachmentURL: visibleAttachment
            )
        }
        let firstSend = Task {
            await action.submit(
                chatJID: chat,
                draft: caption,
                attachmentURL: attachment,
                caption: caption,
                send: send,
                completionState: completionState
            )
        }
        await fulfillment(of: [readStarted], timeout: 2)

        let duplicate = await action.submit(
            chatJID: chat,
            draft: caption,
            attachmentURL: attachment,
            caption: caption,
            send: send,
            completionState: completionState
        )
        XCTAssertFalse(duplicate.accepted)
        XCTAssertFalse(duplicate.succeeded)
        XCTAssertFalse(duplicate.completion.clearsOwnerDraft)
        XCTAssertFalse(duplicate.completion.clearsVisibleDraft)
        XCTAssertEqual(sendInvocations, 1)
        XCTAssertEqual(blockedRead.readCount, 1)

        blockedRead.release()
        let first = await firstSend.value
        XCTAssertTrue(first.accepted)
        XCTAssertTrue(first.succeeded)
        if first.completion.clearsOwnerDraft { state.draftStore[chat] = "" }
        XCTAssertTrue(first.completion.clearsVisibleAttachment)
        if first.completion.clearsVisibleDraft {
            visibleDraft = ""
            visibleAttachment = nil
        }

        XCTAssertEqual(sendInvocations, 1)
        XCTAssertEqual(blockedRead.readCount, 1)
        XCTAssertEqual(endpoints.mediaRequests.count, 1)
        XCTAssertEqual(state.draftStore[chat], "")
        XCTAssertEqual(visibleDraft, "")
        XCTAssertNil(visibleAttachment)
    }

    @MainActor
    func testComposerMediaSubmitActionForwardsCancellationAsFailure() async {
        let chat = "origin@s.whatsapp.net"
        let attachment = URL(fileURLWithPath: "/cancelled-composer.bin")
        let caption = "keep after cancellation"
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let readStarted = expectation(description: "cancelled composer read started")
        let blockedRead = BlockingAttachmentRead(
            data: Data([1, 2, 3]),
            started: readStarted
        )
        let access = AttachmentFileAccess(
            startSecurityScopedAccess: { _ in false },
            stopSecurityScopedAccess: { _ in },
            resourceFileSize: { _ in 3 },
            readData: { try blockedRead.read($0) }
        )
        let state = AppState(
            runtimeClient: client,
            attachmentLoad: { url, maxBytes in
                try await AttachmentLoader.load(
                    url: url,
                    maxBytes: maxBytes,
                    fileAccess: access
                )
            }
        )
        state.selectedChat = chat
        state.draftStore[chat] = caption
        let action = ComposerMediaSubmitAction()
        let submission = Task {
            await action.submit(
                chatJID: chat,
                draft: caption,
                attachmentURL: attachment,
                caption: caption,
                send: { request in
                    await state.sendAttachment(
                        url: request.attachmentURL,
                        caption: request.caption,
                        in: request.chatJID
                    )
                },
                completionState: {
                    ComposerMediaCompositionSnapshot(
                        ownerDraft: state.draftStore[chat],
                        visibleChatJID: chat,
                        visibleDraft: caption,
                        visibleAttachmentURL: attachment
                    )
                }
            )
        }
        await fulfillment(of: [readStarted], timeout: 2)
        XCTAssertTrue(action.isSubmitting)

        submission.cancel()
        blockedRead.release()
        let outcome = await submission.value

        XCTAssertTrue(outcome.accepted)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertFalse(outcome.completion.clearsOwnerDraft)
        XCTAssertFalse(outcome.completion.clearsVisibleDraft)
        XCTAssertFalse(action.isSubmitting)
        XCTAssertEqual(state.draftStore[chat], caption)
        XCTAssertTrue(endpoints.mediaRequests.isEmpty)
    }

    @MainActor
    func testAttachmentSendCancellationAfterLoadAwaitDoesNotSendOrToast() async {
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let loadGate = AttachmentLoadGate()
        let state = AppState(
            runtimeClient: client,
            attachmentLoad: { url, maxBytes in
                try await loadGate.load(url: url, maxBytes: maxBytes)
            }
        )
        let send = Task {
            await state.sendAttachment(
                url: URL(fileURLWithPath: "/cancelled.png"),
                caption: "caption",
                in: "a@s.whatsapp.net"
            )
        }
        await loadGate.waitUntilStarted()

        send.cancel()
        await loadGate.succeed(Data([1, 2, 3]))
        let sent = await send.value

        XCTAssertFalse(sent)
        XCTAssertTrue(endpoints.mediaRequests.isEmpty)
        XCTAssertNil(state.toast)
        XCTAssertFalse(state.sendingMedia)
        XCTAssertTrue(state.messagesByChat.isEmpty)
    }

    @MainActor
    func testAttachmentSendClientReplacementAfterLoadAwaitInvalidatesWork() async {
        let oldEndpoints = RuntimeEndpointProbe()
        let oldClient = makeAppRuntimeClient(oldEndpoints)
        let replacementEndpoints = RuntimeEndpointProbe()
        let replacementClient = makeAppRuntimeClient(replacementEndpoints)
        let loadGate = AttachmentLoadGate()
        let state = AppState(
            runtimeClient: oldClient,
            attachmentLoad: { url, maxBytes in
                try await loadGate.load(url: url, maxBytes: maxBytes)
            }
        )
        let send = Task {
            await state.sendAttachment(
                url: URL(fileURLWithPath: "/replaced.png"),
                caption: "caption",
                in: "a@s.whatsapp.net"
            )
        }
        await loadGate.waitUntilStarted()

        state.installRuntimeClient(replacementClient)
        await loadGate.succeed(Data([1, 2, 3]))
        let sent = await send.value

        XCTAssertFalse(sent)
        XCTAssertTrue(oldEndpoints.mediaRequests.isEmpty)
        XCTAssertTrue(replacementEndpoints.mediaRequests.isEmpty)
        XCTAssertNil(state.toast)
        XCTAssertFalse(state.sendingMedia)
        XCTAssertTrue(state.messagesByChat.isEmpty)
    }

    @MainActor
    func testAttachmentSendKeepsCapturedChatReplyAndResultAfterVisibleChatChanges() async {
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let loadGate = AttachmentLoadGate()
        let state = AppState(
            runtimeClient: client,
            attachmentLoad: { url, maxBytes in
                try await loadGate.load(url: url, maxBytes: maxBytes)
            }
        )
        let origin = "a@s.whatsapp.net"
        let replacement = "b@s.whatsapp.net"
        state.selectedChat = origin
        state.setReply(runtimeMessage(id: 11, chat: origin, text: "original"), for: origin)

        let send = Task {
            await state.sendAttachment(
                url: URL(fileURLWithPath: "/captured.png"),
                caption: "caption",
                in: origin
            )
        }
        await loadGate.waitUntilStarted()
        state.selectedChat = replacement
        state.setReply(runtimeMessage(id: 12, chat: origin, text: "newer"), for: origin)
        await loadGate.succeed(Data([1, 2, 3]))
        let sent = await send.value
        let requestedMaxBytes = await loadGate.requestedMaxBytes

        XCTAssertTrue(sent)
        XCTAssertEqual(requestedMaxBytes, 20 << 20)
        XCTAssertEqual(endpoints.mediaRequests.count, 1)
        XCTAssertEqual(endpoints.mediaRequests[0].chat, origin)
        XCTAssertEqual(endpoints.mediaRequests[0].replyID, "m11")
        XCTAssertEqual(endpoints.mediaRequests[0].replySender, "sender@s.whatsapp.net")
        XCTAssertEqual(state.messagesByChat[origin]?.map(\.message_id), ["media-1"])
        XCTAssertNil(state.messagesByChat[replacement])
        XCTAssertEqual(state.reply(for: origin)?.message_id, "m12")
        XCTAssertEqual(state.selectedChat, replacement)
    }

    @MainActor
    func testAttachmentSendClientReplacementDuringUploadRejectsResultAndFailureToast() async {
        for completion in [RuntimeMediaCompletion.success, .failure] {
            let oldEndpoints = RuntimeEndpointProbe()
            oldEndpoints.blockMediaSend = true
            let oldClient = makeAppRuntimeClient(oldEndpoints)
            let replacementClient = makeAppRuntimeClient(RuntimeEndpointProbe())
            let state = AppState(
                runtimeClient: oldClient,
                attachmentLoad: { _, _ in Data([1, 2, 3]) }
            )

            let send = Task {
                await state.sendAttachment(
                    url: URL(fileURLWithPath: "/upload.png"),
                    caption: "caption",
                    in: "a@s.whatsapp.net"
                )
            }
            await oldEndpoints.waitForMediaRequests(1)
            XCTAssertTrue(state.sendingMedia)

            state.installRuntimeClient(replacementClient)
            oldEndpoints.completeMedia(0, completion: completion)
            let sent = await send.value

            XCTAssertFalse(sent)
            XCTAssertNil(state.toast)
            XCTAssertFalse(state.sendingMedia)
            XCTAssertTrue(state.messagesByChat.isEmpty)
        }
    }

    @MainActor
    func testStaleAttachmentCompletionCannotClearReplacementOperationBusyState() async {
        let oldEndpoints = RuntimeEndpointProbe()
        oldEndpoints.blockMediaSend = true
        let oldClient = makeAppRuntimeClient(oldEndpoints)
        let replacementEndpoints = RuntimeEndpointProbe()
        replacementEndpoints.blockMediaSend = true
        let replacementClient = makeAppRuntimeClient(replacementEndpoints)
        let state = AppState(
            runtimeClient: oldClient,
            attachmentLoad: { _, _ in Data([1, 2, 3]) }
        )

        let staleSend = Task {
            await state.sendAttachment(
                url: URL(fileURLWithPath: "/stale.png"),
                caption: "stale",
                in: "old@s.whatsapp.net"
            )
        }
        await oldEndpoints.waitForMediaRequests(1)
        state.installRuntimeClient(replacementClient)

        let replacementSend = Task {
            await state.sendAttachment(
                url: URL(fileURLWithPath: "/current.png"),
                caption: "current",
                in: "new@s.whatsapp.net"
            )
        }
        await replacementEndpoints.waitForMediaRequests(1)
        XCTAssertTrue(state.sendingMedia)

        oldEndpoints.completeMedia(0, completion: .success)
        let staleResult = await staleSend.value
        XCTAssertFalse(staleResult)
        XCTAssertTrue(
            state.sendingMedia,
            "stale completion must not clear a newer operation's busy state"
        )

        replacementEndpoints.completeMedia(0, completion: .success)
        let replacementResult = await replacementSend.value
        XCTAssertTrue(replacementResult)
        XCTAssertFalse(state.sendingMedia)
    }

    @MainActor
    func testProductionRuntimeAdapterPreservesRawMediaHTTPContract() async throws {
        let responseMessage = runtimeMessage(
            id: 42,
            chat: "origin@s.whatsapp.net",
            text: "caption & details",
            media: true
        )
        let transport = MediaCaptureURLProtocol.state
        transport.prepare(responseData: try JSONEncoder().encode(responseMessage))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaCaptureURLProtocol.self]
        let api = APIClient(
            base: try XCTUnwrap(URL(string: "http://127.0.0.1:43123")),
            token: "transport-secret",
            sessionConfiguration: configuration
        )
        let client = AppRuntimeClient(api: api)
        let body = Data([0x00, 0xff, 0x10, 0x26, 0x3f])

        let result = try await client.sendMedia(
            chat: "origin@s.whatsapp.net",
            data: body,
            mime: "application/x-test-binary",
            filename: "report one?.bin",
            caption: "caption & details",
            replyTo: (id: "quoted/id", sender: "sender+reply@s.whatsapp.net")
        )

        XCTAssertEqual(result, responseMessage)
        let request = try XCTUnwrap(transport.capturedRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.scheme, "http")
        XCTAssertEqual(request.url.host, "127.0.0.1")
        XCTAssertEqual(request.url.port, 43123)
        XCTAssertEqual(request.url.path, "/chats/origin@s.whatsapp.net/media")
        let queryItems = Dictionary(
            uniqueKeysWithValues: URLComponents(
                url: request.url,
                resolvingAgainstBaseURL: false
            )?.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? []
        )
        XCTAssertEqual(queryItems, [
            "caption": "caption & details",
            "filename": "report one?.bin",
            "reply_id": "quoted/id",
            "reply_sender": "sender+reply@s.whatsapp.net",
        ])
        XCTAssertEqual(request.body, body, "media bytes must stay raw, not base64 encoded")
        XCTAssertEqual(request.contentType, "application/x-test-binary")
        XCTAssertEqual(request.authorization, "Bearer transport-secret")
    }

    @MainActor
    func testAttachmentSendPreservesExistingReadErrorMessages() async {
        let endpoints = RuntimeEndpointProbe()
        let client = makeAppRuntimeClient(endpoints)
        let unreadable = AppState(
            runtimeClient: client,
            attachmentLoad: { _, _ in throw AttachmentReadError.unreadable }
        )
        let tooLarge = AppState(
            runtimeClient: client,
            attachmentLoad: { _, _ in
                throw AttachmentReadError.tooLarge(actual: (20 << 20) + 1, limit: 20 << 20)
            }
        )

        let unreadableResult = await unreadable.sendAttachment(
            url: URL(fileURLWithPath: "/missing.bin"),
            caption: "",
            in: "a@s.whatsapp.net"
        )
        XCTAssertFalse(unreadableResult)
        XCTAssertEqual(unreadable.toast, "Cannot read file")
        let tooLargeResult = await tooLarge.sendAttachment(
            url: URL(fileURLWithPath: "/large.bin"),
            caption: "",
            in: "a@s.whatsapp.net"
        )
        XCTAssertFalse(tooLargeResult)
        XCTAssertEqual(tooLarge.toast, "File too large (max 20 MB)")
        XCTAssertTrue(endpoints.mediaRequests.isEmpty)
    }

}

private enum FakeSocketError: Error {
    case finished
    case sendFailed
}

private final class RuntimeRefreshClient {}

private enum RuntimeCancellation: CustomStringConvertible {
    case logout
    case restart

    var description: String {
        switch self {
        case .logout: "logout"
        case .restart: "restart"
        }
    }
}

private enum RuntimeCompletion {
    case success
    case failure
}

private enum RuntimeMediaCompletion {
    case success
    case failure
}

private struct RuntimeMediaRequest: Equatable {
    let chat: String
    let byteCount: Int
    let mime: String
    let filename: String
    let caption: String
    let replyID: String?
    let replySender: String?
}

private struct RuntimeTextRequest: Equatable {
    let chat: String
    let text: String
}

@MainActor
private final class DockBadgeProbe {
    private(set) var labels: [String?] = []

    func record(_ label: String?) {
        labels.append(label)
    }

    func reset() {
        labels.removeAll()
    }
}

private final class TemporaryAttachment {
    let directory: URL
    let url: URL

    init(bytes: [UInt8]) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        url = directory.appendingPathComponent("payload.bin")
        try Data(bytes).write(to: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class AttachmentIOProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [String] = []
    private var metadataCalls = 0
    private var readCalls = 0
    private var securityStarts = 0
    private var securityStops = 0

    var metadataCount: Int { locked { metadataCalls } }
    var readCount: Int { locked { readCalls } }
    var securityStartCount: Int { locked { securityStarts } }
    var securityStopCount: Int { locked { securityStops } }
    var mainThreadPhases: [String] { locked { phases } }

    func recordMetadata() {
        lock.lock()
        metadataCalls += 1
        if Thread.isMainThread { phases.append("metadata") }
        lock.unlock()
    }

    func recordRead() {
        lock.lock()
        readCalls += 1
        if Thread.isMainThread { phases.append("read") }
        lock.unlock()
    }

    func recordSecurityStart() {
        lock.lock()
        securityStarts += 1
        if Thread.isMainThread { phases.append("security-start") }
        lock.unlock()
    }

    func recordSecurityStop() {
        lock.lock()
        securityStops += 1
        if Thread.isMainThread { phases.append("security-stop") }
        lock.unlock()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private enum AttachmentAccessFailure: Error {
    case readFailed
}

private final class BlockingAttachmentRead: @unchecked Sendable {
    private let lock = NSLock()
    private let permits = DispatchSemaphore(value: 0)
    private let data: Data
    private let started: XCTestExpectation
    private var reads = 0

    init(data: Data, started: XCTestExpectation) {
        self.data = data
        self.started = started
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func read(_ url: URL) throws -> Data {
        let shouldSignal: Bool
        lock.lock()
        reads += 1
        shouldSignal = reads == 1
        lock.unlock()
        if shouldSignal { started.fulfill() }
        permits.wait()
        return data
    }

    func release(times: Int = 1) {
        for _ in 0..<times { permits.signal() }
    }
}

private struct CapturedMediaHTTPRequest: Equatable {
    let method: String?
    let url: URL
    let body: Data
    let contentType: String?
    let authorization: String?
}

private final class MediaTransportCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var responseData = Data()
    private var request: CapturedMediaHTTPRequest?
    private var started: XCTestExpectation?
    private var gate: DispatchSemaphore?

    var capturedRequest: CapturedMediaHTTPRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    func prepare(responseData: Data, started: XCTestExpectation? = nil) {
        lock.lock()
        self.responseData = responseData
        self.started = started
        gate = started == nil ? nil : DispatchSemaphore(value: 0)
        request = nil
        lock.unlock()
    }

    func release() {
        lock.lock()
        let pending = gate
        lock.unlock()
        pending?.signal()
    }

    func capture(_ urlRequest: URLRequest) -> Data {
        let body = Self.body(from: urlRequest)
        lock.lock()
        if let url = urlRequest.url {
            request = CapturedMediaHTTPRequest(
                method: urlRequest.httpMethod,
                url: url,
                body: body,
                contentType: urlRequest.value(forHTTPHeaderField: "Content-Type"),
                authorization: urlRequest.value(forHTTPHeaderField: "Authorization")
            )
        }
        let response = responseData
        let pending = gate
        let signal = started
        lock.unlock()
        signal?.fulfill()
        pending?.wait()
        return response
    }

    private static func body(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class MediaCaptureURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = MediaTransportCapture()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let responseData = Self.state.capture(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor AttachmentLoadGate {
    private var started = false
    private var startObservers: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Data, Error>?
    private(set) var requestedMaxBytes: Int64?

    func load(url _: URL, maxBytes: Int64) async throws -> Data {
        requestedMaxBytes = maxBytes
        started = true
        startObservers.forEach { $0.resume() }
        startObservers.removeAll()
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startObservers.append($0) }
    }

    func succeed(_ data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

private enum RuntimeEndpointFailure: Error {
    case failed
}

@MainActor
private final class RuntimeEndpointProbe {
    var session = SessionInfo(state: "connected", account: "self@s.whatsapp.net", qr: nil, sync: nil)
    var contacts = [Contact(jid: "1@s.whatsapp.net", full_name: "One", push_name: nil, business_name: nil)]
    var messagePages: [String: [Message]] = [:]
    var blockStartLink = false
    var blockMediaSend = false
    var blockTextSend = false
    var blockMessageLoads = false
    var failMarkRead = false

    private(set) var calls: [String] = []
    private(set) var chatFilters: [String] = []
    private(set) var mediaRequests: [RuntimeMediaRequest] = []
    private(set) var textRequests: [RuntimeTextRequest] = []
    private(set) var messageChats: [String] = []
    private(set) var markReadChats: [String] = []
    private(set) var markReadReceipts: [Bool] = []
    private(set) var sessionRequestCount = 0
    private(set) var contactRequestCount = 0
    private(set) var startLinkRequestCount = 0
    private var chatWaiters: [Int: CheckedContinuation<ChatsResponse, Error>] = [:]
    private var startLinkWaiter: CheckedContinuation<Void, Error>?
    private var mediaWaiters: [Int: CheckedContinuation<Message, Error>] = [:]
    private var textWaiters: [Int: CheckedContinuation<Message, Error>] = [:]
    private var messageWaiters: [Int: CheckedContinuation<MessagesResponse, Error>] = [:]
    private var onEvent: ((CoreEvent) -> Void)?
    private var onDisconnect: (() -> Void)?

    var refreshEndpointCalls: [String] {
        calls.filter { $0 == "session" || $0 == "events" || $0.hasPrefix("chats:") }
    }

    func sessionInfo() async throws -> SessionInfo {
        calls.append("session")
        sessionRequestCount += 1
        return session
    }

    func chats(filter: String) async throws -> ChatsResponse {
        calls.append("chats:\(filter)")
        chatFilters.append(filter)
        let index = chatFilters.count - 1
        return try await withCheckedThrowingContinuation { chatWaiters[index] = $0 }
    }

    func contactsRequest() async throws -> [Contact] {
        calls.append("contacts")
        contactRequestCount += 1
        return contacts
    }

    func startLink() async throws {
        calls.append("startLink")
        startLinkRequestCount += 1
        guard blockStartLink else { return }
        try await withCheckedThrowingContinuation { startLinkWaiter = $0 }
    }

    func logout() async throws { calls.append("logout") }

    func messages(chat: String) async throws -> MessagesResponse {
        calls.append("messages:\(chat)")
        let index = messageChats.count
        messageChats.append(chat)
        if blockMessageLoads {
            return try await withCheckedThrowingContinuation { messageWaiters[index] = $0 }
        }
        return MessagesResponse(messages: messagePages[chat] ?? [], next_cursor: nil)
    }

    func sendText(chat: String, text: String) async throws -> Message {
        calls.append("sendText:\(chat)")
        let index = textRequests.count
        textRequests.append(RuntimeTextRequest(chat: chat, text: text))
        guard blockTextSend else {
            return runtimeMessage(id: Int64(index + 1), chat: chat, text: text, fromMe: true)
        }
        return try await withCheckedThrowingContinuation { textWaiters[index] = $0 }
    }

    func markRead(chat: String, sendReceipt: Bool) async throws {
        calls.append("markRead:\(chat)")
        markReadChats.append(chat)
        markReadReceipts.append(sendReceipt)
        if failMarkRead { throw RuntimeEndpointFailure.failed }
    }

    func sendMedia(chat: String, data: Data, mime: String, filename: String,
                   caption: String, replyTo: (id: String, sender: String)?) async throws -> Message {
        calls.append("sendMedia:\(chat)")
        let index = mediaRequests.count
        mediaRequests.append(RuntimeMediaRequest(
            chat: chat,
            byteCount: data.count,
            mime: mime,
            filename: filename,
            caption: caption,
            replyID: replyTo?.id,
            replySender: replyTo?.sender
        ))
        guard blockMediaSend else {
            return runtimeMessage(id: Int64(index + 1), chat: chat, text: caption, media: true)
        }
        return try await withCheckedThrowingContinuation { mediaWaiters[index] = $0 }
    }

    func connectEvents(onEvent: @escaping (CoreEvent) -> Void,
                       onHeartbeat _: @escaping () -> Void,
                       onDisconnect: @escaping () -> Void,
                       onGap _: @escaping () -> Void = {}) async {
        calls.append("events")
        self.onEvent = onEvent
        self.onDisconnect = onDisconnect
    }

    func disconnectEvents() async { calls.append("disconnectEvents") }

    func emitDisconnect() { onDisconnect?() }

    func emitEvent(_ event: CoreEvent) { onEvent?(event) }

    func completeChat(_ index: Int, with chats: [Chat]) {
        chatWaiters.removeValue(forKey: index)?.resume(
            returning: ChatsResponse(chats: chats, next_cursor: nil)
        )
    }

    func failChat(_ index: Int) {
        chatWaiters.removeValue(forKey: index)?.resume(throwing: RuntimeEndpointFailure.failed)
    }

    func completeMessage(_ index: Int, with messages: [Message]) {
        messageWaiters.removeValue(forKey: index)?.resume(
            returning: MessagesResponse(messages: messages, next_cursor: nil)
        )
    }

    func failMessage(_ index: Int) {
        messageWaiters.removeValue(forKey: index)?.resume(throwing: RuntimeEndpointFailure.failed)
    }

    func completeStartLink(_ completion: RuntimeCompletion) {
        switch completion {
        case .success:
            startLinkWaiter?.resume()
        case .failure:
            startLinkWaiter?.resume(throwing: RuntimeEndpointFailure.failed)
        }
        startLinkWaiter = nil
    }

    func completeMedia(_ index: Int, completion: RuntimeMediaCompletion) {
        switch completion {
        case .success:
            mediaWaiters.removeValue(forKey: index)?.resume(
                returning: runtimeMessage(
                    id: Int64(index + 1),
                    chat: mediaRequests[index].chat,
                    text: mediaRequests[index].caption,
                    media: true
                )
            )
        case .failure:
            mediaWaiters.removeValue(forKey: index)?.resume(
                throwing: RuntimeEndpointFailure.failed
            )
        }
    }

    func completeText(_ index: Int, completion: RuntimeCompletion) {
        switch completion {
        case .success:
            textWaiters.removeValue(forKey: index)?.resume(
                returning: runtimeMessage(
                    id: Int64(index + 1),
                    chat: textRequests[index].chat,
                    text: textRequests[index].text,
                    fromMe: true
                )
            )
        case .failure:
            textWaiters.removeValue(forKey: index)?.resume(
                throwing: RuntimeEndpointFailure.failed
            )
        }
    }

    func completeText(_ index: Int, with message: Message) {
        textWaiters.removeValue(forKey: index)?.resume(returning: message)
    }

    func waitForChatRequests(_ count: Int) async {
        await waitUntilCount(count, current: { self.chatFilters.count }, label: "chat")
    }

    func waitForSessionRequests(_ count: Int) async {
        await waitUntilCount(count, current: { self.sessionRequestCount }, label: "session")
    }

    func waitForContactRequests(_ count: Int) async {
        await waitUntilCount(count, current: { self.contactRequestCount }, label: "contact")
    }

    func waitForStartLinkRequests(_ count: Int) async {
        await waitUntilCount(count, current: { self.startLinkRequestCount }, label: "startLink")
    }

    func waitForMediaRequests(_ count: Int) async {
        await waitUntilCount(count, current: { self.mediaRequests.count }, label: "media")
    }

    func waitForTextRequests(_ count: Int) async {
        await waitUntilCount(count, current: { self.textRequests.count }, label: "text")
    }

    func waitForMessageRequests(_ count: Int) async {
        await waitUntilCount(count, current: { self.messageChats.count }, label: "message")
    }

    private func waitUntilCount(_ expected: Int, current: @escaping () -> Int,
                                label: String) async {
        for _ in 0..<1_000 {
            if current() >= expected { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for \(label) request \(expected); saw \(current())")
    }
}

@MainActor
private func makeAppRuntimeClient(_ endpoints: RuntimeEndpointProbe, api: APIClient? = nil) -> AppRuntimeClient {
    AppRuntimeClient(
        api: api,
        sessionInfo: { try await endpoints.sessionInfo() },
        chats: { filter in try await endpoints.chats(filter: filter) },
        contacts: { try await endpoints.contactsRequest() },
        startLink: { try await endpoints.startLink() },
        logout: { try await endpoints.logout() },
        messages: { chat in try await endpoints.messages(chat: chat) },
        sendText: { chat, text, _, _ in
            try await endpoints.sendText(chat: chat, text: text)
        },
        markRead: { chat, sendReceipt in try await endpoints.markRead(chat: chat, sendReceipt: sendReceipt) },
        sendMedia: { chat, data, mime, filename, caption, replyTo in
            try await endpoints.sendMedia(
                chat: chat,
                data: data,
                mime: mime,
                filename: filename,
                caption: caption,
                replyTo: replyTo
            )
        },
        connectEvents: { onEvent, onHeartbeat, onDisconnect, onGap in
            await endpoints.connectEvents(
                onEvent: onEvent,
                onHeartbeat: onHeartbeat,
                onDisconnect: onDisconnect,
                onGap: onGap
            )
        },
        disconnectEvents: { await endpoints.disconnectEvents() }
    )
}

private func runtimeChat(
    _ jid: String,
    unread: Int = 0,
    preview: String? = nil,
    muted: Bool = false,
    lid: String? = nil
) -> Chat {
    Chat(
        jid: jid,
        kind: "direct",
        display_name: jid,
        last_message_ts: 1,
        last_preview: preview ?? jid,
        unread_count: unread,
        mentioned_unread: 0,
        is_pinned: false,
        is_muted: muted,
        is_starred: false,
        is_work: false,
        lid: lid
    )
}

private func runtimeMessage(
    id: Int64,
    chat: String,
    text: String,
    fromMe: Bool = false,
    media: Bool = false,
    timestamp: Int64? = nil,
    messageID: String? = nil,
    senderJID: String = "sender@s.whatsapp.net"
) -> Message {
    Message(
        id: id,
        message_id: messageID ?? (media ? "media-\(id)" : "m\(id)"),
        chat_jid: chat,
        sender_jid: senderJID,
        from_me: fromMe || media,
        timestamp: timestamp ?? 1_700_000_000 + id,
        kind: media ? "image" : "text",
        text: text,
        reply_to_id: nil,
        reply_to_sender: nil,
        quoted_text: nil,
        has_mention: false,
        mentioned_jids: nil,
        receipt_status: media ? "sent" : nil,
        revoked: false,
        forwarded: nil,
        edited_ts: nil,
        starred: nil,
        done: nil,
        raw_kind: nil,
        media: media ? MessageMedia(
            id: "attachment",
            kind: "image",
            mime: "image/png",
            size: 3,
            filename: "payload.png",
            state: "downloaded",
            local_path: nil
        ) : nil,
        reactions: nil
    )
}

private func makeSleepTestSidecar(_ probe: SleepAssertionProbe) -> SidecarManager {
    SidecarManager(
        acquirePowerAssertion: { probe.acquire() },
        releasePowerAssertion: { probe.release($0) },
        scheduleSleepCap: { queue, delay, operation in
            probe.schedule(on: queue, after: delay, operation: operation)
        }
    )
}

private func makeLifecycleTestSidecar(
    _ lifecycle: SidecarLifecycleProbe,
    assertions: SleepAssertionProbe
) -> SidecarManager {
    SidecarManager(
        acquirePowerAssertion: { assertions.acquire() },
        releasePowerAssertion: { assertions.release($0) },
        scheduleSleepCap: { queue, delay, operation in
            assertions.schedule(on: queue, after: delay, operation: operation)
        },
        processFactory: { lifecycle.makeProcess() },
        orphanReclaimFactory: { lifecycle.makeReclaim() },
        binaryURL: { URL(fileURLWithPath: "/usr/bin/true") },
        dataDirectory: { lifecycle.dataDirectory },
        scheduleLifecycle: { queue, delay, operation in
            lifecycle.schedule(on: queue, after: delay, operation: operation)
        }
    )
}

private func flushSidecarPublishedState() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

private final class SidecarLifecycleProbe: @unchecked Sendable {
    private struct ScheduledWork {
        let queue: DispatchQueue
        let delay: TimeInterval
        let operation: () -> Void
    }

    let dataDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private let reclaimStartFails: Bool
    private let lock = NSLock()
    private var processes: [FakeSidecarProcess] = []
    private var reclaims: [FakeSidecarOrphanReclaimOperation] = []
    private var scheduled: [ScheduledWork] = []
    private var processExpectations: [Int: XCTestExpectation] = [:]
    private var reclaimExpectations: [Int: XCTestExpectation] = [:]
    private var scheduleExpectations: [TimeInterval: [Int: XCTestExpectation]] = [:]

    init(reclaimStartFails: Bool = false) {
        self.reclaimStartFails = reclaimStartFails
    }

    deinit { try? FileManager.default.removeItem(at: dataDirectory) }

    var processCount: Int { locked { processes.count } }

    func scheduledCount(after delay: TimeInterval) -> Int {
        locked { scheduled.filter { $0.delay == delay }.count }
    }

    func process(at index: Int) -> FakeSidecarProcess {
        locked { processes[index] }
    }

    func reclaim(at index: Int) -> FakeSidecarOrphanReclaimOperation {
        locked { reclaims[index] }
    }

    func expectProcess(_ count: Int, _ expectation: XCTestExpectation) {
        lock.lock()
        if processes.count >= count {
            lock.unlock()
            expectation.fulfill()
        } else {
            processExpectations[count] = expectation
            lock.unlock()
        }
    }

    func expectReclaim(_ count: Int, _ expectation: XCTestExpectation) {
        lock.lock()
        if reclaims.count >= count {
            lock.unlock()
            expectation.fulfill()
        } else {
            reclaimExpectations[count] = expectation
            lock.unlock()
        }
    }

    func expectSchedule(after delay: TimeInterval, count: Int,
                        _ expectation: XCTestExpectation) {
        lock.lock()
        let current = scheduled.filter { $0.delay == delay }.count
        if current >= count {
            lock.unlock()
            expectation.fulfill()
        } else {
            scheduleExpectations[delay, default: [:]][count] = expectation
            lock.unlock()
        }
    }

    func makeProcess() -> any SidecarProcess {
        lock.lock()
        let process = FakeSidecarProcess(pid: Int32(processes.count + 1))
        processes.append(process)
        let count = processes.count
        let expectation = processExpectations.removeValue(forKey: count)
        lock.unlock()
        expectation?.fulfill()
        return process
    }

    func makeReclaim() -> any SidecarOrphanReclaimOperation {
        lock.lock()
        let reclaim = FakeSidecarOrphanReclaimOperation(startFails: reclaimStartFails)
        reclaims.append(reclaim)
        let count = reclaims.count
        let expectation = reclaimExpectations.removeValue(forKey: count)
        lock.unlock()
        expectation?.fulfill()
        return reclaim
    }

    func schedule(on queue: DispatchQueue, after delay: TimeInterval,
                  operation: @escaping () -> Void) {
        lock.lock()
        scheduled.append(ScheduledWork(queue: queue, delay: delay, operation: operation))
        let count = scheduled.filter { $0.delay == delay }.count
        let expectation = scheduleExpectations[delay]?.removeValue(forKey: count)
        lock.unlock()
        expectation?.fulfill()
    }

    func fire(after delay: TimeInterval, occurrence: Int) {
        let work = locked { scheduled.filter { $0.delay == delay }[occurrence] }
        work.queue.sync(execute: work.operation)
    }

    @discardableResult
    func fireIfScheduled(after delay: TimeInterval, occurrence: Int) -> Bool {
        let work = locked { () -> ScheduledWork? in
            let matches = scheduled.filter { $0.delay == delay }
            guard matches.indices.contains(occurrence) else { return nil }
            return matches[occurrence]
        }
        guard let work else { return false }
        work.queue.sync(execute: work.operation)
        return true
    }

    func syncManagerQueue() {
        let queue = locked { scheduled.first?.queue }
        queue?.sync {}
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class FakeSidecarOrphanReclaimOperation:
    SidecarOrphanReclaimOperation,
    @unchecked Sendable
{
    private enum Failure: Error { case launch }

    private let lock = NSLock()
    private let startFails: Bool
    private var completion: (() -> Void)?

    init(startFails: Bool) {
        self.startFails = startFails
    }

    func start(dataDirectory _: URL, onCompletion: @escaping () -> Void) throws {
        if startFails { throw Failure.launch }
        locked { completion = onCompletion }
    }

    func complete() {
        let callback = locked { completion }
        callback?()
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class FakeSidecarProcess: SidecarProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var terminations = 0
    private var stdoutHandler: ((Data) -> Void)?
    private var queuedStdoutHandler: ((Data) -> Void)?
    private var terminationHandler: ((Int32) -> Void)?
    let processIdentifier: Int32

    init(pid: Int32) {
        processIdentifier = pid
    }

    var isRunning: Bool { locked { running } }
    var terminateCount: Int { locked { terminations } }

    func run(executableURL _: URL, arguments _: [String], standardError _: Any?,
             onStdout: @escaping (Data) -> Void,
             onTermination: @escaping (Int32) -> Void) throws {
        lock.lock()
        stdoutHandler = onStdout
        queuedStdoutHandler = onStdout
        terminationHandler = onTermination
        running = true
        lock.unlock()
    }

    func stopReading() {
        locked { stdoutHandler = nil }
    }

    func terminate() {
        lock.lock()
        terminations += 1
        running = false
        lock.unlock()
    }

    func interrupt() {
        locked { running = false }
    }

    func emitStdout(_ text: String) {
        let handler = locked { stdoutHandler }
        handler?(Data(text.utf8))
    }

    /// Models a readability callback that captured data immediately before
    /// `stopReading()` but reaches the manager queue after process replacement.
    func emitQueuedStdout(_ text: String) {
        let handler = locked { queuedStdoutHandler }
        handler?(Data(text.utf8))
    }

    func emitTermination(code: Int32) {
        lock.lock()
        running = false
        let handler = terminationHandler
        lock.unlock()
        handler?(code)
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class SleepAssertionProbe: @unchecked Sendable {
    private struct ScheduledCap {
        let queue: DispatchQueue
        let delay: TimeInterval
        let operation: () -> Void
    }

    private let lock = NSLock()
    private var acquires = 0
    private var releases = 0
    private var caps: [ScheduledCap] = []
    private var acquireExpectations: [Int: XCTestExpectation] = [:]
    private var releaseExpectations: [Int: XCTestExpectation] = [:]
    private var scheduleExpectations: [Int: XCTestExpectation] = [:]

    var acquireCount: Int { locked { acquires } }
    var releaseCount: Int { locked { releases } }
    var scheduledDelays: [TimeInterval] { locked { caps.map(\.delay) } }

    func expectAcquire(_ count: Int, _ expectation: XCTestExpectation) {
        lock.lock()
        if acquires >= count {
            lock.unlock()
            expectation.fulfill()
        } else {
            acquireExpectations[count] = expectation
            lock.unlock()
        }
    }

    func expectRelease(_ count: Int, _ expectation: XCTestExpectation) {
        lock.lock()
        if releases >= count {
            lock.unlock()
            expectation.fulfill()
        } else {
            releaseExpectations[count] = expectation
            lock.unlock()
        }
    }

    func expectSchedule(_ count: Int, _ expectation: XCTestExpectation) {
        lock.lock()
        let current = caps.count
        if current >= count {
            lock.unlock()
            expectation.fulfill()
        } else {
            scheduleExpectations[count] = expectation
            lock.unlock()
        }
    }

    func acquire() -> UInt32 {
        lock.lock()
        acquires += 1
        let count = acquires
        let expectation = acquireExpectations.removeValue(forKey: count)
        lock.unlock()
        expectation?.fulfill()
        return UInt32(count)
    }

    func release(_ id: UInt32) {
        XCTAssertNotEqual(id, 0)
        lock.lock()
        releases += 1
        let count = releases
        let expectation = releaseExpectations.removeValue(forKey: count)
        lock.unlock()
        expectation?.fulfill()
    }

    func schedule(on queue: DispatchQueue, after delay: TimeInterval,
                  operation: @escaping () -> Void) {
        lock.lock()
        caps.append(ScheduledCap(queue: queue, delay: delay, operation: operation))
        let count = caps.count
        let expectation = scheduleExpectations.removeValue(forKey: count)
        lock.unlock()
        expectation?.fulfill()
    }

    func fireCap(at index: Int) {
        let cap = locked { caps[index] }
        cap.queue.sync(execute: cap.operation)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
    for _ in 0..<100 {
        if condition() { return }
        await Task.yield()
    }
    XCTFail("timed out waiting for runtime state sink")
}

private actor RuntimeStepGate {
    private var blocked: Set<ConnectionRefreshStep> = []
    private var blockers: [ConnectionRefreshStep: CheckedContinuation<Void, Never>] = [:]
    private var observers: [ConnectionRefreshStep: CheckedContinuation<Void, Never>] = [:]

    func block(_ step: ConnectionRefreshStep) async {
        blocked.insert(step)
        observers.removeValue(forKey: step)?.resume()
        await withCheckedContinuation { blockers[step] = $0 }
    }

    func waitUntilBlocked(on step: ConnectionRefreshStep) async {
        if blocked.contains(step) { return }
        await withCheckedContinuation { observers[step] = $0 }
    }

    func release(_ step: ConnectionRefreshStep) {
        blockers.removeValue(forKey: step)?.resume()
    }
}

private actor RuntimeClock {
    private var sleepers: [TimeInterval: [CheckedContinuation<Void, Never>]] = [:]
    private var observers: [TimeInterval: CheckedContinuation<Void, Never>] = [:]

    func sleep(for delay: TimeInterval) async {
        observers.removeValue(forKey: delay)?.resume()
        await withCheckedContinuation { sleepers[delay, default: []].append($0) }
    }

    func waitUntilSleeping(for delay: TimeInterval) async {
        if sleepers[delay]?.isEmpty == false { return }
        await withCheckedContinuation { observers[delay] = $0 }
    }

    func advance(_ delay: TimeInterval) async {
        let waiting = sleepers.removeValue(forKey: delay) ?? []
        waiting.forEach { $0.resume() }
        for _ in 0..<8 { await Task.yield() }
    }
}

private actor SocketProbe {
    private var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func entries() -> [String] { values }
}

private actor FakeWebSocketTask: WebSocketEventTask {
    private var frames: [Result<WebSocketFrame, Error>]
    private let failsSend: Bool
    private let probe: SocketProbe

    init(frames: [Result<WebSocketFrame, Error>], failsSend: Bool = false, probe: SocketProbe) {
        self.frames = frames
        self.failsSend = failsSend
        self.probe = probe
    }

    func start() async {
        await probe.record("start")
    }

    func receive() async throws -> WebSocketFrame {
        await probe.record("receive")
        guard !frames.isEmpty else { throw FakeSocketError.finished }
        return try frames.removeFirst().get()
    }

    func send(text: String) async throws {
        await probe.record("send:\(text == #"{"type":"pong"}"# ? "pong" : text)")
        if failsSend { throw FakeSocketError.sendFailed }
    }

    func cancel() async {
        await probe.record("cancel")
    }
}

private final class OrderedWebSocketTaskFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let tasks: [any WebSocketEventTask]
    private var next = 0

    init(_ tasks: [any WebSocketEventTask]) {
        self.tasks = tasks
    }

    func make(_: URLRequest) -> any WebSocketEventTask {
        lock.lock()
        defer { lock.unlock() }
        let task = tasks[next]
        next += 1
        return task
    }

    var createdCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return next
    }
}

private actor ControlledWebSocketTask: WebSocketEventTask {
    private let name: String
    private let blocksStart: Bool
    private var values: [String] = []
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var startObservedWaiter: CheckedContinuation<Void, Never>?
    private var cancelObservedWaiter: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var didCancel = false

    init(name: String, blocksStart: Bool = false) {
        self.name = name
        self.blocksStart = blocksStart
    }

    func start() async {
        values.append("start")
        didStart = true
        startObservedWaiter?.resume()
        startObservedWaiter = nil
        if blocksStart {
            await withCheckedContinuation { startWaiter = $0 }
        }
    }

    func receive() async throws -> WebSocketFrame {
        try await Task.sleep(for: .seconds(60))
        throw FakeSocketError.finished
    }

    func send(text _: String) async throws {}

    func cancel() async {
        values.append("cancel")
        didCancel = true
        cancelObservedWaiter?.resume()
        cancelObservedWaiter = nil
    }

    func waitUntilStart() async {
        if didStart { return }
        await withCheckedContinuation { startObservedWaiter = $0 }
    }

    func releaseStart() {
        startWaiter?.resume()
        startWaiter = nil
    }

    func waitUntilCancel() async {
        if didCancel { return }
        await withCheckedContinuation { cancelObservedWaiter = $0 }
    }

    func operations() -> [String] { values }
}
