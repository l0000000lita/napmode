import Foundation
import NapCore

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}

func table(end: Float) -> DisplayTable {
    DisplayTable(vendor: 1, model: 2, serial: 3, red: [0, end], green: [0, end], blue: [0, end])
}

final class FakeDisplays: DisplayGammaControlling {
    var snapshot: GammaSnapshot
    init(snapshot: GammaSnapshot) { self.snapshot = snapshot }
    func capture() throws -> GammaSnapshot { snapshot }
    func apply(_ snapshot: GammaSnapshot) throws { self.snapshot = snapshot }
}

func temporarySavedURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("saved.json")
}

func testStartSavesOriginalAndLowersWhitePoint() throws {
    let fake = FakeDisplays(snapshot: GammaSnapshot(displays: [table(end: 1)]))
    let url = temporarySavedURL()
    var nap = NapController(displays: fake, savedURL: url)

    try nap.start()

    try check(nap.isOn, "nap should be on")
    try check(fake.snapshot.displays[0].red.last == 0.25, "white point should drop to 0.25, got \(fake.snapshot)")
    let stored = try JSONDecoder().decode(GammaSnapshot.self, from: Data(contentsOf: url))
    try check(stored.displays[0].red.last == 1, "saved curve should stay at 1, got \(stored)")
}

func testStopRestoresOriginalCurve() throws {
    let fake = FakeDisplays(snapshot: GammaSnapshot(displays: [table(end: 1)]))
    let url = temporarySavedURL()
    var nap = NapController(displays: fake, savedURL: url)
    try nap.start()

    try nap.stop()

    try check(!nap.isOn, "nap should be off")
    try check(fake.snapshot.displays[0].red.last == 1, "curve should be restored, got \(fake.snapshot)")
    try check(!FileManager.default.fileExists(atPath: url.path), "saved file should be removed")
}

func testRelaunchStopRestoresFile() throws {
    let url = temporarySavedURL()
    let previous = GammaSnapshot(displays: [table(end: 0.9)])
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(previous).write(to: url)
    let fake = FakeDisplays(snapshot: GammaSnapshot(displays: [table(end: 0.25)]))
    var nap = NapController(displays: fake, savedURL: url)

    try check(nap.isOn, "saved file means nap is still on")
    try nap.stop()
    try check(fake.snapshot == previous, "stop should restore the saved curve, got \(fake.snapshot)")
}

func testReapplyUsesSavedCurve() throws {
    let fake = FakeDisplays(snapshot: GammaSnapshot(displays: [table(end: 1)]))
    let url = temporarySavedURL()
    var nap = NapController(displays: fake, savedURL: url)
    try nap.start()
    fake.snapshot = GammaSnapshot(displays: [table(end: 1)])

    try nap.reapply()
    try nap.reapply()

    try check(fake.snapshot.displays[0].red.last == 0.25, "reapply should stay at 0.25, got \(fake.snapshot)")
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
    try check(abs(duringEnd - beforeEnd * GammaSnapshot.napScale) < 0.02, "live white point \(duringEnd), expected \(beforeEnd * GammaSnapshot.napScale)")
    try nap.stop()
    let after = try gamma.capture()
    try check(abs((after.displays[0].red.last ?? -1) - beforeEnd) < 0.02, "live restore failed: \(after)")
}

do {
    try testStartSavesOriginalAndLowersWhitePoint()
    try testStopRestoresOriginalCurve()
    try testRelaunchStopRestoresFile()
    try testReapplyUsesSavedCurve()
    if CommandLine.arguments.contains("--live") {
        try testLiveRoundTrip()
    }
    print("PASS")
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
