// AIChatModule.swift
// Digitales Büro — KI-Chat (Gemini 2.0 Flash, In-App)

import SwiftUI

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

// MARK: - AIChatView

struct AIChatView: View {
    @StateObject private var gemini = GeminiService()
    @AppStorage("dev_mode_enabled") private var devModeEnabled: Bool = false
    @AppStorage("ai_agent_url") private var agentURL: String = "https://ucmkbhmtdpbxsbahzahj.supabase.co/functions/v1/ai-agent"

    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var selectedMode: Int = 0
    @State private var showClearConfirm: Bool = false

    private let storageKey = "chat_history_v1"

    var body: some View {
        NavigationStack {
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
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Kein Gemini API Key – bitte in Admin-Einstellungen eingeben.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange.opacity(0.12))
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
                    .onChange(of: messages.count) { _ in
                        if let last = messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                Divider()

                // Input bar
                HStack(alignment: .bottom, spacing: 12) {
                    TextField(
                        selectedMode == ChatMode.codeEditor.rawValue
                            ? "Code-Änderung beschreiben..."
                            : "Nachricht eingeben...",
                        text: $inputText,
                        axis: .vertical
                    )
                    .lineLimit(1...5)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

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
                    .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty && !gemini.isStreaming)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .navigationTitle("KI-Assistent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .confirmationDialog("Verlauf löschen?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    messages = []
                    saveMessages()
                }
            }
            .onAppear { loadMessages() }
        }
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
                 ? "Frage mich alles über die App oder nutze den Code-Modus um Änderungen direkt einzuspielen."
                 : "Frage mich alles über deine Schulden, Dokumente und den Haushalt.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .font(.subheadline)
        }
        .padding(40)
    }

    // MARK: - Send message
    private func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        inputText = ""
        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)
        saveMessages()

        if selectedMode == ChatMode.codeEditor.rawValue {
            await sendCodeChangeMessage(prompt: text)
        } else {
            await sendAssistantMessage(prompt: text)
        }
    }

    // MARK: - Assistant streaming
    private func sendAssistantMessage(prompt: String) async {
        var assistantMsg = ChatMessage(role: .assistant, isCodeChange: false)
        assistantMsg.isStreaming = true
        messages.append(assistantMsg)
        let idx = messages.count - 1

        gemini.isStreaming = true
        let context = """
        Du bist ein freundlicher, kompetenter Assistent für die App "Digitales Büro" – \
        eine iOS-App für Schulden- und Haushaltsmanagement (SwiftUI, iOS 17+). \
        Antworte immer auf Deutsch. Sei präzise und hilfreich. \
        Du kennst alle Funktionen der App: Schulden-Tracker, Dokumentenscanner, \
        Putzplan, Hardware-Logbuch, Exportmodul und Abonnement-Verwaltung.
        """

        let stream = gemini.streamResponse(prompt: prompt, systemContext: context, history: Array(messages.dropLast()))
        do {
            for try await chunk in stream {
                messages[idx].content += chunk
            }
        } catch {
            messages[idx].content = "⚠️ \(error.localizedDescription)"
        }

        messages[idx].isStreaming = false
        gemini.isStreaming = false
        saveMessages()
    }

    // MARK: - Code change via agent
    private func sendCodeChangeMessage(prompt: String) async {
        var agentMsg = ChatMessage(role: .assistant, content: "⏳ KI-Agent analysiert Repository...", isCodeChange: true)
        agentMsg.isStreaming = true
        messages.append(agentMsg)
        let idx = messages.count - 1

        gemini.isStreaming = true
        do {
            let result = try await gemini.sendCodeChangeRequest(prompt: prompt, agentURL: agentURL)
            var response = result.text
            if let sha = result.commitSHA {
                response += "\n\n✅ **Code committed!**\nSHA: `\(sha.prefix(8))`\n🔄 GitHub Actions baut neues IPA..."
                messages[idx].commitSHA = sha
            }
            if let url = result.actionsUrl {
                response += "\n[→ Actions öffnen](\(url))"
                messages[idx].actionsUrl = url
            }
            messages[idx].content = response
        } catch {
            messages[idx].content = "⚠️ Agent-Fehler: \(error.localizedDescription)"
        }

        messages[idx].isStreaming = false
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
        Text(message.content)
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
            .textSelection(.enabled)
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

// MARK: - Preview

#if DEBUG
#Preview {
    AIChatView()
        .preferredColorScheme(.dark)
}
#endif
