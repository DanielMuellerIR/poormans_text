// swift-tools-version: 6.2
import PackageDescription

var products: [Product] = [
    .library(name: "PoorMansTextCore", targets: ["PoorMansTextCore"]),
    .executable(name: "poormans-text", targets: ["PoorMansTextCLI"]),
]
var dependencies: [Package.Dependency] = []
var coreDependencies: [Target.Dependency] = []
var coreResources: [Resource] = []
var targets: [Target] = []

#if os(Linux)
coreResources = [.copy("LinuxBackends")]
dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", exact: "4.2.0"))
coreDependencies += [.product(name: "Crypto", package: "swift-crypto"), "CPMTLinux", "zlib"]
products.append(.executable(name: "poormans-text-process-guard", targets: ["PoorMansTextProcessGuard"]))
targets += [
    .target(name: "CPMTLinux", linkerSettings: [.linkedLibrary("png16")]),
    .systemLibrary(name: "zlib", path: "Sources/CZlib", pkgConfig: "zlib",
                   providers: [.apt(["zlib1g-dev"])]),
    .executableTarget(name: "PoorMansTextProcessGuard", linkerSettings: [.unsafeFlags(["-static-stdlib"])]),
]
#else
// Der Updater bleibt exakt gepinnt und außerhalb des Linux-Abhängigkeitsbaums.
dependencies += [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.8.0"),
]
products.append(.executable(name: "PoorMansTextApp", targets: ["PoorMansTextApp"]))
targets += [
    .executableTarget(
        name: "PoorMansTextApp",
        dependencies: ["PoorMansTextAppSupport", "PoorMansTextCore"],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"])]
    ),
    .target(
        name: "PoorMansTextAppSupport",
        dependencies: [
            "PoorMansTextCore",
            .product(name: "Sparkle", package: "Sparkle"),
            .product(name: "Markdown", package: "swift-markdown"),
        ]
    ),
    .testTarget(name: "PoorMansTextCoreTests",
                dependencies: ["PoorMansTextAppSupport", "PoorMansTextCore"],
                resources: [.copy("Fixtures")]),
]
#endif

