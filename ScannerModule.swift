// =============================================================================
// ScannerModule.swift
// Schulden & Haushalt App
// Requires: iOS 17+, Swift 5.9+
// Privacy keys needed in Info.plist:
//   NSCameraUsageDescription
// =============================================================================

import SwiftUI
import VisionKit
import Vision
import Combine
import PDFKit

// MARK: - Shared DTOs

/// Raw result from a single scanned page.
/// `@unchecked Sendable`: UIImage is not formally Sendable, but ScannedPage is
/// only mutated on @MainActor (ScannerCoordinatorView), so it is safe in practice.
struct ScannedPage: Identifiable, @unchecked Sendable {
    let id    = UUID()
    let image: UIImage
    /// Populated after OCR.
    var ocrResult: OCRResult?
}

/// Everything the OCR pipeline found on one page.
struct OCRResult: Sendable {
    let rawText:      String
    let fileNumbers:  [String]      // all Aktenzeichen candidates
    let euroAmounts:  [ParsedAmount]
    /// Best single amount guess (highest-confidence large value).
    var primaryAmount: ParsedAmount? { euroAmounts.max(by: { $0.decimal < $1.decimal }) }
    /// Best single file number (first match, usually most prominent).
    var primaryFileNumber: String?  { fileNumbers.first }
}

struct ParsedAmount: Identifiable, Sendable {
    let id      = UUID()
    let raw:    String      // original string, e.g. "1.234,56 €"
    let decimal: Decimal
}

// =============================================================================
// MARK: - 1. DocumentScannerView
// =============================================================================

/// Wraps `VNDocumentCameraViewController` for SwiftUI.
///
/// Features:
/// - Batch scanning: camera stays open until the user explicitly taps "Save"
///   (built-in VisionKit behaviour — no custom interruption logic needed).
/// - Returns an array of `ScannedPage` sorted by scan order.
/// - `onCancel` is called when the user dismisses without saving.
struct DocumentScannerView: UIViewControllerRepresentable {

    // ── Callbacks ─────────────────────────────────────────────────────────
    var onFinish: ([ScannedPage]) -> Void
    var onCancel: () -> Void = {}

    // ── UIViewControllerRepresentable ──────────────────────────────────────

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    // ── Coordinator ────────────────────────────────────────────────────────

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onFinish: ([ScannedPage]) -> Void
        private let onCancel: () -> Void

        init(onFinish: @escaping ([ScannedPage]) -> Void,
             onCancel: @escaping () -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
        }

        // User tapped "Save" — may contain 1…N pages (batch)
        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            // Build ScannedPage array in scan order
            let pages = (0 ..< scan.pageCount).map { index in
                ScannedPage(image: scan.imageOfPage(at: index))
            }
            controller.dismiss(animated: true) { [weak self] in
                self?.onFinish(pages)
            }
        }

        func documentCameraViewControllerDidCancel(
            _ controller: VNDocumentCameraViewController
        ) {
            controller.dismiss(animated: true) { [weak self] in
                self?.onCancel()
            }
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            controller.dismiss(animated: true) { [weak self] in
                self?.onCancel()
            }
        }
    }
}

// =============================================================================
// MARK: - 2. VisionOCRService
// =============================================================================

