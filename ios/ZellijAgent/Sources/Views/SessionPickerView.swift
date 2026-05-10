import SwiftUI

struct SessionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    @State private var newSessionName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if model.isLoadingSessions {
                        ProgressView("Loading sessions")
                    } else if let error = model.sessionListError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else if let summary = model.lastSessionListSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section("Attach") {
                    if model.isLoadingSessions {
                        Text("Checking server...")
                            .foregroundStyle(.secondary)
                    } else if model.availableSessions.isEmpty {
                        Text("No sessions found.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.availableSessions) { session in
                            Button {
                                model.attachSession(session)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(session.name)
                                        .font(.body.monospaced())
                                    Spacer()
                                    Text(session.status.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Create") {
                    TextField("New session name", text: $newSessionName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Create Session") {
                        model.createSession(newSessionName)
                        dismiss()
                    }
                    .disabled(newSessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Zellij Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.refreshAvailableSessions()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear {
                newSessionName = model.missingSessionName ?? model.selectedProfile?.sessionName ?? ""
                model.refreshAvailableSessions()
            }
        }
    }

    private var message: String {
        guard let missing = model.missingSessionName else {
            return "Choose an active Zellij session or create a new one."
        }
        return "Saved session '\(missing)' no longer exists. Choose an active session or create one explicitly."
    }
}

private extension SessionListStatus {
    var label: String {
        switch self {
        case .live:
            return "Live"
        case .resurrectable:
            return "Saved"
        case .unknown:
            return "Unknown"
        }
    }
}
