// AIChatModule.swift
// Digitales Büro — KI-Chat (Gemini 2.0 Flash, In-App)

import SwiftUI
import PDFKit

// MARK: - Chat Mode

enum ChatMode: Int, CaseIterable {
    case assistant = 0
    case codeEditor = 1

    var label: String {
        switch self {
        case .assistant: return "App-Assistent"
        case .codeEditor: return "Code ändern"
        }
    }
}

enum AttachmentSheetType: Identifiable {
    case camera
    case photoLibrary
    case document
    var id: Self { self }
}

// MARK: - AIChatView

struct AIChatView: View {
    @StateObject private var gemini = GeminiService()
    @AppStorage("dev_mode_enabled") private var devModeEnabled: Bool = false
    @AppStorage("ai_agent_url") private var agentURL: String = "https://ucmkbhmtdpbxsbahzahj.supabase.co/functions/v1/ai-agent"

    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var selectedMode: Int = 0
    @State private var showClearConfirm: Bool = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("gemini_api_key") private var geminiApiKey: String = ""
    @State private var showApiKeySheet: Bool = false

    // Multimodal attachments
    @State private var attachedImageData: Data? = nil
    @State private var attachedImageThumbnail: UIImage? = nil
    @State private var attachedFileName: String? = nil
    @State private var activeAttachmentSheet: AttachmentSheetType? = nil
    @State private var showAttachmentActionSheet: Bool = false

    var isEmbeddedInTabBar: Bool = false
    @FocusState private var isInputFocused: Bool

    private let storageKey = "chat_history_v1"

    init(initialPrompt: String? = nil, isEmbeddedInTabBar: Bool = false) {
        self.isEmbeddedInTabBar = isEmbeddedInTabBar
        if let initialPrompt = initialPrompt {
            _inputText = State(initialValue: initialPrompt)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Mode picker (only in dev mode)
            if devModeEnabled {
                Picker("Modus", selection: $selectedMode) {
                    ForEach(ChatMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            // API key warning
            if gemini.apiKey.isEmpty {
                Button {
                    showApiKeySheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Kein Gemini API Key – hier tippen zum Eingeben")
                            .font(.caption.bold())
                            .foregroundColor(.orange)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.orange.opacity(0.8))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange.opacity(0.15))
                }
            }

            // Code mode warning
            if selectedMode == ChatMode.codeEditor.rawValue {
                HStack(spacing: 8) {
                    Image(systemName: "terminal.fill")
                        .foregroundColor(.green)
                    Text("Code-Modus: KI kann GitHub-Commits erstellen & Build starten.")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color.green.opacity(0.10))
            }

            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if messages.isEmpty {
                            emptyStateView
                        }
                        ForEach(messages) { msg in
                            MessageBubbleView(message: msg)
                                .id(msg.id)
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .contentShape(Rectangle())
                .onTapGesture {
                    isInputFocused = false
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: messages.last?.content) { _, _ in
                    // Scroll auch während Gemini streamt (Chunk für Chunk)
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Attachment preview card
            if let thumb = attachedImageThumbnail {
                HStack(spacing: 10) {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachedFileName ?? "Bild-Anhang")
                            .font(.caption.bold())
                            .lineLimit(1)
                        Text("Bereit zum Senden an Gemini")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        attachedImageData = nil
                        attachedImageThumbnail = nil
                        attachedFileName = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                }
                .padding(8)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal)
                .padding(.bottom, 4)
            } else if let filename = attachedFileName {
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill")
                        .font(.title2)
                        .foregroundStyle(Color(red: 0.43, green: 0.36, blue: 0.91))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(filename)
                            .font(.caption.bold())
                            .lineLimit(1)
                        Text("Dokument angehängt")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        attachedImageData = nil
                        attachedFileName = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                }
                .padding(8)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal)
                .padding(.bottom, 4)
            }

            // Input bar
            HStack(alignment: .bottom, spacing: 10) {
                // Paperclip Attachment Button
                Button {
                    showAttachmentActionSheet = true
                } label: {
                    Image(systemName: attachedImageData != nil ? "paperclip.circle.fill" : "paperclip")
                        .font(.system(size: 22))
                        .foregroundStyle(
                            attachedImageData != nil
                                ? Color(red: 0.43, green: 0.36, blue: 0.91)
                                : Color.secondary
                        )
                        .padding(.vertical, 8)
                }
                .disabled(gemini.isStreaming)

                TextField(
                    selectedMode == ChatMode.codeEditor.rawValue
                        ? "Code-Änderung beschreiben..."
                        : (attachedImageData != nil ? "Frage zum Dokument/Bild..." : "Nachricht eingeben..."),
                    text: $inputText,
                    axis: .vertical
                )
                .focused($isInputFocused)
                .lineLimit(1...5)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                if isInputFocused {
                    Button {
                        isInputFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                }

                Button {
                    Task { await sendMessage() }
                } label: {
                    Image(systemName: gemini.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            selectedMode == ChatMode.codeEditor.rawValue
                                ? Color.green : Color(red: 0.43, green: 0.36, blue: 0.91)
                        )
                }
                .disabled(
                    (inputText.trimmingCharacters(in: .whitespaces).isEmpty && attachedImageData == nil)
                    && !gemini.isStreaming
                )
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isInputFocused)
        }
        .navigationTitle("KI-Assistent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isInputFocused {
                    Button("Fertig") {
                        isInputFocused = false
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.primaryAccent)
                }
            }

