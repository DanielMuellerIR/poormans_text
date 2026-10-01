import CoreGraphics
import PDFKit

/// Ein Tabellenbeleg braucht ein geschlossenes Gitter. Ausrichtung allein
/// unterscheidet eine Tabelle nicht von nebeneinander gesetztem Fließtext.
enum PDFTableGeometry {
    struct Grid {
        let columns: [CGFloat]
        let rows: [CGFloat]
        var bounds: CGRect { CGRect(x: columns.first!, y: rows.last!, width: columns.last! - columns.first!, height: rows.first! - rows.last!) }
    }

    static func grids(on page: PDFPage, textHeight: CGFloat) -> [Grid] {
        guard page.rotation == 0, let reference = page.pageRef, let table = CGPDFOperatorTableCreate() else { return [] }
        let stream = CGPDFContentStreamCreateWithPage(reference)
        let state = PathReader()
        CGPDFOperatorTableSetCallback(table, "q", { _, p in PDFTableGeometry.reader(p).save() })
        CGPDFOperatorTableSetCallback(table, "Q", { _, p in PDFTableGeometry.reader(p).restore() })
        CGPDFOperatorTableSetCallback(table, "cm", { s, p in PDFTableGeometry.reader(p).transform(s) })
        CGPDFOperatorTableSetCallback(table, "w", { s, p in PDFTableGeometry.reader(p).width(s) })
        CGPDFOperatorTableSetCallback(table, "m", { s, p in PDFTableGeometry.reader(p).move(s) })
        CGPDFOperatorTableSetCallback(table, "l", { s, p in PDFTableGeometry.reader(p).line(s) })
        CGPDFOperatorTableSetCallback(table, "re", { s, p in PDFTableGeometry.reader(p).rectangle(s) })
        CGPDFOperatorTableSetCallback(table, "h", { _, p in PDFTableGeometry.reader(p).close() })
        for name in ["S", "B", "B*"] { CGPDFOperatorTableSetCallback(table, name, { _, p in PDFTableGeometry.reader(p).paint(stroke: true) }) }
        for name in ["s", "b", "b*"] { CGPDFOperatorTableSetCallback(table, name, { _, p in
            let reader = PDFTableGeometry.reader(p)
            reader.close()
            reader.paint(stroke: true)
        }) }
        for name in ["f", "F", "f*"] { CGPDFOperatorTableSetCallback(table, name, { _, p in PDFTableGeometry.reader(p).paint(stroke: false) }) }
        CGPDFOperatorTableSetCallback(table, "n", { _, p in PDFTableGeometry.reader(p).clear() })
        for name in ["c", "v", "y"] { CGPDFOperatorTableSetCallback(table, name, { _, p in PDFTableGeometry.reader(p).curved = true }) }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(state).toOpaque())
        guard CGPDFScannerScan(scanner), !state.exhausted, state.ink.count <= 1_024 else { return [] }
        let horizontal = merged(state.ink.filter { $0.height < textHeight && $0.width > $0.height }, horizontal: true)
        let vertical = merged(state.ink.filter { $0.width < textHeight && $0.height > $0.width }, horizontal: false)
        var result: [Grid] = []
        for top in horizontal {
            let columns = vertical.filter { line in touches(line, top) }.sorted { $0.midX < $1.midX }
            guard columns.count >= 3, let first = columns.first, let last = columns.last,
                  abs(first.midX - top.minX) <= max(first.width, top.height),
                  abs(last.midX - top.maxX) <= max(last.width, top.height) else { continue }
            let rows = horizontal.filter { line in
                line.midY <= top.midY && abs(line.minX - top.minX) <= max(line.height, top.height)
                    && abs(line.maxX - top.maxX) <= max(line.height, top.height)
                    && columns.allSatisfy { touches(line, $0) }
            }.sorted { $0.midY > $1.midY }
            guard rows.count >= 3 else { continue }
            let grid = Grid(columns: columns.map(\.midX), rows: rows.map(\.midY))
            if !result.contains(where: { $0.bounds.contains(grid.bounds) }) {
                result.removeAll { grid.bounds.contains($0.bounds) }
                result.append(grid)
            }
        }
        return result
    }

    private static func touches(_ a: CGRect, _ b: CGRect) -> Bool {
        // Strichbreiten sind die Messtoleranz, auch für aneinanderstoßende
        // gefüllte Randsegmente mit Rundungsabweichungen im PDF.
        a.insetBy(dx: -min(a.width, a.height) / 2, dy: -min(a.width, a.height) / 2).intersects(b)
    }

    private static func reader(_ pointer: UnsafeMutableRawPointer?) -> PathReader { Unmanaged<PathReader>.fromOpaque(pointer!).takeUnretainedValue() }

    private static func merged(_ input: [CGRect], horizontal: Bool) -> [CGRect] {
        var output: [CGRect] = []
        for var rectangle in input {
            var index = 0
            while index < output.count {
                let other = output[index]
                let aligned = horizontal ? rectangle.minY < other.maxY && other.minY < rectangle.maxY : rectangle.minX < other.maxX && other.minX < rectangle.maxX
                let tolerance = horizontal ? max(rectangle.height, other.height) : max(rectangle.width, other.width)
                if aligned && rectangle.insetBy(dx: horizontal ? -tolerance : 0, dy: horizontal ? 0 : -tolerance).intersects(other) {
                    rectangle = rectangle.union(output.remove(at: index)); index = 0
                } else { index += 1 }
            }
            output.append(rectangle)
        }
        return output
    }

    private final class PathReader {
        var matrix = CGAffineTransform.identity
        var lineWidth: CGFloat = 1
        var stack: [(CGAffineTransform, CGFloat)] = []
        var paths: [[CGPoint]] = []
        var curved = false
        var ink: [CGRect] = []
        var remaining = 100_000
        var exhausted = false
        func tick() -> Bool {
            remaining -= 1
            if remaining < 0 || ink.count > 1_024 || ConversionExecution.isCancelled { exhausted = true }
            return !exhausted
        }
        func numbers(_ scanner: CGPDFScannerRef?, count: Int) -> [CGFloat]? {
            guard tick(), let scanner else { return nil }
            var values = [CGFloat]()
            for _ in 0..<count {
                var value: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &value), value.isFinite else { return nil }
                values.insert(CGFloat(value), at: 0)
            }
            return values
        }
        func save() { if tick(), stack.count < 64 { stack.append((matrix, lineWidth)) } else { exhausted = true } }
        func restore() { if tick(), let value = stack.popLast() { (matrix, lineWidth) = value } else { exhausted = true } }
        func transform(_ scanner: CGPDFScannerRef?) {
            guard let n = numbers(scanner, count: 6) else { return }
            matrix = CGAffineTransform(a:n[0], b:n[1], c:n[2], d:n[3], tx:n[4], ty:n[5]).concatenating(matrix)
        }
        func width(_ scanner: CGPDFScannerRef?) { if let n = numbers(scanner, count: 1) { lineWidth = abs(n[0]) } }
        func move(_ scanner: CGPDFScannerRef?) { if let n = numbers(scanner, count: 2) { paths.append([CGPoint(x:n[0],y:n[1]).applying(matrix)]) } }
        func line(_ scanner: CGPDFScannerRef?) { if let n = numbers(scanner, count: 2), !paths.isEmpty { paths[paths.count-1].append(CGPoint(x:n[0],y:n[1]).applying(matrix)) } }
        func rectangle(_ scanner: CGPDFScannerRef?) {
            guard let n = numbers(scanner, count: 4) else { return }
            paths.append([CGPoint(x:n[0],y:n[1]), CGPoint(x:n[0]+n[2],y:n[1]), CGPoint(x:n[0]+n[2],y:n[1]+n[3]), CGPoint(x:n[0],y:n[1]+n[3])].map { $0.applying(matrix) })
            close()
        }
        func close() { if tick(), let first = paths.last?.first { paths[paths.count-1].append(first) } }
        func clear() { paths = []; curved = false }
        func paint(stroke: Bool) {
            defer { clear() }
            guard tick(), !curved else { return }
            for path in paths {
                if stroke {
                    let thickness = max(lineWidth * hypot(matrix.a, matrix.b), lineWidth * hypot(matrix.c, matrix.d))
                    for (a,b) in zip(path,path.dropFirst()) where a.x == b.x || a.y == b.y {
                        let r = CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y))
                        ink.append(r.insetBy(dx: a.x == b.x ? -thickness/2 : 0, dy: a.y == b.y ? -thickness/2 : 0))
                    }
                } else if path.count >= 4 && path.count <= 5 {
                    let xs = Set(path.map(\.x)), ys = Set(path.map(\.y))
                    if xs.count == 2 && ys.count == 2 { ink.append(CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)) }
                }
            }
        }
    }
}
