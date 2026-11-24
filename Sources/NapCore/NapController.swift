import Foundation

public struct DisplayIdentity: Codable, Equatable, Hashable {
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32

    public init(vendor: UInt32, model: UInt32, serial: UInt32) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
    }
}

public enum DisplayWriteResult: Equatable {
    case applied
    case offline
    case failed
    case ambiguous
}

public struct DisplayTable: Codable, Equatable {
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]

    public var identity: DisplayIdentity {
        DisplayIdentity(vendor: vendor, model: model, serial: serial)
    }

    public init(vendor: UInt32, model: UInt32, serial: UInt32, red: [Float], green: [Float], blue: [Float]) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct GammaSnapshot: Codable, Equatable {
    public static let napScale: Float = 0.25

    public var displays: [DisplayTable]

    public init(displays: [DisplayTable]) {
        self.displays = displays
    }

    public func scaledForNap() -> GammaSnapshot {
        GammaSnapshot(displays: displays.map { table in
            DisplayTable(
                vendor: table.vendor,
                model: table.model,
                serial: table.serial,
                red: table.red.map { $0 * Self.napScale },
                green: table.green.map { $0 * Self.napScale },
                blue: table.blue.map { $0 * Self.napScale }
            )
        })
    }
}

public struct SavedState: Codable, Equatable {
    public enum Phase: String, Codable {
        case napping
        case pendingRestore
        case cleanupOnly
    }

    public var phase: Phase
    public var displays: [DisplayTable]

    public init(phase: Phase, displays: [DisplayTable]) {
        self.phase = phase
        self.displays = displays
    }
}

public enum NapPhase: Equatable {
    case off
    case napping
    case pendingRestore
}

public protocol DisplayGammaControlling: AnyObject {
    func capture() throws -> GammaSnapshot
    func apply(_ snapshot: GammaSnapshot) -> [DisplayIdentity: DisplayWriteResult]
}

public protocol NapStateStoring: AnyObject {
    func load() -> SavedState?
    func replace(_ state: SavedState) throws
    func remove() throws
    var loadFailureNotice: String? { get }
}

public extension NapStateStoring {
    var loadFailureNotice: String? { nil }
}

private final class FileNapStore: NapStateStoring {
    private let url: URL
    private(set) var loadFailureNotice: String?

    init(url: URL) {
        self.url = url
    }

    func load() -> SavedState? {
        loadFailureNotice = nil
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            loadFailureNotice = "恢复记录无法读取，已忽略。"
            return nil
        }
        if let state = try? JSONDecoder().decode(SavedState.self, from: data) {
            return state
        }
        if let legacy = try? JSONDecoder().decode(GammaSnapshot.self, from: data) {
            return SavedState(phase: .napping, displays: legacy.displays)
        }
        loadFailureNotice = "恢复记录无法读取，已忽略。"
        return nil
    }

    func replace(_ state: SavedState) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

public enum NapDisplayError: Error {
    case noDisplay
    case applyFailed
}

public struct NapController {
    private let displays: DisplayGammaControlling
    private let store: NapStateStoring
    private var saved: SavedState?
    private var dimming = false
    private var fileCleanupOnly = false
    public private(set) var notice: String?

    public var phase: NapPhase {
        if dimming { return .napping }
        if saved != nil { return .pendingRestore }
        return .off
    }

    public var isOn: Bool { phase == .napping }

    public init(displays: DisplayGammaControlling, store: NapStateStoring) {
        self.displays = displays
        self.store = store
        let loaded = store.load()
        if let loaded,
           !loaded.displays.isEmpty,
           loaded.displays.allSatisfy(gammaChannelsAreInRange) {
            self.saved = loaded
            self.dimming = loaded.phase == .napping
            self.fileCleanupOnly = loaded.phase == .cleanupOnly
        } else {
            self.saved = nil
            self.dimming = false
            self.fileCleanupOnly = false
            self.notice = loaded == nil ? store.loadFailureNotice : "恢复记录无效，已忽略。"
        }
    }

