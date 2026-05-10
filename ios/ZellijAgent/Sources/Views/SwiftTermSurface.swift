import SwiftTerm
import SwiftUI
import UIKit

struct SwiftTermSurface: UIViewRepresentable {
    @ObservedObject var stream: TerminalStream
    let fontSize: Double
    let isReadOnly: Bool
    let optionAsMetaKey: Bool
    let touchMode: TouchMode
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
        applyTerminalOptions(to: view)
        // Keyboard starts hidden. SwiftTerm itself shows it on a single tap
        // (cursor positioning, text input). Two-finger swipe down hides it,
        // swipe up shows it explicitly.
        context.coordinator.installFingerScroll(on: view, touchMode: touchMode)
        context.coordinator.installTabClick(on: view, touchMode: touchMode, isReadOnly: isReadOnly)
        context.coordinator.installKeyboardToggle(on: view, isReadOnly: isReadOnly)
        context.coordinator.installShortcutGestures(on: view, isReadOnly: isReadOnly)
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        if view.font.pointSize != fontSize {
            view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        applyTerminalOptions(to: view)
        context.coordinator.installFingerScroll(on: view, touchMode: touchMode)
        context.coordinator.installTabClick(on: view, touchMode: touchMode, isReadOnly: isReadOnly)
        context.coordinator.installKeyboardToggle(on: view, isReadOnly: isReadOnly)
        context.coordinator.installShortcutGestures(on: view, isReadOnly: isReadOnly)
        if isReadOnly, view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
        guard context.coordinator.lastRevision != stream.revision else { return }
        context.coordinator.lastRevision = stream.revision
        for chunk in stream.drain() {
            view.feed(byteArray: chunk[...])
        }
    }

