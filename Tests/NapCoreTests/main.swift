import Foundation
import NapCore

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}

func table(vendor: UInt32 = 1, model: UInt32 = 2, serial: UInt32, end: Float) -> DisplayTable {
    DisplayTable(vendor: vendor, model: model, serial: serial, red: [0, end], green: [0, end], blue: [0, end])
}

final class FakeDisplays: DisplayGammaControlling {
    var captured: GammaSnapshot
    var captureError: Error?
    var handler: (DisplayTable) -> DisplayWriteResult
    var writes: [DisplayTable] = []

    init(captured: GammaSnapshot, handler: @escaping (DisplayTable) -> DisplayWriteResult = { _ in .applied }) {
        self.captured = captured
        self.handler = handler
    }

    func capture() throws -> GammaSnapshot {
        if let captureError { throw captureError }
        return captured
    }

    func apply(_ snapshot: GammaSnapshot) -> [DisplayIdentity: DisplayWriteResult] {
        var results: [DisplayIdentity: DisplayWriteResult] = [:]
        var seen = Set<DisplayIdentity>()
        for display in snapshot.displays {
            let identity = display.identity
            if seen.contains(identity) {
                results[identity] = .ambiguous
                continue
            }
            seen.insert(identity)
            let result = handler(display)
            if result == .applied {
                writes.append(display)
            }
            results[identity] = result
        }
        return results
    }
}

func temporarySavedURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("saved.json")
}

func testStartSavesOriginalAndLowersWhitePoint() throws {
    let fake = FakeDisplays(captured: GammaSnapshot(displays: [table(serial: 3, end: 1)]))
    let url = temporarySavedURL()
    var nap = NapController(displays: fake, savedURL: url)

    try nap.start()

    try check(nap.phase == .napping, "nap should be on")
    try check(fake.writes.last?.red.last == 0.25, "white point should drop to 0.25, got \(fake.writes)")
    let stored = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
    try check(stored.phase == .napping, "saved phase should be napping")
    try check(stored.displays[0].red.last == 1, "saved curve should stay at 1")
}

func testCaptureFailureDoesNotWrite() throws {
    let fake = FakeDisplays(captured: GammaSnapshot(displays: [table(serial: 3, end: 1)]))
    fake.captureError = NapDisplayError.noDisplay
    var nap = NapController(displays: fake, savedURL: temporarySavedURL())

    do {
        try nap.start()
        throw CheckFailure(description: "start should fail")
    } catch NapDisplayError.noDisplay {
    }

    try check(fake.writes.isEmpty, "failed capture must not write, got \(fake.writes)")
    try check(nap.phase == .off, "phase should stay off")
}

func testSaveFailureDoesNotWrite() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("x".utf8).write(to: root)
    let fake = FakeDisplays(captured: GammaSnapshot(displays: [table(serial: 3, end: 1)]))
    var nap = NapController(displays: fake, savedURL: root.appendingPathComponent("saved.json"))

    do {
        try nap.start()
        throw CheckFailure(description: "start should fail")
    } catch {
    }

    try check(fake.writes.isEmpty, "failed save must not write, got \(fake.writes)")
    try check(nap.phase == .off, "phase should stay off")
}

func testPartialApplyRollsBackTheFirstDisplay() throws {
    let first = table(serial: 1, end: 1)
    let second = table(serial: 2, end: 1)
    let fake = FakeDisplays(captured: GammaSnapshot(displays: [first, second]))
    fake.handler = { display in
        display.serial == 2 ? .failed : .applied
    }
    let url = temporarySavedURL()
    var nap = NapController(displays: fake, savedURL: url)

    do {
        try nap.start()
        throw CheckFailure(description: "start should fail")
    } catch {
    }

    try check(fake.writes.count == 2, "expected dim then rollback, got \(fake.writes)")
    try check(fake.writes[0].serial == 1 && fake.writes[0].red.last == 0.25, "first write should dim display 1")
    try check(fake.writes[1].serial == 1 && fake.writes[1].red.last == 1, "rollback should restore display 1")
    try check(nap.phase == .off, "rolled-back start should be off, got \(nap.phase)")
    try check(!FileManager.default.fileExists(atPath: url.path), "backup should be removed after rollback")
}

