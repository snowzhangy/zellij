import SwiftTerm
import SwiftUI
import UIKit

struct SwiftTermSurface: UIViewRepresentable {
    @ObservedObject var stream: TerminalStream
    let fontSize: Double
    let isReadOnly: Bool
    let optionAsMetaKey: Bool
    let onInput: (Data) -> Void
    let onResize: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onResize: onResize)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(
            frame: .zero,
            font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        )
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .systemGreen
        view.caretColor = .systemGreen
        view.optionAsMetaKey = optionAsMetaKey
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        // Keyboard starts hidden. SwiftTerm itself shows it on a single tap
        // (cursor positioning, text input). Two-finger swipe down hides it,
        // swipe up shows it explicitly.
        context.coordinator.installFingerScroll(on: view)
        context.coordinator.installKeyboardToggle(on: view, isReadOnly: isReadOnly)
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        if view.font.pointSize != fontSize {
            view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        if view.optionAsMetaKey != optionAsMetaKey {
            view.optionAsMetaKey = optionAsMetaKey
        }
        context.coordinator.installFingerScroll(on: view)
        context.coordinator.installKeyboardToggle(on: view, isReadOnly: isReadOnly)
        if isReadOnly, view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
        guard context.coordinator.lastRevision != stream.revision else { return }
        context.coordinator.lastRevision = stream.revision
        for chunk in stream.drain() {
            view.feed(byteArray: chunk[...])
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var lastRevision = 0
        private var fingerScrollHandler: FingerScrollHandler?
        private var keyboardToggleHandler: KeyboardToggleHandler?
        let onInput: (Data) -> Void
        let onResize: (Int, Int) -> Void

        init(onInput: @escaping (Data) -> Void, onResize: @escaping (Int, Int) -> Void) {
            self.onInput = onInput
            self.onResize = onResize
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onInput(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onResize(newRows, newCols)
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            UIApplication.shared.open(url)
        }

        func installFingerScroll(on view: TerminalView) {
            guard fingerScrollHandler == nil else { return }
            let handler = FingerScrollHandler(terminalView: view)
            let gesture = UIPanGestureRecognizer(target: handler, action: #selector(FingerScrollHandler.handlePan(_:)))
            gesture.minimumNumberOfTouches = 1
            gesture.maximumNumberOfTouches = 1
            gesture.cancelsTouchesInView = false
            gesture.delegate = handler
            view.addGestureRecognizer(gesture)
            handler.gesture = gesture
            fingerScrollHandler = handler
        }

        func installKeyboardToggle(on view: TerminalView, isReadOnly: Bool) {
            if let keyboardToggleHandler {
                keyboardToggleHandler.isReadOnly = isReadOnly
                return
            }
            let handler = KeyboardToggleHandler(
                terminalView: view,
                isReadOnly: isReadOnly
            )
            let upSwipe = UISwipeGestureRecognizer(
                target: handler,
                action: #selector(KeyboardToggleHandler.handleSwipeUp(_:))
            )
            upSwipe.direction = .up
            upSwipe.numberOfTouchesRequired = 2
            upSwipe.cancelsTouchesInView = false
            upSwipe.delegate = handler
            view.addGestureRecognizer(upSwipe)

            let downSwipe = UISwipeGestureRecognizer(
                target: handler,
                action: #selector(KeyboardToggleHandler.handleSwipeDown(_:))
            )
            downSwipe.direction = .down
            downSwipe.numberOfTouchesRequired = 2
            downSwipe.cancelsTouchesInView = false
            downSwipe.delegate = handler
            view.addGestureRecognizer(downSwipe)

            handler.upSwipe = upSwipe
            handler.downSwipe = downSwipe
            keyboardToggleHandler = handler
        }
    }

    final class FingerScrollHandler: NSObject, UIGestureRecognizerDelegate {
        weak var terminalView: TerminalView?
        weak var gesture: UIPanGestureRecognizer?
        private var accumulatedDelta: CGFloat = 0

        init(terminalView: TerminalView) {
            self.terminalView = terminalView
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let terminalView else { return }
            switch recognizer.state {
            case .began:
                accumulatedDelta = 0
            case .changed:
                let deltaY = recognizer.translation(in: terminalView).y
                accumulatedDelta += deltaY
                recognizer.setTranslation(.zero, in: terminalView)

                let lineHeight = max(terminalView.font.lineHeight, 1)
                let lines = Int(accumulatedDelta / lineHeight)
                if lines > 0 {
                    terminalView.scrollUp(lines: lines)
                    accumulatedDelta -= CGFloat(lines) * lineHeight
                } else if lines < 0 {
                    terminalView.scrollDown(lines: -lines)
                    accumulatedDelta -= CGFloat(lines) * lineHeight
                }
            default:
                accumulatedDelta = 0
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    final class KeyboardToggleHandler: NSObject, UIGestureRecognizerDelegate {
        weak var terminalView: TerminalView?
        weak var upSwipe: UISwipeGestureRecognizer?
        weak var downSwipe: UISwipeGestureRecognizer?
        var isReadOnly: Bool

        init(terminalView: TerminalView, isReadOnly: Bool) {
            self.terminalView = terminalView
            self.isReadOnly = isReadOnly
        }

        @objc func handleSwipeUp(_ recognizer: UISwipeGestureRecognizer) {
            guard let terminalView, !isReadOnly else { return }
            _ = terminalView.becomeFirstResponder()
        }

        @objc func handleSwipeDown(_ recognizer: UISwipeGestureRecognizer) {
            guard let terminalView else { return }
            _ = terminalView.resignFirstResponder()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