targets += [
    .target(name: "PoorMansTextCore", dependencies: coreDependencies, resources: coreResources),
    .executableTarget(name: "PoorMansTextCLI", dependencies: ["PoorMansTextCore"]),
    .testTarget(name: "PoorMansTextPortableTests", dependencies: ["PoorMansTextCore"]),
]
#if os(Linux)
targets.append(.testTarget(name: "PoorMansTextLinuxTests", dependencies: ["PoorMansTextCore", "CPMTLinux"]))
// Nur unter #if os(Linux), bestehende Mac-Testtarget-Deklaration bleibt unverändert.
// Offizielles Swift-Markdown 0.8.0 als unabhängiger AST-Prüfer der vorhandenen Tests.
dependencies.append(.package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.8.0"))
targets.append(.testTarget(
    name: "PoorMansTextFormatTests",
    dependencies: ["PoorMansTextCore", "zlib", .product(name: "Markdown", package: "swift-markdown")],
    path: "Tests/PoorMansTextCoreTests",
    exclude: [
        "AppCollectionTests.swift",
        "AppENEXTests.swift",
        "AppModelBatchTests.swift",
        "AppModelDropTests.swift",
        "AppModelPandocInstallationTests.swift",
        "AppOptionsTests.swift",
        "AppProfileTests.swift",
        "BatchConverterTests.swift",
        "BinaryDataReadingTests.swift",
        "CLIBatchTests.swift",
        "CLICancellationTests.swift",
        "CLIInstallerTests.swift",
        "CLIIntegrationTests.swift",
        "CLIOutputModeTests.swift",
        "CLIProfileTests.swift",
        "CLITargetDirectoryTests.swift",
        "ClipboardImageTests.swift",
        "ClipboardImportTests.swift",
        "CollectionOutputTests.swift",
        "ColoredTextMarkerTests.swift",
        "ComparisonTests.swift",
        "ContentSelectionTests.swift",
        "ConversionCancellationTests.swift",
        "ConversionDiagnosticsTests.swift",
        "ConversionReportTests.swift",
        "DOCXReviewTests.swift",
        "DelimitedTextAdapterTests.swift",
        "DocumentConverterTests.swift",
        "DocumentMetadataTests.swift",
        "ENEXResourceTests.swift",
        "FixtureFactory.swift",
        "FormatCatalogTests.swift",
        "HTMLDocumentConverterTests.swift",
        "HTMLImageRewriterTests.swift",
        "ImageAdapterTests.swift",
        "InputEnumeratorTests.swift",
        "InstallModeTests.swift",
        "InstallScriptRollbackTests.swift",
        "MIMEMessageTests.swift",
        "MarkdownEscapingTests.swift",
        "MarkdownNormalizerTests.swift",
        "NamespacePrefixTrackerTests.swift",
        "OLEStorageTreeTests.swift",
        "OpenedDocumentsRelayTests.swift",
        "PDFAdapterTests.swift",
        "PDFAnnotationTests.swift",
        "PDFQualityTests.swift",
        "PDFSelectionTests.swift",
        "PDFStructureTests.swift",
        "PandocInstallerTests.swift",
        "PandocTextAdapterTests.swift",
        "PandocToolTests.swift",
        "PreviewWebTests.swift",
        "ProcessRunnerTests.swift",
        "ProductInfoTests.swift",
        "RTFDLiteralListTests.swift",
        "RTFUnicodeTests.swift",
        "ReleaseWorkflowTests.swift",
        "RenderedMarkdownPreviewTests.swift",
        "ReviewFixes20260817Tests.swift",
        "ReviewFixes20260819Tests.swift",
        "ReviewFixes20260820Tests.swift",
        "ReviewFixes20260825Tests.swift",
        "ReviewFixes20260829Tests.swift",
        "ReviewFixes20260830Tests.swift",
        "ReviewFixes20260903Tests.swift",
        "ReviewFixes20260910Tests.swift",
        "ReviewOctober10Tests.swift",
        "ReviewOctober11Tests.swift",
        "ReviewOctober13Tests.swift",
        "ReviewOctober14Tests.swift",
        "ReviewOctober17Tests.swift",
        "ReviewOctober7Tests.swift",
        "ReviewOctoberTests.swift",
        "ReviewRegressionTests.swift",
        "RichTextConverterTests.swift",
        "ServicesProviderTests.swift",
        "ShortcutConversionTests.swift",
        "SourceIdentityBindingTests.swift",
        "Stage4FormatTests.swift",
        "StructuredOCRTests.swift",
        "SymbolicLinkInputTests.swift",
        "UpdateControllerTests.swift",
        "VerifiedImageSourceTests.swift",
        "VisionDocumentRecognizerTests.swift",
        "WordProcessingAdapterTests.swift",
        "WordProcessingPackageInspectionTests.swift",
        "XMLTextContentTests.swift",
        "ZIPArchiveVerificationTests.swift",
        "ZIPBoundedInspectionTests.swift",
        "ZIPPackageReaderTests.swift",
    ],
    sources: [
        "EPUBSelectionTests.swift",
        "ProfileStoreEditingTests.swift",
        "ConversionProfileTests.swift",
        "ENEXConversionTests.swift",
        "ENEXReaderTests.swift",
        "ImportXMLParserTests.swift",
        "LegacyXLSBoundaryTests.swift",
        "LegacyXLSNumberFormatTests.swift",
        "MBOXReaderTests.swift",
        "MSGAdapterTests.swift",
        "MSGCompressedRTFTests.swift",
        "MSGEmbeddedWriterTests.swift",
        "MSGMessageTests.swift",
        "MSGPropertiesTests.swift",
        "MSGRTFHTMLTests.swift",
        "MailAdapterTests.swift",
        "MailBodyConverterTests.swift",
        "MailContentTests.swift",
        "ODSNumberFormatTests.swift",
        "OpenDocumentMasterAdapterTests.swift",
        "PresentationLinkTests.swift",
        "PresentationNotebookTests.swift",
        "SpreadsheetAdapterTests.swift",
        "SpreadsheetBudgetTests.swift",
        "SpreadsheetFeasibilityTests.swift",
        "SpreadsheetLinkTargetTests.swift",
        "SpreadsheetNumberFormatTests.swift",
        "SpreadsheetSelectionTests.swift",
        "ZIPFixtureBuilder.swift",
    ],
    resources: [.copy("Fixtures")]
))
#endif

let package = Package(
    name: "PoorMansText", platforms: [.macOS(.v13)],
    products: products, dependencies: dependencies, targets: targets,
    swiftLanguageModes: [.v6]
)
