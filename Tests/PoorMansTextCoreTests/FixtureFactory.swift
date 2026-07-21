import AppKit
import Foundation

struct RichRTFDFixture {
    let packageURL: URL
    let imageData: [Data]
}

enum FixtureFactory {
    static func createRichRTFD(in directory: URL) throws -> RichRTFDFixture {
        let document = NSMutableAttributedString()
        append("Start ", to: document)
        append(
            "bold",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 14)],
            to: document
        )
        append(" before ", to: document)

        let firstImage = try makePNG(color: .systemRed)
        appendImage(
            firstImage,
            preferredFilename: "first image ä.png",
            to: document
        )

        append(" then ", to: document)
        append(
            "italic",
            attributes: [
                .font: NSFontManager.shared.convert(
                    NSFont.systemFont(ofSize: 14),
                    toHaveTrait: .italicFontMask
                ),
            ],
            to: document
        )
        append(" and ", to: document)
        append(
            "example",
            attributes: [.link: URL(string: "https://example.com/path")!],
            to: document
        )
        append(".\nSecond ", to: document)

        let secondImage = try makePNG(color: .systemBlue)
        appendImage(
            secondImage,
            preferredFilename: "second & image.png",
            to: document
        )
        append(" ends here.\n", to: document)

        let listStart = document.length
        append("First item\nSecond item\n", to: document)
        let listStyle = NSMutableParagraphStyle()
        listStyle.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        document.addAttribute(
            .paragraphStyle,
            value: listStyle,
            range: NSRange(location: listStart, length: document.length - listStart)
        )

        let packageURL = directory.appendingPathComponent("Example ä.rtfd", isDirectory: true)
        let wrapper = try document.fileWrapper(
            from: NSRange(location: 0, length: document.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        try wrapper.write(to: packageURL, options: .atomic, originalContentsURL: nil)

        return RichRTFDFixture(
            packageURL: packageURL,
            imageData: [firstImage, secondImage]
        )
    }

    static func createMinimalRTFD(in directory: URL, name: String = "Minimal.rtfd") throws -> URL {
        let packageURL = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: false)
        let rtf = #"{\rtf1\ansi Minimal}"#
        try Data(rtf.utf8).write(to: packageURL.appendingPathComponent("TXT.rtf"))
        return packageURL
    }

    static func createDuplicateImageNameRTFD(in directory: URL) throws -> RichRTFDFixture {
        let document = NSMutableAttributedString(string: "One ")
        let firstImage = try makePNG(color: .systemGreen)
        let secondImage = try makePNG(color: .systemOrange)
        appendImage(firstImage, preferredFilename: "same image.png", to: document)
        append(" two ", to: document)
        appendImage(secondImage, preferredFilename: "same image.png", to: document)
        append(" done.", to: document)

        let packageURL = directory.appendingPathComponent("Duplicates.rtfd", isDirectory: true)
        let wrapper = try document.fileWrapper(
            from: NSRange(location: 0, length: document.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        try wrapper.write(to: packageURL, options: .atomic, originalContentsURL: nil)

        return RichRTFDFixture(
            packageURL: packageURL,
            imageData: [firstImage, secondImage]
        )
    }

    private static func append(
        _ text: String,
        attributes: [NSAttributedString.Key: Any] = [:],
        to document: NSMutableAttributedString
    ) {
        var attributes = attributes
        if attributes[.font] == nil {
            attributes[.font] = NSFont.systemFont(ofSize: 14)
        }
        document.append(NSAttributedString(string: text, attributes: attributes))
    }

    private static func appendImage(
        _ data: Data,
        preferredFilename: String,
        to document: NSMutableAttributedString
    ) {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = preferredFilename
        document.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
    }

    private static func makePNG(color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw FixtureError.imageCreationFailed
        }
        return png
    }

    private enum FixtureError: Error {
        case imageCreationFailed
    }
}
