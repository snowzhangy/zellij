import SwiftTerm
import SwiftUI
import UIKit

struct SwiftTermSurface: UIViewRepresentable {
    private static let defaultScrollbackLines = 20_000

    @ObservedObject var stream: TerminalStream
    let fontSize: Double
    let isReadOnly: Bool
    let optionAsMetaKey: Bool
    let touchMode: TouchMode
    let onInput: (Data) -> Void
    let onResize: (Int, Int) -> Void
    let onFontSizeChange: (Double) -> Void
    let onBell: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onInput: onInput,
            onResize: onResize,
            onFontSizeChange: onFontSizeChange,
            onBell: onBell
        )
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = ZelmuxTerminalView(
            frame: .zero,
            font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        )
        view.extraContextMenuItems = [
            UIMenuItem(
                title: "Copy Last Reply",
                action: #selector(ZelmuxTerminalView.copyLastReply(_:))
            )
        ]
        view.terminalDelegate = context.coordinator
        context.coordinator.terminalView = view
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
        view.getTerminal().changeScrollback(Self.defaultScrollbackLines)
        applyTerminalOptions(to: view)
        // Keyboard starts hidden. SwiftTerm itself shows it on a single tap
        // (cursor positioning, text input). Two-finger swipe down hides it,
        // swipe up shows it explicitly.
        context.coordinator.installFingerScroll(on: view, touchMode: touchMode)
        context.coordinator.installKeyboardToggle(on: view, touchMode: touchMode, isReadOnly: isReadOnly)
        context.coordinator.installShortcutGestures(on: view, isReadOnly: isReadOnly)
        context.coordinator.installPinchZoom(on: view, fontSize: fontSize)
        context.coordinator.customizeKeyboardAccessory(on: view)
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        if view.font.pointSize != fontSize {
            view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        applyTerminalOptions(to: view)
        context.coordinator.installFingerScroll(on: view, touchMode: touchMode)
        context.coordinator.installKeyboardToggle(on: view, touchMode: touchMode, isReadOnly: isReadOnly)
        context.coordinator.installShortcutGestures(on: view, isReadOnly: isReadOnly)
        context.coordinator.installPinchZoom(on: view, fontSize: fontSize)
        context.coordinator.customizeKeyboardAccessory(on: view)
        if isReadOnly, view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
        guard context.coordinator.lastRevision != stream.revision else { return }
        context.coordinator.lastRevision = stream.revision
        let chunk = stream.drainForFrame()
        if !chunk.isEmpty {
            view.feed(byteArray: chunk[...])
            (view as? ZelmuxTerminalView)?.recordRenderedSnapshot()
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

    private static func terminalCell(at point: CGPoint, in view: TerminalView) -> (column: Int, row: Int)? {
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

    final class Coordinator: NSObject, TerminalViewDelegate {
        var lastRevision = 0
        weak var terminalView: TerminalView?
        private var fingerScrollHandler: FingerScrollHandler?
        private var keyboardToggleHandler: KeyboardToggleHandler?
        private var shortcutHandler: ShortcutGestureHandler?
        private var pinchZoomHandler: PinchZoomHandler?
        private let accessoryCustomizer = AgentKeyboardAccessoryCustomizer()
        private var memoryPressureObserver: NSObjectProtocol?
        let onInput: (Data) -> Void
        let onResize: (Int, Int) -> Void
        let onFontSizeChange: (Double) -> Void
        let onBell: () -> Void

        init(
            onInput: @escaping (Data) -> Void,
            onResize: @escaping (Int, Int) -> Void,
            onFontSizeChange: @escaping (Double) -> Void,
            onBell: @escaping () -> Void
        ) {
            self.onInput = onInput
            self.onResize = onResize
            self.onFontSizeChange = onFontSizeChange
            self.onBell = onBell
            super.init()
            memoryPressureObserver = NotificationCenter.default.addObserver(
                forName: .zelmuxMemoryPressure,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // iOS pre-OOM signal. Drop scrollback to free ~3MB so the
                // process survives. Stays shrunk for the lifetime of this view.
                self?.terminalView?.getTerminal().changeScrollback(2_000)
            }
        }

        deinit {
            if let observer = memoryPressureObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onInput(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onResize(newRows, newCols)
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func bell(source: TerminalView) {
            onBell()
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            let text = TerminalSelectionCleaner.pasteboardText(from: content)
            UIPasteboard.general.string = text
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            UIApplication.shared.open(url)
        }

        func customizeKeyboardAccessory(on view: TerminalView) {
            accessoryCustomizer.customize(terminalView: view)
        }

        func installFingerScroll(on view: TerminalView, touchMode: TouchMode) {
            if let fingerScrollHandler {
                fingerScrollHandler.terminalView = view
                fingerScrollHandler.touchMode = touchMode
                return
            }
            let handler = FingerScrollHandler(terminalView: view)
            let gesture = UIPanGestureRecognizer(target: handler, action: #selector(FingerScrollHandler.handlePan(_:)))
            gesture.minimumNumberOfTouches = 1
            gesture.maximumNumberOfTouches = 1
            gesture.cancelsTouchesInView = false
            gesture.delegate = handler
            view.addGestureRecognizer(gesture)
            handler.gesture = gesture
            handler.touchMode = touchMode
            fingerScrollHandler = handler
        }

        func installKeyboardToggle(on view: TerminalView, touchMode: TouchMode, isReadOnly: Bool) {
            if let keyboardToggleHandler {
                keyboardToggleHandler.terminalView = view
                keyboardToggleHandler.touchMode = touchMode
                keyboardToggleHandler.isReadOnly = isReadOnly
                return
            }
            let handler = KeyboardToggleHandler(
                terminalView: view,
                touchMode: touchMode,
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

        func installPinchZoom(on view: TerminalView, fontSize: Double) {
            if let pinchZoomHandler {
                pinchZoomHandler.terminalView = view
                pinchZoomHandler.currentFontSize = fontSize
                return
            }
            let handler = PinchZoomHandler(
                terminalView: view,
                currentFontSize: fontSize,
                onFontSizeChange: onFontSizeChange
            )
            let pinch = UIPinchGestureRecognizer(
                target: handler,
                action: #selector(PinchZoomHandler.handlePinch(_:))
            )
            pinch.cancelsTouchesInView = false
            pinch.delegate = handler
            view.addGestureRecognizer(pinch)
            handler.gesture = pinch
            pinchZoomHandler = handler
        }
    }

    final class PinchZoomHandler: NSObject, UIGestureRecognizerDelegate {
        weak var terminalView: TerminalView?
        weak var gesture: UIPinchGestureRecognizer?
        var currentFontSize: Double
        private var pinchStartFontSize: Double = 0
        private let onFontSizeChange: (Double) -> Void
        private static let minimumFontSize = 8.0
        private static let maximumFontSize = 22.0

        init(
            terminalView: TerminalView,
            currentFontSize: Double,
            onFontSizeChange: @escaping (Double) -> Void
        ) {
            self.terminalView = terminalView
            self.currentFontSize = currentFontSize
            self.onFontSizeChange = onFontSizeChange
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                pinchStartFontSize = currentFontSize
            case .changed, .ended:
                let scaled = pinchStartFontSize * Double(recognizer.scale)
                let clamped = min(max(scaled, Self.minimumFontSize), Self.maximumFontSize)
                guard abs(clamped - currentFontSize) >= 0.25 || recognizer.state == .ended else {
                    return
                }
                currentFontSize = clamped
                onFontSizeChange((clamped * 2).rounded() / 2)
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    final class FingerScrollHandler: NSObject, UIGestureRecognizerDelegate {
        weak var terminalView: TerminalView?
        weak var gesture: UIPanGestureRecognizer?
        var touchMode: TouchMode = .scroll {
            didSet {
                gesture?.isEnabled = touchMode == .scroll
                if touchMode != .scroll {
                    stopMomentumScroll()
                }
            }
        }
        private static let scrollSensitivity: CGFloat = 1.7
        private static let momentumInterval: TimeInterval = 0.025
        private static let momentumDecay: CGFloat = 0.88
        private static let minimumMomentumVelocity: CGFloat = 220
        private static let maximumLinesPerUpdate = 18
        private static let wheelUpButton = 64
        private static let wheelDownButton = 65
        private var accumulatedDelta: CGFloat = 0
        private var momentumVelocity: CGFloat = 0
        private var momentumScrollTimer: Timer?
        private var lastPanLocation: CGPoint = .zero

        init(terminalView: TerminalView) {
            self.terminalView = terminalView
        }

        deinit {
            stopMomentumScroll()
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let terminalView else {
                stopMomentumScroll()
                return
            }
            guard touchMode == .scroll else {
                stopMomentumScroll()
                return
            }
            if terminalView.selectionActive {
                stopMomentumScroll()
                return
            }
            switch recognizer.state {
            case .began:
                stopMomentumScroll()
                accumulatedDelta = 0
                lastPanLocation = recognizer.location(in: terminalView)
            case .changed:
                stopMomentumScroll()
                lastPanLocation = recognizer.location(in: terminalView)
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
                scrollUp(lines: lines, in: terminalView)
                accumulatedDelta -= CGFloat(lines) * lineHeight
            } else if lines < 0 {
                scrollDown(lines: -lines, in: terminalView)
                accumulatedDelta -= CGFloat(lines) * lineHeight
            }
        }

        private func scrollUp(lines: Int, in terminalView: TerminalView) {
            if terminalView.canScroll {
                terminalView.scrollUp(lines: lines)
            } else {
                sendWheel(button: Self.wheelUpButton, repeats: lines, in: terminalView)
            }
        }

        private func scrollDown(lines: Int, in terminalView: TerminalView) {
            if terminalView.canScroll {
                terminalView.scrollDown(lines: lines)
            } else {
                sendWheel(button: Self.wheelDownButton, repeats: lines, in: terminalView)
            }
        }

        private func sendWheel(button: Int, repeats: Int, in terminalView: TerminalView) {
            guard repeats > 0,
                  terminalView.getTerminal().mouseMode != .off,
                  let cell = SwiftTermSurface.terminalCell(at: lastPanLocation, in: terminalView) else {
                return
            }
            let cappedRepeats = min(repeats, Self.maximumLinesPerUpdate)
            let event = "\u{1B}[<\(button);\(cell.column);\(cell.row)M"
            let bytes = Array(String(repeating: event, count: cappedRepeats).utf8)
            terminalView.send(bytes)
        }

        private func startMomentumScroll(velocity: CGFloat, terminalView: TerminalView) {
            momentumVelocity = velocity
            momentumScrollTimer?.invalidate()
            let timer = Timer.scheduledTimer(
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
            timer.tolerance = Self.momentumInterval * 0.5
            momentumScrollTimer = timer
        }

        private func stopMomentumScroll() {
            momentumScrollTimer?.invalidate()
            momentumScrollTimer = nil
            momentumVelocity = 0
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Yield to SwiftTerm's word/line selection. Long-press auto-fails
            // on pan movement, so no explicit dependency needed there — adding
            // it would delay every scroll start by the long-press timeout.
            if let tap = otherGestureRecognizer as? UITapGestureRecognizer,
               tap.numberOfTapsRequired >= 2 {
                return true
            }
            return false
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let terminalView else { return false }
            // Let SwiftTerm own selection gestures end-to-end. Its internal
            // selection pan keeps the anchor stable and handles edge scrolling.
            guard touchMode != .select, !terminalView.selectionActive else {
                stopMomentumScroll()
                return false
            }
            return touchMode != .mouse
        }
    }

    final class ShortcutGestureHandler: NSObject, UIGestureRecognizerDelegate {
        weak var terminalView: TerminalView?
        var isReadOnly: Bool
        private let haptic = UIImpactFeedbackGenerator(style: .light)

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
            haptic.impactOccurred()
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
        var touchMode: TouchMode
        var isReadOnly: Bool

        init(terminalView: TerminalView, touchMode: TouchMode, isReadOnly: Bool) {
            self.terminalView = terminalView
            self.touchMode = touchMode
            self.isReadOnly = isReadOnly
        }

        @objc func handleSwipeUp(_ recognizer: UISwipeGestureRecognizer) {
            guard let terminalView, !isReadOnly, touchMode != .select else { return }
            _ = terminalView.becomeFirstResponder()
        }

        @objc func handleSwipeDown(_ recognizer: UISwipeGestureRecognizer) {
            guard let terminalView, touchMode != .select else { return }
            _ = terminalView.resignFirstResponder()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    final class AgentKeyboardAccessoryCustomizer: NSObject {
        private weak var terminalView: TerminalView?
        private static let returnButtonIdentifier = "Zelmux.ReturnAccessoryButton"
        private static let backspaceButtonIdentifier = "Zelmux.BackspaceAccessoryButton"
        private var backspaceRepeatStart: DispatchWorkItem?
        private var backspaceRepeatTimer: Timer?

        deinit {
            stopBackspaceRepeat()
        }

        func customize(terminalView: TerminalView) {
            self.terminalView = terminalView
            guard let accessory = terminalView.inputAccessoryView else { return }
            DispatchQueue.main.async { [weak self, weak accessory] in
                guard let self, let accessory else { return }
                self.replaceLowValueButtons(in: accessory)
            }
        }

        private func replaceLowValueButtons(in accessory: UIView) {
            let buttons = accessory.subviews
                .compactMap { $0 as? UIButton }
                .sorted { $0.frame.minX < $1.frame.minX }
            guard !buttons.isEmpty else { return }

            if let functionButton = buttons.first(where: { button in
                button.accessibilityIdentifier == Self.backspaceButtonIdentifier ||
                    button.title(for: .normal) == "F1"
            }) {
                configureAsBackspace(functionButton)
            }

            if buttons.count >= 2 {
                let rightUtilityButton = buttons[buttons.count - 2]
                configureAsReturn(rightUtilityButton)
            }
        }

        private func configureAsReturn(_ button: UIButton) {
            guard button.accessibilityIdentifier != Self.returnButtonIdentifier else { return }
            button.accessibilityIdentifier = Self.returnButtonIdentifier
            button.removeTarget(nil, action: nil, for: .allEvents)
            button.setImage(nil, for: .normal)
            button.setTitle("↵", for: .normal)
            button.accessibilityLabel = "Return"
            button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
            button.addTarget(self, action: #selector(sendReturn), for: .touchDown)
        }

        private func configureAsBackspace(_ button: UIButton) {
            guard button.accessibilityIdentifier != Self.backspaceButtonIdentifier else { return }
            button.accessibilityIdentifier = Self.backspaceButtonIdentifier
            button.removeTarget(nil, action: nil, for: .allEvents)
            button.setImage(UIImage(systemName: "delete.left"), for: .normal)
            button.setTitle(nil, for: .normal)
            button.accessibilityLabel = "Backspace"
            button.addTarget(self, action: #selector(startBackspaceRepeat), for: .touchDown)
            button.addTarget(self, action: #selector(stopBackspaceRepeat), for: .touchUpInside)
            button.addTarget(self, action: #selector(stopBackspaceRepeat), for: .touchUpOutside)
            button.addTarget(self, action: #selector(stopBackspaceRepeat), for: .touchCancel)
            button.addTarget(self, action: #selector(stopBackspaceRepeat), for: .touchDragExit)
        }

        @objc private func sendReturn() {
            UIDevice.current.playInputClick()
            terminalView?.send([0x0D])
        }

        @objc private func startBackspaceRepeat() {
            stopBackspaceRepeat()
            sendBackspace(playClick: true)

            let workItem = DispatchWorkItem { [weak self] in
                self?.beginBackspaceTimer()
            }
            backspaceRepeatStart = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
        }

        @objc private func stopBackspaceRepeat() {
            backspaceRepeatStart?.cancel()
            backspaceRepeatStart = nil
            backspaceRepeatTimer?.invalidate()
            backspaceRepeatTimer = nil
        }

        private func beginBackspaceTimer() {
            backspaceRepeatTimer?.invalidate()
            let timer = Timer(timeInterval: 0.055, repeats: true) { [weak self] _ in
                self?.sendBackspace(playClick: false)
            }
            timer.tolerance = 0.015
            RunLoop.main.add(timer, forMode: .common)
            backspaceRepeatTimer = timer
        }

        private func sendBackspace(playClick: Bool) {
            if playClick {
                UIDevice.current.playInputClick()
            }
            terminalView?.deleteBackward()
        }
    }
}

final class ZelmuxTerminalView: TerminalView {
    private var transcriptLines: [String] = []
    private var lastTranscriptSnapshotAt: Date?
    private let maxTranscriptLines = 12_000
    private let transcriptSnapshotInterval: TimeInterval = 0.25

    @objc func copyLastReply(_ sender: Any?) {
        guard let text = currentLastReplyText() else { return }
        recordRenderedSnapshot(force: true)
        UIPasteboard.general.string = text
        UIMenuController.shared.hideMenu()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copyLastReply(_:)) {
            return !transcriptLines.isEmpty || !currentTerminalLines().isEmpty
        }
        return super.canPerformAction(action, withSender: sender)
    }

    private func currentLastReplyText() -> String? {
        let currentLines = currentTerminalLines()
        if let text = TerminalSelectionCleaner.lastReplyText(fromCleanedLines: currentLines) {
            return text
        }
        if let text = TerminalSelectionCleaner.lastReplyText(fromCleanedLines: transcriptLines) {
            return text
        }
        return nil
    }

    private func currentTerminalLines() -> [String] {
        let data = getTerminal().getBufferAsData(kind: .active)
        return TerminalSelectionCleaner.cleanedLines(from: data)
    }

    func recordRenderedSnapshot(force: Bool = false) {
        let now = Date()
        if !force,
           let lastTranscriptSnapshotAt,
           now.timeIntervalSince(lastTranscriptSnapshotAt) < transcriptSnapshotInterval {
            return
        }
        let snapshotLines = currentTerminalLines()
        guard !snapshotLines.isEmpty else { return }
        lastTranscriptSnapshotAt = now
        guard !transcriptLines.isEmpty else {
            transcriptLines = snapshotLines
            return
        }

        let overlap = longestTranscriptOverlap(with: snapshotLines)
        if overlap > 0 {
            transcriptLines.append(contentsOf: snapshotLines.dropFirst(overlap))
        } else {
            // A Zellij tab/session switch usually redraws a completely
            // different screen. Reset so "Copy Last Reply" follows the
            // visible conversation instead of mixing tabs.
            transcriptLines = snapshotLines
        }
        trimTranscriptIfNeeded()
    }

    private func longestTranscriptOverlap(with snapshotLines: [String]) -> Int {
        let maxCandidate = min(snapshotLines.count, transcriptLines.count, 240)
        guard maxCandidate > 0 else { return 0 }
        for count in stride(from: maxCandidate, through: 1, by: -1) {
            let transcriptStart = transcriptLines.count - count
            var matches = true
            for offset in 0..<count where transcriptLines[transcriptStart + offset] != snapshotLines[offset] {
                matches = false
                break
            }
            if matches {
                return count
            }
        }
        return 0
    }

    private func trimTranscriptIfNeeded() {
        guard transcriptLines.count > maxTranscriptLines else { return }
        transcriptLines.removeFirst(transcriptLines.count - maxTranscriptLines)
    }
}
