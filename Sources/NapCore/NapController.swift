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

public enum NapDisplayError: Error {
    case noDisplay
    case applyFailed
}

public struct NapController {
    private let displays: DisplayGammaControlling
    private let savedURL: URL
    private var saved: SavedState?
    public private(set) var notice: String?

    public var phase: NapPhase {
        switch saved?.phase {
        case .napping:
            return .napping
        case .pendingRestore:
            return .pendingRestore
        case nil:
            return .off
        }
    }

    public var isOn: Bool { phase == .napping }

    public init(displays: DisplayGammaControlling, savedURL: URL) {
        self.displays = displays
        self.savedURL = savedURL
        self.saved = Self.load(savedURL)
    }

    public mutating func start() throws {
        guard phase == .off else { return }
        let current = try displays.capture()
        if current.displays.isEmpty {
            throw NapDisplayError.noDisplay
        }
        let napping = SavedState(phase: .napping, displays: current.displays)
        try persist(napping)
        saved = napping

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
        if unrestored.isEmpty {
            saved = nil
            try? FileManager.default.removeItem(at: savedURL)
            notice = "切换失败，屏幕已恢复"
            throw NapDisplayError.applyFailed
        }

        let pending = SavedState(phase: .pendingRestore, displays: unrestored)
        try persist(pending)
        saved = pending
        notice = "部分屏幕没能恢复，已停止压暗"
        throw NapDisplayError.applyFailed
    }

    public mutating func stop() {
        guard var record = saved else { return }
        if record.phase == .napping {
            record.phase = .pendingRestore
            if (try? persist(record)) != nil {
                saved = record
            }
        }
        let results = displays.apply(GammaSnapshot(displays: record.displays))
        let remaining = record.displays.filter { results[$0.identity] != .applied }
        if remaining.isEmpty {
            saved = nil
            try? FileManager.default.removeItem(at: savedURL)
            notice = nil
            return
        }
        let pending = SavedState(phase: .pendingRestore, displays: remaining)
        if (try? persist(pending)) != nil {
            saved = pending
        } else {
            saved = pending
        }
        notice = Self.notice(for: results)
    }

    public func reapply() {
        guard let saved, saved.phase == .napping else { return }
        _ = displays.apply(GammaSnapshot(displays: saved.displays).scaledForNap())
    }

    private func persist(_ state: SavedState) throws {
        let directory = savedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: savedURL, options: .atomic)
    }

    private static func load(_ url: URL) -> SavedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let state = try? JSONDecoder().decode(SavedState.self, from: data) {
            return state
        }
        if let legacy = try? JSONDecoder().decode(GammaSnapshot.self, from: data) {
            return SavedState(phase: .napping, displays: legacy.displays)
        }
        return nil
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
