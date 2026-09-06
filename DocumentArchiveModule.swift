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
import UIKit
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
    public var localFileName: String?
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
        localFileName: String? = nil,
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
        self.localFileName = localFileName
        self.fileType     = fileType
        self.ocrText      = ocrText
        self.tags         = tags
        self.status       = status
        self.notes        = notes
        self.createdAt    = createdAt
        self.updatedAt    = updatedAt
    }

    public var localFileURL: URL? {
        guard let name = localFileName else { return nil }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dms_files", isDirectory: true)
        let file = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
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

        // 1. Rezept (Kassenrezept, Privatrezept, E-Rezept)
        if lower.contains("rezept") || lower.contains("verordnung") || lower.contains("pzn") || lower.contains("apotheke") || lower.contains("aut idem") || lower.contains(" rp.") || lower.hasPrefix("rp.") {
            let commonMeds = [
                "Ibuprofen", "Paracetamol", "Amoxicillin", "Pantoprazol", "Metformin",
                "Ramipril", "L-Thyroxin", "Novaminsulfon", "Cetirizin", "Diclofenac",
                "Aspirin", "Bisoprolol", "Torasemid", "Simvastatin", "Cefuroxim",
                "Prednisolon", "Omeprazol", "Doxycyclin", "Tilidin", "Vomex"
            ]
            var detectedMed: String? = nil
            for med in commonMeds {
                if text.localizedCaseInsensitiveContains(med) {
                    detectedMed = med
                    break
                }
            }
            
            var dose = ""
            if let med = detectedMed {
                if let regex = try? NSRegularExpression(pattern: "(?i)\(med)\\s*(\\d+\\s*(?:mg|g|ml))"),
                   let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                   let r = Range(match.range(at: 1), in: text) {
                    dose = " " + String(text[r])
                }
            }
            
            let doctorName = extractDoctorName(from: text) ?? sender
            if let med = detectedMed {
                let doctorSuffix = doctorName != nil ? " (\(doctorName!))" : ""
                return (.health, "Rezept: \(med)\(dose)\(doctorSuffix)")
            } else if let doc = doctorName {
                return (.health, "Rezept: Verordnung (\(doc))")
            } else {
                return (.health, "Rezept: Medikamentenverordnung")
            }
        }

        // 2. Attest / AU-Bescheinigung / Krankschreibung
        if lower.contains("attest") || lower.contains("arbeitsunfähig") || lower.contains("au-bescheinigung") || lower.contains("krankschreibung") || lower.contains("erstbescheinigung") || lower.contains("folgebescheinigung") || lower.contains("schulunfähig") || lower.contains("sportbefreiung") {
            var reason = "Arbeitsunfähigkeit"
            if lower.contains("sport") || lower.contains("schulsport") {
                reason = "Sportbefreiung"
            } else if lower.contains("schule") || lower.contains("schulunfähig") {
                reason = "Schulbefreiung"
            } else if lower.contains("reise") || lower.contains("storno") {
                reason = "Reiseunfähigkeit"
            } else if lower.contains("gripp") || lower.contains("infekt") {
                reason = "Infekt / Erkrankung"
            } else if lower.contains("rücken") {
                reason = "Rückenbeschwerden"
            } else if lower.contains("quarantäne") || lower.contains("corona") {
                reason = "Infektionsschutz"
            }
            
            let doctorName = extractDoctorName(from: text) ?? sender
            let doctorSuffix = doctorName != nil ? " (\(doctorName!))" : ""
            return (.health, "Attest: \(reason)\(doctorSuffix)")
        }

        // 3. Arztbrief / Befund / Laborbericht
        if lower.contains("befund") || lower.contains("laborbericht") || lower.contains("laborwert") || lower.contains("arztbrief") || lower.contains("entlassungsbrief") || lower.contains("überweisung") || lower.contains("diagnostik") || lower.contains("röntgen") || lower.contains("mrt") {
            let doctorName = extractDoctorName(from: text) ?? sender
            let topic = lower.contains("labor") ? "Laborbericht" : (lower.contains("befund") ? "Befund" : "Arztbrief")
            let suffix = doctorName != nil ? ": \(doctorName!)" : ""
            return (.health, "\(topic)\(suffix)")
        }

        // 4. Kassenbon (Supermarkt / Drogerie)
        let supermarkets = ["REWE", "EDEKA", "Aldi", "Lidl", "dm-drogerie", "dm", "Rossmann", "Netto", "Kaufland", "Penny", "Alnatura", "Müller"]
        for market in supermarkets {
            if text.localizedCaseInsensitiveContains(market) && (lower.contains("kassenbon") || lower.contains("summe") || lower.contains("eur") || lower.contains("bar") || lower.contains("beleg")) {
                let amtStr = amount != nil ? " (\(amount!.formatted(.currency(code: "EUR"))))" : ""
                return (.invoices, "Kassenbon: \(market)\(amtStr)")
            }
        }

        // 5. Verträge
        if lower.contains("mietvertrag") {
            return (.contracts, "Mietvertrag: \(sender ?? "Wohnung")")
        } else if lower.contains("arbeitsvertrag") {
            return (.contracts, "Arbeitsvertrag: \(sender ?? "Arbeitgeber")")
        } else if lower.contains("vertrag") || lower.contains("vertragsunterlagen") || lower.contains("mitgliedschaft") {
            return (.contracts, "Vertrag: \(sender ?? "Vereinbarung")")
        }

        // 6. Mahnung, Mahnbescheid & Vollstreckungsbescheid
        if lower.contains("vollstreckungsbescheid") || lower.contains("vollstreckbare ausfertigung") || lower.contains("vollstreckungsauftrag") {
            let fn = fileNumber != nil ? " (Az: \(fileNumber!))" : ""
            return (.debts, "Vollstreckungsbescheid: \(sender ?? "Gläubiger")\(fn)")
        } else if lower.contains("mahnbescheid") || (lower.contains("amtsgericht") && (lower.contains("mahngericht") || lower.contains("mahnverfahren") || lower.contains("antragsteller"))) {
            let fn = fileNumber != nil ? " (Az: \(fileNumber!))" : ""
            return (.debts, "Mahnbescheid: \(sender ?? "Amtsgericht")\(fn)")
        } else if lower.contains("inkasso") || lower.contains("mahnung") || lower.contains("zahlungsaufforderung") || lower.contains("letzte mahnung") {
            let fn = fileNumber != nil ? " (Az: \(fileNumber!))" : ""
            return (.debts, "Inkasso-Mahnung: \(sender ?? "Forderung")\(fn)")
        }

        // 7. Behörden & Ämter
        if lower.contains("bescheid") || lower.contains("rundfunkbeitrag") || lower.contains("beitragsservice") || lower.contains("finanzamt") || lower.contains("jobcenter") || lower.contains("bürgergeld") || lower.contains("amtsgericht") || lower.contains("bußgeld") {
            var topic = "Amtliche Mitteilung"
            if lower.contains("rundfunkbeitrag") || lower.contains("beitragsservice") { topic = "Rundfunkbeitrag" }
            else if lower.contains("steuerbescheid") || lower.contains("einkommensteuer") { topic = "Steuerbescheid" }
            else if lower.contains("bürgergeld") { topic = "Bürgergeld-Bescheid" }
            else if lower.contains("bußgeld") || lower.contains("verwarnung") { topic = "Bußgeldbescheid" }
            return (.authorities, "Bescheid: \(sender ?? topic)")
        }

        // 8. Versicherungen
        if lower.contains("versicherung") || lower.contains("police") || lower.contains("krankenkasse") || lower.contains("haftpflicht") || lower.contains("hausrat") {
            var kind = "Versicherung"
            if lower.contains("haftpflicht") { kind = "Haftpflicht" }
            else if lower.contains("hausrat") { kind = "Hausrat" }
            else if lower.contains("kfz") || lower.contains("auto") { kind = "KFZ-Versicherung" }
            else if lower.contains("krankenkasse") { kind = "Krankenkasse" }
            return (.insurance, "\(kind): \(sender ?? "Police")")
        }

        // 9. Rechnungen & Belege
        if lower.contains("rechnung") || lower.contains("abrechnung") || lower.contains("invoice") || lower.contains("quittung") {
            var purpose = ""
            if lower.contains("strom") || lower.contains("energie") { purpose = " (Strom)" }
            else if lower.contains("gas") || lower.contains("heizung") { purpose = " (Gas)" }
            else if lower.contains("mobilfunk") || lower.contains("handy") { purpose = " (Mobilfunk)" }
            else if lower.contains("internet") || lower.contains("dsl") { purpose = " (Internet)" }
            else if lower.contains("nebenkosten") { purpose = " (Nebenkosten)" }
            else if lower.contains("werkstatt") || lower.contains("inspektion") { purpose = " (Werkstatt)" }
            
            let s = sender != nil ? "Rechnung: \(sender!)\(purpose)" : "Rechnung\(purpose)"
            return (.invoices, s)
        }

        // 10. Steuern & Finanzen
        if lower.contains("steuer") || lower.contains("steuererklärung") || lower.contains("kontoauszug") || lower.contains("gehaltsabrechnung") || lower.contains("lohnabrechnung") {
            if lower.contains("gehalt") || lower.contains("lohn") {
                return (.taxes, "Gehaltsabrechnung: \(sender ?? "Arbeitgeber")")
            }
            return (.taxes, "Finanzbeleg: \(sender ?? "Konto/Steuer")")
        }

        // 11. Allgemeiner Fallback
        let fallbackTitle = sender != nil ? "Dokument: \(sender!)" : "Eingescanntes Dokument"
        return (.other, fallbackTitle)
    }

    private static func extractDoctorName(from text: String) -> String? {
        let patterns = [
            #"(?i)(Dr\.\s*med\.\s*[A-ZÄÖÜ][a-zäöüß]+(?:\s+[A-ZÄÖÜ][a-zäöüß]+)?)"#,
            #"(?i)(Dr\.\s*[A-ZÄÖÜ][a-zäöüß]+(?:\s+[A-ZÄÖÜ][a-zäöüß]+)?)"#,
            #"(?i)(Praxis\s+[A-ZÄÖÜ][a-zäöüß]+(?:\s+[A-ZÄÖÜ][a-zäöüß]+)?)"#,
            #"(?i)(Gemeinschaftspraxis\s+[A-ZÄÖÜ][a-zäöüß]+)"#
        ]
        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(match.range(at: 1), in: text) {
                return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
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

    public var totalAmountSum: Decimal {
        documents.compactMap(\.amount).reduce(0, +)
    }

    public func categoryCount(_ cat: DocumentCategory) -> Int {
        documents.filter { $0.category == cat }.count
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
        let id = UUID()
        let fileName = "\(userId.uuidString)/\(id.uuidString).\(ext)"

        // Always save locally first so files open reliably offline & without 404
        let localName = "\(id.uuidString).\(ext)"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dms_files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let localURL = dir.appendingPathComponent(localName)
        try? data.write(to: localURL)

        _ = try? await SupabaseConfig.client.storage
            .from("documents")
            .upload(fileName, data: data, contentType: mimeType)

        let doc = AppDocument(
            id:           id,
            userId:       userId,
            title:        title,
            category:     category,
            documentDate: documentDate,
            dueDate:      dueDate,
            sender:       sender,
            fileNumber:   fileNumber,
            amount:       amount,
            storagePath:  fileName,
            localFileName: localName,
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
// =============================================================================
// MARK: - 4. DMSSortOption

public enum DMSSortOption: String, CaseIterable, Identifiable {
    case newest = "Neueste zuerst"
    case oldest = "Älteste zuerst"
    case highestAmount = "Höchster Betrag"
    case urgentDeadline = "Dringendste Frist"

    public var id: String { rawValue }
}

// =============================================================================
// MARK: - 5. DocumentGridCard (Visual A4/Receipt Card for Grid View)
// =============================================================================

public struct DocumentGridCard: View {
    public let document: AppDocument
    public let onTap: () -> Void

    public var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                // Top visual banner / thumbnail
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(document.category.color.opacity(0.12))
                        .frame(height: 95)

                    if let localURL = document.localFileURL,
                       document.fileType == .image,
                       let uiImg = UIImage(contentsOfFile: localURL.path) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 95)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        VStack(spacing: 4) {
                            Image(systemName: document.fileType == .pdf ? "doc.richtext.fill" : document.category.icon)
                                .font(.system(size: 32))
                                .foregroundStyle(document.category.color)
                            Text(document.category.rawValue)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(document.category.color.opacity(0.85))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    // Status pill top right
                    Text(document.status.rawValue)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(document.status.color)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.65), in: Capsule())
                        .padding(6)
                }

                // Title, Sender, Amount
                VStack(alignment: .leading, spacing: 3) {
                    Text(document.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let sender = document.sender {
                        Text(sender)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack {
                        if let amt = document.amount {
                            Text(amt, format: .currency(code: "EUR"))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.primaryAccent)
                        }
                        Spacer()
                        Text(document.documentDate.formatted(date: .numeric, time: .omitted))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(10)
            .liquidGlassCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }
}

// =============================================================================
// MARK: - 6. DocumentArchiveView (Main DMS View)
// =============================================================================

public struct DocumentArchiveView: View {
    @ObservedObject public var service: DocumentArchiveService
    @Environment(\.colorScheme) private var colorScheme

    @State private var showAddSheet:     Bool = false
    @State private var selectedDocument: AppDocument? = nil
    @State private var isGridView:       Bool = false
    @State private var sortOption:       DMSSortOption = .newest
    @State private var filterUrgentOnly: Bool = false

    public init(service: DocumentArchiveService) {
        self.service = service
    }

    private var sortedDocuments: [AppDocument] {
        var list = service.filteredDocuments
        if filterUrgentOnly {
            list = list.filter { $0.isDeadlineUrgent || $0.isOverdue }
        }
        switch sortOption {
        case .newest:
            return list.sorted { $0.documentDate > $1.documentDate }
        case .oldest:
            return list.sorted { $0.documentDate < $1.documentDate }
        case .highestAmount:
            return list.sorted { ($0.amount ?? 0) > ($1.amount ?? 0) }
        case .urgentDeadline:
            return list.sorted { ($0.dueDate ?? Date.distantFuture) < ($1.dueDate ?? Date.distantFuture) }
        }
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // ── KPI Dashboard Cards ────────────────────────────────
                kpiDashboard

                // ── Search & Mode Switcher Bar ─────────────────────────
                searchAndFilterBar

                // ── Category Pills (Horizontal with Counts) ────────────
                categoryPillsSection

                // ── Urgent Deadlines Banner (if any) ───────────────────
                if !service.urgentDocuments.isEmpty && !filterUrgentOnly {
                    urgentDeadlinesSection
                }

                // ── Document List / Grid ───────────────────────────────
                documentContentSection
            }
            .padding(.vertical, 14)
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

    // ── KPI Header ─────────────────────────────────────────────────────

    private var kpiDashboard: some View {
        HStack(spacing: 10) {
            // Belege gesamt
            statCard(
                title: "Belege",
                value: "\(service.documents.count)",
                icon: "doc.text.fill",
                color: Theme.primaryAccent,
                isSelected: !filterUrgentOnly && service.selectedCategory == nil
            ) {
                withAnimation(.spring(response: 0.3)) {
                    filterUrgentOnly = false
                    service.selectedCategory = nil
                }
            }

            // Fristen
            let urgentCount = service.urgentDocuments.count
            statCard(
                title: "Fristen",
                value: "\(urgentCount)",
                icon: "alarm.waves.left.and.right.fill",
                color: urgentCount > 0 ? .orange : .green,
                isSelected: filterUrgentOnly
            ) {
                withAnimation(.spring(response: 0.3)) {
                    filterUrgentOnly.toggle()
                }
            }

            // Gesamtwert
            statCard(
                title: "Gesamtwert",
                value: service.totalAmountSum > 0 ? service.totalAmountSum.formatted(.currency(code: "EUR")) : "0 €",
                icon: "eurosign.circle.fill",
                color: .teal,
                isSelected: false
            ) {}
        }
        .padding(.horizontal, 16)
    }

    private func statCard(title: String, value: String, icon: String, color: Color, isSelected: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(color)
                    Spacer()
                    if isSelected {
                        Circle()
                            .fill(color)
                            .frame(width: 6, height: 6)
                    }
                }
                Text(value)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.12 : 0.04))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(color.opacity(0.6)) : AnyShapeStyle(Theme.glassEdgeGradient), lineWidth: isSelected ? 1.2 : 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    // ── Search & Mode Bar ──────────────────────────────────────────────

    private var searchAndFilterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Titel, Absender, OCR-Text…", text: $service.searchText)
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
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.glassEdgeGradient, lineWidth: 0.8)
            }

            // Grid / List Toggle
            Button {
                withAnimation(.spring(response: 0.35)) {
                    isGridView.toggle()
                }
            } label: {
                Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryAccent)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.glassEdgeGradient, lineWidth: 0.8)
                    }
            }

            // Sort Menu
            Menu {
                ForEach(DMSSortOption.allCases) { opt in
                    Button {
                        sortOption = opt
                    } label: {
                        HStack {
                            Text(opt.rawValue)
                            if sortOption == opt { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryAccent)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.glassEdgeGradient, lineWidth: 0.8)
                    }
            }
        }
        .padding(.horizontal, 16)
    }

    // ── Urgent Deadlines Section ───────────────────────────────────────

    private var urgentDeadlinesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "alarm.waves.left.and.right.fill")
                    .foregroundStyle(.red)
                Text("Fristen-Radar (\(service.urgentDocuments.count))")
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                Spacer()
            }

            ForEach(service.urgentDocuments.prefix(2)) { doc in
                Button {
                    selectedDocument = doc
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(doc.isOverdue ? Color.red : Color.orange)
                            .frame(width: 8, height: 8)

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
                    .padding(8)
                    .background((doc.isOverdue ? Color.red : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: 16)
        .padding(.horizontal, 16)
    }

    // ── Category Pills with Counts ─────────────────────────────────────

    private var categoryPillsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryPill(
                    title: "Alle",
                    count: service.documents.count,
                    icon: "tray.full.fill",
                    isSelected: service.selectedCategory == nil && !filterUrgentOnly
                ) {
                    withAnimation(.spring(response: 0.3)) {
                        service.selectedCategory = nil
                        filterUrgentOnly = false
                    }
                }

                ForEach(DocumentCategory.allCases) { cat in
                    let c = service.categoryCount(cat)
                    categoryPill(
                        title: cat.rawValue,
                        count: c,
                        icon: cat.icon,
                        isSelected: service.selectedCategory == cat
                    ) {
                        withAnimation(.spring(response: 0.3)) {
                            service.selectedCategory = (service.selectedCategory == cat) ? nil : cat
                            filterUrgentOnly = false
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func categoryPill(title: String, count: Int, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.25) : Color.white.opacity(0.1), in: Capsule())
                }
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

    // ── Document Content (Grid vs List) ────────────────────────────────

    @ViewBuilder
    private var documentContentSection: some View {
        if sortedDocuments.isEmpty {
            emptyStateView
        } else if isGridView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(sortedDocuments) { doc in
                    DocumentGridCard(document: doc) {
                        selectedDocument = doc
                    }
                }
            }
            .padding(.horizontal, 16)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(sortedDocuments) { doc in
                    DocumentCardRow(document: doc) {
                        selectedDocument = doc
                    }
                }
            }
            .padding(.horizontal, 16)
        }
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
// MARK: - 6. Document Viewer Components & DocumentDetailView
// =============================================================================

// MARK: - PDFKit Wrapper
public struct PDFKitRepresentedView: UIViewRepresentable {
    public let url: URL?
    public let data: Data?

    public init(url: URL? = nil, data: Data? = nil) {
        self.url = url
        self.data = data
    }

    public func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .clear
        if let url = url {
            pdfView.document = PDFDocument(url: url)
        } else if let data = data {
            pdfView.document = PDFDocument(data: data)
        }
        return pdfView
    }

    public func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document == nil {
            if let url = url {
                uiView.document = PDFDocument(url: url)
            } else if let data = data {
                uiView.document = PDFDocument(data: data)
            }
        }
    }
}

