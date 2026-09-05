import Foundation

/// OLE-Container: Sektoren, Ketten und benannte Streams, ohne Excel-Semantik.
struct OLECompoundDocument {
    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    static func hasSignature(_ data: Data) -> Bool { Array(data.prefix(signature.count)) == signature }
    private enum Limits { static let maximumStreamSize = 1_073_741_824 }
    private struct ParserError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }

    let data: Data
    let sectorSize: Int
    let miniSectorSize: Int
    let miniStreamCutoff: Int
    let fat: [UInt32]
    let miniFAT: [UInt32]
    let miniStream: Data
    private let entries: [DirectoryEntry]

    var entryNames: [String] { entries.map(\.name) }

    init(data: Data) throws {
        guard data.count >= 512,
              Self.hasSignature(data),
              data.legacyUInt16(at: 28) == 0xFFFE else {
            throw ParserError("the OLE compound-document header is invalid")
        }
        self.data = data
        let majorVersion = data.legacyUInt16(at: 26)
        let sectorShift = Int(data.legacyUInt16(at: 30))
        let miniSectorShift = Int(data.legacyUInt16(at: 32))
        guard (majorVersion == 3 && sectorShift == 9)
                || (majorVersion == 4 && sectorShift == 12),
              miniSectorShift == 6 else {
            throw ParserError("the OLE sector layout is unsupported")
        }
        sectorSize = 1 << sectorShift
        miniSectorSize = 1 << miniSectorShift
        miniStreamCutoff = Int(data.legacyUInt32(at: 56))
        guard data.count >= sectorSize,
              (data.count - sectorSize) % sectorSize == 0,
              miniStreamCutoff <= Limits.maximumStreamSize else {
            throw ParserError("the OLE file size or mini-stream cutoff is invalid")
        }

        let sectorCount = (data.count - sectorSize) / sectorSize
        let fatSectorCount = Int(data.legacyUInt32(at: 44))
        var fatSectorIDs = [UInt32]()
        for index in 0..<109 {
            let id = data.legacyUInt32(at: 76 + index * 4)
            if id != Constants.freeSector { fatSectorIDs.append(id) }
        }
        var difatSector = data.legacyUInt32(at: 68)
        let difatCount = Int(data.legacyUInt32(at: 72))
        var seenDIFAT = Set<UInt32>()
        for _ in 0..<difatCount {
            try ConversionExecution.check()
            guard difatSector < UInt32(sectorCount), seenDIFAT.insert(difatSector).inserted else {
                throw ParserError("the OLE DIFAT chain is invalid")
            }
            let sector = try Self.sector(difatSector, in: data, sectorSize: sectorSize)
            for index in 0..<(sectorSize / 4 - 1) {
                let id = sector.legacyUInt32(at: index * 4)
                if id != Constants.freeSector { fatSectorIDs.append(id) }
            }
            difatSector = sector.legacyUInt32(at: sectorSize - 4)
        }
        guard fatSectorIDs.count >= fatSectorCount else {
            throw ParserError("the OLE FAT sector list is incomplete")
        }
        fatSectorIDs = Array(fatSectorIDs.prefix(fatSectorCount))
        var parsedFAT = [UInt32]()
        for id in fatSectorIDs {
            try ConversionExecution.check()
            guard id < UInt32(sectorCount) else {
                throw ParserError("an OLE FAT sector lies outside the file")
            }
            let sector = try Self.sector(id, in: data, sectorSize: sectorSize)
            for offset in stride(from: 0, to: sector.count, by: 4) {
                parsedFAT.append(sector.legacyUInt32(at: offset))
            }
        }
        fat = parsedFAT

        let directoryStart = data.legacyUInt32(at: 48)
        let directoryData = try Self.standardStream(
            start: directoryStart,
            size: nil,
            data: data,
            sectorSize: sectorSize,
            fat: parsedFAT
        )
        guard directoryData.count >= 128 else {
            throw ParserError("the OLE directory stream is truncated")
        }
        var parsedEntries = [DirectoryEntry]()
        for offset in stride(from: 0, through: max(0, directoryData.count - 128), by: 128) {
            let nameByteCount = Int(directoryData.legacyUInt16(at: offset + 64))
            guard nameByteCount == 0
                    || nameByteCount >= 2 && nameByteCount <= 64 && nameByteCount % 2 == 0 else {
                throw ParserError("an OLE directory name is invalid")
            }
            guard nameByteCount > 0 else { continue }
            var units = [UInt16]()
            for nameOffset in stride(from: offset, to: offset + nameByteCount - 2, by: 2) {
                units.append(directoryData.legacyUInt16(at: nameOffset))
            }
            let name = String(decoding: units, as: UTF16.self)
            let type = directoryData[offset + 66]
            let start = directoryData.legacyUInt32(at: offset + 116)
            let lowSize = UInt64(directoryData.legacyUInt32(at: offset + 120))
            let highSize = majorVersion == 4
                ? UInt64(directoryData.legacyUInt32(at: offset + 124)) << 32
                : 0
            let size = highSize | lowSize
            guard size <= UInt64(Limits.maximumStreamSize) else {
                throw ParserError("an OLE stream exceeds the supported size limit")
            }
            parsedEntries.append(
                DirectoryEntry(name: name, type: type, startSector: start, size: Int(size))
            )
        }
        entries = parsedEntries
        guard let root = parsedEntries.first(where: { $0.type == 5 }) else {
            throw ParserError("the OLE root directory is missing")
        }
        miniStream = try Self.standardStream(
            start: root.startSector,
            size: root.size,
            data: data,
            sectorSize: sectorSize,
            fat: parsedFAT
        )
        let firstMiniFAT = data.legacyUInt32(at: 60)
        let miniFATSectorCount = Int(data.legacyUInt32(at: 64))
        if miniFATSectorCount > 0 {
            let miniFATData = try Self.standardStream(
                start: firstMiniFAT,
                size: miniFATSectorCount * sectorSize,
                data: data,
                sectorSize: sectorSize,
                fat: parsedFAT
            )
            var parsedMiniFAT = [UInt32]()
            for offset in stride(from: 0, to: miniFATData.count, by: 4) {
                parsedMiniFAT.append(miniFATData.legacyUInt32(at: offset))
            }
            miniFAT = parsedMiniFAT
        } else {
            miniFAT = []
        }
    }

    func stream(named name: String) throws -> Data? {
        guard let entry = entries.first(where: {
            $0.type == 2 && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            return nil
        }
        if entry.size < miniStreamCutoff {
            return try Self.miniStream(
                start: entry.startSector,
                size: entry.size,
                miniStream: miniStream,
                miniSectorSize: miniSectorSize,
                miniFAT: miniFAT
            )
        }
        return try Self.standardStream(
            start: entry.startSector,
            size: entry.size,
            data: data,
            sectorSize: sectorSize,
            fat: fat
        )
    }

    private static func standardStream(
        start: UInt32,
        size: Int?,
        data: Data,
        sectorSize: Int,
        fat: [UInt32]
    ) throws -> Data {
        var result = Data()
        var current = start
        var seen = Set<UInt32>()
        while current != Constants.endOfChain {
            try ConversionExecution.check()
            guard current < UInt32(fat.count), seen.insert(current).inserted else {
                throw ParserError("an OLE sector chain is invalid")
            }
            result.append(try sector(current, in: data, sectorSize: sectorSize))
            if result.count > Limits.maximumStreamSize {
                throw ParserError("an OLE stream exceeds the supported size limit")
            }
            current = fat[Int(current)]
            if current == Constants.freeSector || current == Constants.fatSector
                || current == Constants.difatSector {
                throw ParserError("an OLE sector chain ends in an invalid marker")
            }
        }
        if let size {
            guard result.count >= size else {
                throw ParserError("an OLE stream is shorter than declared")
            }
            result.count = size
        }
        return result
    }

    private static func miniStream(
        start: UInt32,
        size: Int,
        miniStream: Data,
        miniSectorSize: Int,
        miniFAT: [UInt32]
    ) throws -> Data {
        var result = Data()
        var current = start
        var seen = Set<UInt32>()
        while current != Constants.endOfChain, result.count < size {
            try ConversionExecution.check()
            guard current < UInt32(miniFAT.count), seen.insert(current).inserted else {
                throw ParserError("an OLE mini-sector chain is invalid")
            }
            let offset = Int(current) * miniSectorSize
            guard offset + miniSectorSize <= miniStream.count else {
                throw ParserError("an OLE mini-sector lies outside the mini stream")
            }
            result.append(miniStream.subdata(in: offset..<(offset + miniSectorSize)))
            current = miniFAT[Int(current)]
        }
        guard result.count >= size else {
            throw ParserError("an OLE mini stream is shorter than declared")
        }
        result.count = size
        return result
    }

    private static func sector(
        _ id: UInt32,
        in data: Data,
        sectorSize: Int
    ) throws -> Data {
        let offset = (Int(id) + 1) * sectorSize
        guard offset >= sectorSize, offset + sectorSize <= data.count else {
            throw ParserError("an OLE sector lies outside the file")
        }
        return data.subdata(in: offset..<(offset + sectorSize))
    }

    private struct DirectoryEntry {
        let name: String
        let type: UInt8
        let startSector: UInt32
        let size: Int
    }

    private enum Constants {
        static let freeSector: UInt32 = 0xFFFF_FFFF
        static let endOfChain: UInt32 = 0xFFFF_FFFE
        static let fatSector: UInt32 = 0xFFFF_FFFD
        static let difatSector: UInt32 = 0xFFFF_FFFC
    }
}

