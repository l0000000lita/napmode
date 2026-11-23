import Foundation

public struct DisplayTable: Codable, Equatable {
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]

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

public protocol DisplayGammaControlling: AnyObject {
    func capture() throws -> GammaSnapshot
    func apply(_ snapshot: GammaSnapshot) throws
}

public enum NapDisplayError: Error {
    case noDisplay
    case applyFailed
}

public struct NapController {
    private let displays: DisplayGammaControlling
    private let savedURL: URL
    private var saved: GammaSnapshot?

    public var isOn: Bool { saved != nil }

    public init(displays: DisplayGammaControlling, savedURL: URL) {
        self.displays = displays
        self.savedURL = savedURL
        self.saved = Self.load(savedURL)
    }

    public mutating func start() throws {
        guard saved == nil else { return }
        let current = try displays.capture()
        if current.displays.isEmpty {
            throw NapDisplayError.noDisplay
        }
        try persist(current)
        do {
            try displays.apply(current.scaledForNap())
            saved = current
        } catch {
            try? FileManager.default.removeItem(at: savedURL)
            throw error
        }
    }

    public mutating func stop() throws {
        guard let previous = saved else { return }
        try displays.apply(previous)
        saved = nil
        try? FileManager.default.removeItem(at: savedURL)
    }

    public func reapply() throws {
        guard let saved else { return }
        try displays.apply(saved.scaledForNap())
    }

    private func persist(_ snapshot: GammaSnapshot) throws {
        let directory = savedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: savedURL)
    }

    private static func load(_ url: URL) -> GammaSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GammaSnapshot.self, from: data)
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
