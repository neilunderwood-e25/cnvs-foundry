import AppKit
import SwiftUI

extension CanvasTool {
    /// Cursor shown while this tool is active, so the current mode is visible
    /// without looking away at the tool rail.
    var cursor: NSCursor {
        switch self {
        case .select: .arrow
        case .hand: .openHand
        case .text: .iBeam
        case .pen, .rectangle, .ellipse, .line, .arrow, .eraser: .crosshair
        }
    }
}

/// AppKit bridge for the two things SwiftUI cannot express on a plain canvas:
/// scroll-wheel and trackpad panning (there is no scroll hook outside a
/// `ScrollView`), and a per-tool mouse cursor.
///
/// Scroll arrives through a local event monitor rather than an overridden
/// `scrollWheel(with:)`, because the view sits above the canvas purely for its
/// cursor rects — `hitTest` returns nil so it never intercepts the SwiftUI drag
/// gestures underneath, and a view that is never hit is never sent mouse events
/// either.
struct CanvasInputShim: NSViewRepresentable {
    var cursor: NSCursor
    /// True when the point belongs to the canvas backdrop. Returning false over
    /// an agent card leaves the event for that terminal's own scrollback.
    var handlesScroll: (CGPoint) -> Bool
    var onPan: (CGSize) -> Void
    var onZoom: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> ShimView {
        let view = ShimView()
        view.apply(self)
        return view
    }

    func updateNSView(_ nsView: ShimView, context: Context) {
        nsView.apply(self)
    }

    final class ShimView: NSView {
        private var cursorValue: NSCursor = .arrow
        private var handlesScroll: ((CGPoint) -> Bool)?
        private var onPan: ((CGSize) -> Void)?
        private var onZoom: ((CGFloat, CGPoint) -> Void)?
        private var scrollMonitor: Any?

        /// Match SwiftUI's top-left origin so reported points need no flipping.
        override var isFlipped: Bool { true }

        func apply(_ shim: CanvasInputShim) {
            handlesScroll = shim.handlesScroll
            onPan = shim.onPan
            onZoom = shim.onZoom
            if cursorValue !== shim.cursor {
                cursorValue = shim.cursor
                window?.invalidateCursorRects(for: self)
            }
        }

        /// Never steal clicks from the gestures below.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursorValue)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitor()
                window?.invalidateCursorRects(for: self)
            }
        }

        private func installMonitor() {
            guard scrollMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func removeMonitor() {
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
            }
            scrollMonitor = nil
        }

        deinit {
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
            }
        }

        /// Returns nil to consume the event, or the event to pass it along.
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }

            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), handlesScroll?(point) ?? false else {
                return event
            }

            let isPrecise = event.hasPreciseScrollingDeltas

            if event.modifierFlags.contains(.command) {
                // Clamped per event so one flick of a coarse wheel cannot jump
                // the whole zoom range.
                let step = event.scrollingDeltaY * (isPrecise ? 0.004 : 0.04)
                onZoom?(min(1.25, max(0.8, 1 + step)), point)
            } else {
                // A mouse wheel reports lines, a trackpad reports points.
                let scale: CGFloat = isPrecise ? 1 : 16
                onPan?(
                    CGSize(
                        width: event.scrollingDeltaX * scale,
                        height: event.scrollingDeltaY * scale
                    )
                )
            }
            return nil
        }
    }
}
