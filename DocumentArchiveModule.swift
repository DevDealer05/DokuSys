// =============================================================================
// DocumentArchiveModule.swift
// Digitales Büro – Dokumenten-Managementsystem (DMS) mit KI-Texterkennung & Auto-Extraktion
// Requires: iOS 17+, Swift 5.9+, PDFKit, Vision, UniformTypeIdentifiers
//
// ── Enthält ───────────────────────────────────────────────────────────────────
//  AppDocument                 Modell für archivierte Dokumente, Verträge, Briefe & PDFs
//  DocumentCategory            Kategorien (Verträge, Behörden, Schulden, Finanzen, etc.)
//  DocumentStatus              Status (Eingegangen, In Bearbeitung, Frist gesetzt, Erledigt)
//  ExtractedDocumentData       Automatisch per OCR & Vision extrahierte Hauptdaten
//  DocumentAutoExtractionEngine Engine zur automatischen Auslesung von Absender, Betrag,
//                              Aktenzeichen, Fristen, Kategorie & Titel
//  DocumentArchiveService      @MainActor Service für Volltextsuche, Filter, Upload & Caching
//  DocumentArchiveView         Hauptansicht DMS mit Ordnern, Fristen-Radar & Suchleiste
//  DocumentDetailView          Detailansicht mit Dokumentenvorschau, OCR-Inspektor & Fristen
//  AddDocumentSheet            Auto-Auslesung via Kamera-Scan, PDF-Dateiauswahl & Mediathek
//  DocumentFilePicker          UIDocumentPickerViewController-Wrapper für PDF-Dateien
//  DocumentImagePicker         UIImagePickerController-Wrapper für Kamera & Fotos
// =============================================================================

import SwiftUI
import PDFKit
import Vision
import UniformTypeIdentifiers

// =============================================================================
// MARK: - 1. Data Models
// =============================================================================

public enum DocumentFileType: String, Codable, CaseIterable, Sendable {
    case pdf   = "pdf"
    case image = "image"

    public var icon: String {
        switch self {
        case .pdf:   return "doc.richtext.fill"
        case .image: return "photo.fill"
        }
    }
}

public enum DocumentCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case contracts   = "Verträge & Abos"
    case authorities = "Behörden & Amt"
    case debts       = "Forderungen & Inkasso"
    case insurance   = "Versicherungen"
    case invoices    = "Rechnungen & Belege"
    case taxes       = "Finanzen & Steuern"
    case health      = "Gesundheit"
    case other       = "Sonstiges"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .contracts:   return "signature"
        case .authorities: return "building.columns.fill"
        case .debts:       return "exclamationmark.triangle.fill"
        case .insurance:   return "shield.lefthalf.filled"
        case .invoices:    return "receipt.fill"
        case .taxes:       return "eurosign.circle.fill"
        case .health:      return "cross.case.fill"
        case .other:       return "folder.fill"
        }
    }

    public var color: Color {
        switch self {
        case .contracts:   return .indigo
        case .authorities: return .blue
        case .debts:       return .orange
        case .insurance:   return .teal
        case .invoices:    return .green
        case .taxes:       return .purple
        case .health:      return .pink
        case .other:       return .gray
        }
    }
}

public enum DocumentStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case inbox        = "Eingegangen"
    case inProgress   = "In Bearbeitung"
    case deadlineSet  = "Frist gesetzt"
    case completed    = "Erledigt"
    case archived     = "Archiviert"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .inbox:       return "tray.and.arrow.down.fill"
        case .inProgress:  return "clock.arrow.2.circlepath"
        case .deadlineSet: return "calendar.badge.clock"
        case .completed:   return "checkmark.circle.fill"
        case .archived:    return "archivebox.fill"
        }
    }

    public var color: Color {
        switch self {
        case .inbox:       return .blue
        case .inProgress:  return .orange
        case .deadlineSet: return .red
        case .completed:   return .green
        case .archived:    return .secondary
        }
    }
}

public struct AppDocument: Identifiable, Codable, Sendable {
    public let id:           UUID
    public let userId:       UUID
    public var title:        String
    public var category:     DocumentCategory
    public var documentDate: Date
    public var dueDate:      Date?
    public var sender:       String?
    public var fileNumber:   String?
    public var amount:       Decimal?
    public var storagePath:  String?
    public var fileType:     DocumentFileType
    public var ocrText:      String?
    public var tags:         [String]
    public var status:       DocumentStatus
    public var notes:        String?
    public let createdAt:    Date
    public var updatedAt:    Date

    public init(
        id:           UUID = UUID(),
        userId:       UUID,
        title:        String,
        category:     DocumentCategory,
        documentDate: Date = Date(),
        dueDate:      Date? = nil,
        sender:       String? = nil,
        fileNumber:   String? = nil,
        amount:       Decimal? = nil,
        storagePath:  String? = nil,
        fileType:     DocumentFileType = .image,
        ocrText:      String? = nil,
        tags:         [String] = [],
        status:       DocumentStatus = .inbox,
        notes:        String? = nil,
        createdAt:    Date = Date(),
        updatedAt:    Date = Date()
    ) {
        self.id           = id
        self.userId       = userId
        self.title        = title
        self.category     = category
        self.documentDate = documentDate
        self.dueDate      = dueDate
        self.sender       = sender
        self.fileNumber   = fileNumber
        self.amount       = amount
        self.storagePath  = storagePath
        self.fileType     = fileType
        self.ocrText      = ocrText
        self.tags         = tags
        self.status       = status
        self.notes        = notes
        self.createdAt    = createdAt
        self.updatedAt    = updatedAt
    }