// MARK: - Native Zoomable Scroll View
public struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    private var content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4.0
        scrollView.minimumZoomScale = 1.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let hostedView = context.coordinator.hostingController.view!
        hostedView.translatesAutoresizingMaskIntoConstraints = true
        hostedView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostedView.frame = scrollView.bounds
        hostedView.backgroundColor = .clear
        scrollView.addSubview(hostedView)

        return scrollView
    }

    public func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.hostingController.rootView = content
        context.coordinator.hostingController.view.layoutIfNeeded()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(hostingController: UIHostingController(rootView: content))
    }

    public class Coordinator: NSObject, UIScrollViewDelegate {
        var hostingController: UIHostingController<Content>

        init(hostingController: UIHostingController<Content>) {
            self.hostingController = hostingController
        }

        public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return hostingController.view
        }
    }
}

// MARK: - Photorealistic DIN A4 Document Letter View
public struct DocumentLetterPaperView: View {
    public let document: AppDocument
    public var isInteractive: Bool = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: Aussteller / Absender & Belegdatum
            HStack(alignment: .top) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(document.category.color.opacity(0.18))
                            .frame(width: 44, height: 44)
                        Image(systemName: document.category.icon)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(document.category.color)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.sender ?? "Digitales Belegdokument")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.88))
                            .lineLimit(1)
                        Text(document.category.rawValue.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(document.category.color)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(document.documentDate.formatted(date: .numeric, time: .omitted))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.black.opacity(0.75))
                    Text("Belegdatum")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.45))
                }
            }

            Rectangle()
                .fill(Color.black.opacity(0.12))
                .frame(height: 1)

            // Anschrift & Aktenzeichen
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("EMPFÄNGER:")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.45))
                    Text("Vertraulich / Digitales Büro")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.85))
                }
                Spacer()
                if let fn = document.fileNumber {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("AKTENZEICHEN / BELEG-NR:")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.45))
                        Text(fn)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.black.opacity(0.88))
                    }
                }
            }
            .padding(.vertical, 2)

            // Betreffzeile
            VStack(alignment: .leading, spacing: 4) {
                Text("BETREFF")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.45))
                Text(document.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.95))
            }

            // Betrag falls vorhanden
            if let amt = document.amount {
                HStack {
                    Image(systemName: "eurosign.circle.fill")
                        .foregroundStyle(Color.green)
                        .font(.system(size: 16))
                    Text("Ausgewiesener Betrag:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.65))
                    Spacer()
                    Text(amt.formatted(.currency(code: "EUR")))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.92))
                }
                .padding(10)
                .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }

            // Belegtext / OCR
            VStack(alignment: .leading, spacing: 6) {
                Text("DOKUMENTEN-INHALT:")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.45))

                if let ocr = document.ocrText, !ocr.isEmpty {
                    Text(ocr)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.black.opacity(0.82))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Zu diesem Beleg liegt kein gesonderter Text vor. Alle relevanten Metadaten wurden für dich im Archiv gesichert.")
                        .font(.system(size: 11, weight: .regular))
                        .italic()
                        .foregroundStyle(Color.black.opacity(0.55))
                }

                if let notes = document.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NOTIZEN:")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.45))
                        Text(notes)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.black.opacity(0.78))
                    }
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 12)

            // Footer & Amtlicher Statusstempel
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Digitales Büro DMS · Belegprüfung")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.45))
                    Text("ID: #\(document.id.uuidString.prefix(8).uppercased())")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.black.opacity(0.35))
                }

                Spacer()

                // Tilted Stamp
                Text(document.status.stampText)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(document.status.stampColor)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(document.status.stampColor, style: StrokeStyle(lineWidth: 1.8, dash: [4, 2]))
                    )
                    .rotationEffect(.degrees(-9))
            }
        }
        .padding(18)
        .background(Color.white)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.2), radius: 12, x: 0, y: 6)
    }
}

