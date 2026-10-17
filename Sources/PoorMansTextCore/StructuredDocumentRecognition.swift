import Foundation

/// Interner Vorversuch: Volltext und Struktur sind alternative Sichten auf
/// dieselben Pixel. Sie dürfen nicht aneinandergehängt werden.
struct StructuredDocumentRecognition: Codable, Equatable, Sendable {
    let documents: [Document]
    let languages: [String]

    struct Text: Codable, Equatable, Sendable {
        let text: String
        /// Normalisiert, Ursprung links unten im orientierten Bild.
        let bounds: CGRect
    }

    struct Document: Codable, Equatable, Sendable {
        let text: Text
        let paragraphs: [Text]
        let lists: [List]
        let tables: [Table]
    }

    struct List: Codable, Equatable, Sendable {
        let bounds: CGRect
        let items: [Item]

        struct Item: Codable, Equatable, Sendable {
            let text: Text
            let marker: String
            let markerKind: MarkerKind?
        }

        enum MarkerKind: String, Codable, Sendable {
            case bullet, hyphen, lowercaseLatin, uppercaseLatin
            case decimal, decorativeDecimal, compositeDecimal
        }
    }

    struct Table: Codable, Equatable, Sendable {
        let bounds: CGRect
        /// Jede Zelle einmal; nullbasierte, inklusive Spannen von Vision.
        let cells: [Cell]

        struct Cell: Codable, Equatable, Sendable {
            let rows: ClosedRange<Int>
            let columns: ClosedRange<Int>
            let text: Text
        }
    }
}
