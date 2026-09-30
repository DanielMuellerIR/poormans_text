import Foundation

/// Baut für eingebettete Nachrichten einen eigenständigen MSG-Container. Die
/// Wertstreams bleiben bytegleich; nur der Message-Header bekommt acht Root-Reservebytes.
enum MSGEmbeddedWriter {
    private struct Entry {
        let name: String
        let storage: Bool
        var left: UInt32 = .max
        var right: UInt32 = .max
        var child: UInt32 = .max
        var color: UInt8 = 1
        var start: UInt32 = 0xFFFF_FFFE
        var size = 0
    }

    static func export(_ tree: OLECompoundDocument.StorageTree, storage: [String]) throws -> Data {
        var streams = [[String]: Data]()
        var total = 0
        let prefix = storage.map { $0.uppercased() }
        for path in tree.streamPaths where path.prefix(storage.count).map({ $0.uppercased() }) == prefix {
            try ConversionExecution.check()
            let relative = Array(path.dropFirst(storage.count))
            guard !relative.isEmpty, let bytes = try tree.stream(at: path) else { continue }
            total += bytes.count
            guard total <= MIMEMessage.maximumSourceBytes else {
                throw MSGProperties.Failure(reason: "the embedded MSG exceeds the size limit")
            }
            streams[relative] = bytes
        }
        guard let propertyPath = streams.keys.first(where: { $0.count == 1 && $0[0].lowercased() == "__properties_version1.0" }),
              let properties = streams[propertyPath], properties.count >= 24,
              (properties.count - 24) % 16 == 0 else {
            throw MSGProperties.Failure(reason: "the embedded MSG property header is invalid")
        }
        streams[propertyPath] = properties.prefix(24) + Data(repeating: 0, count: 8) + properties.dropFirst(24)
        // Named-Property-Mappings gehören zum äußeren Messageobjekt und gelten
        // auch für Unterobjekte. Die eigenständige Kopie braucht ihre Zuordnung.
        if !streams.keys.contains(where: { $0.first?.lowercased() == "__nameid_version1.0" }) {
            for path in tree.streamPaths where path.first?.lowercased() == "__nameid_version1.0" {
                if let bytes = try tree.stream(at: path) { streams[path] = bytes }
            }
        }
        return try compound(streams)
    }