extension DocumentStatus {
    var stampText: String {
        switch self {
        case .inbox: return "EINGEGANGEN"
        case .inProgress: return "IN BEARBEITUNG"
        case .deadlineSet: return "FRIST BELEGT"
        case .completed: return "ERLEDIGT"
        case .archived: return "ARCHIVIERT"
        }
    }
    var stampColor: Color {
        switch self {
        case .inbox: return .blue
        case .inProgress: return .orange
        case .deadlineSet: return .red
        case .completed: return .green
        case .archived: return .gray
        }
    }
}

// MARK: - DocumentVisualViewer (Preview in DetailView)
public struct DocumentVisualViewer: View {
    public let document: AppDocument
    public var onExpand: () -> Void

    public var body: some View {
        Button(action: onExpand) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let localURL = document.localFileURL {
                        if document.fileType == .pdf {
                            PDFKitRepresentedView(url: localURL)
                                .disabled(true)
                        } else if let img = UIImage(contentsOfFile: localURL.path) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.black.opacity(0.4))
                        } else {
                            DocumentLetterPaperView(document: document)
                        }
                    } else {
                        DocumentLetterPaperView(document: document)
                    }
                }

                // Vollbild Indikator
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                    Text("Vollbild")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8) }
                .padding(10)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FullScreenDocumentViewer
