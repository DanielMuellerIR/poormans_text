import CoreGraphics
import PDFKit

/// Sucht effektive größere Bildressourcen, auch in Form-XObjects.
/// Ressourcen sind ein Hinweis auf Scaninhalt, keine Zusage über ihre Platzierung.
enum PDFImageResources {
    static func containsScanCandidate(on page: PDFPage) -> Bool {
        guard let pageReference = page.pageRef,
              let dictionary = pageReference.dictionary else { return false }
        let scanner = Scanner()
        scanner.visit(dictionary, depth: 0, inheritPageResources: true)
        return scanner.found
    }

    private final class Context {
        let scanner: Scanner
        let depth: Int
        init(_ scanner: Scanner, _ depth: Int) { self.scanner = scanner; self.depth = depth }
    }

    private final class Scanner {
        var remaining = 10_000
        var found = false
        func visit(_ dictionary: CGPDFDictionaryRef, depth: Int, inheritPageResources: Bool = false) {
            guard !ConversionExecution.isCancelled, depth < 16, remaining > 0, !found else { return }
            remaining -= 1
            var resources: CGPDFDictionaryRef?
            var objects: CGPDFDictionaryRef?
            var current = dictionary
            var visited = Set<CGPDFDictionaryRef>()
            // Nur Seiten erben Ressourcen. Ein eigenes Wörterbuch ersetzt das
            // geerbte vollständig; Form-XObjects folgen keiner Parent-Kette.
            for _ in 0..<64 {
                guard !ConversionExecution.isCancelled, visited.insert(current).inserted else { return }
                var declared: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(current, "Resources", &declared) {
                    _ = CGPDFDictionaryGetDictionary(current, "Resources", &resources)
                    break
                }
                var parent: CGPDFDictionaryRef?
                guard inheritPageResources,
                      CGPDFDictionaryGetDictionary(current, "Parent", &parent), let parent else { return }
                current = parent
            }
            guard let resources,
                  CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return }
            let context = Context(self, depth)
            CGPDFDictionaryApplyFunction(objects, { _, object, pointer in
                guard let pointer else { return }
                let context = Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue()
                let scanner = context.scanner
                guard scanner.remaining > 0, !scanner.found else { return }
                scanner.remaining -= 1
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let dictionary = CGPDFStreamGetDictionary(stream) else { return }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
                if String(cString: subtype) == "Image" {
                    var width: CGPDFInteger = 0
                    var height: CGPDFInteger = 0
                    if CGPDFDictionaryGetInteger(dictionary, "Width", &width),
                       CGPDFDictionaryGetInteger(dictionary, "Height", &height), width >= 256, height >= 128 {
                        scanner.found = true
                    }
                } else if String(cString: subtype) == "Form" { scanner.visit(dictionary, depth: context.depth + 1) }
            }, Unmanaged.passUnretained(context).toOpaque())
        }
    }
}