func testFailedRollbackKeepsTheOriginal() throws {
    let first = table(serial: 1, end: 1)
    let second = table(serial: 2, end: 1)
    let fake = FakeDisplays(captured: GammaSnapshot(displays: [first, second]))
    fake.handler = { display in
        if display.serial == 2 { return .failed }
        return display.red.last == 0.25 ? .applied : .failed
    }
    let url = temporarySavedURL()
    var nap = NapController(displays: fake, savedURL: url)

    do {
        try nap.start()
        throw CheckFailure(description: "start should fail")
    } catch {
    }

    try check(nap.phase == .pendingRestore, "unconfirmed rollback stays pending, got \(nap.phase)")
    try check(!nap.isOn, "pending restore must not stay in nap")
    let stored = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
    try check(stored.phase == .pendingRestore, "file should be pending")
    try check(stored.displays.map(\.serial) == [1], "only the unrestored display remains, got \(stored.displays)")
    try check(stored.displays[0].red.last == 1, "kept curve must be the original")
}

func testStopWithEveryDisplayOfflineCanFinish() throws {
    let displays = [table(serial: 1, end: 1), table(serial: 2, end: 1)]
    let fake = FakeDisplays(captured: GammaSnapshot(displays: displays))
    let url = temporarySavedURL()
    var nap = NapController(displays: fake, savedURL: url)
    try nap.start()
    let writesBeforeStop = fake.writes.count
    fake.handler = { _ in .offline }

    nap.stop()

    try check(nap.phase == .pendingRestore, "offline stop waits to restore, got \(nap.phase)")
    try check(!nap.isOn, "offline stop must leave nap")
    try check(fake.writes.count == writesBeforeStop, "offline stop must not write")
    let stored = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
    try check(stored.displays.map(\.serial) == [1, 2], "offline originals must stay")
}

func testPartialRestoreKeepsOnlyTheOfflineDisplay() throws {
    let fake = FakeDisplays(captured: GammaSnapshot(displays: [table(serial: 1, end: 1), table(serial: 2, end: 1)]))
    let url = temporarySavedURL()
    var nap = NapController(displays: fake, savedURL: url)
    try nap.start()
    fake.handler = { display in display.serial == 1 ? .applied : .offline }

    nap.stop()

    let stored = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
    try check(stored.phase == .pendingRestore, "phase")
    try check(stored.displays.map(\.serial) == [2], "only offline display remains, got \(stored.displays)")
    try check(stored.displays[0].red.last == 1, "remaining curve is original")
}

func testOnlineRestoreFailureKeepsTheCurve() throws {
    let fake = FakeDisplays(captured: GammaSnapshot(displays: [table(serial: 1, end: 1)]))
    let url = temporarySavedURL()
    var nap = NapController(displays: fake, savedURL: url)
    try nap.start()
    fake.handler = { _ in .failed }

    nap.stop()

    try check(nap.phase == .pendingRestore, "failed restore stays pending")
    try check(!nap.isOn, "failed restore is not nap")
    let stored = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
    try check(stored.displays[0].red.last == 1, "original remains")
}