    public init(displays: DisplayGammaControlling, savedURL: URL) {
        self.init(displays: displays, store: FileNapStore(url: savedURL))
    }

    public mutating func start() throws {
        guard phase == .off else { return }
        let current = try displays.capture()
        if current.displays.isEmpty {
            throw NapDisplayError.noDisplay
        }
        let napping = SavedState(phase: .napping, displays: current.displays)
        try store.replace(napping)
        saved = napping
        dimming = true
        fileCleanupOnly = false

        let results = displays.apply(current.scaledForNap())
        if current.displays.allSatisfy({ results[$0.identity] == .applied }) {
            notice = nil
            return
        }

        let applied = current.displays.filter { results[$0.identity] == .applied }
        let rollback = applied.isEmpty
            ? [:]
            : displays.apply(GammaSnapshot(displays: applied))
        let unrestored = applied.filter { rollback[$0.identity] != .applied }
        dimming = false
        if unrestored.isEmpty {
            settleRestored(record: napping)
            if phase == .off {
                notice = results.values.contains(.ambiguous)
                    ? "有多台显示器身份相同，未启用午休模式"
                    : "切换失败，屏幕已恢复"
            }
            throw NapDisplayError.applyFailed
        }

        let pending = SavedState(phase: .pendingRestore, displays: unrestored)
        saved = pending
        fileCleanupOnly = false
        if replace(pending) {
            notice = "部分屏幕没能恢复，已停止压暗"
        } else {
            notice = "部分屏幕没能恢复，当前已停止压暗；状态文件更新失败，重启前请检查或删除状态文件。"
        }
        throw NapDisplayError.applyFailed
    }

    public mutating func stop() {
        guard var record = saved else { return }
        if fileCleanupOnly {
            settleRestored(record: record)
            return
        }
        if dimming {
            dimming = false
            record.phase = .pendingRestore
            saved = record
            _ = replace(record)
        }
        let results = displays.apply(GammaSnapshot(displays: record.displays))
        let remaining = record.displays.filter { results[$0.identity] != .applied }
        if remaining.isEmpty {
            settleRestored(record: record)
            return
        }
        let pending = SavedState(phase: .pendingRestore, displays: remaining)
        saved = pending
        fileCleanupOnly = false
        if replace(pending) {
            notice = Self.notice(for: results)
        } else {
            notice = Self.notice(for: results) + "当前已停止压暗，但状态文件更新失败，重启前请检查或删除状态文件。"
        }
    }

    public func reapply() {
        guard dimming, let saved else { return }
        _ = displays.apply(GammaSnapshot(displays: saved.displays).scaledForNap())
    }

    private mutating func settleRestored(record: SavedState) {
        dimming = false
        do {
            try store.remove()
            saved = nil
            fileCleanupOnly = false
            notice = nil
            return
        } catch {
        }
        let cleanup = SavedState(phase: .cleanupOnly, displays: record.displays)
        saved = cleanup
        fileCleanupOnly = true
        if replace(cleanup) {
            notice = "屏幕已恢复，但恢复记录删除失败"
        } else {
            notice = "屏幕已恢复，但恢复记录更新失败，重启前请手动删除状态文件"
        }
    }

    private func replace(_ state: SavedState) -> Bool {
        do {
            try store.replace(state)
            return true
        } catch {
            return false
        }
    }

    private static func notice(for results: [DisplayIdentity: DisplayWriteResult]) -> String {
        if results.values.contains(.ambiguous) {
            return "有多台显示器身份相同，没有写入。恢复记录已留下。"
        }
        if results.values.contains(.failed) {
            return "有外接屏没能恢复。恢复记录已留下，不会再次压暗。"
        }
        return "外接屏不在线，恢复记录已留下。下次打开只会尝试恢复，不会再次压暗。"
    }
}

public enum NapFiles {
    public static func savedURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("NapMode", isDirectory: true)
            .appendingPathComponent("saved.json")
    }
}
