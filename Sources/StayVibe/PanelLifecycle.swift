import AppKit
import SwiftUI

/// Observes the actual menu bar panel, rather than the lifetime of one of its pages.
/// A settings picker can take key focus without dismissing the panel, and a language
/// change can rebuild its content; neither should send the user back to the main page.
struct PanelDismissObserver: NSViewRepresentable {
    var onPresent: () -> Void = {}
    var onDismiss: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onPresent = onPresent
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onPresent = onPresent
        view.onDismiss = onDismiss
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
        view.stopObserving()
    }

    final class ObserverView: NSView {
        var onPresent: () -> Void = {}
        var onDismiss: () -> Void = {}
        private weak var observedWindow: NSWindow?
        private var visibilityObservation: NSKeyValueObservation?
        private var wasVisible = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard observedWindow !== window else { return }
            stopObserving()
            observedWindow = window
            guard let window else { return }
            visibilityObservation = window.observe(\.isVisible, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.visibilityChanged() }
            }
            NotificationCenter.default.addObserver(self, selector: #selector(willClose),
                                                   name: NSWindow.willCloseNotification, object: window)
        }

        /// AppKit can change visibility briefly while first measuring the panel.
        /// Check the final value on the next turn of the main run loop, and observe
        /// visibility rather than key focus or occlusion (for example, a child menu).
        private func visibilityChanged() {
            guard let window = observedWindow else { return }
            if window.isVisible {
                let newlyPresented = !wasVisible
                wasVisible = true
                if newlyPresented { onPresent() }
            } else {
                dismissed()
            }
        }

        @objc private func willClose(_ notification: Notification) {
            dismissed()
        }

        private func dismissed() {
            guard wasVisible else { return }
            wasVisible = false
            let action = onDismiss
            DispatchQueue.main.async { action() }
        }

        func stopObserving() {
            visibilityObservation?.invalidate()
            visibilityObservation = nil
            NotificationCenter.default.removeObserver(self)
            observedWindow = nil
            wasVisible = false
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
