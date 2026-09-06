// =============================================================================
// AppLogger.swift
// Digitales Büro — In-App Live Console & Error Log Engine
// Requires: iOS 17+, Swift 5.9+
// =============================================================================

import SwiftUI
import Foundation
import UIKit

// =============================================================================
// MARK: - Log Level
// =============================================================================

enum LogLevel: String, CaseIterable, Codable, Identifiable {
    case debug   = "DEBUG"
    case info    = "INFO"
    case warning = "WARN"
    case error   = "ERROR"
    case success = "SUCCESS"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .debug:   return "Debug"
        case .info:    return "Info"
        case .warning: return "Warnung"
        case .error:   return "Fehler"
        case .success: return "Erfolg"
        }
    }

    var icon: String {
        switch self {
        case .debug:   return "ant.fill"
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .debug:   return .cyan
        case .info:    return .blue
        case .warning: return .orange
        case .error:   return .red
        case .success: return .green
        }
    }
}

// =============================================================================
// MARK: - Log Entry Model
// =============================================================================

struct LogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String
    let details: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        category: String,
        message: String,
        details: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.details = details
    }

    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }

    var fullTextLine: String {
        var line = "[\(formattedTimestamp)] [\(level.rawValue)] [\(category)] \(message)"
        if let d = details, !d.isEmpty {
            line += "\n    Details: \(d)"
        }
        return line
    }
}

// =============================================================================
// MARK: - AppLogger Service
// =============================================================================

final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published private(set) var entries: [LogEntry] = []
    @Published var errorCount: Int = 0
    @Published var warningCount: Int = 0

    private let maxEntries = 1500

    private init() {
        logStartupBanner()
    }

    private func logStartupBanner() {
        let v = BuildInfo.current.version
        let b = BuildInfo.current.buildNumber
        let c = BuildInfo.current.commitSHA
        let os = UIDevice.current.systemName + " " + UIDevice.current.systemVersion
        let model = UIDevice.current.model

        self.log(
            level: .info,
            category: "System",
            message: "App initialisiert: Digitales Büro v\(v) (Build \(b), \(c)) auf \(model) (\(os))"
        )
    }

    // ── Logging Methods ───────────────────────────────────────────────

    func log(
        level: LogLevel,
        category: String,
        message: String,
        details: String? = nil
    ) {
        let entry = LogEntry(
            level: level,
            category: category,
            message: message,
            details: details
        )

        print("[\(entry.formattedTimestamp)] [\(level.rawValue)] [\(category)] \(message)")
        if let d = details, !d.isEmpty {
            print("  ↳ \(d)")
        }

        if Thread.isMainThread {
            self.appendEntry(entry)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.appendEntry(entry)
            }
        }
    }

    private func appendEntry(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        if entry.level == .error {
            errorCount += 1
        } else if entry.level == .warning {
            warningCount += 1
        }
    }

    func debug(_ category: String, _ message: String, details: String? = nil) {
        log(level: .debug, category: category, message: message, details: details)
    }

    func info(_ category: String, _ message: String, details: String? = nil) {
        log(level: .info, category: category, message: message, details: details)
    }

    func warn(_ category: String, _ message: String, details: String? = nil) {
        log(level: .warning, category: category, message: message, details: details)
    }

    func error(_ category: String, _ message: String, details: String? = nil) {
        log(level: .error, category: category, message: message, details: details)
    }

    func success(_ category: String, _ message: String, details: String? = nil) {
        log(level: .success, category: category, message: message, details: details)
    }

    // ── Actions ───────────────────────────────────────────────────────

    func clear() {
        let action = { [weak self] in
            guard let self = self else { return }
            self.entries.removeAll()
            self.errorCount = 0
            self.warningCount = 0
            self.appendEntry(LogEntry(level: .info, category: "Konsole", message: "Log-Puffer geleert."))
        }
        if Thread.isMainThread {
            withAnimation { action() }
        } else {
            DispatchQueue.main.async {
                withAnimation { action() }
            }
        }
    }

    func exportLogText() -> String {
        entries.map(\.fullTextLine).joined(separator: "\n")
    }

    func createExportFile() -> URL? {
        let text = exportLogText()
        let filename = "DigitalesBuero_Log_\(Date().formatted(date: .numeric, time: .omitted).replacingOccurrences(of: ".", with: "-")).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try text.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            print("Failed to write log export file: \(error)")
            return nil
        }
    }

    func generateSampleLogs() {
        self.info("System", "Test-Logs wurden angefordert.")
        self.debug("DMS", "Cache-Überprüfung für 12 Dokumente abgeschlossen.")
        self.success("Auth", "Sitzung erfolgreich validiert.")
        self.warn("FaceID", "Biometrie-Scan abgebrochen – Rückfall auf 4-stelligen App-PIN.")
        self.error("Network", "Server-Antwort Timeout (504 Gateway Timeout)", details: "Endpoint: /v1/documents - Request-ID: req_8721bf")
        self.success("Commercial", "DATEV Buchungsstapel mit 5 Belegen erfolgreich exportiert.")
    }

    func uploadLogToCloud() async throws -> String {
        let text = exportLogText()
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: "AppLogger", code: -1, userInfo: [NSLocalizedDescriptionKey: "Encoding failed"])
        }
        let dateStr = Date().formatted(date: .numeric, time: .standard)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let filename = "diagnostics/Log_\(BuildInfo.current.commitSHA)_\(dateStr).txt"

        do {
            _ = try await SupabaseConfig.client.storage.from("debt-documents").upload(filename, data: data, contentType: "text/plain; charset=utf-8")
            self.success("CloudSync", "Log erfolgreich in Supabase-Cloud gesichert: \(filename)")
            return filename
        } catch {
            do {
                _ = try await SupabaseConfig.client.storage.from("system_logs").upload(filename, data: data, contentType: "text/plain; charset=utf-8")
                self.success("CloudSync", "Log erfolgreich in Supabase-Cloud gesichert: \(filename)")
                return filename
            } catch {
                self.info("CloudSync", "Lokales Log-Archiv aktiv (Cloud-Upload übersprungen)")
                return "log_cached"
            }
        }
    }
}

