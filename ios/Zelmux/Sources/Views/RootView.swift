import SwiftUI
import UIKit

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: AppModel
    @State private var isFocusMode = false

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if !isFocusMode {
                    TopBar {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isFocusMode = true
                        }
                    }
                }
                TerminalSurface()
            }

            if isFocusMode {
                FocusRestoreHandle {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isFocusMode = false
                    }
                }
            }

            if let notice = model.sessionSwitchNotice {
                SessionSwitchToast(text: notice)
                    .padding(.top, isFocusMode ? 28 : 72)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.black)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $model.showingSettings) {
            SettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $model.showingConnectionDoctor) {
            if AppBuild.diagnosticsEnabled {
                ConnectionDoctorView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $model.showingGestureShortcuts) {
            GestureShortcutsView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $model.showingAboutPrivacy) {
            AboutPrivacyView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $model.showingComposer) {
            PromptComposerView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $model.showingSessionPicker) {
            SessionPickerView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert(model.certificatePrompt?.title ?? "Trust Zellij server?", isPresented: $model.showingCertificateTrust) {
            Button("Cancel", role: .cancel) {
                model.rejectPendingCertificate()
            }
            Button(model.certificatePrompt?.actionTitle ?? "Trust") {
                model.trustPendingCertificate()
            }
        } message: {
            Text(model.certificatePrompt?.message ?? "")
        }
        .onAppear {
            model.start()
        }
        .onChange(of: scenePhase) { phase in
            model.scenePhaseChanged(phase)
        }
    }
}

private struct SessionSwitchToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .foregroundStyle(.primary)
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            .accessibilityLabel(text)
    }
}