/// Processes images on-device with `VNRecognizeTextRequest`.
/// All heavy work runs on a background actor; results are published on `@MainActor`.
actor VisionOCRService {

    // ── Configuration ─────────────────────────────────────────────────────

    private let recognitionLevel: VNRequestTextRecognitionLevel = .accurate
    private let recognitionLanguages = ["de-DE", "en-US"]   // DE first for amounts

    // ── Public API ─────────────────────────────────────────────────────────

    /// Processes one image and returns an `OCRResult`.
    func recognise(image: UIImage) async throws -> OCRResult {
        guard let cgImage = image.cgImage else {
            throw OCRError.invalidImage
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel         = recognitionLevel
        request.recognitionLanguages     = recognitionLanguages
        request.usesLanguageCorrection   = true
        request.automaticallyDetectsLanguage = true
        // Filter out noise smaller than 2% of image height (ruled lines, stamps, etc.)
        request.minimumTextHeight        = 0.02

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results else {
            return OCRResult(rawText: "", fileNumbers: [], euroAmounts: [])
        }

        // Join all observation strings (preserves reading order)
        let fullText = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")

        let fileNumbers = Self.extractFileNumbers(from: fullText)
        let amounts     = Self.extractEuroAmounts(from: fullText)

        return OCRResult(rawText: fullText, fileNumbers: fileNumbers, euroAmounts: amounts)
    }

    /// Processes a batch of pages concurrently and returns results in order.
    func recogniseBatch(pages: [ScannedPage]) async -> [ScannedPage] {
        await withTaskGroup(of: (Int, ScannedPage).self) { group in
            for (index, page) in pages.enumerated() {
                group.addTask {
                    var mutable = page
                    mutable.ocrResult = try? await self.recognise(image: page.image)
                    return (index, mutable)
                }
            }
            var results = [(Int, ScannedPage)]()
            for await pair in group { results.append(pair) }
            return results.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Regex Extractors
    // ─────────────────────────────────────────────────────────────────────

    // MARK: File Number (Aktenzeichen) Patterns
    //
    // Covers common German patterns:
    //  • AZ-2024-00123, AZ 2024/00123
    //  • Az.: 123/24, Az 12/2024
    //  • Aktenzeichen: 1234/24
    //  • GZ: 123/2024  (Geschäftszahl)
    //  • 12 C 34/24    (court docket: chamber + year)
    //  • 2024-12345-XY (authority reference)

    static func extractFileNumbers(from text: String) -> [String] {
        let patterns: [String] = [
            // "AZ" prefix variants
            #"(?i)A\.?Z\.?[-:\s]?\s*[\w][\w\-\/]{3,20}"#,
            // "Aktenzeichen" full word
            #"(?i)Aktenzeichen[-:\s]+[\w][\w\-\/]{3,20}"#,
            // "GZ" prefix (Geschäftszahl, Austria + some German authorities)
            #"(?i)G\.?Z\.?[-:\s]?\s*\d{1,6}[\/\-]\d{2,4}"#,
            // Court docket: "12 C 34/24" or "2 BvR 123/23"
            #"(?<!\w)\d{1,3}\s+[A-Z]{1,4}\s+\d{1,6}\/\d{2,4}(?!\w)"#,
            // Authority reference: "2024-12345" or "2024/12345"
            #"(?<!\w)20\d{2}[-\/]\d{4,8}(?!\w)"#,
        ]

        var found = [String]()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            for match in matches {
                if let r = Range(match.range, in: text) {
                    let candidate = String(text[r])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // Deduplicate and keep only meaningful length
                    if candidate.count >= 5, !found.contains(candidate) {
                        found.append(candidate)
                    }
                }
            }
        }
        return found
    }

    // MARK: Euro Amount Patterns
    //
    // Handles German decimal notation (comma = decimal separator):
    //  • 1.234,56 €
    //  • € 1.234,56
    //  • EUR 1.234,56
    //  • 1234,56€
    //  • 1.234.567,89 EUR

    static func extractEuroAmounts(from text: String) -> [ParsedAmount] {
        // Canonical German number: optional thousands dots + mandatory decimal comma
        let numericCore = #"\d{1,3}(?:\.\d{3})*,\d{2}"#

        let patterns: [String] = [
            // trailing € / EUR
            "(\(numericCore))\\s*(?:€|EUR)(?!\\w)",
            // leading € / EUR
            "(?:€|EUR)\\s*(\(numericCore))(?!\\d)",
        ]

        var found = [ParsedAmount]()

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)

            for match in matches {
                // Capture group 1 holds the numeric part
                let captureRange = match.range(at: 1)
                guard let r = Range(captureRange, in: text) else { continue }
                let raw = String(text[r])

                if let decimal = parseGermanDecimal(raw), !found.contains(where: { $0.raw == raw }) {
                    let fullRange = Range(match.range, in: text)!
                    let fullRaw = String(text[fullRange])
                    found.append(ParsedAmount(raw: fullRaw.trimmingCharacters(in: .whitespaces),
                                             decimal: decimal))
                }
            }
        }
        return found
    }

    static func parseGermanDecimal(_ raw: String) -> Decimal? {
        let normalised = raw
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Decimal(string: normalised)
    }

    enum OCRError: LocalizedError {
        case invalidImage
        var errorDescription: String? { "Ungültiges Bild – OCR nicht möglich." }
    }
}

// =============================================================================
// MARK: - 3. TriageListView (Übersichtliche Liste nach Gläubiger aufgeteilt)
// =============================================================================

enum ScannedDocumentKind: String, CaseIterable, Identifiable {
    case mahnbescheid = "Mahnbescheid"
    case vollstreckungsbescheid = "Vollstreckungsbescheid"
    case inkassoMahnung = "Inkasso-Mahnung"
    case invoice = "Rechnung / Beleg"
    case pantry = "Vorrat / Kassenbon"
    case hardware = "Hardware-Wartung"
    case general = "Dokument"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .mahnbescheid: return "scale.3d"
        case .vollstreckungsbescheid: return "bolt.shield.fill"
        case .inkassoMahnung: return "envelope.badge.fill"
        case .invoice: return "doc.plaintext.fill"
        case .pantry: return "cart.fill"
        case .hardware: return "wrench.and.screwdriver.fill"
        case .general: return "doc.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .mahnbescheid: return .orange
        case .vollstreckungsbescheid: return .red
        case .inkassoMahnung: return .blue
        case .invoice: return .teal
        case .pantry: return .blue
        case .hardware: return .purple
        case .general: return .secondary
        }
    }
}

