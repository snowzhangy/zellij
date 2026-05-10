import SwiftUI

struct PromptComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                TextEditor(text: $prompt)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 150)
                    .padding(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.secondary.opacity(0.3))
                    )

                List {
                    if !commandSuggestions.isEmpty {
                        Section("Commands") {
                            ForEach(commandSuggestions, id: \.self) { item in
                                SuggestionRow(
                                    title: item,
                                    insert: { prompt = item },
                                    send: { send(item) }
                                )
                            }
                        }
                    }

                    if !historySuggestions.isEmpty {
                        Section("History") {
                            ForEach(historySuggestions, id: \.self) { item in
                                SuggestionRow(
                                    title: item,
                                    insert: { prompt = item },
                                    send: { send(item) }
                                )
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .padding()
            .navigationTitle("Prompt")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        send(prompt)
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var commandSuggestions: [String] {
        filtered(model.settingsStore.settings.snippets, limit: 12)
    }

    private var historySuggestions: [String] {
        filtered(model.settingsStore.settings.promptHistory, limit: 20)
    }

    private func filtered(_ candidates: [String], limit: Int) -> [String] {
        let prefix = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else {
            return Array(candidates.prefix(limit))
        }
        return Array(candidates.filter { $0.localizedCaseInsensitiveContains(prefix) }.prefix(limit))
    }

    private func send(_ value: String) {
        model.sendPrompt(value)
        dismiss()
    }
}

private struct SuggestionRow: View {
    let title: String
    let insert: () -> Void
    let send: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: insert) {
                Text(title)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.body)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Send \(title)")
        }
    }
}