            ToolbarItemGroup(placement: .keyboard) {
                Text(selectedMode == ChatMode.codeEditor.rawValue ? "Code-Modus" : "KI-Assistent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isInputFocused = false
                } label: {
                    HStack(spacing: 4) {
                        Text("Fertig")
                            .bold()
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryAccent)
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.secondary)
                }
            }
        }
        .confirmationDialog("Anhang hinzufügen", isPresented: $showAttachmentActionSheet, titleVisibility: .visible) {
            Button("Foto aufnehmen (Kamera)") {
                activeAttachmentSheet = .camera
            }
            Button("Aus Fotomediathek wählen") {
                activeAttachmentSheet = .photoLibrary
            }
            Button("Dokument / Datei wählen (PDF)") {
                activeAttachmentSheet = .document
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .sheet(item: $activeAttachmentSheet) { sheetType in
            switch sheetType {
            case .camera:
                DocumentImagePicker(sourceType: .camera) { image in
                    activeAttachmentSheet = nil
                    if let image = image {
                        handlePickedImage(image)
                    }
                }
            case .photoLibrary:
                DocumentImagePicker(sourceType: .photoLibrary) { image in
                    activeAttachmentSheet = nil
                    if let image = image {
                        handlePickedImage(image)
                    }
                }
            case .document:
                DocumentFilePicker { url in
                    activeAttachmentSheet = nil
                    if let url = url {
                        handlePickedDocument(url)
                    }
                }
            }
        }
        .confirmationDialog("Verlauf löschen?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                messages = []
                saveMessages()
            }
        }
        .sheet(isPresented: $showApiKeySheet) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Gib hier deinen Google Gemini API Key ein, um den KI-Chat und den Code-Modus zu nutzen.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    SecureField("AIzaSy...", text: $geminiApiKey)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Text("Der Key wird sicher lokal auf diesem Gerät gespeichert.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Spacer()
                }
                .padding()
                .navigationTitle("Gemini API Key")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Speichern") {
                            UserDefaults.standard.set(geminiApiKey, forKey: "gemini_api_key")
                            showApiKeySheet = false
                        }
                        .bold()
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen") {
                            showApiKeySheet = false
                        }
                    }
                }
            }
            .presentationDetents([.fraction(0.35), .medium])
        }
        .onAppear { loadMessages() }
    }

    // MARK: - Empty state
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(Color(red: 0.43, green: 0.36, blue: 0.91))
            Text("KI-Assistent")
                .font(.title3.bold())
            Text(devModeEnabled
                 ? "Frage mich alles über die App oder lade Dokumente/Fotos hoch zur automatischen Analyse."
                 : "Frage mich alles über deine Schulden, Dokumente und den Haushalt. Du kannst auch Dokumente oder Rechnungen anhängen.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .font(.subheadline)
        }
        .padding(40)
    }

    // MARK: - Attachment Handling
    private func handlePickedImage(_ image: UIImage) {
        let maxDim: CGFloat = 1280
        let s = image.size
        var resized = image
        if s.width > maxDim || s.height > maxDim {
            let scale = min(maxDim / s.width, maxDim / s.height)
            let newSize = CGSize(width: s.width * scale, height: s.height * scale)
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            image.draw(in: CGRect(origin: .zero, size: newSize))
            if let c = UIGraphicsGetImageFromCurrentImageContext() {
                resized = c
            }
            UIGraphicsEndImageContext()
        }
        attachedImageThumbnail = resized
        attachedImageData = resized.jpegData(compressionQuality: 0.8)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmm"
        attachedFileName = "Foto_\(df.string(from: Date())).jpg"
    }

    private func handlePickedDocument(_ url: URL) {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }

        attachedFileName = url.lastPathComponent

        guard let data = try? Data(contentsOf: url) else { return }

        if url.pathExtension.lowercased() == "pdf" {
            if let pdfDoc = PDFDocument(data: data), let page = pdfDoc.page(at: 0) {
                let rect = page.bounds(for: .mediaBox)
                let renderer = UIGraphicsImageRenderer(size: rect.size)
                let img = renderer.image { ctx in
                    UIColor.white.set()
                    ctx.fill(rect)
                    ctx.cgContext.translateBy(x: 0, y: rect.height)
                    ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                    page.draw(with: .mediaBox, to: ctx.cgContext)
                }
                attachedImageThumbnail = img
                attachedImageData = img.jpegData(compressionQuality: 0.8)
            }
        } else if let img = UIImage(data: data) {
            handlePickedImage(img)
        }
    }

    // MARK: - Send message
    private func sendMessage() async {
        isInputFocused = false   // ← Tastatur sofort schließen
        let text = inputText.trimmingCharacters(in: .whitespaces)
        let imgData = attachedImageData
        let fname = attachedFileName

        guard !text.isEmpty || imgData != nil else { return }

        inputText = ""
        attachedImageData = nil
        attachedImageThumbnail = nil
        attachedFileName = nil

        let finalPrompt = text.isEmpty ? "Bitte analysiere dieses angehängte Dokument bzw. Bild und erkläre mir die wichtigsten Punkte." : text
        let userMsg = ChatMessage(
            role: .user,
            content: finalPrompt,
            attachedImageData: imgData,
            attachedFileName: fname
        )
        messages.append(userMsg)
        saveMessages()

        if selectedMode == ChatMode.codeEditor.rawValue {
            await sendCodeChangeMessage(prompt: finalPrompt)
        } else {
            await sendAssistantMessage(prompt: finalPrompt, imageData: imgData)
        }
    }

    // MARK: - Assistant streaming (crash-safe: ID statt Index)
    private func sendAssistantMessage(prompt: String, imageData: Data? = nil) async {
        var assistantMsg = ChatMessage(role: .assistant, isCodeChange: false)
        assistantMsg.isStreaming = true
        let msgId = assistantMsg.id          // ← ID merken, nicht Index!
        messages.append(assistantMsg)

        gemini.isStreaming = true
        let context = """
        Du bist ein freundlicher, kompetenter Assistent für die App \"Digitales Büro\" – \
        eine iOS-App für Schulden- und Haushaltsmanagement (SwiftUI, iOS 17+). \
        Antworte immer auf Deutsch. Sei präzise und hilfreich. \
        Du kennst alle Funktionen der App: Schulden-Tracker, Dokumentenscanner, \
        Putzplan, Hardware-Logbuch, Exportmodul und Abonnement-Verwaltung. \
        Wenn der Nutzer ein Dokument oder Foto hochgeladen hat, analysiere den Inhalt präzise \
        (Gläubiger, Forderungshöhe, Zahlungsfristen, Aktenzeichen, etc.) und gib sofort handlungsorientierte Empfehlungen.
        """

        let stream = gemini.streamResponse(
            prompt: prompt,
            systemContext: context,
            history: Array(messages.dropLast()),
            imageData: imageData
        )
        do {
            for try await chunk in stream {
                // Nach jedem Chunk sicher per ID suchen (crash-sicher)
                if let i = messages.firstIndex(where: { $0.id == msgId }) {
                    messages[i].content += chunk
                }
            }
        } catch {
            if let i = messages.firstIndex(where: { $0.id == msgId }) {
                messages[i].content = "⚠️ \(error.localizedDescription)"
            }
        }

        if let i = messages.firstIndex(where: { $0.id == msgId }) {
            messages[i].isStreaming = false
        }
        gemini.isStreaming = false
        saveMessages()
    }

    // MARK: - Code change via agent (crash-safe: ID statt Index)
    private func sendCodeChangeMessage(prompt: String) async {
        var agentMsg = ChatMessage(role: .assistant, content: "⏳ KI-Agent analysiert Repository...", isCodeChange: true)
        agentMsg.isStreaming = true
        let msgId = agentMsg.id               // ← ID merken, nicht Index!
        messages.append(agentMsg)

        gemini.isStreaming = true
        do {
            let result = try await gemini.sendCodeChangeRequest(prompt: prompt, agentURL: agentURL)
            var response = result.text
            if let i = messages.firstIndex(where: { $0.id == msgId }) {
                if let sha = result.commitSHA {
                    response += "\n\n✅ **Code committed!**\nSHA: `\(sha.prefix(8))`\n🔄 GitHub Actions baut neues IPA..."
                    messages[i].commitSHA = sha
                }
                if let url = result.actionsUrl {
                    response += "\n[→ Actions öffnen](\(url))"
                    messages[i].actionsUrl = url
                }
                messages[i].content = response
            }
        } catch {
            AppLogger.shared.warn("KI-Agent", "Code-Anfrage fehlgeschlagen: \(error.localizedDescription)")
            if let i = messages.firstIndex(where: { $0.id == msgId }) {
                messages[i].content = "⚠️ *Code-Anfrage fehlgeschlagen: \(error.localizedDescription). Wechsle auf direkten Assistenten:*\n\n"
            }
            let codeSystemContext = """
            Du bist ein erfahrener iOS Swift-Entwickler für die App \"Digitales Büro\". \
            Beantworte Programmierfragen präzise auf Deutsch und liefere fertige, fehlerfreie Swift-Codeblöcke.
            """
            let stream = gemini.streamResponse(prompt: prompt, systemContext: codeSystemContext, history: Array(messages.dropLast()))
            do {
                for try await chunk in stream {
                    if let i = messages.firstIndex(where: { $0.id == msgId }) {
                        messages[i].content += chunk
                    }
                }
            } catch let directErr {
                if let i = messages.firstIndex(where: { $0.id == msgId }) {
                    messages[i].content += "\n\n⚠️ Auch direkter Gemini-Aufruf fehlgeschlagen: \(directErr.localizedDescription)"
                }
            }
        }

        if let i = messages.firstIndex(where: { $0.id == msgId }) {
            messages[i].isStreaming = false
        }
        gemini.isStreaming = false
        saveMessages()
    }

    // MARK: - Persistence
    private func saveMessages() {
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadMessages() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            messages = saved
        }
    }
}