private struct TopBar: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var model: AppModel
    let onFocusMode: () -> Void

    var body: some View {
        HStack(spacing: isCompactPhone ? 8 : 14) {
            Menu {
                ForEach(model.settingsStore.settings.profiles) { profile in
                    Button(profile.name) {
                        model.selectProfile(profile)
                    }
                }
                Divider()
                if model.activeSession?.isReadOnly != true {
                    Button("Compose Prompt") {
                        model.showingComposer = true
                    }
                }
                Button("Settings") {
                    model.showingSettings = true
                }
                if AppBuild.diagnosticsEnabled {
                    Button("Connection Doctor") {
                        model.showingConnectionDoctor = true
                    }
                }
                Button("Gesture Shortcuts") {
                    model.showingGestureShortcuts = true
                }
                Button("About & Privacy") {
                    model.showingAboutPrivacy = true
                }
                Button("Focus Terminal") {
                    onFocusMode()
                }
            } label: {
                profileLabel
            }

            Button {
                model.showSessionPicker()
            } label: {
                HStack(spacing: isCompactPhone ? 3 : 5) {
                    Text(model.selectedProfile?.sessionName ?? "No session")
                        .font(isCompactPhone ? .caption2 : .caption)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: isCompactPhone ? 92 : 180, alignment: .leading)

            TabSwitchControls(compact: isCompactPhone)

            Spacer()

            if !isCompactPhone {
                Button {
                    model.showingComposer = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(model.activeSession?.isReadOnly == true)
                .accessibilityLabel("Compose prompt")

                if AppBuild.diagnosticsEnabled {
                    Button {
                        model.showingConnectionDoctor = true
                    } label: {
                        Image(systemName: "stethoscope")
                    }
                    .accessibilityLabel("Connection doctor")
                }

                Button {
                    model.showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }

            TouchModeMenu(showLabel: !isCompactPhone)

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .monospacedDigit()
                .frame(minWidth: isCompactPhone ? 42 : 96, alignment: .trailing)

            if !isCompactPhone {
                Button(action: onFocusMode) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("Focus terminal")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, isCompactPhone ? 10 : 16)
        .padding(.vertical, isCompactPhone ? 7 : 10)
        .background(.regularMaterial)
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var profileLabel: some View {
        if isCompactPhone {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.connected.to.line.below")
                Text(model.selectedProfile?.name ?? "Mac")
                    .lineLimit(1)
            }
            .font(.headline)
        } else {
            Label(model.selectedProfile?.name ?? "Profile", systemImage: "rectangle.connected.to.line.below")
                .font(.headline)
                .lineLimit(1)
        }
    }

    private var isCompactPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && horizontalSizeClass == .compact
    }

    private var statusText: String {
        guard isCompactPhone else {
            return model.connectionState.label
        }
        switch model.connectionState {
        case .connected(let version):
            return version ?? "Live"
        case .connecting:
            return "Link"
        case .reconnecting:
            return "Retry"
        case .disconnected:
            return "Off"
        case .failed:
            return "Fail"
        }
    }

    private var statusColor: Color {
        switch model.connectionState {
        case .connected:
            return .green
        case .failed:
            return .red
        case .connecting, .reconnecting:
            return .orange
        case .disconnected:
            return .secondary
        }
    }
}

private struct TabSwitchControls: View {
    @EnvironmentObject private var model: AppModel
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 2 : 4) {
            Button {
                model.goToPreviousTab()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: compact ? 22 : 28, height: 28)
            }
            .disabled(model.activeSession?.isReadOnly == true)
            .accessibilityLabel("Previous tab")

            Button {
                model.goToNextTab()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: compact ? 22 : 28, height: 28)
            }
            .disabled(model.activeSession?.isReadOnly == true)
            .accessibilityLabel("Next tab")

            if !compact {
                Menu {
                    ForEach(1...9, id: \.self) { index in
                        Button("Tab \(index)") {
                            model.goToTab(index)
                        }
                    }
                } label: {
                    Image(systemName: "list.number")
                        .frame(width: 28, height: 28)
                }
                .disabled(model.activeSession?.isReadOnly == true)
                .accessibilityLabel("Go to tab")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct TouchModeMenu: View {
    @EnvironmentObject private var model: AppModel
    let showLabel: Bool

    var body: some View {
        Menu {
            ForEach(TouchMode.allCases) { mode in
                Button {
                    guard let profile = model.selectedProfile else { return }
                    model.settingsStore.updateTouchMode(mode, for: profile.id)
                } label: {
                    HStack {
                        Text(mode.label)
                        if mode == selectedMode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            if showLabel {
                Label(selectedMode.label, systemImage: selectedMode.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Image(systemName: selectedMode.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
        }
        .accessibilityLabel("Touch mode")
    }

    private var selectedMode: TouchMode {
        model.selectedProfile?.touchMode ?? .scroll
    }
}

private struct FocusRestoreHandle: View {
    let restore: () -> Void

    var body: some View {
        Button(action: restore) {
            Capsule()
                .fill(.regularMaterial)
                .frame(width: 54, height: 10)
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                )
                .padding(.top, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show controls")
    }
}

private struct TerminalSurface: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SwiftTermSurface(
            stream: model.terminalStream,
            fontSize: model.settingsStore.settings.fontSize,
            colorSet: model.settingsStore.settings.terminalColorSet,
            zellijTheme: model.zellijTheme,
            isReadOnly: model.activeSession?.isReadOnly == true,
            optionAsMetaKey: model.optionAsMetaKey,
            touchMode: model.selectedProfile?.touchMode ?? .scroll,
            onInput: { data in
                model.sendData(data)
            },
            onResize: { rows, cols in
                model.sendResize(rows: rows, cols: cols)
            },
            onFontSizeChange: { fontSize in
                model.settingsStore.settings.fontSize = fontSize
            },
            onBell: {
                model.handleTerminalBell()
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

private struct ConnectionDoctorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    DoctorRow("URL", model.selectedProfile?.baseURL.absoluteString ?? "None")
                    DoctorRow("Version", model.activeSession?.version ?? "Unknown")
                    DoctorRow("State", model.connectionState.label)
                    DoctorRow("Session", model.selectedProfile?.sessionName ?? "None")
                    DoctorRow("Read-only", model.activeSession?.isReadOnly == true ? "Yes" : "No")
                }

                Section("Health") {
                    DoctorRow("Terminal bytes", "\(model.terminalBytesReceived)")
                    DoctorRow("Reconnects", "\(model.reconnectCount)")
                    DoctorRow("Memory warnings", "\(model.memoryWarningCount)")
                    if let close = model.lastClose {
                        DoctorRow("Last close", close.message)
                    }
                    if let summary = model.lastSessionListSummary {
                        DoctorRow("Sessions", summary)
                    }
                }

                Section("Certificate") {
                    DoctorRow("Observed SPKI", model.lastObservedPublicKeyHash ?? "Unknown")
                    DoctorRow("Pinned SPKI", model.selectedProfile?.trustedPublicKeyHash ?? "None")
                }

                Section("Events") {
                    ForEach(model.connectionLog) { entry in
                        Text(entry.displayLine)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Connection Doctor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") {
                        UIPasteboard.general.string = model.diagnosticLogText
                    }
                }
            }
        }
    }
}

private struct GestureShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Everyday") {
                    ShortcutRow("Tap terminal", "Show keyboard and place cursor when supported.")
                    ShortcutRow("Two-finger swipe down", "Hide keyboard.")
                    ShortcutRow("Two-finger swipe up", "Show keyboard.")
                    ShortcutRow("Pinch", "Adjust terminal font size.")
                }

                Section("Scroll & Select") {
                    ShortcutRow("One-finger drag", "Scroll terminal history in Scroll mode.")
                    ShortcutRow("Long press or double tap", "Start text selection.")
                    ShortcutRow("Drag selection past edge", "Let SwiftTerm extend the selection while it scrolls.")
                }

                Section("Agent Control") {
                    ShortcutRow("Two-finger tap", "Esc, useful to interrupt agent output.")
                    ShortcutRow("Three-finger tap", "Ctrl-C.")
                    ShortcutRow("Four-finger tap", "Ctrl-D.")
                    ShortcutRow("Two-finger swipe left", "Arrow Up, previous command.")
                    ShortcutRow("Two-finger swipe right", "Arrow Down, next command.")
                }

                Section("Zellij") {
                    ShortcutRow("Top bar chevrons", "Switch to previous or next Zellij tab.")
                    ShortcutRow("Mouse mode", "Send taps and drags directly to Zellij panes.")
                    ShortcutRow("Scroll mode", "Best default for reading agent output.")
                    ShortcutRow("Select mode", "Best when copying terminal text.")
                }
            }
            .navigationTitle("Gesture Shortcuts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct AboutPrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    var body: some View {
        NavigationStack {
            List {
                Section("About") {
                    AboutRow("App", "Zelmux")
                    AboutRow("Version", versionText)
                    AboutRow("Purpose", "A mobile client for your own Zellij web sessions.")
                }

                Section("Privacy") {
                    AboutRow("Network", "Zelmux connects only to the server URL you configure.")
                    AboutRow("Tokens", "Auth tokens are stored in the iOS Keychain.")
                    AboutRow("Certificates", "Pinned server public-key hashes are stored with your local profile settings.")
                    AboutRow("Prompts", "Prompt history and snippets stay on this device unless you send them to your terminal.")
                    AboutRow("Images", "Selected or pasted images are uploaded only when you choose an image in the prompt composer.")
                }

                Section("Data") {
                    AboutRow("No analytics", "Zelmux does not include third-party analytics or advertising SDKs.")
                    AboutRow("Diagnostics", "Connection Doctor logs are local and copied only when you tap Copy.")
                }
            }
            .navigationTitle("About & Privacy")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct AboutRow: View {
    let title: String
    let detail: String

    init(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

private struct ShortcutRow: View {
    let title: String
    let detail: String

    init(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct DoctorRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
    }
}
