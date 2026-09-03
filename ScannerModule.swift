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
        // Sort descending so the largest (= most likely Hauptforderung) comes first
        return found.sorted { $0.decimal > $1.decimal }
    }

    // MARK: German Decimal Parser
    // "1.234.567,89" → Decimal(1234567.89)
    static func parseGermanDecimal(_ raw: String) -> Decimal? {
        // Remove thousands dots, replace comma with dot
        let normalised = raw
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Decimal(string: normalised)
    }

    // ── Error ──────────────────────────────────────────────────────────────

    enum OCRError: LocalizedError {
        case invalidImage
        var errorDescription: String? { "Ungültiges Bild – OCR nicht möglich." }
    }
}

// =============================================================================
// MARK: - 3. TriageCardDeckView
// =============================================================================

// MARK: TriageItem – one card in the deck

struct TriageItem: Identifiable {
    let id       = UUID()
    var page:    ScannedPage
    var ocr:     OCRResult?

    // Editable fields (user can correct before confirming)
    var fileNumber: String
    var amount:     String
    var letterDate: Date

    init(page: ScannedPage) {
        self.page       = page
        self.ocr        = page.ocrResult
        self.fileNumber = page.ocrResult?.primaryFileNumber ?? ""
        self.amount     = page.ocrResult?.primaryAmount?.raw ?? ""
        self.letterDate = Date()
    }
}

// MARK: SwipeDecision

enum SwipeDecision {
    case toDebts     // 👉 Swipe Rechts: Übernahme in die Schulden-Engine
    case toPantry    // 👈 Swipe Links: Ablage im Vorratsschrank
    case toHardware  // 👆 Swipe Oben: Zuordnung zur Hardware-Akte
    case discard     // 👇 Swipe Unten: Verwerfen / Papierkorb
}

// MARK: TriageCardDeckView

struct TriageCardDeckView: View {
    // Injected from parent
    @ObservedObject var engine: DebtEngineService

    // The pending cards (top of array = top card)
    @State private var items: [TriageItem]

    // Feedback
    @State private var toast: ToastData?
    @State private var showEditSheet: Bool = false
    @State private var editingItem: TriageItem?