// MARK: - MessageBubbleView

struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.isCodeChange {
                    codeChangeBubble
                } else if message.role == .user {
                    userBubble
                } else {
                    assistantBubble
                }

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    // User bubble: indigo gradient, right-aligned
    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let imgData = message.attachedImageData, let uiImg = UIImage(data: imgData) {
                Image(uiImage: uiImg)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if let fileName = message.attachedFileName {
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill")
                    Text(fileName)
                        .font(.caption.bold())
                }
                .padding(8)
                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }

            if !message.content.isEmpty {
                Text(message.content)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color(red: 0.43, green: 0.36, blue: 0.91), Color(red: 0.55, green: 0.22, blue: 0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .foregroundColor(.white)
    }

    // Assistant bubble: glass card, left-aligned
    private var assistantBubble: some View {
        Group {
            if message.isStreaming && message.content.isEmpty {
                streamingIndicator
            } else {
                Text(message.isStreaming ? message.content + " ▌" : message.content)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    // Code change bubble: green tinted
    private var codeChangeBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .foregroundColor(.green)
                Text("Code-Änderung")
                    .font(.caption.bold())
                    .foregroundColor(.green)
                Spacer()
                if message.isStreaming {
                    ProgressView().scaleEffect(0.7)
                }
            }
            if message.content.isEmpty {
                streamingIndicator
            } else {
                Text(message.content)
                    .textSelection(.enabled)
            }
            // Actions link button
            if let urlStr = message.actionsUrl, let url = URL(string: urlStr) {
                Link("→ GitHub Actions öffnen", destination: url)
                    .font(.caption.bold())
                    .foregroundColor(.green)
            }
        }
        .padding(14)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.green.opacity(0.25), lineWidth: 1)
        )
    }

    private var streamingIndicator: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(0.6)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - AIChatSheet

struct AIChatSheet: View {
    var initialPrompt: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AIChatView(initialPrompt: initialPrompt, isEmbeddedInTabBar: false)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Schließen") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    AIChatSheet()
        .preferredColorScheme(.dark)
}
#endif

