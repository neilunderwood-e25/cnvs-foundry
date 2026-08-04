import AppKit
import SwiftUI

private final class NativePointerDragView: NSView {
    var onBegan: (() -> Void)?
    var onChanged: ((CGSize) -> Void)?
    var onEnded: ((CGSize) -> Void)?
    var cursor: NSCursor = .openHand

    private var startLocation: CGPoint?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        startLocation = NSEvent.mouseLocation
        cursor = .closedHand
        window?.invalidateCursorRects(for: self)
        onBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation else { return }
        onChanged?(Self.translation(from: startLocation))
    }

    override func mouseUp(with event: NSEvent) {
        guard let startLocation else { return }
        let translation = Self.translation(from: startLocation)
        self.startLocation = nil
        cursor = .openHand
        window?.invalidateCursorRects(for: self)
        onEnded?(translation)
    }

    private static func translation(from start: CGPoint) -> CGSize {
        let current = NSEvent.mouseLocation
        return CGSize(
            width: current.x - start.x,
            height: start.y - current.y
        )
    }
}

final class NativeTerminalCardHost<Content: View>: NSView {
    let hostingView: NSHostingView<Content>

    var onInteractionBegan: (() -> Void)?
    var onMoveEnded: ((CGSize) -> Void)?
    var onResizeEnded: ((CGSize, CGSize) -> Void)?

    private let dragRegion = NativePointerDragView(frame: .zero)
    private let resizeRegion = NativePointerDragView(frame: .zero)
    private var isDragging = false
    private var isResizing = false
    private var liveResizeSize = CGSize.zero

    init(rootView: Content) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = false
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = false
        addSubview(hostingView)

        dragRegion.wantsLayer = true
        dragRegion.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(dragRegion)

        resizeRegion.cursor = .crosshair
        resizeRegion.wantsLayer = true
        resizeRegion.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(resizeRegion)

        dragRegion.onBegan = { [weak self] in
            guard let self else { return }
            isDragging = true
            onInteractionBegan?()
        }
        dragRegion.onChanged = { [weak self] translation in
            self?.applyMove(translation)
        }
        dragRegion.onEnded = { [weak self] translation in
            guard let self else { return }
            onMoveEnded?(translation)
            DispatchQueue.main.async { [weak self] in
                self?.isDragging = false
                self?.needsLayout = true
            }
        }

        resizeRegion.onBegan = { [weak self] in
            guard let self else { return }
            isResizing = true
            liveResizeSize = bounds.size
            onInteractionBegan?()
        }
        resizeRegion.onChanged = { [weak self] translation in
            self?.applyResize(translation)
        }
        resizeRegion.onEnded = { [weak self] translation in
            guard let self else { return }
            applyResize(translation)
            let widthDelta = liveResizeSize.width - bounds.width
            let heightDelta = liveResizeSize.height - bounds.height
            onResizeEnded?(
                liveResizeSize,
                CGSize(width: widthDelta / 2, height: heightDelta / 2)
            )
            DispatchQueue.main.async { [weak self] in
                self?.isResizing = false
                self?.needsLayout = true
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        if !isDragging && !isResizing {
            hostingView.frame = bounds
        }

        let headerHeight: CGFloat = 38
        let menuExclusion: CGFloat = 46
        dragRegion.frame = CGRect(
            x: 0,
            y: max(0, bounds.height - headerHeight),
            width: max(0, bounds.width - menuExclusion),
            height: headerHeight
        )
        resizeRegion.frame = CGRect(x: bounds.width - 34, y: 0, width: 34, height: 34)
    }

    func applyMove(_ translation: CGSize) {
        hostingView.frame = CGRect(
            x: translation.width,
            y: -translation.height,
            width: bounds.width,
            height: bounds.height
        )
    }

    func applyResize(_ translation: CGSize) {
        let newSize = CGSize(
            width: max(420, bounds.width + translation.width),
            height: max(280, bounds.height + translation.height)
        )
        liveResizeSize = newSize
        let heightDelta = newSize.height - bounds.height
        hostingView.frame = CGRect(
            x: 0,
            y: -heightDelta,
            width: newSize.width,
            height: newSize.height
        )
    }
}

struct NativeTerminalCardContainer<Content: View>: NSViewRepresentable {
    let content: Content
    let onInteractionBegan: () -> Void
    let onMoveEnded: (CGSize) -> Void
    let onResizeEnded: (CGSize, CGSize) -> Void

    func makeNSView(context: Context) -> NativeTerminalCardHost<Content> {
        let host = NativeTerminalCardHost(rootView: content)
        updateCallbacks(on: host)
        return host
    }

    func updateNSView(_ nsView: NativeTerminalCardHost<Content>, context: Context) {
        nsView.hostingView.rootView = content
        updateCallbacks(on: nsView)
    }

    private func updateCallbacks(on host: NativeTerminalCardHost<Content>) {
        host.onInteractionBegan = onInteractionBegan
        host.onMoveEnded = onMoveEnded
        host.onResizeEnded = onResizeEnded
    }
}
