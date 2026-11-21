import Foundation

struct PDFTextLine {
    let text: String
    let bounds: CGRect
    var fontSize: CGFloat? = nil
    var isBold: Bool = false
    var sourceLine: Int = 0
}