    public var isDeadlineUrgent: Bool {
        guard let due = dueDate, status != .completed && status != .archived else { return false }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: due).day ?? 0
        return days <= 7 && days >= 0
    }

    public var isOverdue: Bool {
        guard let due = dueDate, status != .completed && status != .archived else { return false }
        return due < Date()
    }
}

// =============================================================================
// MARK: - 2. Automatic Extraction Engine (Vision + NLP + Regex)
// =============================================================================

public struct ExtractedDocumentData: Sendable {
    public var title:        String
    public var category:     DocumentCategory
    public var sender:       String?
    public var fileNumber:   String?
    public var amount:       Decimal?
    public var documentDate: Date
    public var dueDate:      Date?
    public var tags:         [String]
    public var ocrText:      String
    public var confidence:   Double
}

public enum DocumentAutoExtractionEngine {

    /// Extrahiert automatisch alle Hauptdaten aus einem Bild
    public static func analyze(image: UIImage) async -> ExtractedDocumentData {
        guard let cgImage = image.cgImage else {
            return fallbackData(ocr: "")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        let observations = request.results ?? []
        let rawText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")

        return parseDocumentText(rawText)
    }

    /// Extrahiert automatisch alle Hauptdaten aus einer PDF-Datei
    public static func analyze(pdfData: Data) async -> ExtractedDocumentData {
        guard let pdf = PDFDocument(data: pdfData) else {
            return fallbackData(ocr: "")
        }

        var fullText = ""
        for i in 0..<pdf.pageCount {
            if let page = pdf.page(at: i), let pageText = page.string, !pageText.isEmpty {
                fullText += pageText + "\n"
            }
        }

        // Falls die PDF gescannt ist und keinen Textlayer hat, rendern wir Seite 1
        if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let firstPage = pdf.page(at: 0) {
            let pageRect = firstPage.bounds(for: .mediaBox)
            let renderer = UIGraphicsImageRenderer(size: pageRect.size)
            let image = renderer.image { ctx in
                UIColor.white.set()
                ctx.fill(pageRect)
                ctx.cgContext.translateBy(x: 0.0, y: pageRect.size.height)
                ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                firstPage.draw(with: .mediaBox, to: ctx.cgContext)
            }
            return await analyze(image: image)
        }

        return parseDocumentText(fullText)
    }

    // ── Text Parsing & NLP Heuristics ──────────────────────────────────────

    private static func parseDocumentText(_ text: String) -> ExtractedDocumentData {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        // 1. Sender Detection
        let sender = extractSender(from: text, lines: lines)

        // 2. File Number / Aktenzeichen / Rechnungs-Nr.
        let fileNumber = extractFileNumber(from: text)

        // 3. Amount
        let amount = extractAmount(from: text)

        // 4. Document Date & Due Date (Frist)
        let (docDate, dueDate) = extractDates(from: text)

        // 5. Category & Title
        let (category, title) = classifyAndTitle(from: text, sender: sender, fileNumber: fileNumber, amount: amount)

        // 6. Tags
        var tags = [String]()
        if let s = sender { tags.append(s.prefix(15).trimmingCharacters(in: .whitespaces)) }
        tags.append(category.rawValue.components(separatedBy: " ").first ?? "Dokument")
        if dueDate != nil { tags.append("Frist") }
        if amount != nil { tags.append("Zahlung") }

        return ExtractedDocumentData(
            title:        title,
            category:     category,
            sender:       sender,
            fileNumber:   fileNumber,
            amount:       amount,
            documentDate: docDate ?? Date(),
            dueDate:      dueDate,
            tags:         tags,
            ocrText:      text,
            confidence:   0.92
        )
    }

    // ── Extractor Helpers ──────────────────────────────────────────────────

    private static func extractSender(from text: String, lines: [String]) -> String? {
        let knownIssuers = [
            "Vodafone", "Deutsche Telekom", "Telekom", "O2", "1&1", "Telefónica",
            "Stadtwerke", "Vattenfall", "E.ON", "EnBW", "Stromnetz",
            "Allianz", "HUK-Coburg", "ERGO", "AXA", "Generali", "AOK", "Barmer", "Techniker Krankenkasse", "TK", "DAK",
            "Finanzamt", "Jobcenter", "Bundesagentur für Arbeit", "ARD ZDF Deutschlandradio Beitragsservice", "Beitragsservice",
            "EOS Deutscher Inkasso-Dienst", "EOS", "Creditreform", "Universum Inkasso", "Intrum", "Paigo", "Riverty", "KSP Rechtsanwälte", "Infoscore", "Lowell",
            "Amazon", "Klarna", "PayPal", "Apple", "Otto", "Zalando"
        ]

        for issuer in knownIssuers {
            if text.localizedCaseInsensitiveContains(issuer) {
                return issuer
            }
        }

        // Check top 5 lines for typical sender formats
        for line in lines.prefix(6) {
            if line.count > 3 && line.count < 40 && !line.localizedCaseInsensitiveContains("Rechnung") && !line.localizedCaseInsensitiveContains("Datum") && !line.contains("@") {
                if line.contains("GmbH") || line.contains("AG") || line.contains("e.V.") || line.contains("SE") || line.contains("KG") {
                    return line
                }
            }
        }
        return lines.first { $0.count > 3 && $0.count < 35 }
    }

    private static func extractFileNumber(from text: String) -> String? {
        let patterns = [
            #"(?i)(?:Aktenzeichen|Az\.?|Akten-Nr\.?|Vorgangs-Nr\.?|Vorgangsnummer)[:\s]+([\w\/\-\.]{4,25})"#,
            #"(?i)(?:Rechnungs-?Nr\.?|Rechnungsnummer|Invoice-?No\.?)[:\s]+([\w\/\-\.]{4,25})"#,
            #"(?i)(?:Kunden-?Nr\.?|Kundennummer|Vertrags-?Nr\.?|Vertragsnummer)[:\s]+([\w\/\-\.]{4,25})"#,
            #"(?i)(?:Beitragsnummer|Kassenzeichen)[:\s]+([\w\/\-\.]{4,25})"#,
            #"(?<!\w)\d{1,3}\s+[A-Z]{1,4}\s+\d{1,6}\/\d{2,4}(?!\w)"#, // Gerichts-AZ
            #"(?i)AZ[-:\s]+[\w\/\-]{4,20}"#
        ]

        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                if match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) {
                    return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let r = Range(match.range, in: text) {
                    return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private static func extractAmount(from text: String) -> Decimal? {
        let pattern = #"(?i)(?:Gesamtbetrag|Endbetrag|Forderung|Zu zahlen|Betrag|Summe|Total)?[:\s]*(\d{1,3}(?:\.\d{3})*,\d{2})\s*(?:€|EUR)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var foundAmounts = [Decimal]()

        for match in matches {
            if match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) {
                let str = String(text[r]).replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                if let d = Decimal(string: str), d > 0 {
                    foundAmounts.append(d)
                }
            }
        }
        // Nimm den wahrscheinlichsten Hauptbetrag (oft der höchste gefundene Betrag)
        return foundAmounts.max()
    }

    private static func extractDates(from text: String) -> (documentDate: Date?, dueDate: Date?) {
        var docDate: Date? = nil
        var dueDate: Date? = nil

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd.MM.yyyy"
        dateFormatter.locale = Locale(identifier: "de_DE")

        // 1. Frist / Fälligkeits-Datum
        let duePatterns = [
            #"(?i)(?:Zahlbar bis|Frist bis|Zahlungsziel|Fällig am|bis zum)[:\s]+(\d{2}\.\d{2}\.\d{4})"#,
            #"(?i)(?:innerhalb von)\s+14\s+Tagen"#,
            #"(?i)(?:innerhalb von)\s+7\s+Tagen"#,
            #"(?i)(?:innerhalb)\s+eines\s+Monats"#
        ]

        for pat in duePatterns {
            if let regex = try? NSRegularExpression(pattern: pat),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                if match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) {
                    dueDate = dateFormatter.date(from: String(text[r]))
                    break
                } else {
                    // Relatives Zahlungsziel
                    if text.localizedCaseInsensitiveContains("14 Tagen") {
                        dueDate = Calendar.current.date(byAdding: .day, value: 14, to: Date())
                    } else if text.localizedCaseInsensitiveContains("7 Tagen") {
                        dueDate = Calendar.current.date(byAdding: .day, value: 7, to: Date())
                    } else if text.localizedCaseInsensitiveContains("Monat") {
                        dueDate = Calendar.current.date(byAdding: .month, value: 1, to: Date())
                    }
                    break
                }
            }
        }

        // 2. Belegdatum (Standard deutsches Datumsformat)
        let datePattern = #"\b(\d{2}\.\d{2}\.\d{4})\b"#
        if let regex = try? NSRegularExpression(pattern: datePattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let r = Range(match.range(at: 1), in: text) {
                    if let parsed = dateFormatter.date(from: String(text[r])) {
                        if parsed <= Date() {
                            docDate = parsed
                            break
                        }
                    }
                }
            }
        }