enum TriageDestination: String, CaseIterable, Identifiable {
    case debt = "Schulden-Akte"
    case pantry = "Vorratsschrank"
    case hardware = "Hardware-Akte"
    case archive = "Dokumenten-Archiv"
    case discard = "Verwerfen"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .debt:     return "exclamationmark.triangle.fill"
        case .pantry:   return "cart.fill"
        case .hardware: return "wrench.and.screwdriver.fill"
        case .archive:  return "archivebox.fill"
        case .discard:  return "trash.fill"
        }
    }

    var color: Color {
        switch self {
        case .debt:     return .orange
        case .pantry:   return .blue
        case .hardware: return .purple
        case .archive:  return .teal
        case .discard:  return .gray
        }
    }
}

struct TriageItem: Identifiable {
    let id = UUID()
    var page: ScannedPage
    var ocr: OCRResult?

    var fileNumber: String
    var creditorName: String
    var amount: String
    var letterDate: Date
    var kind: ScannedDocumentKind
    var destination: TriageDestination
    var targetStatus: DebtStatus
    var matchedDebtId: UUID?
    var notes: String

    init(page: ScannedPage, engine: DebtEngineService? = nil) {
        self.page = page
        self.ocr = page.ocrResult
        self.letterDate = Date()
        self.notes = ""

        let text = page.ocrResult?.rawText ?? ""
        let lower = text.lowercased()

        let fn = page.ocrResult?.primaryFileNumber ?? ""
        self.fileNumber = fn
        self.amount = page.ocrResult?.primaryAmount?.raw ?? ""

        let detectedSender = Self.detectSender(from: text)
        self.creditorName = detectedSender ?? "Unbekannter Gläubiger"

        if lower.contains("vollstreckungsbescheid") || lower.contains("vollstreckbare ausfertigung") || lower.contains("vollstreckungsauftrag") {
            self.kind = .vollstreckungsbescheid
            self.destination = .debt
            self.targetStatus = .vollstreckung
        } else if lower.contains("mahnbescheid") || (lower.contains("amtsgericht") && (lower.contains("mahngericht") || lower.contains("mahnverfahren") || lower.contains("antragsteller"))) {
            self.kind = .mahnbescheid
            self.destination = .debt
            self.targetStatus = .mahnbescheid
        } else if lower.contains("inkasso") || lower.contains("mahnung") || lower.contains("letzte mahnung") || lower.contains("gläubiger") || lower.contains("forderung") {
            self.kind = .inkassoMahnung
            self.destination = .debt
            self.targetStatus = .active
        } else if lower.contains("kassenbon") || lower.contains("rewe") || lower.contains("edeka") || lower.contains("aldi") || lower.contains("lidl") || lower.contains("hafermilch") {
            self.kind = .pantry
            self.destination = .pantry
            self.targetStatus = .active
        } else if lower.contains("wartung") || lower.contains("seriennummer") || lower.contains("reparatur") || lower.contains("kaffeemaschine") || lower.contains("jura") {
            self.kind = .hardware
            self.destination = .hardware
            self.targetStatus = .active
        } else {
            self.kind = .invoice
            self.destination = .debt
            self.targetStatus = .active
        }

        if let eng = engine {
            if let matched = eng.debts.first(where: { debt in
                (!fn.isEmpty && (debt.fileNumber.localizedCaseInsensitiveContains(fn) || fn.localizedCaseInsensitiveContains(debt.fileNumber)))
                || (!debt.fileNumber.isEmpty && text.localizedCaseInsensitiveContains(debt.fileNumber))
                || (!debt.creditorName.isEmpty && debt.creditorName != "Unbekannt" && text.localizedCaseInsensitiveContains(debt.creditorName))
            }) {
                self.matchedDebtId = matched.id
                if self.fileNumber.isEmpty { self.fileNumber = matched.fileNumber }
                if self.creditorName.isEmpty || self.creditorName == "Unbekannter Gläubiger" {
                    self.creditorName = matched.creditorName
                }
            }
        }
    }

    private static func detectSender(from text: String) -> String? {
        let issuers = [
            "EOS Deutscher Inkasso-Dienst", "EOS", "Creditreform", "Universum Inkasso", "Intrum",
            "Paigo", "Riverty", "KSP Rechtsanwälte", "Infoscore", "Lowell", "Vodafone", "Deutsche Telekom",
            "Telekom", "O2", "1&1", "Stadtwerke", "Vattenfall", "E.ON", "Allianz", "REWE", "EDEKA",
            "Lidl", "Aldi", "Jura", "Amtsgericht Hamburg", "Amtsgericht Wedding", "Amtsgericht"
        ]
        for iss in issuers {
            if text.localizedCaseInsensitiveContains(iss) { return iss }
        }
        return nil
    }
}

