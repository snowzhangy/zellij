import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            TerminalSurface()
        }
        .background(Color.black)
        .foregroundStyle(.white)
        .sheet(isPresented: $model.showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $model.showingComposer) {
            PromptComposerView()
        }
        .sheet(isPresented: $model.showingSessionPicker) {
            SessionPickerView()
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
            if phase == .active {
                model.reconnect()
            }
        }
    }
}

private struct TopBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
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
            } label: {
                Label(model.selectedProfile?.name ?? "Profile", systemImage: "rectangle.connected.to.line.below")
                    .lineLimit(1)
            }

            Button {
                model.showSessionPicker()
            } label: {
                HStack(spacing: 4) {
                    Text(model.selectedProfile?.sessionName ?? "No session")
                        .font(.caption)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(model.connectionState.label)
                .font(.caption2)
                .foregroundStyle(statusColor)
                .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .foregroundStyle(.primary)
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

private struct TerminalSurface: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SwiftTermSurface(
            stream: model.terminalStream,
            fontSize: model.settingsStore.settings.fontSize,
            isReadOnly: model.activeSession?.isReadOnly == true,
            optionAsMetaKey: model.optionAsMetaKey,
            onInput: { data in
                model.sendData(data)
            },
            onResize: { rows, cols in
                model.sendResize(rows: rows, cols: cols)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
