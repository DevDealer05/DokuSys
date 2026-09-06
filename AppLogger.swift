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

public enum LogLevel: String, CaseIterable, Codable, Identifiable {
    case debug   = "DEBUG"
    case info    = "INFO"
    case warning = "WARN"
    case error   = "ERROR"
    case success = "SUCCESS"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .debug:   return "Debug"
        case .info:    return "Info"
        case .warning: return "Warnung"
        case .error:   return "Fehler"
        case .success: return "Erfolg"
        }
    }

    public var icon: String {
        switch self {
        case .debug:   return "ant.fill"
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    public var color: Color {
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

public struct LogEntry: Identifiable, Codable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String
    public let details: String?

    public init(
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

    public var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }

    public var fullTextLine: String {
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

@MainActor
public final class AppLogger: ObservableObject {
    public static let shared = AppLogger()

    @Published public private(set) var entries: [LogEntry] = []
    @Published public var errorCount: Int = 0
    @Published public var warningCount: Int = 0

    private let maxEntries = 1500
    private let logFileURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.logFileURL = docs.appendingPathComponent("app_console.log")

        // Initial system startup log
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

    public func log(
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

        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        if level == .error {
            errorCount += 1
        } else if level == .warning {
            warningCount += 1
        }

        // Print to Xcode/system console as well
        print("[\(entry.formattedTimestamp)] [\(level.rawValue)] [\(category)] \(message)")
        if let d = details, !d.isEmpty {
            print("  ↳ \(d)")
        }
    }

    public func debug(_ category: String, _ message: String, details: String? = nil) {
        log(level: .debug, category: category, message: message, details: details)
    }

    public func info(_ category: String, _ message: String, details: String? = nil) {
        log(level: .info, category: category, message: message, details: details)
    }

    public func warn(_ category: String, _ message: String, details: String? = nil) {
        log(level: .warning, category: category, message: message, details: details)
    }

    public func error(_ category: String, _ message: String, details: String? = nil) {
        log(level: .error, category: category, message: message, details: details)
    }

    public func success(_ category: String, _ message: String, details: String? = nil) {
        log(level: .success, category: category, message: message, details: details)
    }

    // ── Actions ───────────────────────────────────────────────────────

    public func clear() {
        withAnimation {
            entries.removeAll()
            errorCount = 0
            warningCount = 0
        }
        self.info("Konsole", "Log-Puffer geleert.")
    }

    public func exportLogText() -> String {
        entries.map(\.fullTextLine).joined(separator: "\n")
    }

    public func createExportFile() -> URL? {
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

    public func generateSampleLogs() {
        self.info("System", "Test-Logs wurden angefordert.")
        self.debug("DMS", "Cache-Überprüfung für 12 Dokumente abgeschlossen.")
        self.success("Auth", "Sitzung erfolgreich validiert.")
        self.warn("FaceID", "Biometrie-Scan abgebrochen – Rückfall auf 4-stelligen App-PIN.")
        self.error("Network", "Server-Antwort Timeout (504 Gateway Timeout)", details: "Endpoint: /v1/documents - Request-ID: req_8721bf")
        self.success("Commercial", "DATEV Buchungsstapel mit 5 Belegen erfolgreich exportiert.")
    }
}

// =============================================================================
// MARK: - ConsoleLogView (In-App Terminal & Error Viewer)
// =============================================================================

public struct ConsoleLogView: View {
    @ObservedObject private var logger = AppLogger.shared
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var selectedLevel: LogLevel? = nil
    @State private var autoScroll: Bool = true
    @State private var shareURL: URL? = nil
    @State private var showShareSheet: Bool = false
    @State private var showCopiedToast: Bool = false
    @State private var selectedEntryForDetail: LogEntry? = nil

    public init() {}

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

    // ── Bottom Control Bar ────────────────────────────────────────────
    private var bottomControlBar: some View {
        HStack(spacing: 12) {
            // Copy button
            Button {
                UIPasteboard.general.string = logger.exportLogText()
                withAnimation { showCopiedToast = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { showCopiedToast = false }
                }
            } label: {
                Label(showCopiedToast ? "✓ Kopiert!" : "Kopieren", systemImage: showCopiedToast ? "checkmark" : "doc.on.doc")
                    .font(.caption.bold())
                    .foregroundStyle(showCopiedToast ? Color.green : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            // Share / Export button
            Button {
                if let url = logger.createExportFile() {
                    self.shareURL = url
                    self.showShareSheet = true
                }
            } label: {
                Label("Exportieren", systemImage: "square.and.arrow.up")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.primaryAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.primaryAccent.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }

            // Clear button
            Button(role: .destructive) {
                logger.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                    .padding(10)
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