        return (docDate, dueDate)
    }

    private static func classifyAndTitle(
        from text: String,
        sender: String?,
        fileNumber: String?,
        amount: Decimal?
    ) -> (DocumentCategory, String) {
        let lower = text.lowercased()

        if lower.contains("mietvertrag") {
            return (.contracts, "Mietvertrag \(sender ?? "Wohnung")")
        } else if lower.contains("arbeitsvertrag") {
            return (.contracts, "Arbeitsvertrag \(sender ?? "")")
        } else if lower.contains("vertrag") || lower.contains("vertragsunterlagen") || lower.contains("abomodell") {
            return (.contracts, "\(sender ?? "Vertrag")")
        } else if lower.contains("mahnung") || lower.contains("inkasso") || lower.contains("zahlungsaufforderung") || lower.contains("vollstreckungsbescheid") {
            return (.debts, "Mahnung von \(sender ?? "Gläubiger")")
        } else if lower.contains("bescheid") || lower.contains("rundfunkbeitrag") || lower.contains("beitragsservice") || lower.contains("finanzamt") || lower.contains("jobcenter") || lower.contains("amtsgericht") {
            return (.authorities, "Bescheid: \(sender ?? "Behörde")")
        } else if lower.contains("versicherung") || lower.contains("police") || lower.contains("krankenkasse") {
            return (.insurance, "Versicherung: \(sender ?? "Police")")
        } else if lower.contains("rechnung") || lower.contains("abrechnung") || lower.contains("quittung") {
            let s = sender != nil ? "Rechnung \(sender!)" : "Rechnung"
            return (.invoices, s)
        } else if lower.contains("steuer") || lower.contains("steuererklärung") || lower.contains("kontoauszug") || lower.contains("gehaltsabrechnung") {
            return (.taxes, "Finanzbeleg \(sender ?? "")")
        } else if lower.contains("arzt") || lower.contains("rezept") || lower.contains("befund") || lower.contains("patient") {
            return (.health, "Gesundheitsdokument \(sender ?? "")")
        }

        let fallbackTitle = sender != nil ? "Dokument von \(sender!)" : "Eingescanntes Dokument"
        return (.other, fallbackTitle)
    }

    private static func fallbackData(ocr: String) -> ExtractedDocumentData {
        ExtractedDocumentData(
            title:        "Neuer Scan",
            category:     .other,
            sender:       nil,
            fileNumber:   nil,
            amount:       nil,
            documentDate: Date(),
            dueDate:      nil,
            tags:         ["Scan"],
            ocrText:      ocr,
            confidence:   0.0
        )
    }
}

