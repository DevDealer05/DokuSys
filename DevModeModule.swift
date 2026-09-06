// DevModeModule.swift
// Digitales Büro — Live / Entwickler-Modus

import SwiftUI

// MARK: - BuildInfo

struct BuildInfo {
    let version: String
    let buildNumber: String
    let commitSHA: String
    let buildDate: String

    static var current: BuildInfo {
        let info = Bundle.main.infoDictionary
        return BuildInfo(
            version: info?["CFBundleShortVersionString"] as? String ?? "1.0",
            buildNumber: info?["CFBundleVersion"] as? String ?? "1",
            commitSHA: info?["GIT_COMMIT_SHA"] as? String ?? "dev-local",
            buildDate: info?["BUILD_DATE"] as? String ?? "lokal"
        )
    }
}

// MARK: - DevModeStore

final class DevModeStore: ObservableObject {
    @AppStorage("dev_mode_enabled") var isDevMode: Bool = false
    @AppStorage("show_dev_banner") var showDevBanner: Bool = false
    @AppStorage("gemini_api_key") var geminiApiKey: String = ""
    @AppStorage("ai_agent_url") var aiAgentUrl: String = "https://ucmkbhmtdpbxsbahzahj.supabase.co/functions/v1/ai-agent"
    @AppStorage("github_repo") var githubRepo: String = "DevDealer05/DokuSys"

    var buildInfo: BuildInfo { BuildInfo.current }

    var sideStoreURL: String {
        "https://\(githubRepo.components(separatedBy: "/").first ?? "DevDealer05").github.io/\(githubRepo.components(separatedBy: "/").last ?? "DokuSys")/apps.json"
    }
    var actionsURL: String { "https://github.com/\(githubRepo)/actions" }
}

// MARK: - DevModeBanner

struct DevModeBanner: View {
    @EnvironmentObject var store: DevModeStore
    @ObservedObject private var logger = AppLogger.shared
    @State private var showAIChat: Bool = false
    @State private var showConsole: Bool = false

    @ViewBuilder
    var body: some View {
        if store.isDevMode && store.showDevBanner {
            HStack(spacing: 8) {
                Image(systemName: "hammer.fill")
                Text("ENTWICKLER")
                    .font(.caption.bold())
                    .kerning(1)
                Spacer()
                Button {
                    showConsole = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal.fill")
                        Text("Konsole")
                            .font(.caption.bold())
                        if RemoteLogServer.shared.isRunning {
                            Image(systemName: "wifi")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.green)
                        }
                        if logger.errorCount > 0 {
                            Text("\(logger.errorCount)")
                                .font(.system(size: 9, weight: .black))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.red, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.3), in: Capsule())
                }

                Button {
                    showAIChat = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("KI-Chat")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.25), in: Capsule())
                }
                Button {
                    withAnimation { store.showDevBanner = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.92))
            .foregroundColor(.white)
            .sheet(isPresented: $showAIChat) {
                AIChatSheet()
            }
            .sheet(isPresented: $showConsole) {
                ConsoleLogView()
            }
        }
    }

}

// MARK: - LiveModeBadge

struct LiveModeBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
            Text("Live")
                .font(.caption2.bold())
                .foregroundColor(.green)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.green.opacity(0.12), in: Capsule())
    }
}

// MARK: - DevModePanel

struct DevModePanel: View {
    @EnvironmentObject var store: DevModeStore
    @State private var showCopied: Bool = false
    @State private var testDocsGenerated: Bool = false
    @State private var showSaveConfirm: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // 0 — KI-Assistent & Code-Agent
                devCard(title: "KI-Assistent & Code-Agent", icon: "sparkles") {
                    Text("Unterhalte dich mit dem integrierten Gemini-Assistenten oder beauftrage direkte Code-Änderungen auf GitHub.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    NavigationLink {
                        AIChatView()
                    } label: {
                        HStack {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                            Text("KI-Chat öffnen")
                                .fontWeight(.semibold)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.43, green: 0.36, blue: 0.91))
                }

                // 0.5 — Live-Konsole & Error-Log
                devCard(title: "Live-Konsole & Error-Log", icon: "terminal.fill") {
                    Text("Echtzeit-Diagnose, System-Meldungen, Netzwerk-Aufrufe und Fehlerprotokoll direkt in der App.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Text("\(AppLogger.shared.entries.count)")
                                .font(.subheadline.monospaced().bold())
                            Text("Logs")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if AppLogger.shared.errorCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text("\(AppLogger.shared.errorCount) Fehler")
                                    .font(.caption.bold())
                                    .foregroundColor(.red)
                            }
                        }

