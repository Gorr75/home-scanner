import Foundation

/// Enough of a TIFF / GeoTIFF / EXIF IFD to read tags without decoding pixels.
struct TIFFDirectory {
    enum Endian {
        case little
        case big
    }

    struct Field {
        var type: Int
        var count: Int
        /// Absolute index in `data` where the values begin.
        var valueOffset: Int
        var integers: [Int]
        var doubles: [Double]
        var ascii: String
    }

    let data: Data
    let endian: Endian
    let fields: [Int: Field]

    static func classicHeader(_ data: Data) -> (endian: Endian, firstIFD: Int)? {
        guard data.count >= 8 else { return nil }
        let endian: Endian
        if data[0] == 0x49 && data[1] == 0x49 {
            endian = .little
        } else if data[0] == 0x4D && data[1] == 0x4D {
            endian = .big
        } else {
            return nil
        }
        let magic = readU16(data, 2, endian)
        // 42 is classic TIFF. 43 is BigTIFF, which this reader does not claim to support.
        guard magic == 42 else { return nil }
        let offset = Int(readU32(data, 4, endian))
        guard offset >= 0 else { return nil }
        return (endian, offset)
    }

    static func read(data: Data, ifdOffset: Int, endian: Endian, base: Int) -> TIFFDirectory? {
        guard ifdOffset >= 0, ifdOffset + 2 <= data.count else { return nil }
        let count = Int(readU16(data, ifdOffset, endian))
        let entries = ifdOffset + 2
        guard count < 10_000, entries + count * 12 <= data.count else { return nil }
        var fields: [Int: Field] = [:]
        for index in 0..<count {
            let entry = entries + index * 12
            let tag = Int(readU16(data, entry, endian))
            let type = Int(readU16(data, entry + 2, endian))
            let valueCount = Int(readU32(data, entry + 4, endian))
            guard valueCount >= 0, valueCount < 5_000_000, let size = unitSize(type) else { continue }
            let bytes = valueCount * size
            let valueOffset: Int
            if bytes <= 4 {
                valueOffset = entry + 8
            } else {
                let pointer = Int(readU32(data, entry + 8, endian))
                valueOffset = base + pointer
            }
            guard valueOffset >= 0, valueOffset + bytes <= data.count else { continue }
            let integers = readIntegers(data, valueOffset, endian, type: type, count: valueCount)
            let doubles = readDoubles(data, valueOffset, endian, type: type, count: valueCount, integers: integers)
            let ascii = type == 2 ? readASCII(data, valueOffset, valueCount) : ""
            fields[tag] = Field(
                type: type,
                count: valueCount,
                valueOffset: valueOffset,
                integers: integers,
                doubles: doubles,
                ascii: ascii
            )
        }
        return TIFFDirectory(data: data, endian: endian, fields: fields)
    }

    func field(_ tag: Int) -> Field? {
        fields[tag]
    }

    func int(_ tag: Int) -> Int? {
        fields[tag]?.integers.first
    }

    func doubles(_ tag: Int) -> [Double] {
        fields[tag]?.doubles ?? []
    }

    private static func unitSize(_ type: Int) -> Int? {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11: return 4
        case 5, 10, 12: return 8
        default: return nil
        }
    }

    private static func readIntegers(_ data: Data, _ offset: Int, _ endian: Endian, type: Int, count: Int) -> [Int] {
        var values: [Int] = []
        values.reserveCapacity(count)
        for index in 0..<count {
            let cursor = offset + index * (unitSize(type) ?? 1)
            switch type {
            case 1, 7:
                guard cursor < data.count else { return values }
                values.append(Int(data[cursor]))
            case 6:
                guard cursor < data.count else { return values }
                values.append(Int(Int8(bitPattern: data[cursor])))
            case 3:
                values.append(Int(readU16(data, cursor, endian)))
            case 8:
                values.append(Int(Int16(bitPattern: readU16(data, cursor, endian))))
            case 4:
                values.append(Int(readU32(data, cursor, endian)))
            case 9:
                values.append(Int(Int32(bitPattern: readU32(data, cursor, endian))))
            case 5, 10:
                let numerator = readU32(data, cursor, endian)
                let denominator = readU32(data, cursor + 4, endian)
                guard denominator != 0 else { continue }
                values.append(Int(numerator / denominator))
            default:
                break
            }
        }
        return values
    }

    private static func readDoubles(
        _ data: Data,
        _ offset: Int,
        _ endian: Endian,
        type: Int,
        count: Int,
        integers: [Int]
    ) -> [Double] {
        if [1, 3, 4, 6, 8, 9].contains(type) {
            return integers.map(Double.init)
        }
        var values: [Double] = []
        for index in 0..<count {
            switch type {
            case 5:
                let cursor = offset + index * 8
                let denominator = Double(readU32(data, cursor + 4, endian))
                guard denominator != 0 else { continue }
                values.append(Double(readU32(data, cursor, endian)) / denominator)
            case 10:
                let cursor = offset + index * 8
                let denominator = Double(Int32(bitPattern: readU32(data, cursor + 4, endian)))
                guard denominator != 0 else { continue }
                values.append(Double(Int32(bitPattern: readU32(data, cursor, endian))) / denominator)
            case 11:
                values.append(Double(readFloat(data, offset + index * 4, endian)))
            case 12:
                values.append(readDouble(data, offset + index * 8, endian))
            default:
                break
            }
        }
        return values
    }

    private static func readASCII(_ data: Data, _ offset: Int, _ count: Int) -> String {
        guard count > 0, offset + count <= data.count else { return "" }
        let bytes = data[offset..<(offset + count)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func readU16(_ data: Data, _ offset: Int, _ endian: Endian) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let lo = UInt16(data[offset])
        let hi = UInt16(data[offset + 1])
        switch endian {
        case .little: return lo | (hi << 8)
        case .big: return (lo << 8) | hi
        }
    }

    static func readU32(_ data: Data, _ offset: Int, _ endian: Endian) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for index in 0..<4 {
            let byte = UInt32(data[offset + index])
            switch endian {
            case .little: value |= byte << (8 * index)
            case .big: value = (value << 8) | byte
            }
        }
        return value
    }

    private static func readFloat(_ data: Data, _ offset: Int, _ endian: Endian) -> Float {
        let bits = readU32(data, offset, endian)
        return Float(bitPattern: bits)
    }

    private static func readDouble(_ data: Data, _ offset: Int, _ endian: Endian) -> Double {
        guard offset + 8 <= data.count else { return 0 }
        var bits: UInt64 = 0
        for index in 0..<8 {
            let byte = UInt64(data[offset + index])
            switch endian {
            case .little: bits |= byte << (8 * index)
            case .big: bits = (bits << 8) | byte
            }
        }
        return Double(bitPattern: bits)
    }
}
