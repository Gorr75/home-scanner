import Foundation

/// A ZIP archive stored uncompressed, so a layout and a model can be shared
/// without a compression library. Paths use forward slashes.
public enum StoredZip {
    public static func archive(files: [(path: String, data: Data)]) -> Data {
        var locals = Data()
        var central = Data()
        var count: UInt16 = 0
        for file in files {
            let path = sanitized(file.path)
            guard !path.isEmpty else { continue }
            let name = Data(path.utf8)
            guard name.count <= Int(UInt16.max) else { continue }
            let crc = CRC32.hash(file.data)
            let size = UInt32(file.data.count)
            let offset = UInt32(locals.count)
            appendLocalHeader(name: name, crc: crc, size: size, to: &locals)
            locals.append(file.data)
            appendCentralHeader(name: name, crc: crc, size: size, offset: offset, to: &central)
            count += 1
        }
        var archive = locals
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        appendEnd(count: count, centralSize: UInt32(central.count), centralOffset: centralOffset, to: &archive)
        return archive
    }

    private static func sanitized(_ path: String) -> String {
        let trimmed = path.replacingOccurrences(of: "\\", with: "/")
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("..") else { return "" }
        return trimmed
    }

    private static func appendLocalHeader(name: Data, crc: UInt32, size: UInt32, to data: inout Data) {
        appendUInt32(0x04034B50, to: &data)
        appendUInt16(20, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0x0021, to: &data)
        appendUInt32(crc, to: &data)
        appendUInt32(size, to: &data)
        appendUInt32(size, to: &data)
        appendUInt16(UInt16(name.count), to: &data)
        appendUInt16(0, to: &data)
        data.append(name)
    }

    private static func appendCentralHeader(
        name: Data,
        crc: UInt32,
        size: UInt32,
        offset: UInt32,
        to data: inout Data
    ) {
        appendUInt32(0x02014B50, to: &data)
        appendUInt16(20, to: &data)
        appendUInt16(20, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0x0021, to: &data)
        appendUInt32(crc, to: &data)
        appendUInt32(size, to: &data)
        appendUInt32(size, to: &data)
        appendUInt16(UInt16(name.count), to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(offset, to: &data)
        data.append(name)
    }

    private static func appendEnd(count: UInt16, centralSize: UInt32, centralOffset: UInt32, to data: inout Data) {
        appendUInt32(0x06054B50, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(count, to: &data)
        appendUInt16(count, to: &data)
        appendUInt32(centralSize, to: &data)
        appendUInt32(centralOffset, to: &data)
        appendUInt16(0, to: &data)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}

enum CRC32 {
    static func hash(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = {
        (0..<256).map { index in
            var value = UInt32(index)
            for _ in 0..<8 {
                if value & 1 == 1 {
                    value = 0xEDB8_8320 ^ (value >> 1)
                } else {
                    value >>= 1
                }
            }
            return value
        }
    }()
}