public struct FullScreenDocumentViewer: View {
    public let document: AppDocument
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet: Bool = false
    @State private var copiedText: Bool = false

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                Group {
                    if let localURL = document.localFileURL {
                        if document.fileType == .pdf {
                            PDFKitRepresentedView(url: localURL)
                        } else if let img = UIImage(contentsOfFile: localURL.path) {
                            ZoomableScrollView {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFit()
                            }
                        } else {
                            letterDocumentView
                        }
                    } else {
                        letterDocumentView
                    }
                }
            }
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 14) {
                        if let ocr = document.ocrText, !ocr.isEmpty {
                            Button {
                                UIPasteboard.general.string = ocr
                                copiedText = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedText = false }
                            } label: {
                                Image(systemName: copiedText ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(copiedText ? .green : .white)
                            }
                        }

                        Button {
                            showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.white)
                        }

                        Button {
                            printCurrentDocument()
                        } label: {
                            Image(systemName: "printer")
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let localURL = document.localFileURL {
                    ShareSheet(items: [localURL])
                } else if let ocr = document.ocrText, !ocr.isEmpty {
                    ShareSheet(items: ["\(document.title)\n\n\(ocr)"])
                } else {
                    ShareSheet(items: ["\(document.title)\nAbsender: \(document.sender ?? "-")\nAktenzeichen: \(document.fileNumber ?? "-")"])
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var letterDocumentView: some View {
        ScrollView([.vertical, .horizontal], showsIndicators: true) {
            DocumentLetterPaperView(document: document, isInteractive: true)
                .frame(maxWidth: 550)
                .padding(24)
        }
    }

    private func printCurrentDocument() {
        let printController = UIPrintInteractionController.shared
        let printInfo = UIPrintInfo(dictionary: nil)
        printInfo.outputType = .general
        printInfo.jobName = document.title
        printController.printInfo = printInfo
        if let url = document.localFileURL {
            printController.printingItem = url
        } else if let ocr = document.ocrText {
            let html = "<html><body style='font-family:sans-serif;padding:20px;'><h2>\(document.title)</h2><p><b>Absender:</b> \(document.sender ?? "-")</p><p><b>Aktenzeichen:</b> \(document.fileNumber ?? "-")</p><hr/><pre style='white-space:pre-wrap;font-size:12pt;'>\(ocr)</pre></body></html>"
            printController.printFormatter = UIMarkupTextPrintFormatter(markupText: html)
        }
        printController.present(animated: true, completionHandler: nil)
    }
}

// MARK: - EditDocumentSheet
public struct EditDocumentSheet: View {
    public let document: AppDocument
    @ObservedObject public var service: DocumentArchiveService
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var category: DocumentCategory
    @State private var status: DocumentStatus
    @State private var sender: String
    @State private var fileNumber: String
    @State private var amountString: String
    @State private var documentDate: Date
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var tagsString: String
    @State private var notes: String
    @State private var isSaving: Bool = false

    public init(document: AppDocument, service: DocumentArchiveService) {
        self.document = document
        self.service = service
        _title = State(initialValue: document.title)
        _category = State(initialValue: document.category)
        _status = State(initialValue: document.status)
        _sender = State(initialValue: document.sender ?? "")
        _fileNumber = State(initialValue: document.fileNumber ?? "")
        if let amt = document.amount {
            _amountString = State(initialValue: "\(amt)".replacingOccurrences(of: ".", with: ","))
        } else {
            _amountString = State(initialValue: "")
        }
        _documentDate = State(initialValue: document.documentDate)
        _hasDueDate = State(initialValue: document.dueDate != nil)
        _dueDate = State(initialValue: document.dueDate ?? Calendar.current.date(byAdding: .day, value: 14, to: Date())!)
        _tagsString = State(initialValue: document.tags.joined(separator: ", "))
        _notes = State(initialValue: document.notes ?? "")
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        // Section: Titel & Status
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Titel & Bearbeitungsstatus")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Titel des Dokuments")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("z. B. Rezept: Ibuprofen 600mg", text: $title)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }

                            // Smart Naming Button
                            if let ocr = document.ocrText, !ocr.isEmpty {
                                Button {
                                    let smartName = DocumentAutoExtractionEngine.generateSmartDocumentTitle(ocrText: ocr, category: category, sender: sender.isEmpty ? nil : sender)
                                    withAnimation {
                                        title = smartName
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "sparkles")
                                        Text("Titel aus Belegtext automatisch optimieren")
                                    }
                                    .font(.caption.bold())
                                    .foregroundStyle(Theme.primaryAccent)
                                }
                            }

                            // Status
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Bearbeitungsstatus")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(DocumentStatus.allCases) { st in
                                            Button {
                                                status = st
                                            } label: {
                                                HStack(spacing: 5) {
                                                    Image(systemName: st.icon)
                                                        .font(.system(size: 11))
                                                    Text(st.rawValue)
                                                        .font(.caption2.bold())
                                                }
                                                .padding(.horizontal, 10).padding(.vertical, 7)
                                                .background(status == st ? st.color.opacity(0.25) : Color.white.opacity(0.05), in: Capsule())
                                                .overlay {
                                                    Capsule().strokeBorder(status == st ? st.color : Color.clear, lineWidth: 1)
                                                }
                                                .foregroundStyle(status == st ? st.color : .secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }

                            // Kategorie
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Kategorie")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(DocumentCategory.allCases) { cat in
                                            Button {
                                                category = cat
                                            } label: {
                                                HStack(spacing: 5) {
                                                    Image(systemName: cat.icon)
                                                        .font(.system(size: 12))
                                                    Text(cat.rawValue)
                                                        .font(.caption.weight(.medium))
                                                }
                                                .padding(.horizontal, 12).padding(.vertical, 7)
                                                .background(category == cat ? Theme.primaryGradient : LinearGradient(colors: [Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom), in: Capsule())
                                                .foregroundStyle(category == cat ? .white : .primary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 18)

                        // Section: Absender & Betrag
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Absender & Betrag")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Absender / Firma / Arzt")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("z. B. Dr. Weber oder Stadtwerke", text: $sender)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Aktenzeichen / Rechnungs-Nr.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("z. B. AZ-2024-8841", text: $fileNumber)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Betrag in €")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("0,00", text: $amountString)
                                    .keyboardType(.numbersAndPunctuation)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 18)

                        // Section: Datum & Frist
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Datum & Frist")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            DatePicker("Belegdatum", selection: $documentDate, displayedComponents: .date)
                                .font(.subheadline)

                            Toggle("Frist / Wiedervorlage aktivieren", isOn: $hasDueDate)
                                .font(.subheadline)
                                .tint(Theme.primaryAccent)

                            if hasDueDate {
                                DatePicker("Fälligkeitsdatum", selection: $dueDate, displayedComponents: .date)
                                    .font(.subheadline)
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 18)

                        // Section: Schlagwörter & Notizen
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Schlagwörter & Notizen")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Schlagwörter (mit Komma getrennt)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("Rezept, Apotheke, Wichtig", text: $tagsString)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Notizen & Bemerkungen")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("Zusatzangaben...", text: $notes, axis: .vertical)
                                    .lineLimit(3...6)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 18)

                        // Save Button
                        Button {
                            saveChanges()
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.headline)
                                Text("Änderungen speichern")
                                    .font(.headline)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Theme.primaryGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: Theme.primaryAccent.opacity(0.4), radius: 10, y: 4)
                        }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Dokument bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { saveChanges() }
                        .bold()
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func saveChanges() {
        isSaving = true
        var updated = document
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.category = category
        updated.status = status
        updated.sender = sender.trimmingCharacters(in: .whitespaces).isEmpty ? nil : sender.trimmingCharacters(in: .whitespaces)
        updated.fileNumber = fileNumber.trimmingCharacters(in: .whitespaces).isEmpty ? nil : fileNumber.trimmingCharacters(in: .whitespaces)
        let amt = Decimal(string: amountString.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        updated.amount = amt
        updated.documentDate = documentDate
        updated.dueDate = hasDueDate ? dueDate : nil
        updated.tags = tagsString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        updated.notes = notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes.trimmingCharacters(in: .whitespaces)
        service.updateDocument(updated)
        dismiss()
    }
}