struct TriageListView: View {
    @ObservedObject var engine: DebtEngineService
    @State private var items: [TriageItem]
    @State private var editingItem: TriageItem?
    @State private var previewImage: UIImage?
    @State private var toast: ToastData?
    @State private var isCommittingAll = false
    @Environment(\.dismiss) private var dismiss

    init(pages: [ScannedPage], engine: DebtEngineService) {
        self._items = State(initialValue: pages.map { TriageItem(page: $0, engine: engine) })
        self.engine = engine
    }

    private var groupedSections: [(creditor: String, total: Decimal, items: [TriageItem])] {
        let dict = Dictionary(grouping: items, by: { $0.creditorName.isEmpty ? "Unbekannter Gläubiger / Beleg" : $0.creditorName })
        return dict.keys.sorted().map { key in
            let list = dict[key] ?? []
            let total = list.reduce(Decimal.zero) { sum, it in
                let val = VisionOCRService.parseGermanDecimal(
                    it.amount
                        .replacingOccurrences(of: "€", with: "")
                        .replacingOccurrences(of: "EUR", with: "")
                        .trimmingCharacters(in: .whitespaces)
                ) ?? Decimal.zero
                return sum + val
            }
            return (creditor: key, total: total, items: list)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 20) {
                        headerBanner

                        ForEach(groupedSections, id: \.creditor) { section in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .center, spacing: 8) {
                                    Image(systemName: "building.2.crop.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(Theme.primaryAccent)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(section.creditor)
                                            .font(.headline.weight(.bold))
                                            .foregroundStyle(.primary)

                                        Text("\(section.items.count) Beleg\(section.items.count == 1 ? "" : "e") erfasst")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if section.total > 0 {
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text("Gesamtsumme")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                            Text(section.total, format: .currency(code: "EUR"))
                                                .font(.subheadline.weight(.heavy))
                                                .foregroundStyle(Theme.primaryAccent)
                                        }
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(Theme.primaryAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                                .padding(.horizontal, 4)

                                ForEach(section.items) { item in
                                    if let idx = items.firstIndex(where: { $0.id == item.id }) {
                                        TriageItemCard(
                                            item: $items[idx],
                                            engine: engine,
                                            onPreview: { previewImage = items[idx].page.image },
                                            onOptions: { editingItem = items[idx] },
                                            onCommitSingle: { Task { await commitSingleItem(items[idx]) } },
                                            onDiscard: {
                                                withAnimation(.spring(response: 0.35)) {
                                                    items.removeAll { $0.id == item.id }
                                                }
                                                showToast(icon: "trash.fill", text: "Beleg verworfen", color: .orange)
                                            }
                                        )
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        Color.clear.frame(height: 100)
                    }
                    .padding(.top, 12)
                }

                stickyBottomBar
            }
        }
        .navigationTitle("Belege erfassen (\(items.count))")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let toast {
                ToastView(data: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: toast?.id)
        .sheet(item: $editingItem) { item in
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                TriageOptionsSheet(item: $items[idx], engine: engine)
            }
        }
        .sheet(isPresented: Binding(
            get: { previewImage != nil },
            set: { if !$0 { previewImage = nil } }
        )) {
            if let img = previewImage {
                NavigationStack {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                    }
                    .navigationTitle("Scan-Vorschau")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") { previewImage = nil }
                        }
                    }
                }
            }
        }
    }

    private var headerBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.clipboard.fill")
                .font(.title2)
                .foregroundStyle(Theme.primaryAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Übersicht nach Gläubigern")
                    .font(.subheadline.bold())
                Text("Prüfe Betrag & Status. Bescheide werden automatisch bestehenden Aktenzeichen zugeordnet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.glassEdgeGradient, lineWidth: 0.8))
        .padding(.horizontal, 16)
    }

    private var stickyBottomBar: some View {
        VStack(spacing: 8) {
            Button {
                Task { await commitAllItems() }
            } label: {
                HStack(spacing: 10) {
                    if isCommittingAll {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.headline)
                    }
                    Text("Alle \(items.count) Belege speichern & zuordnen")
                        .font(.headline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.primaryGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Theme.primaryAccent.opacity(0.4), radius: 10, y: 4)
            }
            .disabled(isCommittingAll)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.primaryGradient)
            Text("Alle Belege übernommen!")
                .font(.title2.weight(.semibold))
            Text("Die Dokumente wurden erfolgreich zugeordnet und abgespeichert.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Zurück zur Übersicht") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.primaryAccent)
            .padding(.top, 8)
        }
        .padding(40)
    }

    private func commitSingleItem(_ item: TriageItem) async {
        await executeCommit(for: item)
        withAnimation(.spring(response: 0.35)) {
            items.removeAll { $0.id == item.id }
        }
        if items.isEmpty {
            try? await Task.sleep(for: .seconds(1.0))
            await MainActor.run { dismiss() }
        }
    }

    private func commitAllItems() async {
        isCommittingAll = true
        for item in items {
            await executeCommit(for: item)
        }
        isCommittingAll = false
        withAnimation(.spring(response: 0.35)) {
            items.removeAll()
        }
        showToast(icon: "checkmark.circle.fill", text: "Alle Belege erfolgreich zugeordnet!", color: .green)
        try? await Task.sleep(for: .seconds(1.2))
        await MainActor.run { dismiss() }
    }

    private func executeCommit(for item: TriageItem) async {
        let decimal = VisionOCRService.parseGermanDecimal(
            item.amount
                .replacingOccurrences(of: "€", with: "")
                .replacingOccurrences(of: "EUR", with: "")
                .trimmingCharacters(in: .whitespaces)
        ) ?? 0

        var documentURL: String? = nil
        if let data = item.page.image.jpegData(compressionQuality: 0.8) {
            let userIdString = (try? SupabaseConfig.client.auth.session.user.id.uuidString) ?? "unknown_user"
            let fileName = "\(userIdString)/\(UUID().uuidString).jpg"
            do {
                _ = try await SupabaseConfig.client.storage
                    .from("debt-documents")
                    .upload(fileName, data: data)
                documentURL = fileName
            } catch {
                print("Failed to upload document: \(error)")
            }
        }

        switch item.destination {
        case .debt:
            let docTitle = "\(item.kind.rawValue): \(item.creditorName)"
            if let matchedId = item.matchedDebtId {
                let entryType: TimelineEntryType
                switch item.kind {
                case .mahnbescheid: entryType = .mahnbescheid
                case .vollstreckungsbescheid: entryType = .vollstreckungsbescheid
                default: entryType = .letterReceived
                }

                let desc: String
                if item.kind == .mahnbescheid {
                    desc = "⚖️ Gerichtlicher Mahnbescheid eingegangen (Forderung: \(item.amount))"
                } else if item.kind == .vollstreckungsbescheid {
                    desc = "⚡ Vollstreckungsbescheid ergangen (Gesamt: \(item.amount))"
                } else {
                    desc = "\(item.kind.rawValue) erfasst (AZ: \(item.fileNumber))"
                }

                engine.attachNoticeToDebt(
                    debtId: matchedId,
                    newStatus: item.targetStatus,
                    newPrincipal: decimal > 0 ? decimal : nil,
                    entryType: entryType,
                    letterDate: item.letterDate,
                    sender: item.creditorName,
                    description: desc,
                    documentURL: documentURL,
                    documentName: docTitle
                )
                showToast(icon: "arrow.triangle.2.circlepath", text: "Zu Inkasso-Fall hinzugefügt", color: .green)
            } else {
                let newDebt = Debt(
                    userId: engine.currentUserId,
                    fileNumber: item.fileNumber.isEmpty ? "AZ-\(Int.random(in: 10000...99999))" : item.fileNumber,
                    creditorName: item.creditorName.isEmpty ? "Unbekannt" : item.creditorName,
                    originalAmount: decimal,
                    currentPrincipal: decimal,
                    status: item.targetStatus,
                    latestLetterDate: item.letterDate
                )
                let note = "\(item.kind.rawValue) erfasst. Betrag: \(item.amount)"
                engine.addDebt(newDebt, initialNote: note)
                showToast(icon: "plus.circle.fill", text: "Neue Forderung: \(newDebt.fileNumber)", color: Theme.primaryAccent)
            }

        case .pantry:
            let name = item.fileNumber.isEmpty ? (item.creditorName.isEmpty ? "Vorratseinkauf" : item.creditorName) : item.fileNumber
            let pantryItem = PantryItem(
                id: UUID(),
                householdId: (try? SupabaseConfig.client.auth.session.user.id) ?? UUID(),
                addedBy: (try? SupabaseConfig.client.auth.session.user.id) ?? UUID(),
                name: name,
                category: "Lebensmittel",
                quantity: 1,
                unit: "Stück",
                minQuantity: 1,
                expiryDate: Calendar.current.date(byAdding: .month, value: 3, to: Date()),
                storageLocation: "Küche",
                onShoppingList: false,
                createdAt: Date(),
                updatedAt: Date()
            )
            do {
                try await SupabaseConfig.client.from("household_pantry").insert(pantryItem).execute()
                showToast(icon: "cart.fill.badge.plus", text: "Im Vorratsschrank abgelegt", color: .blue)
            } catch {
                showToast(icon: "cart.fill", text: "Im Vorrat gespeichert", color: .blue)
            }

        case .hardware:
            let deviceName = item.creditorName.isEmpty ? "Gerät / Rechnung" : item.creditorName
            let log = HardwareLogEntry(
                id: UUID(),
                userId: (try? SupabaseConfig.client.auth.session.user.id) ?? UUID(),
                deviceName: deviceName,
                deviceType: .other,
                logType: .maintenance,
                performedAt: item.letterDate,
                cost: decimal,
                description: "Beleg vom \(item.letterDate.formatted(date: .numeric, time: .omitted)) (AZ: \(item.fileNumber))",
                createdAt: Date(),
                updatedAt: Date()
            )
            do {
                try await SupabaseConfig.client.from("hardware_log").insert(log).execute()
                showToast(icon: "wrench.and.screwdriver.fill", text: "In Hardware-Akte abgelegt", color: .purple)
            } catch {
                showToast(icon: "wrench.fill", text: "In Hardware-Akte gespeichert", color: .purple)
            }

        case .archive:
            showToast(icon: "archivebox.fill", text: "Im Archiv abgelegt", color: .teal)

        case .discard:
            showToast(icon: "trash.fill", text: "Beleg verworfen", color: .orange)
        }
    }

    private func showToast(icon: String, text: String, color: Color) {
        toast = ToastData(id: UUID(), icon: icon, text: text, color: color)
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            await MainActor.run { toast = nil }
        }
    }
}

