import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    @State private var selectedProfileID: UUID?
    @State private var name = "Mac"
    @State private var baseURL = "https://"
    @State private var sessionName = ""
    @State private var authToken = ""
    @State private var trustedPublicKeyHash = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    if !model.settingsStore.settings.profiles.isEmpty {
                        Picker("Saved", selection: $selectedProfileID) {
                            ForEach(model.settingsStore.settings.profiles) { profile in
                                Text(profile.name).tag(Optional(profile.id))
                            }
                        }
                        .onChange(of: selectedProfileID) { id in
                            loadProfile(id)
                        }
                    }

                    TextField("Name", text: $name)
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Session", text: $sessionName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Auth token", text: $authToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Certificate Pin") {
                    TextField("Trusted public key hash", text: $trustedPublicKeyHash)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let observed = model.lastObservedPublicKeyHash {
                        Button("Use observed hash") {
                            trustedPublicKeyHash = observed
                        }
                        Text(observed)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }

                Section("Display") {
                    HStack {
                        Text("Font")
                        Slider(value: $model.settingsStore.settings.fontSize, in: 9...18, step: 1)
                        Text("\(Int(model.settingsStore.settings.fontSize))")
                            .font(.caption.monospacedDigit())
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Zellij Agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                }
            }
            .onAppear {
                selectedProfileID = model.selectedProfile?.id
                loadProfile(selectedProfileID)
            }
        }
    }

    private func loadProfile(_ id: UUID?) {
        guard let profile = model.settingsStore.settings.profiles.first(where: { $0.id == id }) ?? model.selectedProfile else {
            return
        }
        name = profile.name
        baseURL = profile.baseURL.absoluteString
        sessionName = profile.sessionName
        trustedPublicKeyHash = profile.trustedPublicKeyHash ?? ""
        authToken = (try? KeychainStore.token(profileID: profile.id)) ?? ""
    }

    private func save() {
        guard let url = URL(string: baseURL), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            errorMessage = "Enter a valid http(s) base URL."
            return
        }
        guard !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter a Zellij session name."
            return
        }
        let profile = ZellijProfile(
            id: selectedProfileID ?? UUID(),
            name: name.isEmpty ? url.host ?? "Mac" : name,
            baseURL: url,
            sessionName: sessionName.trimmingCharacters(in: .whitespacesAndNewlines),
            trustedPublicKeyHash: trustedPublicKeyHash.isEmpty ? nil : trustedPublicKeyHash
        )
        model.settingsStore.upsertProfile(profile, token: authToken)
        model.connect()
        dismiss()
    }
}