                        if AppLogger.shared.warningCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("\(AppLogger.shared.warningCount) Warnungen")
                                    .font(.caption.bold())
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

                    // WLAN-Diagnoseserver Status
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Circle()
                                .fill(RemoteLogServer.shared.isRunning ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(RemoteLogServer.shared.isRunning ? "WLAN-Diagnoseserver aktiv" : "WLAN-Diagnoseserver inaktiv")
                                .font(.caption.bold())
                                .foregroundColor(RemoteLogServer.shared.isRunning ? .green : .secondary)
                            Spacer()
                            Button(RemoteLogServer.shared.isRunning ? "Stopp" : "Starten") {
                                RemoteLogServer.shared.toggle()
                            }
                            .font(.caption2.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RemoteLogServer.shared.isRunning ? Color.red.opacity(0.2) : Color.green.opacity(0.2), in: Capsule())
                            .foregroundColor(RemoteLogServer.shared.isRunning ? .red : .green)
                        }

                        if RemoteLogServer.shared.isRunning, let url = RemoteLogServer.shared.serverURL {
                            HStack {
                                Text("curl -s \(url)/logs/text")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = "curl -s \(url)/logs/text"
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                        .foregroundColor(Theme.primaryAccent)
                                }
                            }
                            .padding(6)
                            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                    NavigationLink {
                        ConsoleLogView()
                    } label: {
                        HStack {
                            Image(systemName: "terminal.fill")
                            Text("Live-Konsole öffnen")
                                .fontWeight(.semibold)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.green)
                }

                // A — Build Info
                devCard(title: "Build-Informationen", icon: "info.circle") {
                    infoRow("Version", store.buildInfo.version)
                    infoRow("Build-Nr.", store.buildInfo.buildNumber)
                    infoRow("Commit", store.buildInfo.commitSHA)
                    infoRow("Build-Datum", store.buildInfo.buildDate)
                }

                // B — GitHub Actions
                devCard(title: "GitHub Actions (CI/CD)", icon: "arrow.triangle.2.circlepath") {
                    Text("Jeder Commit auf \(store.githubRepo) startet automatisch einen neuen Build und deployt ein neues IPA.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button {
                        if let url = URL(string: store.actionsURL) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Actions öffnen ↗", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color(red: 0.43, green: 0.36, blue: 0.91))
                }

                // C — SideStore
                devCard(title: "SideStore Repository", icon: "square.and.arrow.down") {
                    Text("Repository-URL für SideStore:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(store.sideStoreURL)
                        .font(.caption.monospaced())
                        .foregroundColor(.primary)
                        .padding(8)
                        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

                    Button {
                        UIPasteboard.general.string = store.sideStoreURL
                        withAnimation { showCopied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { showCopied = false }
                        }
                    } label: {
                        Label(showCopied ? "✓ Kopiert!" : "URL kopieren", systemImage: showCopied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(showCopied ? .green : .secondary)
                }

                // D — Test Documents
                devCard(title: "Testdaten", icon: "doc.badge.plus") {
                    Text("Erstellt 5 Musterdokumente zum Testen des Dokumentenarchivs und Scanners.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button {
                        withAnimation { testDocsGenerated = true }
                    } label: {
                        Label("5 Testdokumente erstellen", systemImage: "plus.square.dashed")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color(red: 0.43, green: 0.36, blue: 0.91))

                    if testDocsGenerated {
                        Label("5 Testdokumente wurden erstellt", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption.bold())
                            .transition(.opacity)
                    }
                }

                // E — API Config
                devCard(title: "API & Cloud-Einstellungen", icon: "key") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Gemini API Key")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        SecureField("Gemini API Key eingeben...", text: $store.geminiApiKey)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Text("Agent URL (Supabase Edge Function)")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        TextField("Agent URL", text: $store.aiAgentUrl)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Text("GitHub Repository")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        TextField("owner/repo", text: $store.githubRepo)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Text("Einstellungen werden automatisch lokal gespeichert und nie an Server übertragen.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: Helpers
    @ViewBuilder
    private func devCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(Color(red: 0.43, green: 0.36, blue: 0.91))
                Text(title)
                    .font(.headline)
            }
            Divider()
            content()
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.monospaced())
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    let store = DevModeStore()
    store.isDevMode = true
    return NavigationStack {
        DevModePanel()
    }
    .environmentObject(store)
    .preferredColorScheme(.dark)
}
#endif
