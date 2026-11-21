import PoorMansTextAppSupport
import PoorMansTextCore
import SwiftUI

struct ConversionOptionsView: View {
    @ObservedObject var settings: ConversionSettings
    let acceptsNewDocuments: Bool
    let chooseDestinationFolder: () -> Void

    var body: some View {
        DisclosureGroup("Conversion Options") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Destination")
                    Text(settings.values.destinationFolder?.path ?? NSLocalizedString("Next to each source", comment: ""))
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseDestinationFolder() }
                        .help("Selects the folder where the app will create new conversion results.")
                    if settings.values.destinationFolder != nil {
                        Button("Reset") { settings.values.destinationFolder = nil }
                            .help("Saves new results next to their source documents again.")
                    }
                }
                Picker("Tables", selection: $settings.values.spreadsheetRendering) {
                    Text("Markdown tables").tag(SpreadsheetRendering.markdownTable)
                    Text("Tab-separated text").tag(SpreadsheetRendering.tabSeparated)
                }
                .help("Markdown creates a readable table. Tab-separated text separates cells with tabs for use in spreadsheet tools.")
                Picker("DOCX text changes", selection: $settings.values.docxChangeMode) {
                    Text("Accept changes").tag(DOCXChangeMode.accept)
                    Text("Reject changes").tag(DOCXChangeMode.reject)
                    Text("Mark changes visibly").tag(DOCXChangeMode.mark)
                }
                .accessibilityIdentifier("docxChangeMode")
                .help("Applies to DOCX text changes. Comments retain their author, date and source reference. Other document formats keep their existing behavior.")
                Picker("Images", selection: $settings.values.imageTextRecognition) {
                    Text("Add local OCR text").tag(ImageTextRecognition.enabled)
                    Text("Keep only the image").tag(ImageTextRecognition.disabled)
                }
                .help("Run local text recognition to include text found in images, or keep just the image.")
                Picker("PDF OCR", selection: $settings.values.pdfTextRecognition) {
                    Text("Automatic").tag(PDFTextRecognition.automatic)
                    Text("Always").tag(PDFTextRecognition.always)
                    Text("Off").tag(PDFTextRecognition.disabled)
                }
                .help("Automatic recognizes text on pages without usable embedded text. Always also checks pages with embedded text. Off uses the existing text layer.")
                Picker("OCR method", selection: $settings.values.ocrMethod) {
                    Text("Standard OCR").tag(OCRMethod.standard)
                    Text("Structured OCR (macOS 26+)").tag(OCRMethod.structured)
                }
                .accessibilityIdentifier("ocrMethod")
                .help("Structured OCR preserves paragraphs, lists and tables. If unavailable or uncertain, standard OCR is used with a diagnostic.")
                TextField("OCR languages (empty: automatic; e.g. de,en)", text: $settings.values.ocrLanguageCodes)
                    .help("Separate language codes with commas, such as de,en for German and English. Leave empty for automatic selection.")
                Picker("PDF text order", selection: $settings.values.pdfLayout) {
                    Text("Automatic layout").tag(PDFLayout.automatic)
                    Text("Legacy extraction").tag(PDFLayout.legacy)
                }
                .help("Automatic tries to identify columns and reading order. Try legacy extraction if the resulting order is hard to read.")
                Toggle("Remove repeated PDF headers and footers", isOn: $settings.values.pdfRemoveHeadersFooters)
                    .help("Omits repeated lines identified as headers or footers from the PDF output.")
                Toggle("Join conservative PDF word breaks", isOn: $settings.values.pdfDehyphenate)
                    .help("Joins words when a PDF line break is likely to be a hyphenation break.")
                Toggle("Include presentation notes", isOn: $settings.values.presentationIncludeNotes)
                    .help("Includes presenter notes when converting presentations.")
                Toggle("Record source locations", isOn: $settings.values.sourceMapping)
                    .help("Links Markdown sections to their locations in the source, such as PDF pages, when possible. This helps when comparing the output with the source.")
                Toggle("Write conversion report", isOn: $settings.values.conversionReport)
                    .help("Saves a JSON file alongside the Markdown with conversion details, tools used and warnings.")
                Picker("Batch documents at once", selection: $settings.values.batchParallelism) {
                    ForEach(1...4, id: \.self) { Text(String($0)).tag($0) }
                }
                .help("Number of documents processed at once. A higher value may use more memory.")
                Text("Local OCR processes one image at a time.").font(.caption)
                Toggle("Add YAML frontmatter", isOn: $settings.values.frontmatter)
                    .help("Writes details such as the title, author or date in a block at the top of the Markdown file. A line of three dashes (---) opens and closes the block. Other tools can read these details separately from the text.")
                Picker("Output", selection: $settings.values.outputLayout) {
                    Text("Markdown folder").tag(OutputLayout.markdownFolder)
                    Text("Textbundle").tag(OutputLayout.textbundle)
                }
                .help("Choose a plain output folder or package Markdown and images in a .textbundle folder for apps such as iA Writer.")
            }
            .padding(.top, 8)
            .disabled(!acceptsNewDocuments)
        }
    }
}
