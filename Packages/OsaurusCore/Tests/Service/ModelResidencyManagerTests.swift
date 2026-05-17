// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

private actor ResidencySleepRecorder {
    private var requests: [UInt64] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(_ nanoseconds: UInt64) async {
        requests.append(nanoseconds)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func recordedRequests() -> [UInt64] {
        requests
    }

    func finishAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor ResidencyUnloadRecorder {
    private var unloadedNames: [String] = []

    func unload(_ name: String) {
        unloadedNames.append(name)
    }

    func names() -> [String] {
        unloadedNames
    }
}

@Suite("Model idle residency manager")
struct ModelResidencyManagerTests {
    private static func allowTasksToRun() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    @Test("afterSeconds schedules one delayed unload")
    func afterSecondsSchedulesDelayedUnload() async {
        let sleeper = ResidencySleepRecorder()
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager(sleep: { nanoseconds in
            await sleeper.sleep(nanoseconds)
        })
        let now = Date(timeIntervalSinceReferenceDate: 100)

        await manager.scheduleIdleUnload(
            modelName: "llama",
            policy: .afterSeconds(300),
            now: now,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )

        await Self.allowTasksToRun()
        #expect(await sleeper.recordedRequests() == [300_000_000_000])
        let snapshots = await manager.snapshots()
        #expect(snapshots.first?.modelName == "llama")
        #expect(snapshots.first?.unloadAt == now.addingTimeInterval(300))

        await sleeper.finishAll()
        await Self.allowTasksToRun()
        #expect(await unloads.names() == ["llama"])
        #expect(await manager.snapshots().isEmpty)
    }

    @Test("markActive cancels pending idle unload")
    func markActiveCancelsPendingIdleUnload() async {
        let sleeper = ResidencySleepRecorder()
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager(sleep: { nanoseconds in
            await sleeper.sleep(nanoseconds)
        })

        await manager.scheduleIdleUnload(
            modelName: "gemma",
            policy: .afterSeconds(30),
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()

        await manager.markActive(modelName: "gemma")
        await sleeper.finishAll()
        await Self.allowTasksToRun()

        #expect(await unloads.names().isEmpty)
        let snapshots = await manager.snapshots()
        #expect(snapshots.first?.modelName == "gemma")
        #expect(snapshots.first?.unloadAt == nil)
    }

    @Test("never policy records residency without scheduling a timer")
    func neverPolicyDoesNotScheduleTimer() async {
        let sleeper = ResidencySleepRecorder()
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager(sleep: { nanoseconds in
            await sleeper.sleep(nanoseconds)
        })

        await manager.scheduleIdleUnload(
            modelName: "hy3",
            policy: .never,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()

        #expect(await sleeper.recordedRequests().isEmpty)
        #expect(await unloads.names().isEmpty)
        let snapshots = await manager.snapshots()
        #expect(snapshots.first?.policy == .never)
        #expect(snapshots.first?.unloadAt == nil)
    }

    @Test("idle fire rechecks lease count before unloading")
    func idleFireRechecksLeaseCountBeforeUnloading() async {
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager()

        await manager.scheduleIdleUnload(
            modelName: "busy",
            policy: .immediately,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 1 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()

        #expect(await unloads.names().isEmpty)
        let snapshots = await manager.snapshots()
        #expect(snapshots.first?.modelName == "busy")
        #expect(snapshots.first?.unloadAt == nil)
    }

    @Test("idle fire drops stale entries when model is not resident")
    func idleFireDropsStaleEntriesWhenModelIsNotResident() async {
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager()

        await manager.scheduleIdleUnload(
            modelName: "gone",
            policy: .immediately,
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in false }
        )
        await Self.allowTasksToRun()

        #expect(await unloads.names().isEmpty)
        #expect(await manager.snapshots().isEmpty)
    }

    @Test("cancelAll cancels timers and clears snapshots")
    func cancelAllCancelsTimersAndClearsSnapshots() async {
        let sleeper = ResidencySleepRecorder()
        let unloads = ResidencyUnloadRecorder()
        let manager = ModelResidencyManager(sleep: { nanoseconds in
            await sleeper.sleep(nanoseconds)
        })

        await manager.scheduleIdleUnload(
            modelName: "cancelled",
            policy: .afterSeconds(30),
            unload: { name in await unloads.unload(name) },
            leaseCount: { _ in 0 },
            isResident: { _ in true }
        )
        await Self.allowTasksToRun()
        await manager.cancelAll()
        await sleeper.finishAll()
        await Self.allowTasksToRun()

        #expect(await unloads.names().isEmpty)
        #expect(await manager.snapshots().isEmpty)
    }
}
