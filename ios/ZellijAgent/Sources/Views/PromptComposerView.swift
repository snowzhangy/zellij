import SwiftUI

struct PromptComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextEditor(text: $prompt)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.secondary.opacity(0.3))
                    )

                if !suggestions.isEmpty {
                    List(suggestions, id: \.self) { item in
                        Button(item) {
                            prompt = item
                        }
                        .lineLimit(2)
                    }
                    .frame(maxHeight: 220)
                }
            }
            .padding()
            .navigationTitle("Prompt")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        model.sendPrompt(prompt)
                        dismiss()
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var suggestions: [String] {
        let candidates = model.settingsStore.settings.snippets + model.settingsStore.settings.promptHistory
        let prefix = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else {
            return Array(candidates.prefix(12))
        }
        return Array(candidates.filter { $0.localizedCaseInsensitiveContains(prefix) }.prefix(12))
    }
}