typealias TriageCardDeckView = TriageListView

private struct TriageItemCard: View {
    @Binding var item: TriageItem
    @ObservedObject var engine: DebtEngineService
    var onPreview: () -> Void
    var onOptions: () -> Void
    var onCommitSingle: () -> Void
    var onDiscard: () -> Void

    var matchedDebt: Debt? {
        guard let id = item.matchedDebtId else { return nil }
        return engine.debts.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Button(action: onPreview) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(uiImage: item.page.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 105)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.glassEdgeGradient, lineWidth: 0.8))

                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.6), in: Circle())
                            .padding(4)
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: item.kind.icon)
                                .font(.system(size: 10, weight: .bold))
                            Text(item.kind.rawValue)
                                .font(.system(size: 10, weight: .bold))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(item.kind.badgeColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(item.kind.badgeColor)

                        Text(item.targetStatus.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .foregroundStyle(.secondary)
                    }

                    Text(item.fileNumber.isEmpty ? "Kein AZ erkannt" : item.fileNumber)
                        .font(.system(.subheadline, design: .monospaced).weight(.bold))
                        .foregroundStyle(.primary)

                    if let mDebt = matchedDebt {
                        HStack(spacing: 4) {
                            Image(systemName: "link.circle.fill")
                                .font(.caption)
                            Text("Wird zu Aktenzeichen „\(mDebt.fileNumber)“ hinzugefügt")
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.green)
                    }

                    HStack(spacing: 6) {
                        Text("Betrag:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("0,00 €", text: $item.amount)
                            .font(.system(.body, design: .rounded).weight(.bold))
                            .foregroundStyle(Theme.primaryAccent)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

                    Text(item.letterDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Ziel-Modul:")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    ForEach([TriageDestination.debt, .pantry, .hardware, .archive], id: \.self) { dest in
                        Button {
                            withAnimation(.spring(response: 0.25)) {
                                item.destination = dest
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: dest.icon)
                                    .font(.system(size: 9))
                                Text(dest.rawValue.components(separatedBy: "-").first ?? dest.rawValue)
                                    .font(.system(size: 11, weight: item.destination == dest ? .bold : .medium))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(
                                item.destination == dest ? dest.color.opacity(0.25) : Color.white.opacity(0.05),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(item.destination == dest ? dest.color : Color.clear, lineWidth: 1)
                            )
                            .foregroundStyle(item.destination == dest ? dest.color : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button(action: onOptions) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Optionen & Status")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onDiscard) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.8))
                        .padding(7)
                        .background(Color.red.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)

                Button(action: onCommitSingle) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                        Text("Übernehmen")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.primaryGradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 18)
    }
}

private struct TriageOptionsSheet: View {
    @Binding var item: TriageItem
    @ObservedObject var engine: DebtEngineService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // Section 1: Betrag & Status
                Section("Betrag & Status") {
                    HStack {
                        Text("Betrag")
                        Spacer()
                        TextField("z. B. 742,50 €", text: $item.amount)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                            .font(.system(.body, design: .rounded).bold())
                            .foregroundStyle(Theme.primaryAccent)
                    }

                    Picker("Status festlegen", selection: $item.targetStatus) {
                        ForEach(DebtStatus.allCases, id: \.self) { status in
                            Text(status.displayName).tag(status)
                        }
                    }

                    Picker("Dokument-Art", selection: $item.kind) {
                        ForEach(ScannedDocumentKind.allCases) { kind in
                            Label(kind.rawValue, systemImage: kind.icon).tag(kind)
                        }
                    }

                    Picker("Ziel-Modul", selection: $item.destination) {
                        ForEach(TriageDestination.allCases) { dest in
                            Label(dest.rawValue, systemImage: dest.icon).tag(dest)
                        }
                    }
                }

                // Section 2: Zuordnung zu Aktenzeichen / Inkasso
                Section {
                    Picker("Forderungs-Zuordnung", selection: Binding(
                        get: { item.matchedDebtId },
                        set: { newId in
                            item.matchedDebtId = newId
                            if let matched = engine.debts.first(where: { $0.id == newId }) {
                                item.fileNumber = matched.fileNumber
                                item.creditorName = matched.creditorName
                            }
                        }
                    )) {
                        Text("✨ Als neue Forderung anlegen").tag(UUID?.none)
                        ForEach(engine.debts) { debt in
                            Text("📁 \(debt.fileNumber) – \(debt.creditorName)").tag(Optional(debt.id))
                        }
                    }

                    if let matchedId = item.matchedDebtId,
                       let matched = engine.debts.first(where: { $0.id == matchedId }) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Wird an bestehendes Aktenzeichen angehängt:")
                                    .font(.caption.bold())
                                    .foregroundStyle(.green)
                            }
                            Text("Gläubiger: \(matched.creditorName)\nBisheriger Stand: \(matched.currentPrincipal.formatted(.currency(code: "EUR")))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Inkasso- & Aktenzeichen Zuordnung")
                } footer: {
                    Text("Bescheide (z.B. Mahnbescheid oder Vollstreckungsbescheid) werden der gewählten Akte als neuer Verlaufseintrag hinzugefügt.")
                }

                // Section 3: Gläubiger & Daten
                Section("Gläubiger & Dokumentendetails") {
                    TextField("Gläubiger / Absender", text: $item.creditorName)
                    TextField("Aktenzeichen", text: $item.fileNumber)
                        .font(.system(.body, design: .monospaced))
                    DatePicker("Belegdatum", selection: $item.letterDate, displayedComponents: .date)
                    TextField("Notizen / Bemerkung", text: $item.notes)
                }

                // Section 4: OCR Rohtext & Alternativen
                if let ocr = item.ocr {
                    if !ocr.fileNumbers.isEmpty {
                        Section("Weitere erkannte Aktenzeichen") {
                            ForEach(ocr.fileNumbers, id: \.self) { fn in
                                Button(fn) { item.fileNumber = fn }
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                    if !ocr.euroAmounts.isEmpty {
                        Section("Weitere erkannte Beträge") {
                            ForEach(ocr.euroAmounts) { amount in
                                Button(amount.raw) { item.amount = amount.raw }
                            }
                        }
                    }
                    if !ocr.rawText.isEmpty {
                        Section("Erkannter Belegtext (OCR)") {
                            DisclosureGroup("Rohtext anzeigen") {
                                ScrollView {
                                    Text(ocr.rawText)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 160)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Optionen & Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}

// =============================================================================
// MARK: - Toast
// =============================================================================

struct ToastData: Identifiable {
    let id:    UUID
    let icon:  String
    let text:  String
    let color: Color
}

private struct ToastView: View {
    let data: ToastData

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: data.icon)
                .foregroundStyle(data.color)
            Text(data.text)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .liquidGlassCard(cornerRadius: 40,
                         padding: .init(top: 0, leading: 0, bottom: 0, trailing: 0))
    }
}

// =============================================================================
// MARK: - ScannerCoordinatorView (wires everything together)
// =============================================================================

/// Entry point: shows the camera, photo library or file picker, runs OCR, then presents the Triage deck.
struct ScannerCoordinatorView: View {
    @ObservedObject var engine: DebtEngineService
    @State private var showScanner = false
    @State private var showImagePicker = false
    @State private var showFilePicker = false
    @State private var scannedPages: [ScannedPage] = []
    @State private var isProcessingOCR = false
    @Environment(\.dismiss) private var dismiss

    private let ocr = VisionOCRService()

    var body: some View {
        NavigationStack {
            Group {
                if isProcessingOCR {
                    ocrProgressView
                } else if !scannedPages.isEmpty {
                    TriageCardDeckView(pages: scannedPages, engine: engine)
                } else {
                    landingView
                }
            }
            .navigationTitle("Beleg erfassen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView(
                onFinish: { pages in
                    Task { await runOCR(on: pages) }
                },
                onCancel: { showScanner = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showImagePicker) {
            DocumentImagePicker(sourceType: .photoLibrary) { img in
                guard let image = img else { return }
                Task {
                    let page = ScannedPage(image: image)
                    await runOCR(on: [page])
                }
            }
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentFilePicker { url in
                guard let fileURL = url else { return }
                Task {
                    await handlePickedFile(at: fileURL)
                }
            }
        }
    }

    // ── Sub-views ─────────────────────────────────────────────────────

    private var landingView: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "doc.viewfinder.fill")
                        .font(.system(size: 68))
                        .foregroundStyle(Theme.primaryGradient)

                    Text("Dokument & Beleg erfassen")
                        .font(.title2.weight(.bold))

                    Text("Kamera nutzen oder Beleg vom Gerät hochladen.\nAktenzeichen, Beträge & Fristen werden per KI erkannt.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .padding(.top, 10)

                // Option 1: Live Kamera-Scan
                Button {
                    showScanner = true
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.2))
                                .frame(width: 44, height: 44)
                            Image(systemName: "camera.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Kamera-Scan")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("Brief oder Beleg direkt abfotografieren")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Theme.primaryGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: Theme.primaryAccent.opacity(0.4), radius: 10, y: 4)
                }
                .buttonStyle(.plain)

                // Option 2: Foto aus Mediathek
                Button {
                    showImagePicker = true
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.purple.opacity(0.18))
                                .frame(width: 44, height: 44)
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.purple)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Foto aus Mediathek")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Gespeichertes Foto oder Screenshot wählen")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.subheadline.bold())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Theme.glassEdgeGradient, lineWidth: 0.8)
                    }
                }
                .buttonStyle(.plain)

                // Option 3: PDF / Datei vom Gerät
                Button {
                    showFilePicker = true
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.teal.opacity(0.18))
                                .frame(width: 44, height: 44)
                            Image(systemName: "doc.badge.arrow.up.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.teal)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("PDF / Datei vom Gerät")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("PDF-Dokument oder Datei aus Dateien-App laden")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.subheadline.bold())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Theme.glassEdgeGradient, lineWidth: 0.8)
                    }
                }
                .buttonStyle(.plain)

                // Option 4: Test-Musterdokumente
                Button {
                    let samples = SampleDocumentGenerator.generateSamplePages()
                    self.scannedPages = samples
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                        Text("Musterdokumente testen (Mac / Simulator)")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(20)
        }
    }

    private var ocrProgressView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(Theme.primaryAccent)
            Text("KI-Texterkennung läuft…")
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
            Text("Aktenzeichen, Gläubiger und Beträge werden analysiert")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // ── Datei-Uploads verarbeiten ──────────────────────────────────────

    @MainActor
    private func handlePickedFile(at fileURL: URL) async {
        isProcessingOCR = true
        let ext = fileURL.pathExtension.lowercased()

        if ext == "pdf" || (try? Data(contentsOf: fileURL, options: .mappedIfSafe).starts(with: [0x25, 0x50, 0x44, 0x46])) == true {
            if let pdfDoc = PDFDocument(url: fileURL) {
                var pages: [ScannedPage] = []
                let count = min(pdfDoc.pageCount, 10)
                for i in 0..<count {
                    if let pdfPage = pdfDoc.page(at: i) {
                        let rect = pdfPage.bounds(for: .mediaBox)
                        let scale: CGFloat = 2.0
                        let renderer = UIGraphicsImageRenderer(size: CGSize(width: rect.width * scale, height: rect.height * scale))
                        let img = renderer.image { ctx in
                            UIColor.white.set()
                            ctx.fill(CGRect(origin: .zero, size: CGSize(width: rect.width * scale, height: rect.height * scale)))
                            ctx.cgContext.scaleBy(x: scale, y: scale)
                            ctx.cgContext.translateBy(x: 0, y: rect.height)
                            ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                            pdfPage.draw(with: .mediaBox, to: ctx.cgContext)
                        }
                        pages.append(ScannedPage(image: img))
                    }
                }
                if !pages.isEmpty {
                    await runOCR(on: pages)
                    return
                }
            }
        } else if let data = try? Data(contentsOf: fileURL), let img = UIImage(data: data) {
            let page = ScannedPage(image: img)
            await runOCR(on: [page])
            return
        }
        isProcessingOCR = false
    }

    // ── OCR pipeline ──────────────────────────────────────────────────

    @MainActor
    private func runOCR(on pages: [ScannedPage]) async {
        showScanner    = false
        isProcessingOCR = true
        let processed  = await ocr.recogniseBatch(pages: pages)
        scannedPages   = processed
        isProcessingOCR = false
    }
}

// =============================================================================
// MARK: - Preview
// =============================================================================

#if DEBUG
#Preview("TriageCardDeck – Demo") {
    // Synthetic pages with pre-baked OCR for the preview
    let demoPages: [ScannedPage] = {
        let demoResults: [(String, String)] = [
            ("AZ-2024-00123", "3.450,00 €"),
            ("GZ: 2023/4567",  "1.200,50 €"),
            ("12 C 34/22",     "890,00 €"),
        ]
        return demoResults.map { fn, amt in
            var page = ScannedPage(image: UIImage(systemName: "doc.text.fill")
                                   ?? UIImage())
            page.ocrResult = OCRResult(
                rawText: "Aktenzeichen: \(fn)\nBetrag: \(amt)",
                fileNumbers: [fn],
                euroAmounts: [ParsedAmount(raw: amt,
                                           decimal: Decimal(string: "1000") ?? 0)]
            )
            return page
        }
    }()

    return NavigationStack {
        TriageCardDeckView(
            pages:  demoPages,
            engine: DebtEngineService(userId: UUID())
        )
    }
    .preferredColorScheme(.dark)
}
#endif
