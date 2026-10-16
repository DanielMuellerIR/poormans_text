import AppKit
import Foundation
import PoorMansTextCore

@MainActor final class ComparisonSourceModel: ObservableObject {
    enum State: Equatable {
        case loading, verified, changed, missing, unverified, limit, unreadable
        var message: String {
            switch self {
            case .loading: NSLocalizedString("Verifying source…", comment: "")
            case .verified: NSLocalizedString("Source bytes match the conversion.", comment: "")
            case .changed: NSLocalizedString("The source or its folder changed. Recheck the comparison.", comment: "")
            case .missing: NSLocalizedString("The source is missing. The comparison no longer matches.", comment: "")
            case .unverified: NSLocalizedString("No source fingerprint is available. Positions cannot be verified.", comment: "")
            case .limit: NSLocalizedString("The source exceeds the verification limit.", comment: "")
            case .unreadable: NSLocalizedString("The source cannot be read safely. Positions cannot be verified.", comment: "")
            }
        }
    }
    @Published private(set) var state = State.loading
    @Published private(set) var count = 0
    @Published private(set) var number = 1
    @Published private(set) var image: NSImage?
    @Published private(set) var imageBusy = false
    @Published private(set) var imageUnavailable = false
    var isVerified: Bool { state == .verified }
    private var generation = UUID()
    private var renderGeneration = UUID()
    private var watcher: ComparisonSourceWatcher?
    private var renderer: ComparisonSourceRenderer?
    private var operation: Task<Void, Never>?
    private var rendering: Task<Void, Never>?

    func load(_ result: ConversionResult) {
        stop()
        state = .loading; count = 0; number = 1; image = nil; imageUnavailable = false
        let token = generation
        watcher = ComparisonSourceWatcher(url: result.inputURL) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.invalidate()
            }
        }
        let read = Task.detached(priority: .userInitiated) { try ComparisonSourceSnapshot.read(result) }
        operation = Task { [weak self] in
            do {
                let snapshot = try await withTaskCancellationHandler(operation: { try await read.value }, onCancel: { read.cancel() })
                guard let self, !Task.isCancelled, self.generation == token else { return }
                guard self.watcher?.hasChanged != true else { self.invalidate(); return }
                self.state = .verified
                if result.format == .pdf || result.format == .image {
                    guard snapshot.data != nil else { self.imageUnavailable = true; return }
                    let renderer = ComparisonSourceRenderer(snapshot)
                    let count = try await renderer.prepare()
                    guard !Task.isCancelled, self.generation == token, self.isVerified else { return }
                    self.renderer = renderer; self.count = count
                    self.select(1)
                }
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                if self.isVerified { self.imageUnavailable = true }
                else { self.state = Self.state(for: error) }
            }
        }
    }

    func select(_ number: Int) {
        guard isVerified, (1...max(1, count)).contains(number), let renderer else { return }
        self.number = number; image = nil; imageBusy = true; imageUnavailable = false
        rendering?.cancel()
        let token = UUID(); renderGeneration = token
        rendering = Task { [weak self] in
            do {
                let data = try await renderer.render(number)
                guard let self, !Task.isCancelled, self.renderGeneration == token, self.isVerified else { return }
                self.image = NSImage(data: data); self.imageUnavailable = self.image == nil; self.imageBusy = false
            } catch {
                guard let self, !Task.isCancelled, self.renderGeneration == token, self.isVerified else { return }
                self.imageUnavailable = true; self.imageBusy = false
            }
        }
    }

    func stop() {
        operation?.cancel(); operation = nil; rendering?.cancel(); rendering = nil
        watcher = nil; renderer = nil; generation = UUID(); renderGeneration = UUID()
    }
    private func invalidate() {
        operation?.cancel(); rendering?.cancel(); renderer = nil
        state = .changed; image = nil; imageBusy = false
    }
    private static func state(for error: Error) -> State {
        switch error as? ComparisonSourceSnapshot.Failure {
        case .missing: .missing
        case .changed: .changed
        case .unverified: .unverified
        case .limit: .limit
        default: .unreadable
        }
    }
}