// =============================================================================
// MARK: - 3. DocumentArchiveService
// =============================================================================

@MainActor
public final class DocumentArchiveService: ObservableObject {
    @Published public private(set) var documents: [AppDocument] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public var selectedCategory: DocumentCategory? = nil
    @Published public var selectedStatus:   DocumentStatus?   = nil
    @Published public var searchText:       String            = ""

    public let userId: UUID
    private let storageKey: String

    public init(userId: UUID) {
        self.userId = userId
        self.storageKey = "dms_documents_\(userId.uuidString)"
        loadLocalCache()
        if documents.isEmpty {
            seedSampleDocuments()
        }
    }

    public var filteredDocuments: [AppDocument] {
        documents.filter { doc in
            if let cat = selectedCategory, doc.category != cat { return false }
            if let st = selectedStatus, doc.status != st { return false }
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                let titleMatch  = doc.title.lowercased().contains(q)
                let senderMatch = doc.sender?.lowercased().contains(q) ?? false
                let fileMatch   = doc.fileNumber?.lowercased().contains(q) ?? false
                let tagMatch    = doc.tags.contains { $0.lowercased().contains(q) }
                let ocrMatch    = doc.ocrText?.lowercased().contains(q) ?? false
                let notesMatch  = doc.notes?.lowercased().contains(q) ?? false
                if !(titleMatch || senderMatch || fileMatch || tagMatch || ocrMatch || notesMatch) {
                    return false
                }
            }
            return true
        }
        .sorted { ($0.dueDate ?? $0.documentDate) > ($1.dueDate ?? $1.documentDate) }
    }

    public var urgentDocuments: [AppDocument] {
        documents.filter { $0.isDeadlineUrgent || $0.isOverdue }
    }

    public func addDocument(_ doc: AppDocument) {
        documents.removeAll { $0.id == doc.id }
        documents.insert(doc, at: 0)
        saveLocalCache()
    }

    public func updateDocument(_ doc: AppDocument) {
        if let idx = documents.firstIndex(where: { $0.id == doc.id }) {
            var updated = doc
            updated.updatedAt = Date()
            documents[idx] = updated
            saveLocalCache()
        }
    }

    public func deleteDocument(_ id: UUID) {
        documents.removeAll { $0.id == id }
        saveLocalCache()
    }

    public func updateStatus(_ id: UUID, newStatus: DocumentStatus) {
        if let idx = documents.firstIndex(where: { $0.id == id }) {
            documents[idx].status = newStatus
            documents[idx].updatedAt = Date()
            saveLocalCache()
        }
    }

    public func uploadAndAdd(
        title: String,
        category: DocumentCategory,
        data: Data,
        fileType: DocumentFileType,
        sender: String? = nil,
        fileNumber: String? = nil,
        amount: Decimal? = nil,
        documentDate: Date = Date(),
        dueDate: Date? = nil,
        ocrText: String? = nil,
        tags: [String] = [],
        notes: String? = nil
    ) async throws -> AppDocument {
        let ext = fileType == .pdf ? "pdf" : "jpg"
        let mimeType = fileType == .pdf ? "application/pdf" : "image/jpeg"
        let fileName = "\(userId.uuidString)/\(UUID().uuidString).\(ext)"

        _ = try? await SupabaseConfig.client.storage
            .from("documents")
            .upload(fileName, data: data, contentType: mimeType)

        let doc = AppDocument(
            id:           UUID(),
            userId:       userId,
            title:        title,
            category:     category,
            documentDate: documentDate,
            dueDate:      dueDate,
            sender:       sender,
            fileNumber:   fileNumber,
            amount:       amount,
            storagePath:  fileName,
            fileType:     fileType,
            ocrText:      ocrText,
            tags:         tags,
            status:       dueDate != nil ? .deadlineSet : .inbox,
            notes:        notes
        )

        addDocument(doc)
        return doc
    }

    private func saveLocalCache() {
        if let data = try? JSONEncoder().encode(documents) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadLocalCache() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([AppDocument].self, from: data)
        else { return }
        self.documents = decoded
    }

    private func seedSampleDocuments() {
        let now = Date()
        let sample1 = AppDocument(
            userId: userId,
            title: "Mietvertrag Hauptwohnung",
            category: .contracts,
            documentDate: Calendar.current.date(byAdding: .month, value: -6, to: now)!,
            dueDate: nil,
            sender: "Wohnungsbaugesellschaft mbH",
            fileNumber: "MV-2024-8841",
            amount: 850.00,
            fileType: .pdf,
            ocrText: "Mietvertrag über Wohnräume in der Musterstraße 1. Monatliche Kaltmiete: 850,00 Euro.",
            tags: ["Wohnung", "Miete", "Wichtig"],
            status: .completed,
            notes: "Kaution von 3 Kaltmieten vollständig bezahlt."
        )

        let sample2 = AppDocument(
            userId: userId,
            title: "Bescheid über Rundfunkbeitrag",
            category: .authorities,
            documentDate: Calendar.current.date(byAdding: .day, value: -10, to: now)!,
            dueDate: Calendar.current.date(byAdding: .day, value: 5, to: now)!,
            sender: "ARD ZDF Deutschlandradio Beitragsservice",
            fileNumber: "554 982 109",
            amount: 55.08,
            fileType: .image,
            ocrText: "Zahlungsaufforderung für den Zeitraum. Offener Betrag: 55,08 EUR. Zahlungsziel bis zum 15. des Monats.",
            tags: ["Beitragsservice", "Gebühren"],
            status: .deadlineSet,
            notes: "Frist beachten: Vor dem Ablauf überweisen."
        )

        let sample3 = AppDocument(
            userId: userId,
            title: "Strom Jahresabrechnung",
            category: .invoices,
            documentDate: Calendar.current.date(byAdding: .month, value: -1, to: now)!,
            dueDate: nil,
            sender: "Stadtwerke Energie",
            fileNumber: "SW-8942-EL",
            amount: 142.30,
            fileType: .pdf,
            ocrText: "Jahresabrechnung Strom. Guthaben von 142,30 EUR wird auf Ihr Bankkonto erstattet.",
            tags: ["Strom", "Stadtwerke", "Guthaben"],
            status: .completed,
            notes: "Abschlag wurde um 15€ gesenkt."
        )

        self.documents = [sample1, sample2, sample3]
        saveLocalCache()
    }
}

