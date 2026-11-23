import CoreGraphics
import Foundation

public final class DisplayGamma: DisplayGammaControlling {
    public init() {}

    public func capture() throws -> GammaSnapshot {
        let external = Self.onlineIDs().filter { CGDisplayIsBuiltin($0) == 0 }
        if external.isEmpty {
            throw NapDisplayError.noDisplay
        }
        return GammaSnapshot(displays: try external.map(Self.read))
    }

    public func apply(_ snapshot: GammaSnapshot) throws {
        let online = Self.onlineIDs()
        var applied = 0
        for table in snapshot.displays {
            guard let id = online.first(where: { Self.sameIdentity($0, table) }) else { continue }
            try Self.write(table, to: id)
            applied += 1
        }
        if applied == 0 {
            throw NapDisplayError.applyFailed
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

    private static func sameIdentity(_ id: CGDirectDisplayID, _ table: DisplayTable) -> Bool {
        CGDisplayVendorNumber(id) == table.vendor
            && CGDisplayModelNumber(id) == table.model
            && CGDisplaySerialNumber(id) == table.serial
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