// MARK: - DocumentDetailView
public struct DocumentDetailView: View {
    public let document: AppDocument
    @ObservedObject public var service: DocumentArchiveService
    @Environment(\.dismiss) private var dismiss

    @State private var showOCRDrawer:        Bool = false
    @State private var isCopied:             Bool = false
    @State private var showFullScreenViewer: Bool = false
    @State private var showEditSheet:        Bool = false
    @State private var showAIChat:           Bool = false

    public var currentDoc: AppDocument {
        service.documents.first(where: { $0.id == document.id }) ?? document
    }

    public var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    documentVisualCard
                    metadataSection
                    deadlineSection
                    if let ocr = currentDoc.ocrText, !ocr.isEmpty {
                        ocrTextSection(ocr)
                    }
                    tagsAndNotesSection
                    actionButtonsSection
                }
                .padding(16)
            }
        }
        .navigationTitle(currentDoc.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showEditSheet = true
                } label: {
                    Label("Bearbeiten", systemImage: "pencil")
                        .font(.subheadline.bold())
                }
                .tint(Theme.primaryAccent)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { dismiss() }
                    .font(.subheadline.bold())
            }
        }
        .sheet(isPresented: $showEditSheet) {
            EditDocumentSheet(document: currentDoc, service: service)
        }
        .sheet(isPresented: $showFullScreenViewer) {
            FullScreenDocumentViewer(document: currentDoc)
        }
        .sheet(isPresented: $showAIChat) {
            AIChatSheet(initialPrompt: buildAIPrompt())
        }
    }

    private func buildAIPrompt() -> String {
        var parts: [String] = []
        parts.append("Analysiere bitte folgendes Dokument und berate mich dazu:")
        parts.append("• Titel: \(currentDoc.title)")
        parts.append("• Kategorie: \(currentDoc.category.rawValue)")
        if let sender = currentDoc.sender {
            parts.append("• Absender: \(sender)")
        }
        if let fn = currentDoc.fileNumber {
            parts.append("• Aktenzeichen: \(fn)")
        }
        if let amt = currentDoc.amount {
            parts.append("• Betrag: \(amt.formatted(.currency(code: "EUR")))")
        }
        if let due = currentDoc.dueDate {
            parts.append("• Frist: \(due.formatted(date: .numeric, time: .omitted))")
        }
        if let ocr = currentDoc.ocrText, !ocr.isEmpty {
            parts.append("\nErkannter Belegtext / OCR:\n\(ocr)")
        }
        parts.append("\nFrage: Gibt es Fristen, Zahlungsaufforderungen oder konkrete Handlungsempfehlungen für mich?")
        return parts.joined(separator: "\n")
    }

    private var documentVisualCard: some View {
        VStack(spacing: 12) {
            HStack {
                Label(currentDoc.fileType == .pdf ? "PDF-Dokument" : "Dokumenten-Vorschau", systemImage: currentDoc.fileType.icon)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showFullScreenViewer = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text("Vollbild")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(Theme.primaryAccent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.primaryAccent.opacity(0.12), in: Capsule())
                }
            }

            DocumentVisualViewer(document: currentDoc, onExpand: {
                showFullScreenViewer = true
            })
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.glassEdgeGradient, lineWidth: 1)
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 18)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hauptdaten")
                .font(.headline)

            detailRow("Kategorie", value: currentDoc.category.rawValue, icon: currentDoc.category.icon, color: currentDoc.category.color)
            if let sender = currentDoc.sender {
                detailRow("Absender / Firma", value: sender, icon: "person.crop.circle", color: .blue)
            }
            if let fn = currentDoc.fileNumber {
                detailRow("Aktenzeichen / Nr.", value: fn, icon: "number", color: .purple)
            }
            if let amt = currentDoc.amount {
                detailRow("Betrag", value: amt.formatted(.currency(code: "EUR")), icon: "eurosign.circle.fill", color: .green)
            }
            detailRow("Belegdatum", value: currentDoc.documentDate.formatted(date: .long, time: .omitted), icon: "calendar", color: .teal)
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
                if currentDoc.dueDate != nil {
                    Text(currentDoc.isOverdue ? "Abgelaufen" : "Aktiv")
                        .font(.caption2.bold())
                        .foregroundStyle(currentDoc.isOverdue ? Color.red : Color.green)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((currentDoc.isOverdue ? Color.red : Color.green).opacity(0.12), in: Capsule())
                }
            }

            if let due = currentDoc.dueDate {
                HStack {
                    Text("Fälligkeitsdatum:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(due.formatted(date: .long, time: .omitted))
                        .bold()
                        .foregroundStyle(currentDoc.isOverdue ? Color.red : (currentDoc.isDeadlineUrgent ? Color.orange : Color.primary))
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

            if !currentDoc.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(currentDoc.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2.bold())
                            .foregroundStyle(Theme.primaryAccent)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.primaryAccent.opacity(0.12), in: Capsule())
                    }
                }
            }

            if let notes = currentDoc.notes, !notes.isEmpty {
                Text(notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 18)
    }

    private var actionButtonsSection: some View {
        VStack(spacing: 12) {
            // Vollbild öffnen
            Button {
                showFullScreenViewer = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 16, weight: .bold))
                    Text("Dokument im Vollbild öffnen")
                        .font(.subheadline.bold())
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.glassEdgeGradient, lineWidth: 1)
                }
            }

            // Dokument bearbeiten
            Button {
                showEditSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.system(size: 16, weight: .bold))
                    Text("Dokument bearbeiten")
                        .font(.subheadline.bold())
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.glassEdgeGradient, lineWidth: 1)
                }
            }

            // Mit KI analysieren & beraten
            Button {
                showAIChat = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .bold))
                    Text("Mit KI analysieren & beraten")
                        .font(.subheadline.bold())
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.primaryGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Theme.primaryAccent.opacity(0.35), radius: 8, y: 3)
            }

            // Status ändern
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
                    Label("Status: \(currentDoc.status.rawValue)", systemImage: currentDoc.status.icon)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }
                .font(.subheadline.bold())
                .padding()
                .background(currentDoc.status.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(currentDoc.status.color)
            }

            // Löschen
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
// MARK: - 7. Modern AddDocumentSheet (Liquid Glass Studio)
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
    @State private var showCameraPicker:  Bool     = false
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
            ZStack {
                Theme.appBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Header
                        VStack(spacing: 6) {
                            Image(systemName: "doc.badge.plus")
                                .font(.system(size: 38, weight: .bold))
                                .foregroundStyle(Theme.primaryGradient)

                            Text("Neues Dokument erfassen")
                                .font(.title3.bold())
                                .foregroundStyle(.primary)

                            Text("Scan, Foto oder PDF hochladen – Daten werden automatisch ausgelesen.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                        .padding(.top, 4)

                        // Hero Upload Buttons
                        HStack(spacing: 12) {
                            uploadTile(title: "Kamera", icon: "camera.fill", color: Theme.primaryAccent) {
                                showCameraPicker = true
                            }
                            uploadTile(title: "Mediathek", icon: "photo.on.rectangle.angled", color: .purple) {
                                showImagePicker = true
                            }
                            uploadTile(title: "PDF Datei", icon: "doc.fill", color: .teal) {
                                showFilePicker = true
                            }
                        }

                        // Analyse-Status-Banner
                        if isAnalyzing {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .tint(Theme.primaryAccent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("KI analysiert Beleg…")
                                        .font(.caption.bold())
                                        .foregroundStyle(.primary)
                                    Text("Lese Absender, Aktenzeichen, Betrag & Frist aus")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(14)
                            .background(Theme.primaryAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(Theme.primaryAccent.opacity(0.3), lineWidth: 1)
                            }
                        } else if hasAutoFilled {
                            HStack(spacing: 10) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Hauptdaten & Titel automatisch erkannt!")
                                        .font(.caption.bold())
                                        .foregroundStyle(.green)
                                    Text("Der Beleg wurde präzise benannt und vorkategorisiert.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(14)
                            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(Color.green.opacity(0.3), lineWidth: 1)
                            }
                        }

                        // Angehängte Datei Vorschau
                        if let name = selectedFileName {
                            HStack(spacing: 12) {
                                if let imgData = selectedImageData, let uiImg = UIImage(data: imgData) {
                                    Image(uiImage: uiImg)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Theme.primaryAccent.opacity(0.2))
                                            .frame(width: 44, height: 44)
                                        Image(systemName: selectedPDFData != nil ? "doc.richtext.fill" : "photo.fill")
                                            .foregroundStyle(Theme.primaryAccent)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name)
                                        .font(.caption.bold())
                                        .lineLimit(1)
                                    Text(selectedPDFData != nil ? "PDF-Dokument angehängt" : "Scan-Bild angehängt")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    withAnimation {
                                        selectedImageData = nil
                                        selectedPDFData   = nil
                                        selectedFileName  = nil
                                        hasAutoFilled     = false
                                    }
                                } label: {
                                    Image(systemName: "trash.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.red)
                                }
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        }

                        // Card: Titel & Kategorie
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Titel & Kategorie")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Dokumententitel")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("z. B. Rezept: Ibuprofen 600mg oder Stromrechnung", text: $title)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Kategorie")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(DocumentCategory.allCases) { cat in
                                            Button {
                                                category = cat
                                            } label: {
                                                HStack(spacing: 5) {
                                                    Image(systemName: cat.icon)
                                                        .font(.system(size: 12))
                                                    Text(cat.rawValue)
                                                        .font(.caption.weight(.medium))
                                                }
                                                .padding(.horizontal, 12).padding(.vertical, 7)
                                                .background(category == cat ? Theme.primaryGradient : LinearGradient(colors: [Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom), in: Capsule())
                                                .foregroundStyle(category == cat ? .white : .primary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 18)

                        // Card: Absender & Aktenzeichen
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Erkannte Daten & Absender")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Absender / Firma / Arzt")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("z. B. Dr. Schmidt oder Stadtwerke", text: $sender)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Aktenzeichen / Rechnungs-Nr.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("z. B. AZ-2024-8841", text: $fileNumber)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Betrag in € (optional)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("0,00", text: $amountString)
                                    .keyboardType(.numbersAndPunctuation)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 18)

                        // Card: Belegdatum & Fristen
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Datum & Fristen")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            DatePicker("Belegdatum", selection: $documentDate, displayedComponents: .date)
                                .font(.subheadline)

                            Toggle("Frist / Wiedervorlage setzen", isOn: $hasDueDate)
                                .font(.subheadline)
                                .tint(Theme.primaryAccent)

                            if hasDueDate {
                                DatePicker("Fälligkeitsdatum", selection: $dueDate, displayedComponents: .date)
                                    .font(.subheadline)
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 18)

                        // Card: Notizen & Tags
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Zusatzangaben")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Schlagwörter (Kommagetrennt)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("Auto, Mahnung, Wichtig", text: $tagsString)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Notizen")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("Zusatzangaben...", text: $notes, axis: .vertical)
                                    .lineLimit(2...4)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 18)

                        // Big Glow Speichern Button
                        Button {
                            save()
                        } label: {
                            HStack(spacing: 8) {
                                if isUploading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "arrow.down.doc.fill")
                                }
                                Text(isUploading ? "Wird gespeichert…" : "Dokument im Archiv sichern")
                                    .font(.headline)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                title.trimmingCharacters(in: .whitespaces).isEmpty || isUploading || isAnalyzing
                                    ? LinearGradient(colors: [Color.gray.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                                    : Theme.primaryGradient,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                            .shadow(color: title.isEmpty ? Color.clear : Theme.primaryAccent.opacity(0.4), radius: 10, y: 4)
                        }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isUploading || isAnalyzing)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                    }
                    .padding(16)
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
                        .bold()
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isUploading || isAnalyzing)
                }
            }
            .sheet(isPresented: $showCameraPicker) {
                DocumentImagePicker(sourceType: .camera) { img in
                    handlePickedImage(img)
                }
            }
            .sheet(isPresented: $showImagePicker) {
                DocumentImagePicker(sourceType: .photoLibrary) { img in
                    handlePickedImage(img)
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

    private func uploadTile(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.2))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.glassEdgeGradient, lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private func handlePickedImage(_ img: UIImage?) {
        guard let image = img, let data = image.jpegData(compressionQuality: 0.82) else { return }
        selectedImageData = data
        selectedPDFData   = nil
        selectedFileName  = "Scan_\(Date().formatted(date: .numeric, time: .omitted)).jpg"
        runAutoExtraction(image: image, rawData: data)
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
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isUploading = true

        let amt = Decimal(string: amountString.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        let tags = tagsString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        Task {
            if let pdfData = selectedPDFData {
                _ = try? await service.uploadAndAdd(
                    title:        title.trimmingCharacters(in: .whitespacesAndNewlines),
                    category:     category,
                    data:         pdfData,
                    fileType:     .pdf,
                    sender:       sender.trimmingCharacters(in: .whitespaces).isEmpty ? nil : sender.trimmingCharacters(in: .whitespaces),
                    fileNumber:   fileNumber.trimmingCharacters(in: .whitespaces).isEmpty ? nil : fileNumber.trimmingCharacters(in: .whitespaces),
                    amount:       amt,
                    documentDate: documentDate,
                    dueDate:      hasDueDate ? dueDate : nil,
                    ocrText:      extractedOCRText,
                    tags:         tags,
                    notes:        notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes.trimmingCharacters(in: .whitespaces)
                )
            } else if let imgData = selectedImageData {
                _ = try? await service.uploadAndAdd(
                    title:        title.trimmingCharacters(in: .whitespacesAndNewlines),
                    category:     category,
                    data:         imgData,
                    fileType:     .image,
                    sender:       sender.trimmingCharacters(in: .whitespaces).isEmpty ? nil : sender.trimmingCharacters(in: .whitespaces),
                    fileNumber:   fileNumber.trimmingCharacters(in: .whitespaces).isEmpty ? nil : fileNumber.trimmingCharacters(in: .whitespaces),
                    amount:       amt,
                    documentDate: documentDate,
                    dueDate:      hasDueDate ? dueDate : nil,
                    ocrText:      extractedOCRText,
                    tags:         tags,
                    notes:        notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes.trimmingCharacters(in: .whitespaces)
                )
            } else {
                let doc = AppDocument(
                    userId:       service.userId,
                    title:        title.trimmingCharacters(in: .whitespacesAndNewlines),
                    category:     category,
                    documentDate: documentDate,
                    dueDate:      hasDueDate ? dueDate : nil,
                    sender:       sender.trimmingCharacters(in: .whitespaces).isEmpty ? nil : sender.trimmingCharacters(in: .whitespaces),
                    fileNumber:   fileNumber.trimmingCharacters(in: .whitespaces).isEmpty ? nil : fileNumber.trimmingCharacters(in: .whitespaces),
                    amount:       amt,
                    fileType:     .image,
                    ocrText:      extractedOCRText,
                    tags:         tags,
                    status:       hasDueDate ? .deadlineSet : .inbox,
                    notes:        notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes.trimmingCharacters(in: .whitespaces)
                )
                await service.addDocument(doc)
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

struct DocumentImagePicker: UIViewControllerRepresentable {
    var sourceType: UIImagePickerController.SourceType = .photoLibrary
    var onPick: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(sourceType) {
            picker.sourceType = sourceType
        } else {
            picker.sourceType = .photoLibrary
        }
        picker.delegate = context.coordinator
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

struct DocumentFilePicker: UIViewControllerRepresentable {
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

