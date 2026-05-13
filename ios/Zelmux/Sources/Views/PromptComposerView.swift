import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct PromptComposerView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    @State private var prompt = ""
    @State private var sendMode: PromptSendMode = .sendAndEnter
    @State private var editingSnippet: String?
    @State private var snippetDraft = ""
    @State private var showingSnippetEditor = false
    @State private var selectedImageItem: PhotosPickerItem?
    @State private var isUploadingImage = false
    @State private var uploadError: String?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                if proxy.size.width >= 760 || horizontalSizeClass == .regular {
                    HStack(alignment: .top, spacing: 16) {
                        editorPanel
                            .frame(minWidth: 360, maxWidth: 560, maxHeight: .infinity, alignment: .top)
                        suggestionsList
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 10) {
                        editorPanel
                        suggestionsList
                    }
                    .padding()
                }
            }
            .navigationTitle("Prompt")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        uploadClipboardImage()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .disabled(isUploadingImage || !UIPasteboard.general.hasImages)
                    .accessibilityLabel("Paste Image")

                    PhotosPicker(
                        selection: $selectedImageItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Image(systemName: "photo")
                    }
                    .disabled(isUploadingImage)
                    .accessibilityLabel("Choose Image")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sendMode.actionLabel) {
                        send(prompt)
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showingSnippetEditor) {
                SnippetEditorView(
                    title: editingSnippet == nil ? "New Snippet" : "Edit Snippet",
                    snippet: $snippetDraft,
                    save: saveSnippet
                )
            }
            .onChange(of: selectedImageItem) { item in
                guard let item else { return }
                uploadPhotoPickerImage(item)
            }
        }
    }

    private var editorPanel: some View {
        VStack(spacing: 10) {
            Picker("Send mode", selection: $sendMode) {
                ForEach(PromptSendMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            TextEditor(text: $prompt)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(minHeight: horizontalSizeClass == .regular ? 260 : 130)
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.secondary.opacity(0.3))
                )

            if isUploadingImage {
                ProgressView("Uploading image...")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let uploadError {
                Text(uploadError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
    }

    private var suggestionsList: some View {
        List {
            if !snippetSuggestions.isEmpty {
                Section {
                    ForEach(snippetSuggestions, id: \.self) { item in
                        SuggestionRow(
                            title: item,
                            insert: { prompt = item },
                            send: { send(item) },
                            edit: { editSnippet(item) },
                            delete: { model.settingsStore.deleteSnippet(item) }
                        )
                    }
                } header: {
                    HStack {
                        Text("Snippets")
                        Spacer()
                        Button("Add") {
                            editSnippet(nil)
                        }
                        .textCase(nil)
                    }
                }
            } else {
                Section("Snippets") {
                    Button("Add Snippet") {
                        editSnippet(nil)
                    }
                }
            }

            if !historySuggestions.isEmpty {
                Section("History") {
                    ForEach(historySuggestions, id: \.self) { item in
                        SuggestionRow(
                            title: item,
                            insert: { prompt = item },
                            send: { send(item) },
                            edit: nil,
                            delete: nil
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var snippetSuggestions: [String] {
        filtered(model.settingsStore.settings.snippets, limit: 16)
    }

    private var historySuggestions: [String] {
        filtered(model.settingsStore.settings.promptHistory, limit: 24)
    }

    private func filtered(_ candidates: [String], limit: Int) -> [String] {
        let query = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return Array(candidates.prefix(limit))
        }
        return Array(candidates.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(limit))
    }

    private func send(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch sendMode {
        case .sendAndEnter:
            model.sendPrompt(trimmed, appendEnter: true)
            dismiss()
        case .pasteOnly:
            model.sendPrompt(trimmed, appendEnter: false)
            dismiss()
        case .stage:
            prompt = trimmed
        }
    }

    private func editSnippet(_ snippet: String?) {
        editingSnippet = snippet
        snippetDraft = snippet ?? prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        showingSnippetEditor = true
    }

    private func saveSnippet() {
        if let editingSnippet {
            model.settingsStore.updateSnippet(oldValue: editingSnippet, newValue: snippetDraft)
        } else {
            model.settingsStore.addSnippet(snippetDraft)
        }
        showingSnippetEditor = false
        editingSnippet = nil
        snippetDraft = ""
    }

    private func uploadClipboardImage() {
        guard let image = UIPasteboard.general.image,
              let data = image.pngData() else {
            uploadError = "Clipboard does not contain a readable image."
            return
        }
        uploadImage(data: data, filename: "clipboard.png", mimeType: "image/png")
    }

    private func uploadPhotoPickerImage(_ item: PhotosPickerItem) {
        Task {
            let contentType = item.supportedContentTypes.first { $0.conforms(to: .image) }
            let mimeType = contentType?.preferredMIMEType ?? "image/png"
            let filename = "photo.\(contentType?.preferredFilenameExtension ?? "png")"
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    await MainActor.run {
                        uploadError = "Could not read the selected image."
                        selectedImageItem = nil
                    }
                    return
                }
                let upload = preparedPhotoUpload(
                    data: data,
                    filename: filename,
                    mimeType: mimeType
                )
                await MainActor.run {
                    uploadImage(data: upload.data, filename: upload.filename, mimeType: upload.mimeType)
                    selectedImageItem = nil
                }
            } catch {
                await MainActor.run {
                    uploadError = error.localizedDescription
                    selectedImageItem = nil
                }
            }
        }
    }

    private func preparedPhotoUpload(
        data: Data,
        filename: String,
        mimeType: String
    ) -> (data: Data, filename: String, mimeType: String) {
        let lowercasedFilename = filename.lowercased()
        let shouldConvertToPNG = mimeType == "image/heic"
            || mimeType == "image/heif"
            || lowercasedFilename.hasSuffix(".heic")
            || lowercasedFilename.hasSuffix(".heif")
        guard shouldConvertToPNG,
              let image = UIImage(data: data),
              let jpegData = image.jpegData(compressionQuality: 0.85) else {
            return (data, filename, mimeType)
        }
        return (jpegData, "photo.jpg", "image/jpeg")
    }

    private func uploadImage(data: Data, filename: String, mimeType: String) {
        isUploadingImage = true
        uploadError = nil
        Task {
            do {
                let path = try await model.uploadImageForPrompt(
                    data: data,
                    filename: filename,
                    mimeType: mimeType
                )
                await MainActor.run {
                    appendPath(path)
                    isUploadingImage = false
                }
            } catch {
                await MainActor.run {
                    uploadError = error.localizedDescription
                    isUploadingImage = false
                }
            }
        }
    }

    private func appendPath(_ path: String) {
        let pathReference = shellQuotedPath(path)
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt = pathReference
        } else {
            prompt += "\n\(pathReference)"
        }
    }

    private func shellQuotedPath(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private enum PromptSendMode: String, CaseIterable, Identifiable {
    case sendAndEnter
    case pasteOnly
    case stage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sendAndEnter:
            return "Send"
        case .pasteOnly:
            return "Paste"
        case .stage:
            return "Stage"
        }
    }

    var actionLabel: String {
        label
    }
}

private struct SuggestionRow: View {
    let title: String
    let insert: () -> Void
    let send: () -> Void
    let edit: (() -> Void)?
    let delete: (() -> Void)?

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
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Send \(title)")

            if edit != nil || delete != nil {
                Menu {
                    if let edit {
                        Button("Edit", action: edit)
                    }
                    if let delete {
                        Button("Delete", role: .destructive, action: delete)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .frame(width: 30, height: 34)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Snippet options")
            }
        }
    }
}

private struct SnippetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var snippet: String
    let save: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Snippet") {
                    TextEditor(text: $snippet)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