func testRelaunchNapKeepsDimmingAndPendingDoesNot() throws {
    let nappingURL = temporarySavedURL()
    let original = table(serial: 3, end: 1)
    try FileManager.default.createDirectory(at: nappingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(SavedState(phase: .napping, displays: [original])).write(to: nappingURL)
    let nappingDisplays = FakeDisplays(captured: GammaSnapshot(displays: [table(serial: 3, end: 0.25)]))
    var napping = NapController(displays: nappingDisplays, savedURL: nappingURL)
    try check(napping.phase == .napping, "saved nap resumes")
    napping.reapply()
    try check(nappingDisplays.writes.last?.red.last == 0.25, "resume may dim again")

    let pendingURL = temporarySavedURL()
    try FileManager.default.createDirectory(at: pendingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(SavedState(phase: .pendingRestore, displays: [original])).write(to: pendingURL)
    let pendingDisplays = FakeDisplays(captured: GammaSnapshot(displays: [table(serial: 3, end: 1)]))
    var pending = NapController(displays: pendingDisplays, savedURL: pendingURL)
    try check(pending.phase == .pendingRestore, "pending file is not nap")
    pending.reapply()
    try check(pendingDisplays.writes.isEmpty, "pending relaunch must not dim, got \(pendingDisplays.writes)")
}

func testRepeatedStopDoesNotRewriteOriginals() throws {
    let fake = FakeDisplays(captured: GammaSnapshot(displays: [table(serial: 1, end: 1)]))
    var nap = NapController(displays: fake, savedURL: temporarySavedURL())
    try nap.start()
    nap.stop()
    let count = fake.writes.count

    nap.stop()

    try check(fake.writes.count == count, "second stop should not write, got \(fake.writes.count) from \(count)")
    try check(nap.phase == .off, "still off")
}

func testAmbiguousIdentityIsNotWrittenTwice() throws {
    let identity = DisplayIdentity(vendor: 9, model: 8, serial: 7)
    let targets = [
        table(vendor: 9, model: 8, serial: 7, end: 1),
        table(vendor: 9, model: 8, serial: 7, end: 0.4)
    ]
    let online = [OnlineDisplay(id: 10, identity: identity, isBuiltin: false)]
    let plan = planDisplayWrites(targets: targets, online: online)
    try check(plan.allSatisfy {
        if case .ambiguous = $0 { return true }
        return false
    }, "duplicate saved identity must not write, got \(plan)")

    let crowded = [
        OnlineDisplay(id: 10, identity: identity, isBuiltin: false),
        OnlineDisplay(id: 11, identity: identity, isBuiltin: false)
    ]
    let crowdedPlan = planDisplayWrites(targets: [targets[0]], online: crowded)
    try check(crowdedPlan == [.ambiguous(identity)], "two matching displays must not pick the first, got \(crowdedPlan)")

    let reused = planDisplayWrites(
        targets: [
            table(vendor: 1, model: 1, serial: 1, end: 1),
            table(vendor: 1, model: 1, serial: 2, end: 1)
        ],
        online: [
            OnlineDisplay(id: 4, identity: DisplayIdentity(vendor: 1, model: 1, serial: 1), isBuiltin: false),
            OnlineDisplay(id: 4, identity: DisplayIdentity(vendor: 1, model: 1, serial: 2), isBuiltin: false)
        ]
    )
    let writes = reused.compactMap { item -> UInt32? in
        if case .write(let id, _) = item { return id }
        return nil
    }
    try check(writes == [4], "one display id is used once, got \(reused)")
}

final class ScriptedStore: NapStateStoring {
    struct Failure: Error {}

    var state: SavedState?
    var replaceCount = 0
    var failReplaceAfter = Int.max
    var failRemove = false

    func load() -> SavedState? { state }

    func replace(_ state: SavedState) throws {
        replaceCount += 1
        if replaceCount > failReplaceAfter { throw Failure() }
        self.state = state
    }

    func remove() throws {
        if failRemove { throw Failure() }
        state = nil
    }
}

func testFullRestoreKeepsRetryWhenFileUpdateFails() throws {
    let fake = FakeDisplays(captured: GammaSnapshot(displays: [table(serial: 1, end: 1)]))
    let store = ScriptedStore()
    var nap = NapController(displays: fake, store: store)
    try nap.start()
    let writesAfterStart = fake.writes.count
    store.failRemove = true
    store.failReplaceAfter = store.replaceCount

    nap.stop()
    let writesAfterRestore = fake.writes.count

    try check(writesAfterRestore > writesAfterStart, "stop still restores the display")
    try check(fake.writes.last?.red.last == 1, "restore writes the original, got \(fake.writes)")
    try check(nap.phase == .pendingRestore, "file failure must stay retryable, got \(nap.phase)")
    try check(!nap.isOn, "ended nap must not stay on")
    try check(store.state?.phase == .napping, "disk can still say napping, got \(String(describing: store.state?.phase))")
    try check(store.state?.displays[0].red.last == 1, "disk keeps the original curve")
    try check(nap.notice?.contains("屏幕已恢复") == true, "notice \(nap.notice ?? "")")
    try check(nap.notice?.contains("恢复记录更新失败") == true, "notice \(nap.notice ?? "")")
    nap.reapply()
    try check(fake.writes.count == writesAfterRestore, "timer must not dim after the user ended nap")
    try nap.start()
    try check(store.state?.displays[0].red.last == 1, "start must not overwrite the original")
    try check(fake.writes.count == writesAfterRestore, "blocked start must not write")

    store.failRemove = false
    store.failReplaceAfter = Int.max
    nap.stop()
    try check(nap.phase == .off, "retry can clear the record, got \(nap.phase)")
    try check(store.state == nil, "retry deletes the file")
    try check(fake.writes.count == writesAfterRestore, "file retry must not rewrite the display")
}

func testPartialRestoreKeepsRecordWhenFileReplaceFails() throws {
    let fake = FakeDisplays(captured: GammaSnapshot(displays: [table(serial: 1, end: 1), table(serial: 2, end: 1)]))
    let store = ScriptedStore()
    var nap = NapController(displays: fake, store: store)
    try nap.start()
    fake.handler = { display in display.serial == 1 ? .applied : .failed }
    store.failReplaceAfter = store.replaceCount

    nap.stop()

    try check(nap.phase == .pendingRestore, "partial failure stays pending, got \(nap.phase)")
    try check(!nap.isOn, "partial failure must not keep dimming")
    try check(store.state?.phase == .napping, "failed replace leaves the napping file")
    try check(store.state?.displays.map(\.serial) == [1, 2], "failed replace must not drop a display")
    try check(nap.notice?.contains("状态文件更新失败") == true, "notice \(nap.notice ?? "")")
    let writesAfterStop = fake.writes.count
    nap.reapply()
    try check(fake.writes.count == writesAfterStop, "pending file failure must not dim")
    try nap.start()
    try check(store.state?.displays.map(\.serial) == [1, 2], "start must not overwrite the backup")

    store.failReplaceAfter = Int.max
    nap.stop()
    try check(store.state?.phase == .pendingRestore, "retry persists the unrestored display")
    try check(store.state?.displays.map(\.serial) == [2], "retry keeps only the failed display, got \(String(describing: store.state?.displays))")
    try check(store.state?.displays[0].red.last == 1, "kept curve is original")
    try check(!nap.isOn, "retry stays out of nap")
}

func testRollbackCleanupFailureDoesNotLeaveNapOn() throws {
    let fake = FakeDisplays(captured: GammaSnapshot(displays: [table(serial: 1, end: 1), table(serial: 2, end: 1)]))
    fake.handler = { display in display.serial == 2 ? .failed : .applied }
    let store = ScriptedStore()
    store.failRemove = true
    store.failReplaceAfter = 1
    var nap = NapController(displays: fake, store: store)

    do {
        try nap.start()
        throw CheckFailure(description: "start should fail")
    } catch NapDisplayError.applyFailed {
    }

    try check(nap.phase == .pendingRestore, "rolled-back start with a stuck file stays retryable, got \(nap.phase)")
    try check(!nap.isOn, "rolled-back start must not stay on")
    try check(fake.writes.count == 2, "dim then rollback, got \(fake.writes)")
    try check(fake.writes[1].red.last == 1, "rollback restored the first display")
    try check(store.state?.phase == .napping, "cleanup failure leaves the old napping file")
    try check(store.state?.displays.map(\.serial) == [1, 2], "original backup stays complete")
    try check(nap.notice?.contains("屏幕已恢复") == true, "notice \(nap.notice ?? "")")
    try check(nap.notice?.contains("恢复记录更新失败") == true, "notice \(nap.notice ?? "")")
    nap.reapply()
    try nap.start()
    try check(fake.writes.count == 2, "must not dim or overwrite after cleanup failure")

    store.failRemove = false
    store.failReplaceAfter = Int.max
    nap.stop()
    try check(nap.phase == .off, "later stop can delete the stuck file")
    try check(store.state == nil, "stuck file removed")
    try check(fake.writes.count == 2, "cleanup retry must not write again")
}

func testInvalidGammaTablesAreRejected() throws {
    let ok = table(serial: 1, end: 1)
    try check(gammaChannelsAreWritable(ok, capacity: 256), "a normal curve is writable")
    var empty = ok
    empty.red = []
    empty.green = []
    empty.blue = []
    try check(!gammaChannelsAreWritable(empty, capacity: 256), "empty channels are rejected")
    var short = ok
    short.green = [0]
    try check(!gammaChannelsAreWritable(short, capacity: 256), "unequal channels are rejected")
    var nan = ok
    nan.blue = [0, .nan]
    try check(!gammaChannelsAreWritable(nan, capacity: 256), "NaN is rejected")
    var infinite = ok
    infinite.red = [0, .infinity]
    try check(!gammaChannelsAreWritable(infinite, capacity: 256), "infinity is rejected")
    var high = ok
    high.red = [0, 1.2]
    try check(!gammaChannelsAreWritable(high, capacity: 256), "values above 1 are rejected")
    try check(!gammaChannelsAreWritable(ok, capacity: 1), "tables longer than capacity are rejected")
}

func testCleanupOnlyRelaunchDoesNotRewriteGamma() throws {
    let fake = FakeDisplays(captured: GammaSnapshot(displays: [table(serial: 1, end: 1)]))
    let store = ScriptedStore()
    var nap = NapController(displays: fake, store: store)
    try nap.start()
    store.failRemove = true
    nap.stop()
    try check(store.state?.phase == .cleanupOnly, "delete failure is saved as cleanup only, got \(String(describing: store.state?.phase))")
    let writes = fake.writes.count
    store.failRemove = false

    var again = NapController(displays: fake, store: store)
    try check(!again.isOn, "cleanup record is not nap")
    try check(again.phase == .pendingRestore, "cleanup record stays retryable")
    again.stop()

    try check(fake.writes.count == writes, "relaunch must not write gamma, got \(fake.writes.count) from \(writes)")
    try check(again.phase == .off, "retry deletes the cleanup record")
    try check(store.state == nil, "cleanup file removed")
}

func testAmbiguousStartKeepsTheSpecificNotice() throws {
    let fake = FakeDisplays(captured: GammaSnapshot(displays: [table(serial: 1, end: 1), table(serial: 2, end: 1)]))
    fake.handler = { _ in .ambiguous }
    let store = ScriptedStore()
    var nap = NapController(displays: fake, store: store)

    do {
        try nap.start()
        throw CheckFailure(description: "ambiguous start should fail")
    } catch NapDisplayError.applyFailed {
    }

    try check(nap.phase == .off, "ambiguous start does not stay on, got \(nap.phase)")
    try check(fake.writes.isEmpty, "ambiguous start must not write")
    try check(store.state == nil, "failed start removes the temporary record")
    try check(nap.notice?.contains("身份相同") == true, "notice \(nap.notice ?? "")")
}

func testEmptyOrCorruptRecordDoesNotStartNap() throws {
    let fake = FakeDisplays(captured: GammaSnapshot(displays: [table(serial: 1, end: 1)]))
    let emptyStore = ScriptedStore()
    emptyStore.state = SavedState(phase: .napping, displays: [])
    let empty = NapController(displays: fake, store: emptyStore)
    try check(empty.phase == .off, "empty record is off")
    try check(!empty.isOn, "empty record must not dim")
    try check(empty.notice?.contains("无效") == true, "notice \(empty.notice ?? "")")
    empty.reapply()
    try check(fake.writes.isEmpty, "empty record must not write")

    let url = temporarySavedURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{".utf8).write(to: url)
    let corrupt = NapController(displays: fake, savedURL: url)
    try check(corrupt.phase == .off, "corrupt record is off")
    try check(corrupt.notice?.contains("无法读取") == true, "notice \(corrupt.notice ?? "")")
    corrupt.reapply()
    try check(fake.writes.isEmpty, "corrupt record must not write")
}

func testUnusableCurveDoesNotStickInRestore() throws {
    let fake = FakeDisplays(captured: GammaSnapshot(displays: [table(serial: 1, end: 1)]))
    var broken = table(serial: 1, end: 1)
    broken.red = []
    let store = ScriptedStore()
    store.state = SavedState(phase: .pendingRestore, displays: [broken])
    let nap = NapController(displays: fake, store: store)
    try check(nap.phase == .off, "unusable curve is ignored, got \(nap.phase)")
    try check(!nap.isOn, "unusable curve must not dim")
    try check(nap.notice?.contains("无效") == true, "notice \(nap.notice ?? "")")
    nap.reapply()
    try check(fake.writes.isEmpty, "ignored curve must not write")

    var long = table(serial: 2, end: 0.5)
    long.red = Array(repeating: Float(0.5), count: 300)
    long.green = long.red
    long.blue = long.red
    let longStore = ScriptedStore()
    longStore.state = SavedState(phase: .napping, displays: [long])
    let resumed = NapController(displays: fake, store: longStore)
    try check(resumed.isOn, "a long but valid curve can still resume")
}

func testMissingFileIsQuietAndUnreadableFileIsReported() throws {
    let fake = FakeDisplays(captured: GammaSnapshot(displays: [table(serial: 1, end: 1)]))
    let missing = NapController(displays: fake, savedURL: temporarySavedURL())
    try check(missing.phase == .off, "missing file stays off")
    try check(missing.notice == nil, "missing file has no notice, got \(missing.notice ?? "")")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let unreadable = NapController(displays: fake, savedURL: directory)
    try check(unreadable.phase == .off, "unreadable record stays off")
    try check(unreadable.notice?.contains("无法读取") == true, "notice \(unreadable.notice ?? "")")
}

func testLiveRoundTrip() throws {
    let gamma = DisplayGamma()
    let before = try gamma.capture()
    let beforeEnd = before.displays[0].red.last ?? -1
    let url = temporarySavedURL()
    var nap = NapController(displays: gamma, savedURL: url)
    try nap.start()
    let during = try gamma.capture()
    let duringEnd = during.displays[0].red.last ?? -1
    try check(abs(duringEnd - beforeEnd * GammaSnapshot.napScale) < 0.02, "live white point \(duringEnd)")
    nap.stop()
    let after = try gamma.capture()
    try check(abs((after.displays[0].red.last ?? -1) - beforeEnd) < 0.02, "live restore failed: \(after.displays[0].red.last ?? -1)")
    try check(nap.phase == .off, "live stop should clear nap")
}

do {
    try testStartSavesOriginalAndLowersWhitePoint()
    try testCaptureFailureDoesNotWrite()
    try testSaveFailureDoesNotWrite()
    try testPartialApplyRollsBackTheFirstDisplay()
    try testFailedRollbackKeepsTheOriginal()
    try testStopWithEveryDisplayOfflineCanFinish()
    try testPartialRestoreKeepsOnlyTheOfflineDisplay()
    try testOnlineRestoreFailureKeepsTheCurve()
    try testRelaunchNapKeepsDimmingAndPendingDoesNot()
    try testRepeatedStopDoesNotRewriteOriginals()
    try testAmbiguousIdentityIsNotWrittenTwice()
    try testFullRestoreKeepsRetryWhenFileUpdateFails()
    try testPartialRestoreKeepsRecordWhenFileReplaceFails()
    try testRollbackCleanupFailureDoesNotLeaveNapOn()
    try testInvalidGammaTablesAreRejected()
    try testCleanupOnlyRelaunchDoesNotRewriteGamma()
    try testAmbiguousStartKeepsTheSpecificNotice()
    try testEmptyOrCorruptRecordDoesNotStartNap()
    try testUnusableCurveDoesNotStickInRestore()
    try testMissingFileIsQuietAndUnreadableFileIsReported()
    if CommandLine.arguments.contains("--live") {
        try testLiveRoundTrip()
    }
    print("PASS")
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