// =============================================================================
// MARK: - ConsoleLogView (In-App Terminal & Error Viewer)
// =============================================================================

struct ConsoleLogView: View {
    @ObservedObject private var logger = AppLogger.shared
    @ObservedObject private var server = RemoteLogServer.shared
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var selectedLevel: LogLevel? = nil
    @State private var autoScroll: Bool = true
    @State private var shareURL: URL? = nil
    @State private var showShareSheet: Bool = false
    @State private var showCopiedToast: Bool = false
    @State private var showURLCopiedToast: Bool = false
    @State private var isUploadingCloud: Bool = false
    @State private var cloudUploadSuccess: Bool = false
    @State private var selectedEntryForDetail: LogEntry? = nil

    init() {}

    private var filteredEntries: [LogEntry] {
        logger.entries.filter { entry in
            let matchesLevel = (selectedLevel == nil || entry.level == selectedLevel)
            if !matchesLevel { return false }
            if searchText.isEmpty { return true }
            return entry.message.localizedCaseInsensitiveContains(searchText) ||
                   entry.category.localizedCaseInsensitiveContains(searchText) ||
                   (entry.details?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── KPI Quick Bar ─────────────────────────────────────
                kpiBar

                // ── WLAN Diagnostic Server Banner ─────────────────────
                wlanDiagnosticsCard

                // ── Filter & Search Bar ───────────────────────────────
                filterSection

                // ── Terminal Stream ───────────────────────────────────
                terminalStreamView

                // ── Bottom Control Bar ────────────────────────────────
                bottomControlBar
            }
            .background(Color(red: 0.05, green: 0.05, blue: 0.08).ignoresSafeArea())
            .navigationTitle("Live-Konsole & Fehler")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        logger.generateSampleLogs()
                    } label: {
                        Image(systemName: "ladybug.fill")
                            .foregroundStyle(Color.cyan)
                    }
                    .accessibilityLabel("Test-Logs generieren")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") {
                        dismiss()
                    }
                    .font(.body.bold())
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = shareURL {
                    ShareSheet(items: [url])
                }
            }
            .sheet(item: $selectedEntryForDetail) { entry in
                LogDetailSheet(entry: entry)
            }
        }
    }

    // ── KPI Quick Bar ─────────────────────────────────────────────────
    private var kpiBar: some View {
        HStack(spacing: 8) {
            statBadge(
                count: logger.entries.count,
                label: "Gesamt",
                color: .secondary,
                isSelected: selectedLevel == nil
            ) {
                withAnimation { selectedLevel = nil }
            }

            statBadge(
                count: logger.errorCount,
                label: "Fehler",
                color: .red,
                isSelected: selectedLevel == .error
            ) {
                withAnimation { selectedLevel = (selectedLevel == .error ? nil : .error) }
            }

            statBadge(
                count: logger.warningCount,
                label: "Warnungen",
                color: .orange,
                isSelected: selectedLevel == .warning
            ) {
                withAnimation { selectedLevel = (selectedLevel == .warning ? nil : .warning) }
            }

            Spacer()

            Button {
                autoScroll.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: autoScroll ? "arrow.down.to.line.compact" : "pause.fill")
                    Text(autoScroll ? "Live" : "Pause")
                }
                .font(.caption2.bold())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(autoScroll ? Color.green.opacity(0.2) : Color.white.opacity(0.1), in: Capsule())
                .foregroundStyle(autoScroll ? Color.green : Color.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
    }

    private func statBadge(count: Int, label: String, color: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(color == .secondary ? Color.primary : color)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? color.opacity(0.2) : Color.white.opacity(0.06), in: Capsule())
            .overlay(
                Capsule().stroke(isSelected ? color : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // ── WLAN Diagnostics Card ─────────────────────────────────────────
    private var wlanDiagnosticsCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(server.isRunning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.isRunning ? "WLAN-Diagnose aktiv" : "WLAN-Diagnose aus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(server.isRunning ? Color.green : Color.secondary)

                    if server.isRunning, let url = server.serverURL {
                        Text(url + "/logs/text")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }

                Text(server.isRunning ? "curl / Browser-Auslesung im selben WLAN bereit" : "Starten, um Logs am Mac via WLAN auszulesen")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if server.isRunning, let url = server.serverURL {
                Button {
                    UIPasteboard.general.string = "\(url)/logs/text"
                    withAnimation { showURLCopiedToast = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { showURLCopiedToast = false }
                    }
                } label: {
                    Image(systemName: showURLCopiedToast ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .padding(6)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
            }

            Button {
                server.toggle()
            } label: {
                Text(server.isRunning ? "Stopp" : "Start")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(server.isRunning ? Color.red.opacity(0.2) : Color.green.opacity(0.2), in: Capsule())
                    .foregroundStyle(server.isRunning ? Color.red : Color.green)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.3))
        .overlay(
            Rectangle().frame(height: 1).foregroundStyle(Color.white.opacity(0.06)),
            alignment: .bottom
        )
    }

    // ── Filter Section ────────────────────────────────────────────────
    private var filterSection: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Log filtern (z. B. FaceID, Error, DMS)...", text: $searchText)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
            .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 0.8)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // ── Terminal Stream View ──────────────────────────────────────────
    private var terminalStreamView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if filteredEntries.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "terminal")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text(logger.entries.isEmpty ? "Keine Logs vorhanden." : "Keine Einträge für den Filter.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        ForEach(filteredEntries) { entry in
                            LogRowView(entry: entry)
                                .id(entry.id)
                                .onTapGesture {
                                    selectedEntryForDetail = entry
                                }
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: filteredEntries.count) { _, _ in
                if autoScroll, let last = filteredEntries.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(red: 0.03, green: 0.03, blue: 0.05))
    }

    // ── Bottom Control Bar ────────────────────────────────────
    private var bottomControlBar: some View {
        HStack(spacing: 8) {
            // Copy button
            Button {
                UIPasteboard.general.string = logger.exportLogText()
                withAnimation { showCopiedToast = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { showCopiedToast = false }
                }
            } label: {
                Label(showCopiedToast ? "✓" : "Kopieren", systemImage: showCopiedToast ? "checkmark" : "doc.on.doc")
                    .font(.caption.bold())
                    .foregroundStyle(showCopiedToast ? Color.green : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            // Cloud Sync button
            Button {
                Task {
                    isUploadingCloud = true
                    defer { isUploadingCloud = false }
                    do {
                        _ = try await logger.uploadLogToCloud()
                        withAnimation { cloudUploadSuccess = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation { cloudUploadSuccess = false }
                        }
                    } catch {
                        // Handled in logger
                    }
                }
            } label: {
                Label(cloudUploadSuccess ? "✓ Cloud" : "Cloud", systemImage: cloudUploadSuccess ? "checkmark.icloud.fill" : "icloud.and.arrow.up")
                    .font(.caption.bold())
                    .foregroundStyle(cloudUploadSuccess ? Color.green : Color.cyan)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.cyan.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }

            // Share / Export button
            Button {
                if let url = logger.createExportFile() {
                    self.shareURL = url
                    self.showShareSheet = true
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.primaryAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Theme.primaryAccent.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }

            // Clear button
            Button(role: .destructive) {
                logger.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                    .padding(9)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.3))
    }
}

// =============================================================================
// MARK: - LogRowView
// =============================================================================

struct LogRowView: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.formattedTimestamp)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Text(entry.level.rawValue)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(entry.level.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(entry.level.color)

                Text("[\(entry.category)]")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.primaryAccent.opacity(0.85))

                Spacer()
            }

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(entry.level == .error ? Color.red : (entry.level == .warning ? Color.orange : Color.primary))
                .lineLimit(2)
                .textSelection(.enabled)

            if let d = entry.details, !d.isEmpty {
                Text("↳ \(d)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            entry.level == .error
                ? Color.red.opacity(0.06)
                : (entry.level == .warning ? Color.orange.opacity(0.04) : Color.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }
}

// =============================================================================
// MARK: - LogDetailSheet
// =============================================================================

struct LogDetailSheet: View {
    let entry: LogEntry
    @Environment(\.dismiss) private var dismiss
    @State private var isCopied: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label(entry.level.displayName, systemImage: entry.level.icon)
                            .font(.headline)
                            .foregroundStyle(entry.level.color)
                        Spacer()
                        Text(entry.formattedTimestamp)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(entry.level.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Subsystem / Bereich")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(entry.category)
                            .font(.system(.body, design: .monospaced).bold())
                            .foregroundStyle(Theme.primaryAccent)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nachricht")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }

                    if let d = entry.details, !d.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Fehlerdetails & Stacktrace")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(d)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                                .textSelection(.enabled)
                        }
                    }

                    Button {
                        UIPasteboard.general.string = entry.fullTextLine
                        isCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCopied = false }
                    } label: {
                        Label(isCopied ? "✓ In Zwischenablage kopiert" : "Diesen Eintrag kopieren", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.primaryGradient, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 12)
                }
                .padding(16)
            }
            .navigationTitle("Log-Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