// =============================================================================
// MARK: - 4. DocumentArchiveView (Main DMS View)
// =============================================================================

public struct DocumentArchiveView: View {
    @ObservedObject public var service: DocumentArchiveService
    @Environment(\.colorScheme) private var colorScheme

    @State private var showAddSheet:     Bool = false
    @State private var selectedDocument: AppDocument? = nil

    public init(service: DocumentArchiveService) {
        self.service = service
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                // ── Search & Filter Bar ────────────────────────────────
                searchAndFilterBar

                // ── Urgent Deadlines Banner (if any) ───────────────────
                if !service.urgentDocuments.isEmpty {
                    urgentDeadlinesSection
                }

                // ── Category Pills (Horizontal) ────────────────────────
                categoryPillsSection

                // ── Document List / Cards ──────────────────────────────
                if service.filteredDocuments.isEmpty {
                    emptyStateView
                } else {
                    documentListView
                }
            }
            .padding(.vertical, 16)
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Dokumente")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.primaryAccent)
                }
                .accessibilityLabel("Dokument hinzufügen")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddDocumentSheet(service: service)
        }
        .sheet(item: $selectedDocument) { doc in
            NavigationStack {
                DocumentDetailView(document: doc, service: service)
            }
        }
    }

    private var searchAndFilterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Suche nach Titel, Absender, OCR-Text…", text: $service.searchText)
                    .textFieldStyle(.plain)
                if !service.searchText.isEmpty {
                    Button {
                        service.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.glassEdgeGradient, lineWidth: 0.8)
            }

            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.primaryAccent)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
    }

    private var urgentDeadlinesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "alarm.waves.left.and.right.fill")
                    .foregroundStyle(.red)
                Text("Fristen-Radar (\(service.urgentDocuments.count))")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
            }

            ForEach(service.urgentDocuments.prefix(2)) { doc in
                Button {
                    selectedDocument = doc
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(doc.isOverdue ? Color.red : Color.orange)
                            .frame(width: 10, height: 10)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let due = doc.dueDate {
                                Text(doc.isOverdue ? "Fällig seit: \(due.formatted(date: .abbreviated, time: .omitted))" : "Frist bis: \(due.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2)
                                    .foregroundStyle(doc.isOverdue ? .red : .orange)
                            }
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption2.bold())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .background((doc.isOverdue ? Color.red : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 18)
        .padding(.horizontal, 16)
    }

    private var categoryPillsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryPill(title: "Alle", icon: "tray.full.fill", isSelected: service.selectedCategory == nil) {
                    withAnimation(.spring(response: 0.3)) { service.selectedCategory = nil }
                }

                ForEach(DocumentCategory.allCases) { cat in
                    categoryPill(title: cat.rawValue, icon: cat.icon, isSelected: service.selectedCategory == cat) {
                        withAnimation(.spring(response: 0.3)) {
                            service.selectedCategory = (service.selectedCategory == cat) ? nil : cat
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func categoryPill(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isSelected
                    ? Theme.primaryGradient
                    : LinearGradient(colors: [Color.white.opacity(0.06), Color.white.opacity(0.02)], startPoint: .top, endPoint: .bottom),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        isSelected ? Color.white.opacity(0.4) : Color.white.opacity(0.12),
                        lineWidth: 0.8
                    )
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var documentListView: some View {
        LazyVStack(spacing: 12) {
            ForEach(service.filteredDocuments) { doc in
                DocumentCardRow(document: doc) {
                    selectedDocument = doc
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("Keine Dokumente gefunden", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Füge über das Plus oben ein neues Dokument oder einen Scan hinzu.")
        }
        .padding(.top, 40)
    }
}

// =============================================================================
// MARK: - 5. DocumentCardRow
// =============================================================================

public struct DocumentCardRow: View {
    public let document: AppDocument
    public let onTap: () -> Void

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(document.category.color.opacity(0.16))
                        .frame(width: 44, height: 44)
                    Image(systemName: document.category.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(document.category.color)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(document.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if document.fileType == .pdf {
                            Text("PDF")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.red.opacity(0.15), in: Capsule())
                                .foregroundStyle(.red)
                        }
                    }

                    HStack(spacing: 6) {
                        if let sender = document.sender {
                            Text(sender)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text("·").foregroundStyle(.tertiary)
                        }
                        Text(document.documentDate.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if let due = document.dueDate {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.system(size: 10))
                            Text("Frist: \(due.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(document.isOverdue ? Color.red : (document.isDeadlineUrgent ? Color.orange : Color.secondary))
                        .padding(.top, 2)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    if let amt = document.amount {
                        Text(amt, format: .currency(code: "EUR"))
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(Theme.primaryAccent)
                    }
                    Text(document.status.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(document.status.color)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(document.status.color.opacity(0.12), in: Capsule())
                }
            }
            .padding(12)
            .liquidGlassCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }
}

// =============================================================================
// MARK: - 6. DocumentDetailView
// =============================================================================

public struct DocumentDetailView: View {
    public let document: AppDocument
    public let service:  DocumentArchiveService
    @Environment(\.dismiss) private var dismiss

    @State private var showOCRDrawer: Bool = false
    @State private var isCopied:      Bool = false

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                documentPreviewCard
                metadataSection
                deadlineSection
                if let ocr = document.ocrText, !ocr.isEmpty {
                    ocrTextSection(ocr)
                }
                tagsAndNotesSection
                actionButtonsSection
            }
            .padding(16)
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { dismiss() }
            }
        }
    }

    private var documentPreviewCard: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.3))
                    .frame(height: 160)

                VStack(spacing: 10) {
                    Image(systemName: document.fileType == .pdf ? "doc.richtext.fill" : "doc.text.image.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.primaryAccent)

                    Text(document.fileType == .pdf ? "PDF-Dokument" : "Dokumenten-Scan")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let path = document.storagePath {
                        let fullURL = SupabaseConfig.url.appendingPathComponent("storage/v1/object/public/documents/\(path)")
                        Link(destination: fullURL) {
                            Label("Originaldatei anzeigen", systemImage: "arrow.up.right.square")
                                .font(.caption.bold())
                        }
                        .tint(Theme.primaryAccent)
                    }
                }
            }
        }
        .liquidGlassCard(cornerRadius: 18)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hauptdaten")
                .font(.headline)

            detailRow("Kategorie", value: document.category.rawValue, icon: document.category.icon, color: document.category.color)
            if let sender = document.sender {
                detailRow("Absender / Firma", value: sender, icon: "person.crop.circle", color: .blue)
            }
            if let fn = document.fileNumber {
                detailRow("Aktenzeichen / Nr.", value: fn, icon: "number", color: .purple)
            }
            if let amt = document.amount {
                detailRow("Betrag", value: amt.formatted(.currency(code: "EUR")), icon: "eurosign.circle.fill", color: .green)
            }
            detailRow("Belegdatum", value: document.documentDate.formatted(date: .long, time: .omitted), icon: "calendar", color: .teal)
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 18)
    }

    private func detailRow(_ title: String, value: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 24)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
        }
    }

    private var deadlineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Frist & Wiedervorlage", systemImage: "calendar.badge.clock")
                    .font(.headline)
                Spacer()
                if document.dueDate != nil {
                    Text(document.isOverdue ? "Abgelaufen" : "Aktiv")
                        .font(.caption2.bold())
                        .foregroundStyle(document.isOverdue ? Color.red : Color.green)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((document.isOverdue ? Color.red : Color.green).opacity(0.12), in: Capsule())
                }
            }

            if let due = document.dueDate {
                HStack {
                    Text("Fälligkeitsdatum:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(due.formatted(date: .long, time: .omitted))
                        .bold()
                        .foregroundStyle(document.isOverdue ? Color.red : (document.isDeadlineUrgent ? Color.orange : Color.primary))
                }
            } else {
                Text("Keine Frist für dieses Dokument hinterlegt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 18)
    }

    private func ocrTextSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Automatisch erkannter Text (OCR)", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                    isCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCopied = false }
                } label: {
                    Label(isCopied ? "Kopiert!" : "Kopieren", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption.bold())
                        .foregroundStyle(isCopied ? Color.green : Theme.primaryAccent)
                }
                .buttonStyle(.plain)
            }

            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(showOCRDrawer ? nil : 6)
                .frame(maxWidth: .infinity, alignment: .leading)

            if text.count > 200 {
                Button(showOCRDrawer ? "Weniger anzeigen" : "Vollständigen Text anzeigen") {
                    withAnimation { showOCRDrawer.toggle() }
                }
                .font(.caption.bold())
                .foregroundStyle(Theme.primaryAccent)
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 18)
    }

    private var tagsAndNotesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Schlagwörter & Notizen")
                .font(.headline)

            if !document.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(document.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2.bold())
                            .foregroundStyle(Theme.primaryAccent)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.primaryAccent.opacity(0.12), in: Capsule())
                    }
                }
            }

            if let notes = document.notes, !notes.isEmpty {
                Text(notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 18)
    }

    private var actionButtonsSection: some View {
        VStack(spacing: 10) {
            Menu {
                ForEach(DocumentStatus.allCases) { st in
                    Button {
                        service.updateStatus(document.id, newStatus: st)
                    } label: {
                        Label(st.rawValue, systemImage: st.icon)
                    }
                }
            } label: {
                HStack {
                    Label("Status: \(document.status.rawValue)", systemImage: document.status.icon)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }
                .font(.subheadline.bold())
                .padding()
                .background(document.status.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(document.status.color)
            }

            Button(role: .destructive) {
                service.deleteDocument(document.id)
                dismiss()
            } label: {
                Label("Dokument löschen", systemImage: "trash")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
    }
}

// =============================================================================
// MARK: - 7. AddDocumentSheet (mit Auto-Erkennung & Auto-Ausfüllen)
// =============================================================================

public struct AddDocumentSheet: View {
    public let service: DocumentArchiveService
    @Environment(\.dismiss) private var dismiss

    @State private var title:           String           = ""
    @State private var category:        DocumentCategory = .contracts
    @State private var sender:          String           = ""
    @State private var fileNumber:      String           = ""
    @State private var amountString:    String           = ""
    @State private var documentDate:    Date             = Date()
    @State private var hasDueDate:      Bool             = false
    @State private var dueDate:         Date             = Calendar.current.date(byAdding: .day, value: 14, to: Date())!
    @State private var notes:           String           = ""
    @State private var tagsString:      String           = ""
    @State private var extractedOCRText: String?         = nil

    // Attachment & Status
    @State private var selectedImageData: Data?    = nil
    @State private var selectedPDFData:   Data?    = nil
    @State private var selectedFileName:  String?  = nil
    @State private var showImagePicker:   Bool     = false
    @State private var showFilePicker:    Bool     = false
    @State private var isAnalyzing:       Bool     = false
    @State private var isUploading:       Bool     = false
    @State private var hasAutoFilled:     Bool     = false

    public init(service: DocumentArchiveService) {
        self.service = service
    }

    public var body: some View {
        NavigationStack {
            Form {
                // ── Datei-Auswahl ──────────────────────────────────────
                Section("Dokument anhängen") {
                    HStack(spacing: 12) {
                        Button {
                            showImagePicker = true
                        } label: {
                            Label("Foto / Scan", systemImage: "camera.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            showFilePicker = true
                        } label: {
                            Label("PDF wählen", systemImage: "doc.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if isAnalyzing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Analysiere Dokument & lese Hauptdaten aus…")
                                .font(.caption.bold())
                                .foregroundStyle(Theme.primaryAccent)
                        }
                        .padding(.vertical, 4)
                    } else if hasAutoFilled {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.orange)
                            Text("Hauptdaten automatisch erkannt & ausgefüllt!")
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                        }
                    }

                    if let name = selectedFileName {
                        HStack {
                            Image(systemName: selectedPDFData != nil ? "doc.richtext.fill" : "photo.fill")
                                .foregroundStyle(Theme.primaryAccent)
                            Text(name)
                                .font(.caption.bold())
                                .lineLimit(1)
                            Spacer()
                            Button("Entfernen") {
                                selectedImageData = nil
                                selectedPDFData   = nil
                                selectedFileName  = nil
                                hasAutoFilled     = false
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                    }
                }

                // ── Automatisch ausgelesene Hauptdaten ──────────────────
                Section("Hauptdaten") {
                    TextField("Dokumenttitel (z. B. Mietvertrag)", text: $title)
                    Picker("Kategorie", selection: $category) {
                        ForEach(DocumentCategory.allCases) { cat in
                            Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                        }
                    }
                    TextField("Absender / Firma", text: $sender)
                    TextField("Aktenzeichen / Rechnungs-Nr.", text: $fileNumber)
                    TextField("Betrag in € (optional)", text: $amountString)
                        .keyboardType(.numbersAndPunctuation)
                }

                // ── Daten & Fristen ────────────────────────────────────
                Section("Datum & Frist") {
                    DatePicker("Belegdatum", selection: $documentDate, displayedComponents: .date)
                    Toggle("Frist / Wiedervorlage setzen", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Fälligkeitsdatum", selection: $dueDate, displayedComponents: .date)
                    }
                }

                // ── Notizen & Tags ─────────────────────────────────────
                Section("Zusatzangaben") {
                    TextField("Schlagwörter (Kommagetrennt, z. B. Auto, Mahnung)", text: $tagsString)
                    TextField("Notizen", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Neues Dokument")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }
                        .disabled(title.isEmpty || isUploading || isAnalyzing)
                        .bold()
                }
            }
            .sheet(isPresented: $showImagePicker) {
                DocumentImagePicker { img in
                    guard let image = img, let data = image.jpegData(compressionQuality: 0.82) else { return }
                    selectedImageData = data
                    selectedPDFData   = nil
                    selectedFileName  = "Scan_\(Date().formatted(date: .numeric, time: .omitted)).jpg"
                    runAutoExtraction(image: image, rawData: data)
                }
            }
            .sheet(isPresented: $showFilePicker) {
                DocumentFilePicker { url in
                    guard let fileURL = url, let data = try? Data(contentsOf: fileURL) else { return }
                    selectedPDFData   = data
                    selectedImageData = nil
                    selectedFileName  = fileURL.lastPathComponent
                    runAutoExtraction(pdfData: data)
                }
            }
        }
    }

    // ── Automatische Extraktion anstoßen ───────────────────────────────────

    private func runAutoExtraction(image: UIImage? = nil, rawData: Data? = nil, pdfData: Data? = nil) {
        isAnalyzing = true
        Task {
            let extracted: ExtractedDocumentData
            if let img = image {
                extracted = await DocumentAutoExtractionEngine.analyze(image: img)
            } else if let pData = pdfData {
                extracted = await DocumentAutoExtractionEngine.analyze(pdfData: pData)
            } else {
                isAnalyzing = false
                return
            }

            await MainActor.run {
                withAnimation(.spring(response: 0.4)) {
                    self.title            = extracted.title
                    self.category         = extracted.category
                    self.sender           = extracted.sender ?? ""
                    self.fileNumber       = extracted.fileNumber ?? ""
                    if let amt = extracted.amount {
                        self.amountString = "\(amt)".replacingOccurrences(of: ".", with: ",")
                    }
                    self.documentDate     = extracted.documentDate
                    if let due = extracted.dueDate {
                        self.hasDueDate   = true
                        self.dueDate       = due
                    }
                    self.tagsString       = extracted.tags.joined(separator: ", ")
                    self.extractedOCRText = extracted.ocrText
                    self.hasAutoFilled    = true
                    self.isAnalyzing      = false
                }
            }
        }
    }

    private func save() {
        guard !title.isEmpty else { return }
        isUploading = true

        let amt = Decimal(string: amountString.replacingOccurrences(of: ",", with: "."))
        let tags = tagsString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        Task {
            if let pdfData = selectedPDFData {
                _ = try? await service.uploadAndAdd(
                    title:        title,
                    category:     category,
                    data:         pdfData,
                    fileType:     .pdf,
                    sender:       sender.isEmpty ? nil : sender,
                    fileNumber:   fileNumber.isEmpty ? nil : fileNumber,
                    amount:       amt,
                    documentDate: documentDate,
                    dueDate:      hasDueDate ? dueDate : nil,
                    ocrText:      extractedOCRText,
                    tags:         tags,
                    notes:        notes.isEmpty ? nil : notes
                )
            } else if let imgData = selectedImageData {
                _ = try? await service.uploadAndAdd(
                    title:        title,
                    category:     category,
                    data:         imgData,
                    fileType:     .image,
                    sender:       sender.isEmpty ? nil : sender,
                    fileNumber:   fileNumber.isEmpty ? nil : fileNumber,
                    amount:       amt,
                    documentDate: documentDate,
                    dueDate:      hasDueDate ? dueDate : nil,
                    ocrText:      extractedOCRText,
                    tags:         tags,
                    notes:        notes.isEmpty ? nil : notes
                )
            } else {
                let doc = AppDocument(
                    userId:       service.userId,
                    title:        title,
                    category:     category,
                    documentDate: documentDate,
                    dueDate:      hasDueDate ? dueDate : nil,
                    sender:       sender.isEmpty ? nil : sender,
                    fileNumber:   fileNumber.isEmpty ? nil : fileNumber,
                    amount:       amt,
                    fileType:     .image,
                    ocrText:      extractedOCRText,
                    tags:         tags,
                    status:       hasDueDate ? .deadlineSet : .inbox,
                    notes:        notes.isEmpty ? nil : notes
                )
                service.addDocument(doc)
            }

            await MainActor.run {
                isUploading = false
                dismiss()
            }
        }
    }
}

// =============================================================================
// MARK: - 8. UIKit Wrappers for Pickers
// =============================================================================

private struct DocumentImagePicker: UIViewControllerRepresentable {
    var onPick: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate   = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            picker.dismiss(animated: true) { [weak self] in
                self?.onPick(info[.originalImage] as? UIImage)
            }
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) { [weak self] in self?.onPick(nil) }
        }
    }
}

private struct DocumentFilePicker: UIViewControllerRepresentable {
    var onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf, .image, .plainText], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}