    private func applyTerminalOptions(to view: TerminalView) {
        if view.optionAsMetaKey != optionAsMetaKey {
            view.optionAsMetaKey = optionAsMetaKey
        }
        let allowMouseReporting = touchMode == .mouse
        if view.allowMouseReporting != allowMouseReporting {
            view.allowMouseReporting = allowMouseReporting
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var lastRevision = 0
        private var fingerScrollHandler: FingerScrollHandler?
        private var keyboardToggleHandler: KeyboardToggleHandler?
        private var shortcutHandler: ShortcutGestureHandler?
        private var tabClickHandler: TabClickHandler?
        let onInput: (Data) -> Void
        let onResize: (Int, Int) -> Void

        init(
            onInput: @escaping (Data) -> Void,
            onResize: @escaping (Int, Int) -> Void
        ) {
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

        func installFingerScroll(on view: TerminalView, touchMode: TouchMode) {
            if let fingerScrollHandler {
                fingerScrollHandler.terminalView = view
                fingerScrollHandler.touchMode = touchMode
                return
            }
            let handler = FingerScrollHandler(terminalView: view)
            handler.touchMode = touchMode
            let gesture = UIPanGestureRecognizer(target: handler, action: #selector(FingerScrollHandler.handlePan(_:)))
            gesture.minimumNumberOfTouches = 1
            gesture.maximumNumberOfTouches = 1
            gesture.cancelsTouchesInView = false
            gesture.delegate = handler
            view.addGestureRecognizer(gesture)
            handler.gesture = gesture
            gesture.isEnabled = touchMode != .mouse
            fingerScrollHandler = handler
        }

        func installTabClick(on view: TerminalView, touchMode: TouchMode, isReadOnly: Bool) {
            if let tabClickHandler {
                tabClickHandler.terminalView = view
                tabClickHandler.touchMode = touchMode
                tabClickHandler.isReadOnly = isReadOnly
                return
            }
            let handler = TabClickHandler(
                terminalView: view,
                touchMode: touchMode,
                isReadOnly: isReadOnly
            )
            let tap = StateCapturingTapGesture(target: handler, action: #selector(TabClickHandler.handleTap(_:)))
            tap.numberOfTapsRequired = 1
            tap.numberOfTouchesRequired = 1
            tap.cancelsTouchesInView = false
            tap.delegate = handler
            view.addGestureRecognizer(tap)
            tabClickHandler = handler
        }

        func installKeyboardToggle(on view: TerminalView, isReadOnly: Bool) {
            if let keyboardToggleHandler {
                keyboardToggleHandler.terminalView = view
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

        func installShortcutGestures(on view: TerminalView, isReadOnly: Bool) {
            if let shortcutHandler {
                shortcutHandler.terminalView = view
                shortcutHandler.isReadOnly = isReadOnly
                return
            }
            let handler = ShortcutGestureHandler(terminalView: view, isReadOnly: isReadOnly)

            // 2-finger tap → Esc
            let escTap = UITapGestureRecognizer(
                target: handler,
                action: #selector(ShortcutGestureHandler.handleEsc(_:))
            )
            escTap.numberOfTapsRequired = 1
            escTap.numberOfTouchesRequired = 2
            escTap.cancelsTouchesInView = false
            escTap.delegate = handler
            view.addGestureRecognizer(escTap)

            // 3-finger tap → Ctrl-C
            let ctrlCTap = UITapGestureRecognizer(
                target: handler,
                action: #selector(ShortcutGestureHandler.handleCtrlC(_:))
            )
            ctrlCTap.numberOfTapsRequired = 1
            ctrlCTap.numberOfTouchesRequired = 3
            ctrlCTap.cancelsTouchesInView = false
            ctrlCTap.delegate = handler
            view.addGestureRecognizer(ctrlCTap)

            // 4-finger tap → Ctrl-D
            let ctrlDTap = UITapGestureRecognizer(
                target: handler,
                action: #selector(ShortcutGestureHandler.handleCtrlD(_:))
            )
            ctrlDTap.numberOfTapsRequired = 1
            ctrlDTap.numberOfTouchesRequired = 4
            ctrlDTap.cancelsTouchesInView = false
            ctrlDTap.delegate = handler
            view.addGestureRecognizer(ctrlDTap)

            // 2-finger swipe left → ↑ (history previous)
            let leftSwipe = UISwipeGestureRecognizer(
                target: handler,
                action: #selector(ShortcutGestureHandler.handleArrowUp(_:))
            )
            leftSwipe.direction = .left
            leftSwipe.numberOfTouchesRequired = 2
            leftSwipe.cancelsTouchesInView = false
            leftSwipe.delegate = handler
            view.addGestureRecognizer(leftSwipe)

            // 2-finger swipe right → ↓ (history next)
            let rightSwipe = UISwipeGestureRecognizer(
                target: handler,
                action: #selector(ShortcutGestureHandler.handleArrowDown(_:))
            )
            rightSwipe.direction = .right
            rightSwipe.numberOfTouchesRequired = 2
            rightSwipe.cancelsTouchesInView = false
            rightSwipe.delegate = handler
            view.addGestureRecognizer(rightSwipe)

            shortcutHandler = handler
        }
    }

    final class FingerScrollHandler: NSObject, UIGestureRecognizerDelegate {
        weak var terminalView: TerminalView?
        weak var gesture: UIPanGestureRecognizer?
        var touchMode: TouchMode = .scroll {
            didSet {
                gesture?.isEnabled = touchMode != .mouse
                if touchMode == .mouse {
                    stopSelectionAutoScroll()
                    stopMomentumScroll()
                }
            }
        }
        private static let scrollSensitivity: CGFloat = 1.7
        private static let momentumInterval: TimeInterval = 0.025
        private static let momentumDecay: CGFloat = 0.88
        private static let minimumMomentumVelocity: CGFloat = 220
        private static let maximumLinesPerUpdate = 18
        private var accumulatedDelta: CGFloat = 0
        private var momentumVelocity: CGFloat = 0
        private var momentumScrollTimer: Timer?
        private var selectionScrollTimer: Timer?
        private var selectionScrollDirection = 0
        private var selectionScrollLines = 1

        init(terminalView: TerminalView) {
            self.terminalView = terminalView
        }

        deinit {
            stopMomentumScroll()
            stopSelectionAutoScroll()
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let terminalView else {
                stopMomentumScroll()
                stopSelectionAutoScroll()
                return
            }
            guard touchMode != .mouse else {
                stopMomentumScroll()
                stopSelectionAutoScroll()
                return
            }
            if terminalView.selectionActive {
                stopMomentumScroll()
                handleSelectionAutoScroll(recognizer, in: terminalView)
                return
            }
            guard touchMode == .scroll else {
                stopMomentumScroll()
                stopSelectionAutoScroll()
                return
            }
            switch recognizer.state {
            case .began:
                stopMomentumScroll()
                accumulatedDelta = 0
            case .changed:
                stopMomentumScroll()
                let deltaY = recognizer.translation(in: terminalView).y * Self.scrollSensitivity
                recognizer.setTranslation(.zero, in: terminalView)
                scrollBy(deltaY, in: terminalView)
            case .ended, .cancelled:
                let velocity = recognizer.velocity(in: terminalView).y * Self.scrollSensitivity
                accumulatedDelta = 0
                if abs(velocity) > Self.minimumMomentumVelocity {
                    startMomentumScroll(velocity: velocity, terminalView: terminalView)
                } else {
                    stopMomentumScroll()
                }
            default:
                accumulatedDelta = 0
                stopMomentumScroll()
                stopSelectionAutoScroll()
            }
        }

        private func scrollBy(_ deltaY: CGFloat, in terminalView: TerminalView) {
            accumulatedDelta += deltaY

            let lineHeight = max(terminalView.font.lineHeight, 1)
            let rawLines = Int(accumulatedDelta / lineHeight)
            let lines = max(
                min(rawLines, Self.maximumLinesPerUpdate),
                -Self.maximumLinesPerUpdate
            )
            if lines > 0 {
                terminalView.scrollUp(lines: lines)
                accumulatedDelta -= CGFloat(lines) * lineHeight
            } else if lines < 0 {
                terminalView.scrollDown(lines: -lines)
                accumulatedDelta -= CGFloat(lines) * lineHeight
            }
        }

        private func startMomentumScroll(velocity: CGFloat, terminalView: TerminalView) {
            momentumVelocity = velocity
            momentumScrollTimer?.invalidate()
            momentumScrollTimer = Timer.scheduledTimer(
                withTimeInterval: Self.momentumInterval,
                repeats: true
            ) { [weak self, weak terminalView] _ in
                guard let self, let terminalView else {
                    self?.stopMomentumScroll()
                    return
                }
                guard self.touchMode == .scroll, !terminalView.selectionActive else {
                    self.stopMomentumScroll()
                    return
                }
                self.scrollBy(self.momentumVelocity * Self.momentumInterval, in: terminalView)
                self.momentumVelocity *= Self.momentumDecay
                if abs(self.momentumVelocity) < Self.minimumMomentumVelocity {
                    self.stopMomentumScroll()
                }
            }
        }

        private func stopMomentumScroll() {
            momentumScrollTimer?.invalidate()
            momentumScrollTimer = nil
            momentumVelocity = 0
        }

        private func handleSelectionAutoScroll(_ recognizer: UIPanGestureRecognizer, in terminalView: TerminalView) {
            switch recognizer.state {
            case .began, .changed:
                accumulatedDelta = 0
                let y = recognizer.location(in: terminalView).y
                let lineHeight = max(terminalView.font.lineHeight, 1)
                let edgeHeight = max(lineHeight * 3, 44)
                if y < edgeHeight {
                    let intensity = max(1, Int((edgeHeight - y) / lineHeight) + 1)
                    startSelectionAutoScroll(direction: -1, lines: min(intensity, 4), terminalView: terminalView)
                } else if y > terminalView.bounds.height - edgeHeight {
                    let distance = y - (terminalView.bounds.height - edgeHeight)
                    let intensity = max(1, Int(distance / lineHeight) + 1)
                    startSelectionAutoScroll(direction: 1, lines: min(intensity, 4), terminalView: terminalView)
                } else {
                    stopSelectionAutoScroll()
                }
            default:
                stopSelectionAutoScroll()
            }
        }

        private func startSelectionAutoScroll(direction: Int, lines: Int, terminalView: TerminalView) {
            selectionScrollDirection = direction
            selectionScrollLines = lines
            guard selectionScrollTimer == nil else { return }
            selectionScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self, weak terminalView] _ in
                guard let self, let terminalView, terminalView.selectionActive else {
                    self?.stopSelectionAutoScroll()
                    return
                }
                if self.selectionScrollDirection < 0 {
                    terminalView.scrollUp(lines: self.selectionScrollLines)
                } else if self.selectionScrollDirection > 0 {
                    terminalView.scrollDown(lines: self.selectionScrollLines)
                }
            }
        }

        private func stopSelectionAutoScroll() {
            selectionScrollTimer?.invalidate()
            selectionScrollTimer = nil
            selectionScrollDirection = 0
            selectionScrollLines = 1
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    final class TabClickHandler: NSObject, UIGestureRecognizerDelegate {
        weak var terminalView: TerminalView?
        var touchMode: TouchMode
        var isReadOnly: Bool

        init(terminalView: TerminalView, touchMode: TouchMode, isReadOnly: Bool) {
            self.terminalView = terminalView
            self.touchMode = touchMode
            self.isReadOnly = isReadOnly
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  !isReadOnly,
                  touchMode != .mouse,
                  let terminalView else {
                return
            }
            let location = recognizer.location(in: terminalView)
            guard let cell = terminalCell(at: location, in: terminalView),
                  cell.row <= 2 else {
                return
            }
            sendSGRMouseClick(column: cell.column, row: cell.row, via: terminalView)
            if let recognizer = recognizer as? StateCapturingTapGesture,
               !recognizer.firstResponderAtTouchStart {
                DispatchQueue.main.async {
                    _ = terminalView.resignFirstResponder()
                }
            }
        }

        private func terminalCell(at point: CGPoint, in view: TerminalView) -> (column: Int, row: Int)? {
            let terminal = view.getTerminal()
            guard view.bounds.width > 0,
                  view.bounds.height > 0,
                  terminal.cols > 0,
                  terminal.rows > 0 else {
                return nil
            }
            let column = min(
                max(Int((point.x / view.bounds.width) * CGFloat(terminal.cols)) + 1, 1),
                terminal.cols
            )
            let row = min(
                max(Int((point.y / view.bounds.height) * CGFloat(terminal.rows)) + 1, 1),
                terminal.rows
            )
            return (column, row)
        }

        private func sendSGRMouseClick(column: Int, row: Int, via terminalView: TerminalView) {
            let press = "\u{1B}[<0;\(column);\(row)M"
            let release = "\u{1B}[<0;\(column);\(row)m"
            terminalView.send(Array((press + release).utf8))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    final class StateCapturingTapGesture: UITapGestureRecognizer {
        private(set) var firstResponderAtTouchStart = false

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            firstResponderAtTouchStart = view?.isFirstResponder ?? false
            super.touchesBegan(touches, with: event)
        }
    }

    final class ShortcutGestureHandler: NSObject, UIGestureRecognizerDelegate {
        weak var terminalView: TerminalView?
        var isReadOnly: Bool

        init(terminalView: TerminalView, isReadOnly: Bool) {
            self.terminalView = terminalView
            self.isReadOnly = isReadOnly
        }

        @objc func handleEsc(_ recognizer: UITapGestureRecognizer) {
            guard !isReadOnly else { return }
            send([0x1B])
        }

        @objc func handleCtrlC(_ recognizer: UITapGestureRecognizer) {
            guard !isReadOnly else { return }
            send([0x03])
        }

        @objc func handleCtrlD(_ recognizer: UITapGestureRecognizer) {
            guard !isReadOnly else { return }
            send([0x04])
        }

        @objc func handleArrowUp(_ recognizer: UISwipeGestureRecognizer) {
            guard !isReadOnly else { return }
            send([0x1B, 0x5B, 0x41])    // ESC [ A
        }

        @objc func handleArrowDown(_ recognizer: UISwipeGestureRecognizer) {
            guard !isReadOnly else { return }
            send([0x1B, 0x5B, 0x42])    // ESC [ B
        }

        private func send(_ bytes: [UInt8]) {
            terminalView?.send(bytes)
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