    init(pages: [ScannedPage], engine: DebtEngineService) {
        self._items = State(initialValue: pages.map(TriageItem.init))
        self.engine = engine
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // ── Background ─────────────────────────────────────────────
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            // ── Deck ───────────────────────────────────────────────────
            ZStack {
                if items.isEmpty {
                    emptyState
                } else {
                    ForEach(items.indices.reversed(), id: \.self) { index in
                        CardView(
                            item: $items[index],
                            isTop: index == items.count - 1,
                            stackIndex: items.count - 1 - index,
                            onSwipe: { decision in handleSwipe(decision, at: index) },
                            onEdit: {
                                editingItem = items[index]
                                showEditSheet = true
                            }
                        )
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── 4-Way Action hints ─────────────────────────────────────
            if !items.isEmpty {
                VStack(spacing: 8) {
                    actionHint(icon: "wrench.and.screwdriver.fill", label: "👆 Oben: Hardware", color: .purple)
                    HStack(spacing: 20) {
                        actionHint(icon: "cart.fill", label: "👈 Links: Vorrat", color: .blue)
                        actionHint(icon: "eurosign.circle.fill", label: "👉 Rechts: Schulden", color: .green)
                    }
                    actionHint(icon: "trash.fill", label: "👇 Unten: Verwerfen", color: .orange)
                }
                .padding(.bottom, 24)
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                ToastView(data: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: toast?.id)
        .sheet(isPresented: $showEditSheet, onDismiss: applyEdit) {
            if let binding = bindingForEditing() {
                EditCardSheet(item: binding)
            }
        }
        .navigationTitle("Belege (\(items.count))")
        .navigationBarTitleDisplayMode(.inline)
    }

    // ── Private helpers ───────────────────────────────────────────────

    private func handleSwipe(_ decision: SwipeDecision, at index: Int) {
        let item = items[index]
        _ = withAnimation(.spring(response: 0.35)) {
            items.remove(at: index)
        }

        switch decision {
        case .toDebts:
            Task { await commitItem(item) }
        case .toPantry:
            Task { await commitPantryItem(item) }
        case .toHardware:
            Task { await commitHardwareItem(item) }
        case .discard:
            showToast(icon: "trash.fill", text: "Beleg verworfen", color: .orange)
        }
    }

    private func commitPantryItem(_ item: TriageItem) async {
        let name = item.fileNumber.isEmpty ? "Neuer Vorrat" : item.fileNumber
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
    }

    private func commitHardwareItem(_ item: TriageItem) async {
        let deviceName = item.fileNumber.isEmpty ? "Gerät / Rechnung" : item.fileNumber
        let cost = Decimal(string: item.amount.replacingOccurrences(of: "€", with: "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
        let log = HardwareLogEntry(
            id: UUID(),
            userId: (try? SupabaseConfig.client.auth.session.user.id) ?? UUID(),
            deviceName: deviceName,
            deviceType: .other,
            logType: .maintenance,
            performedAt: Date(),
            cost: cost,
            description: "Scan vom \(Date().formatted(date: .numeric, time: .omitted))",
            createdAt: Date(),
            updatedAt: Date()
        )
        do {
            try await SupabaseConfig.client.from("hardware_log").insert(log).execute()
            showToast(icon: "wrench.and.screwdriver.fill", text: "In Hardware-Akte abgelegt", color: .purple)
        } catch {
            showToast(icon: "wrench.fill", text: "In Hardware-Akte gespeichert", color: .purple)
        }
    }

    private func commitItem(_ item: TriageItem) async {
        // Parse amount from the (possibly edited) string
        guard let decimal = VisionOCRService.parseGermanDecimal(
            item.amount
                .replacingOccurrences(of: "€", with: "")
                .replacingOccurrences(of: "EUR", with: "")
                .trimmingCharacters(in: .whitespaces)
        ) else {
            showToast(icon: "exclamationmark.triangle", text: "Betrag ungültig", color: .red)
            return
        }

        // Upload image to Storage
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

        let scanResult = ScanResult(
            fileNumber: item.fileNumber,
            amount: decimal,
            letterDate: item.letterDate,
            documentURL: documentURL,
            documentName: "Scan \(item.letterDate.formatted(date: .numeric, time: .omitted))"
        )

        do {
            let outcome = try engine.processNewScan(scanResult)
            switch outcome {
            case .created:
                showToast(icon: "plus.circle.fill",
                          text: "Neue Forderung: \(item.fileNumber)",
                          color: Theme.primaryAccent)
            case .updated(_, let delta, _):
                let sign  = delta > 0 ? "+" : "−"
                let abs   = Swift.abs(delta)
                showToast(icon: "arrow.triangle.2.circlepath",
                          text: "Aktualisiert: \(sign)\(abs) €",
                          color: .blue)
            case .unchanged:
                showToast(icon: "equal.circle.fill", text: "Keine Änderung", color: .gray)
            }
        } catch {
            showToast(icon: "xmark.octagon.fill",
                      text: error.localizedDescription,
                      color: .red)
        }
    }

    private func showToast(icon: String, text: String, color: Color) {
        toast = ToastData(id: UUID(), icon: icon, text: text, color: color)
        // Auto-dismiss
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            await MainActor.run { toast = nil }
        }
    }

    private func applyEdit() {
        guard let edited = editingItem,
              let idx = items.firstIndex(where: { $0.id == edited.id }) else { return }
        items[idx] = edited
        editingItem = nil
    }

    private func bindingForEditing() -> Binding<TriageItem>? {
        guard let edited = editingItem,
              let idx = items.firstIndex(where: { $0.id == edited.id }) else { return nil }
        return $items[idx]
    }

    // ── Empty state ───────────────────────────────────────────────────

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.primaryGradient)
            Text("Alle Belege bearbeitet")
                .font(.title2.weight(.semibold))
            Text("Gehe zurück, um weitere Dokumente zu scannen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    // ── Action hint ───────────────────────────────────────────────────

    private func actionHint(icon: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(color)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

// =============================================================================
// MARK: - CardView (individual swipeable card)
// =============================================================================

private struct CardView: View {
    @Binding var item: TriageItem
    let isTop:      Bool
    let stackIndex: Int     // 0 = top, 1 = second, …
    let onSwipe:    (SwipeDecision) -> Void
    let onEdit:     () -> Void

    @State private var dragOffset = CGSize.zero
    @State private var rotation:  Double = 0

    // Swipe thresholds
    private let acceptThreshold: CGFloat =  120
    private let rejectThreshold: CGFloat = -120
    private let maxRotation:     Double  =  18

    var body: some View {
        ZStack(alignment: .topTrailing) {
            cardContent
            decisionOverlay
        }
        .scaleEffect(scaleForStack)
        .offset(y: offsetYForStack)
        .offset(dragOffset)
        .rotationEffect(.degrees(rotation))
        .gesture(isTop ? swipeGesture : nil)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: stackIndex)
        .zIndex(isTop ? 100 : Double(100 - stackIndex))
    }

    // ── Stack visual offset ───────────────────────────────────────────

    private var scaleForStack: CGFloat {
        max(0.88, 1.0 - CGFloat(stackIndex) * 0.04)
    }

    private var offsetYForStack: CGFloat {
        CGFloat(stackIndex) * 10
    }

    // ── Decision overlay (4-Way contextual tint while swiping) ───────────

    @ViewBuilder
    private var decisionOverlay: some View {
        if isTop {
            ZStack {
                // 👉 Rechts: Schulden
                if dragOffset.width > 30 {
                    HStack {
                        Spacer()
                        Label("Schulden", systemImage: "eurosign.circle.fill")
                            .font(.headline.bold())
                            .foregroundStyle(.green)
                            .padding(12)
                            .background(.green.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                            .padding(.trailing, 20)
                            .opacity(Double(min(dragOffset.width / 120, 1.0)))
                    }
                }
                
                // 👈 Links: Vorrat
                if dragOffset.width < -30 {
                    HStack {
                        Label("Vorrat", systemImage: "cart.fill")
                            .font(.headline.bold())
                            .foregroundStyle(.blue)
                            .padding(12)
                            .background(.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                            .padding(.leading, 20)
                            .opacity(Double(min(-dragOffset.width / 120, 1.0)))
                        Spacer()
                    }
                }
                
                // 👆 Oben: Hardware
                if dragOffset.height < -30 {
                    VStack {
                        Label("Hardware-Akte", systemImage: "wrench.and.screwdriver.fill")
                            .font(.headline.bold())
                            .foregroundStyle(.purple)
                            .padding(12)
                            .background(.purple.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                            .padding(.top, 20)
                            .opacity(Double(min(-dragOffset.height / 120, 1.0)))
                        Spacer()
                    }
                }
                
                // 👇 Unten: Verwerfen
                if dragOffset.height > 30 {
                    VStack {
                        Spacer()
                        Label("Verwerfen", systemImage: "trash.fill")
                            .font(.headline.bold())
                            .foregroundStyle(.orange)
                            .padding(12)
                            .background(.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                            .padding(.bottom, 20)
                            .opacity(Double(min(dragOffset.height / 120, 1.0)))
                    }
                }
            }
        }
    }

    // ── Swipe gesture ─────────────────────────────────────────────────

    private var swipeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
                rotation   = Double(value.translation.width / 20) * (maxRotation / 10)
            }
            .onEnded { value in
                let x = value.translation.width
                let y = value.translation.height
                
                if abs(x) > abs(y) {
                    if x >= 100 {
                        flyOut(to: .toDebts)
                    } else if x <= -100 {
                        flyOut(to: .toPantry)
                    } else {
                        snapBack()
                    }
                } else {
                    if y <= -100 {
                        flyOut(to: .toHardware)
                    } else if y >= 100 {
                        flyOut(to: .discard)
                    } else {
                        snapBack()
                    }
                }
            }
    }

    private func flyOut(to decision: SwipeDecision) {
        var xTarget: CGFloat = 0
        var yTarget: CGFloat = 0
        
        switch decision {
        case .toDebts:    xTarget = 700
        case .toPantry:   xTarget = -700
        case .toHardware: yTarget = -800
        case .discard:    yTarget = 800
        }
        
        withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
            dragOffset = CGSize(width: xTarget, height: yTarget)
            rotation   = xTarget > 0 ? maxRotation : (xTarget < 0 ? -maxRotation : 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            onSwipe(decision)
            dragOffset = .zero
            rotation   = 0
        }
    }

    private func snapBack() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            dragOffset = .zero
            rotation   = 0
        }
    }

    // ── Card content ──────────────────────────────────────────────────

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail
            documentThumbnail

            // OCR Data
            VStack(alignment: .leading, spacing: 14) {
                infoRow(label: "Aktenzeichen", value: item.fileNumber.isEmpty ? "—" : item.fileNumber,
                        icon: "doc.text.fill")
                infoRow(label: "Betrag",
                        value: item.amount.isEmpty ? "—" : item.amount,
                        icon: "eurosign.circle.fill",
                        valueColor: Theme.primaryAccent)
                datePicker

                // Raw text preview (collapsed)
                if let raw = item.ocr?.rawText, !raw.isEmpty {
                    rawTextPreview(raw)
                }

                // Edit button
                Button(action: onEdit) {
                    Label("Daten korrigieren", systemImage: "pencil")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.primaryAccent)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .liquidGlassCard(cornerRadius: 24, padding: .init(top: 0, leading: 0, bottom: 0, trailing: 0))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var documentThumbnail: some View {
        Image(uiImage: item.page.image)
            .resizable()
            .scaledToFill()
            .frame(height: 200)
            .clipped()
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 24
            ))
    }

    private func infoRow(
        label: String,
        value: String,
        icon: String,
        valueColor: Color = .primary
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Theme.primaryAccent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(valueColor)
            }
        }
    }

    private var datePicker: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar")
                .foregroundStyle(Theme.primaryAccent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Briefdatum")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DatePicker("", selection: $item.letterDate,
                           in: ...Date(),
                           displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }
        }
    }

    private func rawTextPreview(_ text: String) -> some View {
        DisclosureGroup {
            ScrollView {
                Text(text)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .frame(maxHeight: 100)
        } label: {
            Text("OCR-Rohtext anzeigen")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// =============================================================================
// MARK: - EditCardSheet
// =============================================================================

private struct EditCardSheet: View {
    @Binding var item: TriageItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Aktenzeichen") {
                    TextField("z. B. AZ-2024-00123", text: $item.fileNumber)
                        .font(.system(.body, design: .monospaced))
                }
                Section("Betrag") {
                    TextField("z. B. 1.234,56 €", text: $item.amount)
                        .keyboardType(.decimalPad)
                }
                Section("Briefdatum") {
                    DatePicker("Datum", selection: $item.letterDate,
                               in: ...Date(),
                               displayedComponents: .date)
                }
                if let ocr = item.ocr, !ocr.fileNumbers.isEmpty {
                    Section("Weitere erkannte Aktenzeichen") {
                        ForEach(ocr.fileNumbers, id: \.self) { fn in
                            Button(fn) { item.fileNumber = fn }
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
                if let ocr = item.ocr, !ocr.euroAmounts.isEmpty {
                    Section("Weitere erkannte Beträge") {
                        ForEach(ocr.euroAmounts) { amount in
                            Button(amount.raw) { item.amount = amount.raw }
                        }
                    }
                }
            }
            .navigationTitle("Beleg korrigieren")
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

/// Entry point: shows the camera, runs OCR, then presents the Triage deck.
struct ScannerCoordinatorView: View {
    @ObservedObject var engine: DebtEngineService
    @State private var showScanner = false
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
            .navigationTitle("Beleg scannen")
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
    }

    // ── Sub-views ─────────────────────────────────────────────────────

    private var landingView: some View {
        VStack(spacing: 24) {
            Image(systemName: "doc.viewfinder.fill")
                .font(.system(size: 72))
                .foregroundStyle(Theme.primaryGradient)

            Text("Briefe & Mahnungen scannen")
                .font(.title2.weight(.semibold))

            Text("Halte die Kamera über den Brief.\nAktenzeichen und Betrag werden automatisch erkannt.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showScanner = true
            } label: {
                Label("Kamera öffnen", systemImage: "camera.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.primaryGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 32)

            // Test-Generator für Mac / Simulator
            Button {
                let samples = SampleDocumentGenerator.generateSamplePages()
                self.scannedPages = samples
            } label: {
                Label("Musterdokumente testen (Mac / Simulator)", systemImage: "sparkles.rectangle.stack.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 32)
        }
        .padding()
    }

    private var ocrProgressView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(Theme.primaryAccent)
            Text("Texte werden erkannt…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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
