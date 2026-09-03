// =============================================================================
// StorageService.swift
// Digitales Büro – Lokale atomare Daten-Persistenz nach Blueprint §6
// Requires: iOS 17+, Swift 5.9+
//
// ── Zweck ─────────────────────────────────────────────────────────────────────
// Speichert alle erfassten Akten, Timelines, Vorräte, Putzpläne und Einstellungen
// als typensichere JSON-Dateien atomar im Documents-Verzeichnis des Benutzers.
// Garantiert 100% Offline-Funktionalität und sofortige Verfügbarkeit beim App-Start.
// =============================================================================

import Foundation

final class StorageService: @unchecked Sendable {
    static let shared = StorageService()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    // ── Documents Directory ────────────────────────────────────────────────

    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func fileURL(for filename: String) -> URL {
        documentsDirectory.appendingPathComponent(filename)
    }

    // ── Generic Save & Load (Atomic) ───────────────────────────────────────

    func save<T: Encodable>(_ object: T, to filename: String) {
        let url = fileURL(for: filename)
        do {
            let data = try encoder.encode(object)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            print("❌ StorageService.save Fehler bei \(filename): \(error.localizedDescription)")
        }
    }

    func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let url = fileURL(for: filename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(T.self, from: data)
        } catch {
            print("❌ StorageService.load Fehler bei \(filename): \(error.localizedDescription)")
            return nil
        }
    }

    func delete(filename: String) {
        let url = fileURL(for: filename)
        try? fileManager.removeItem(at: url)
    }

    // ── Specialized Helpers for Blueprint Models ───────────────────────────

    func saveDebts(_ debts: [Debt], userId: UUID) {
        save(debts, to: "debts_\(userId.uuidString).json")
    }

    func loadDebts(userId: UUID) -> [Debt]? {
        load([Debt].self, from: "debts_\(userId.uuidString).json")
    }

    func saveTimelines(_ timelines: [UUID: [DebtTimeline]], userId: UUID) {
        // Encode dictionary as key-value pairs
        let serializable = timelines.map { KeyValueTimeline(debtId: $0.key, entries: $0.value) }
        save(serializable, to: "timelines_\(userId.uuidString).json")
    }

    func loadTimelines(userId: UUID) -> [UUID: [DebtTimeline]]? {
        guard let list = load([KeyValueTimeline].self, from: "timelines_\(userId.uuidString).json") else {
            return nil
        }
        var result = [UUID: [DebtTimeline]]()
        for item in list {
            result[item.debtId] = item.entries
        }
        return result
    }
}

private struct KeyValueTimeline: Codable {
    let debtId: UUID
    let entries: [DebtTimeline]
}
