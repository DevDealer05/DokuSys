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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hammer.fill")
            Text("ENTWICKLER-MODUS")
                .font(.caption.bold())
                .kerning(1)
            Spacer()
            Button {
                withAnimation { store.isDevMode = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.92))
        .foregroundColor(.white)
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

#Preview {
    let store = DevModeStore()
    store.isDevMode = true
    return NavigationStack {
        DevModePanel()
    }
    .environmentObject(store)
    .preferredColorScheme(.dark)
}