    static func compound(_ streams: [[String]: Data]) throws -> Data {
        guard streams.count <= 100_000, streams.values.reduce(0, { $0 + $1.count }) <= MIMEMessage.maximumSourceBytes else {
            throw MSGProperties.Failure(reason: "the MSG export has too many streams or bytes")
        }
        var paths: Set<[String]> = [[]]
        for path in streams.keys {
            guard !path.isEmpty, path.count <= 32 else { throw MSGProperties.Failure(reason: "the MSG export path is invalid") }
            for count in 1...path.count { paths.insert(Array(path.prefix(count))) }
        }
        let ordered = paths.sorted { a, b in
            if a.count != b.count { return a.count < b.count }
            return a.lexicographicallyPrecedes(b)
        }
        let ids = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, UInt32($0.offset)) })
        var entries = ordered.map { Entry(name: $0.last ?? "Root Entry", storage: streams[$0] == nil) }
        var childrenByParent = [[String]: [[String]]]()
        for path in ordered where !path.isEmpty {
            let parent = Array(path.dropLast())
            guard streams[parent] == nil else { throw MSGProperties.Failure(reason: "a MSG export stream has children") }
            childrenByParent[parent, default: []].append(path)
        }
        for path in ordered {
            try ConversionExecution.check()
            guard let id = ids[path], entries[Int(id)].storage else { continue }
            let children = (childrenByParent[path] ?? [])
                .sorted { a, b in
                    let left = a.last!.uppercased(), right = b.last!.uppercased()
                    return left.utf16.count == right.utf16.count
                        ? left.utf16.lexicographicallyPrecedes(right.utf16) : left.utf16.count < right.utf16.count
                }.map { ids[$0]! }
            var redLevel = 0
            var count = children.count - 1
            while count >= 0 { redLevel += 1; count = count / 2 - 1 }
            func build(_ low: Int, _ high: Int, _ level: Int) -> UInt32 {
                guard low <= high else { return .max }
                let middle = (low + high) / 2
                let child = children[middle]
                entries[Int(child)].left = build(low, middle - 1, level + 1)
                entries[Int(child)].right = build(middle + 1, high, level + 1)
                entries[Int(child)].color = level == redLevel ? 0 : 1
                return child
            }
            entries[Int(id)].child = build(0, children.count - 1, 0)
        }
        var sectors = [Data]()
        var fat = [UInt32]()
        func allocate(_ data: Data) -> UInt32 {
            guard !data.isEmpty else { return 0xFFFF_FFFE }
            let start = UInt32(sectors.count)
            let count = (data.count + 511) / 512
            for i in 0..<count {
                let begin = data.startIndex + i * 512
                let end = min(begin + 512, data.endIndex)
                var sector = Data(data[begin..<end])
                sector.append(Data(repeating: 0, count: 512 - sector.count))
                sectors.append(sector)
                fat.append(i == count - 1 ? 0xFFFF_FFFE : start + UInt32(i + 1))
            }
            return start
        }
        var mini = Data()
        var miniFAT = [UInt32]()
        for path in ordered {
            try ConversionExecution.check()
            guard let data = streams[path], let id = ids[path] else { continue }
            entries[Int(id)].size = data.count
            guard !data.isEmpty else { continue }
            if data.count < 4096 {
                let start = UInt32(miniFAT.count)
                entries[Int(id)].start = start
                let count = (data.count + 63) / 64
                mini.append(data); mini.append(Data(repeating: 0, count: count * 64 - data.count))
                for i in 0..<count { miniFAT.append(i == count - 1 ? 0xFFFF_FFFE : start + UInt32(i + 1)) }
            } else { entries[Int(id)].start = allocate(data) }
        }
        entries[0].start = allocate(mini); entries[0].size = mini.count
        var miniTable = Data()
        for item in miniFAT { append32(item, to: &miniTable) }
        while miniTable.count % 512 != 0 { append32(.max, to: &miniTable) }
        let miniStart = allocate(miniTable)
        var directory = Data(repeating: 0, count: ((entries.count + 3) / 4) * 512)
        for (id, entry) in entries.enumerated() {
            let offset = id * 128
            let name = Array((entry.name + "\0").utf16)
            guard name.count <= 32 else { throw MSGProperties.Failure(reason: "the MSG export name is too long") }
            for (index, unit) in name.enumerated() { put16(unit, at: offset + index * 2, in: &directory) }
            put16(UInt16(name.count * 2), at: offset + 64, in: &directory)
            directory[offset + 66] = id == 0 ? 5 : entry.storage ? 1 : 2
            directory[offset + 67] = entry.color
            if id == 0 {
                let messageClass: [UInt8] = [0x0B, 0x0D, 0x02, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46]
                directory.replaceSubrange((offset + 80)..<(offset + 96), with: messageClass)
            }
            put32(entry.left, at: offset + 68, in: &directory)
            put32(entry.right, at: offset + 72, in: &directory)
            put32(entry.child, at: offset + 76, in: &directory)
            put32(entry.start, at: offset + 116, in: &directory)
            put32(UInt32(entry.size), at: offset + 120, in: &directory)
        }
        let directoryStart = allocate(directory)
        let base = sectors.count
        var fatCount = 0, difatCount = 0
        while true {
            let nextFAT = (base + fatCount + difatCount + 127) / 128
            let nextDIFAT = max(0, (nextFAT - 109 + 126) / 127)
            if nextFAT == fatCount && nextDIFAT == difatCount { break }
            fatCount = nextFAT; difatCount = nextDIFAT
        }
        guard (base + fatCount + difatCount + 1) * 512 <= MIMEMessage.maximumSourceBytes * 2 else {
            throw MSGProperties.Failure(reason: "the MSG export exceeds the container size limit")
        }
        let fatIDs = (0..<fatCount).map { UInt32(base + $0) }
        fat += Array(repeating: 0xFFFF_FFFD, count: fatCount)
        fat += Array(repeating: 0xFFFF_FFFC, count: difatCount)
        while fat.count < fatCount * 128 { fat.append(.max) }
        for i in 0..<fatCount {
            var data = Data()
            for item in fat[(i * 128)..<((i + 1) * 128)] { append32(item, to: &data) }
            sectors.append(data)
        }
        for i in 0..<difatCount {
            var data = Data()
            for j in 0..<127 {
                let index = 109 + i * 127 + j
                append32(index < fatIDs.count ? fatIDs[index] : .max, to: &data)
            }
            append32(i == difatCount - 1 ? 0xFFFF_FFFE : UInt32(base + fatCount + i + 1), to: &data)
            sectors.append(data)
        }
        var header = Data(repeating: 0, count: 512)
        header.replaceSubrange(0..<8, with: OLECompoundDocument.signature)
        put16(0x003E, at: 24, in: &header); put16(3, at: 26, in: &header)
        put16(0xFFFE, at: 28, in: &header); put16(9, at: 30, in: &header); put16(6, at: 32, in: &header)
        put32(UInt32(fatCount), at: 44, in: &header); put32(directoryStart, at: 48, in: &header)
        put32(4096, at: 56, in: &header); put32(miniStart, at: 60, in: &header)
        put32(UInt32(miniTable.count / 512), at: 64, in: &header)
        put32(difatCount == 0 ? 0xFFFF_FFFE : UInt32(base + fatCount), at: 68, in: &header)
        put32(UInt32(difatCount), at: 72, in: &header)
        for i in 0..<109 { put32(i < fatIDs.count ? fatIDs[i] : .max, at: 76 + i * 4, in: &header) }
        for sector in sectors { header.append(sector) }
        return header
    }

    private static func append32(_ value: UInt32, to data: inout Data) {
        for i in 0..<4 { data.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
    }
    private static func put32(_ value: UInt32, at offset: Int, in data: inout Data) {
        for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
    private static func put16(_ value: UInt16, at offset: Int, in data: inout Data) {
        data[offset] = UInt8(truncatingIfNeeded: value); data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
}
