import CoreGraphics
import Foundation

public struct OnlineDisplay: Equatable {
    public var id: UInt32
    public var identity: DisplayIdentity
    public var isBuiltin: Bool

    public init(id: UInt32, identity: DisplayIdentity, isBuiltin: Bool) {
        self.id = id
        self.identity = identity
        self.isBuiltin = isBuiltin
    }
}

public enum PlannedWrite: Equatable {
    case write(displayID: UInt32, identity: DisplayIdentity)
    case offline(DisplayIdentity)
    case ambiguous(DisplayIdentity)
}

public func planDisplayWrites(targets: [DisplayTable], online: [OnlineDisplay]) -> [PlannedWrite] {
    var identityCounts: [DisplayIdentity: Int] = [:]
    for target in targets {
        identityCounts[target.identity, default: 0] += 1
    }

    var matches: [DisplayIdentity: [UInt32]] = [:]
    for display in online where !display.isBuiltin {
        var ids = matches[display.identity] ?? []
        if !ids.contains(display.id) {
            ids.append(display.id)
        }
        matches[display.identity] = ids
    }

    var used = Set<UInt32>()
    var seen = Set<DisplayIdentity>()
    var plan: [PlannedWrite] = []
    for target in targets {
        let identity = target.identity
        if !seen.insert(identity).inserted {
            continue
        }
        if identityCounts[identity, default: 0] > 1 {
            plan.append(.ambiguous(identity))
            continue
        }
        let ids = matches[identity] ?? []
        if ids.isEmpty {
            plan.append(.offline(identity))
            continue
        }
        if ids.count != 1 || used.contains(ids[0]) {
            plan.append(.ambiguous(identity))
            continue
        }
        used.insert(ids[0])
        plan.append(.write(displayID: ids[0], identity: identity))
    }
    return plan
}

public final class DisplayGamma: DisplayGammaControlling {
    public init() {}

    public func capture() throws -> GammaSnapshot {
        let external = Self.onlineDisplays().filter { !$0.isBuiltin }
        if external.isEmpty {
            throw NapDisplayError.noDisplay
        }
        return GammaSnapshot(displays: try external.map { try Self.read($0.id) })
    }

    public func apply(_ snapshot: GammaSnapshot) -> [DisplayIdentity: DisplayWriteResult] {
        let plan = planDisplayWrites(targets: snapshot.displays, online: Self.onlineDisplays())
        var results: [DisplayIdentity: DisplayWriteResult] = [:]
        for item in plan {
            switch item {
            case .offline(let identity):
                results[identity] = .offline
            case .ambiguous(let identity):
                results[identity] = .ambiguous
            case .write(let id, let identity):
                guard let table = snapshot.displays.first(where: { $0.identity == identity }) else {
                    results[identity] = .failed
                    continue
                }
                do {
                    try Self.write(table, to: id)
                    results[identity] = .applied
                } catch {
                    results[identity] = .failed
                }
            }
        }
        return results
    }

    private static func onlineDisplays() -> [OnlineDisplay] {
        onlineIDs().map { id in
            OnlineDisplay(
                id: id,
                identity: DisplayIdentity(
                    vendor: CGDisplayVendorNumber(id),
                    model: CGDisplayModelNumber(id),
                    serial: CGDisplaySerialNumber(id)
                ),
                isBuiltin: CGDisplayIsBuiltin(id) != 0
            )
        }
    }

    private static func onlineIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        _ = ids.withUnsafeMutableBufferPointer { buffer in
            CGGetOnlineDisplayList(UInt32(buffer.count), buffer.baseAddress, &count)
        }
        return Array(ids.prefix(Int(count)))
    }

    private static func read(_ id: CGDirectDisplayID) throws -> DisplayTable {
        let capacity = 256
        var red = [CGGammaValue](repeating: 0, count: capacity)
        var green = [CGGammaValue](repeating: 0, count: capacity)
        var blue = [CGGammaValue](repeating: 0, count: capacity)
        var samples: UInt32 = 0
        let err = red.withUnsafeMutableBufferPointer { redBuffer in
            green.withUnsafeMutableBufferPointer { greenBuffer in
                blue.withUnsafeMutableBufferPointer { blueBuffer in
                    CGGetDisplayTransferByTable(
                        id,
                        UInt32(capacity),
                        redBuffer.baseAddress!,
                        greenBuffer.baseAddress!,
                        blueBuffer.baseAddress!,
                        &samples
                    )
                }
            }
        }
        guard err == .success, samples > 0 else { throw NapDisplayError.applyFailed }
        let count = Int(samples)
        return DisplayTable(
            vendor: CGDisplayVendorNumber(id),
            model: CGDisplayModelNumber(id),
            serial: CGDisplaySerialNumber(id),
            red: Array(red.prefix(count)),
            green: Array(green.prefix(count)),
            blue: Array(blue.prefix(count))
        )
    }

    private static func write(_ table: DisplayTable, to id: CGDirectDisplayID) throws {
        var red = table.red
        var green = table.green
        var blue = table.blue
        let count = UInt32(red.count)
        let err = red.withUnsafeMutableBufferPointer { redBuffer in
            green.withUnsafeMutableBufferPointer { greenBuffer in
                blue.withUnsafeMutableBufferPointer { blueBuffer in
                    CGSetDisplayTransferByTable(
                        id,
                        count,
                        redBuffer.baseAddress!,
                        greenBuffer.baseAddress!,
                        blueBuffer.baseAddress!
                    )
                }
            }
        }
        guard err == .success else { throw NapDisplayError.applyFailed }
    }
}
