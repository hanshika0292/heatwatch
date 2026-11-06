// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Hanshika Gupta. See LICENSE.

import Foundation
import IOKit

/// Read-only access to the System Management Controller, the chip that owns the
/// temperature sensors and fan controller (on Intel and Apple silicon Macs alike).
/// Reading needs no root.
final class SMC {
    private typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    /// Mirrors the kernel's 80-byte SMCKeyData_t. `padding` keeps `result` at
    /// offset 40, where C struct alignment puts it.
    private struct Param {
        struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
        struct PowerLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attributes: UInt8 = 0 }

        var key: UInt32 = 0
        var version = Version()
        var powerLimit = PowerLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let handleEvent: UInt32 = 2
    private static let readKey: UInt8 = 5
    private static let readKeyInfo: UInt8 = 9
    private static let readKeyAtIndex: UInt8 = 8

    private var connection: io_connect_t = 0
    private var keyInfoCache: [UInt32: Param.KeyInfo?] = [:]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(connection) }

    /// The decoded value of a four-character SMC key, or nil if this Mac doesn't have it.
    func read(_ key: String) -> Double? {
        let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard let info = keyInfo(code) else { return nil }
        var input = Param()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.command = Self.readKey
        guard let output = call(input) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return Self.decode(bytes, type: info.dataType)
    }

    /// Every key this SMC has (about 3,600 on an M5 Pro). That's thousands of
    /// calls, a few milliseconds in all, so call it once and keep the result.
    func allKeys() -> [String] {
        guard let count = read("#KEY"), count > 0, count < 100_000 else { return [] }
        return (0..<UInt32(count)).compactMap { index in
            var input = Param()
            input.command = Self.readKeyAtIndex
            input.data32 = index
            return call(input).map { Self.fourCC($0.key) }
        }
    }

    private static func fourCC(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? ""
    }

    private func keyInfo(_ code: UInt32) -> Param.KeyInfo? {
        if let cached = keyInfoCache[code] { return cached }
        var input = Param()
        input.key = code
        input.command = Self.readKeyInfo
        let info = call(input)?.keyInfo
        keyInfoCache.updateValue(info, forKey: code)
        return info
    }

    private func call(_ input: Param) -> Param? {
        var input = input
        var output = Param()
        var outputSize = MemoryLayout<Param>.stride
        let status = IOConnectCallStructMethod(connection, Self.handleEvent,
                                               &input, MemoryLayout<Param>.stride, &output, &outputSize)
        return status == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private static func decode(_ bytes: [UInt8], type: UInt32) -> Double? {
        let name = fourCC(type)
        let bigEndian = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        switch name {
        case "flt " where bytes.count == 4:
            return Double(bytes.withUnsafeBytes { $0.load(as: Float32.self) })
        case "ui8 ", "ui16", "ui32":
            return Double(bigEndian)
        default:
            // Fixed point: "spXY" is signed, "fpXY" unsigned; the last hex digit is the fraction bits.
            guard bytes.count == 2, name.count == 4, let fraction = Int(String(name.last!), radix: 16) else { return nil }
            let scale = Double(1 << fraction)
            if name.hasPrefix("sp") { return Double(Int16(bitPattern: UInt16(bigEndian))) / scale }
            if name.hasPrefix("fp") { return Double(UInt16(bigEndian)) / scale }
            return nil
        }
    }
}
