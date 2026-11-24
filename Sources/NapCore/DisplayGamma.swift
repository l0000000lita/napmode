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

public func gammaChannelsAreInRange(_ table: DisplayTable) -> Bool {
    let count = table.red.count
    guard count > 0, count == table.green.count, count == table.blue.count else {
        return false
    }
    let valid = { (samples: [Float]) in
        samples.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    return valid(table.red) && valid(table.green) && valid(table.blue)
}

public func gammaChannelsAreWritable(_ table: DisplayTable, capacity: Int) -> Bool {
    let limit = capacity > 0 ? capacity : 256
    return gammaChannelsAreInRange(table) && table.red.count <= limit
}

public final class DisplayGamma: DisplayGammaControlling {
    public init() {}

    public func capture() throws -> GammaSnapshot {
        guard let allDisplays = Self.onlineDisplays() else {
            throw NapDisplayError.applyFailed
        }
        let external = allDisplays.filter { !$0.isBuiltin }
        if external.isEmpty {
            throw NapDisplayError.noDisplay
        }
        return GammaSnapshot(displays: try external.map { try Self.read($0.id) })
    }

    public func apply(_ snapshot: GammaSnapshot) -> [DisplayIdentity: DisplayWriteResult] {
        guard let allDisplays = Self.onlineDisplays() else {
            return Dictionary(
                snapshot.displays.map { ($0.identity, DisplayWriteResult.failed) },
                uniquingKeysWith: { _, latest in latest }
            )
        }
        let plan = planDisplayWrites(targets: snapshot.displays, online: allDisplays)
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

    private static func onlineDisplays() -> [OnlineDisplay]? {
        guard let ids = onlineIDs() else { return nil }
        return ids.map { id in
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

    private static func onlineIDs() -> [CGDirectDisplayID]? {
        var total: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &total) == .success else { return nil }
        guard total > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(total))
        var count: UInt32 = 0
        let err = ids.withUnsafeMutableBufferPointer { buffer in
            CGGetOnlineDisplayList(total, buffer.baseAddress, &count)
        }
        guard err == .success else { return nil }
        return Array(ids.prefix(Int(count)))
    }

    private static func read(_ id: CGDirectDisplayID) throws -> DisplayTable {
        let hardware = Int(CGDisplayGammaTableCapacity(id))
        let capacity = hardware > 0 ? hardware : 256
        var red = [CGGammaValue](repeating: 0, count: capacity)
        var green = [CGGammaValue](repeating: 0, count: capacity)
        var blue = [CGGammaValue](repeating: 0, count: capacity)
        var samples: UInt32 = 0
        let err: CGError = red.withUnsafeMutableBufferPointer { redBuffer in
            green.withUnsafeMutableBufferPointer { greenBuffer in
                blue.withUnsafeMutableBufferPointer { blueBuffer in
                    guard let redPointer = redBuffer.baseAddress,
                          let greenPointer = greenBuffer.baseAddress,
                          let bluePointer = blueBuffer.baseAddress else {
                        return .illegalArgument
                    }
                    return CGGetDisplayTransferByTable(
                        id,
                        UInt32(capacity),
                        redPointer,
                        greenPointer,
                        bluePointer,
                        &samples
                    )
                }
            }
        }
        guard err == .success, samples > 0, Int(samples) <= capacity else {
            throw NapDisplayError.applyFailed
        }
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
        let capacity = Int(CGDisplayGammaTableCapacity(id))
        guard gammaChannelsAreWritable(table, capacity: capacity),
              let count = UInt32(exactly: table.red.count) else {
            throw NapDisplayError.applyFailed
        }
        var red = table.red
        var green = table.green
        var blue = table.blue
        let err: CGError = red.withUnsafeMutableBufferPointer { redBuffer in
            green.withUnsafeMutableBufferPointer { greenBuffer in
                blue.withUnsafeMutableBufferPointer { blueBuffer in
                    guard let redPointer = redBuffer.baseAddress,
                          let greenPointer = greenBuffer.baseAddress,
                          let bluePointer = blueBuffer.baseAddress else {
                        return .illegalArgument
                    }
                    return CGSetDisplayTransferByTable(id, count, redPointer, greenPointer, bluePointer)
                }
            }
        }
        guard err == .success else { throw NapDisplayError.applyFailed }
    }
}
