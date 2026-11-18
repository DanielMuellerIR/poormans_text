import PDFKit
import PoorMansTextCore
import SwiftUI

struct ReceiptPDFRegion: Equatable {
    let page: Int
    let bounds: CGRect
}

struct ReceiptPDFMark: Equatable {
    let id = UUID()
    let regions: [ReceiptPDFRegion]
}

struct ReceiptPDFZoom: Equatable {
    enum Action { case fit, inwards, outwards }
    let id = UUID()
    let action: Action
}

struct ReceiptPDFView: NSViewRepresentable {
    let pdf: PDFDocument
    let text: ReceiptDocument
    let markedRegion: ReceiptPDFMark?
    let selectedRegion: ReceiptPDFRegion?
    let zoom: ReceiptPDFZoom?
    let onSelection: (ReceiptPDFRegion) -> Void

    func makeNSView(context: Context) -> ReceiptPDFCanvas {
        let view = ReceiptPDFCanvas()
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.setAccessibilityLabel("PDF")
        return view
    }

    func updateNSView(_ view: ReceiptPDFCanvas, context: Context) {
        view.onSelection = onSelection
        view.setDocument(pdf)
        view.text = text
        view.showRegions(marked: markedRegion, selected: selectedRegion)
        view.adjustZoom(zoom)
    }

    static func dismantleNSView(_ view: ReceiptPDFCanvas, coordinator: ()) {
        view.stopSelection()
    }
}

final class ReceiptPDFCanvas: PDFView {
    var onSelection: ((ReceiptPDFRegion) -> Void)?
    var text: ReceiptDocument?
    private var markedRegion: ReceiptPDFMark?
    private var selectedRegion: ReceiptPDFRegion?
    private var marks: [PDFAnnotation] = []
    private var selection: PDFAnnotation?
    private var lastZoom: ReceiptPDFZoom?
    private var dragStart: (page: PDFPage, location: CGPoint)?
    private var dragAnnotation: PDFAnnotation?
    private var selectionMonitor: Any?

    func setDocument(_ pdf: PDFDocument) {
        guard document !== pdf else { return }
        document = pdf
        markedRegion = nil
        selectedRegion = nil
        marks = []
        selection = nil
        lastZoom = nil
        dragStart = nil
        dragAnnotation = nil
        autoScales = true
    }

    func showRegions(marked: ReceiptPDFMark?, selected: ReceiptPDFRegion?) {
        if marked != markedRegion {
            marks.forEach(remove)
            markedRegion = marked
            let regions = marked?.regions ?? []
            marks = regions.compactMap { add($0, color: .systemOrange) }
            if let first = regions.first, let page = document?.page(at: first.page - 1) {
                let visible = regions.filter { $0.page == first.page }.reduce(CGRect.null) { $0.union($1.bounds) }
                go(to: visible, on: page)
            }
        }
        if selected != selectedRegion {
            remove(selection)
            selectedRegion = selected
            selection = selected.flatMap { add($0, color: .systemBlue) }
        }
    }

    func adjustZoom(_ zoom: ReceiptPDFZoom?) {
        guard let zoom, zoom != lastZoom else { return }
        lastZoom = zoom
        switch zoom.action {
        case .fit: autoScales = true
        case .inwards:
            autoScales = false
            zoomIn(nil)
        case .outwards:
            autoScales = false
            zoomOut(nil)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopSelection()
        guard window != nil else { return }
        // PDFKit verarbeitet Mausklicks in der internen PDFPageView.
        selectionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleSelection(event) == true ? nil : event
        }
    }

    func stopSelection() {
        if let selectionMonitor { NSEvent.removeMonitor(selectionMonitor) }
        selectionMonitor = nil
        dragStart = nil
        remove(dragAnnotation)
        dragAnnotation = nil
    }

    private func handleSelection(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        switch event.type {
        case .leftMouseDown:
            guard let contentView = window?.contentView,
                  let hit = contentView.hitTest(event.locationInWindow), hit.isDescendant(of: self),
                  !(hit is NSScroller) else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard let page = page(for: point, nearest: false) else { return false }
            dragStart = (page, convert(point, to: page))
        case .leftMouseDragged:
            guard let dragStart else { return false }
            remove(dragAnnotation)
            dragAnnotation = region(for: event, start: dragStart, allowClick: false).flatMap { add($0, color: .systemBlue) }
        case .leftMouseUp:
            guard let dragStart else { return false }
            self.dragStart = nil
            remove(dragAnnotation)
            dragAnnotation = nil
            if let region = region(for: event, start: dragStart, allowClick: true) {
                onSelection?(region)
            }
        default:
            return false
        }
        return true
    }

    private func region(for event: NSEvent, start: (page: PDFPage, location: CGPoint), allowClick: Bool) -> ReceiptPDFRegion? {
        guard let document else { return nil }
        let pageIndex = document.index(for: start.page)
        guard pageIndex < document.pageCount else { return nil }
        let location = convert(convert(event.locationInWindow, from: nil), to: start.page)
        let width = abs(start.location.x - location.x)
        let height = abs(start.location.y - location.y)
        let bounds: CGRect
        if width < 3 && height < 3 {
            guard allowClick, let text, text.pages.indices.contains(pageIndex) else { return nil }
            let page = text.pages[pageIndex]
            let scale = page.pointsPerMillimeter
            let position = CGPoint(x: start.location.x / scale, y: start.location.y / scale)
            guard let word = page.words.first(where: { $0.rectangle.cgRect.contains(position) }) else { return nil }
            bounds = word.rectangle.cgRect.applying(CGAffineTransform(scaleX: scale, y: scale))
        } else {
            bounds = CGRect(x: min(start.location.x, location.x), y: min(start.location.y, location.y), width: max(width, 3), height: max(height, 3))
        }
        let clipped = bounds.intersection(start.page.bounds(for: displayBox))
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return ReceiptPDFRegion(page: pageIndex + 1, bounds: clipped)
    }

    private func add(_ region: ReceiptPDFRegion, color: NSColor) -> PDFAnnotation? {
        guard let page = document?.page(at: region.page - 1) else { return nil }
        let annotation = PDFAnnotation(bounds: region.bounds, forType: .square, withProperties: nil)
        annotation.color = color
        annotation.interiorColor = color.withAlphaComponent(0.20)
        let border = PDFBorder()
        border.lineWidth = 1.5
        annotation.border = border
        annotation.shouldPrint = false
        page.addAnnotation(annotation)
        return annotation
    }

    private func remove(_ annotation: PDFAnnotation?) {
        guard let annotation else { return }
        annotation.page?.removeAnnotation(annotation)
    }
}
