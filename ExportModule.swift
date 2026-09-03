// =============================================================================
// ExportModule.swift
// Schulden & Haushalt App
// Requires: iOS 17+, Swift 5.9+, PencilKit, PDFKit
// =============================================================================

import SwiftUI
import PencilKit
import PDFKit
import UIKit

// =============================================================================
// MARK: - Models
// =============================================================================

struct InstallmentProposal: Sendable {
    // ── Debt Reference ─────────────────────────────────────────────────
    let fileNumber:      String       // Aktenzeichen
    let creditorName:    String       // Gläubiger
    let creditorAddress: String?
    let totalAmount:     Decimal      // Aktuelle Hauptforderung

    // ── Payment Plan ───────────────────────────────────────────────────
    let monthlyRate:     Decimal      // Vorgeschlagene Rate / Monat
    let numberOfMonths:  Int          // Laufzeit
    let startDate:       Date         // Erster Zahlungstermin
    let reason:          String       // Begründung (Härtefall, etc.)

    // ── Sender (Schuldner) ─────────────────────────────────────────────
    let senderName:      String
    let senderAddress:   String
    let senderEmail:     String?
    let senderPhone:     String?

    // ── Document ───────────────────────────────────────────────────────
    let documentDate:    Date
    let documentId:      UUID

    var endDate: Date {
        Calendar.current.date(byAdding: .month, value: numberOfMonths, to: startDate) ?? startDate
    }

    var totalProposed: Decimal { monthlyRate * Decimal(numberOfMonths) }
    var discountDelta:  Decimal { totalAmount - totalProposed }
}

// =============================================================================
// MARK: - 1. PencilKitSignatureCanvas
// =============================================================================

/// `UIViewRepresentable` wrapping `PKCanvasView` for digital signatures.
/// - White monoline ink at 2.5 pt for crisp rendering on dark surfaces.
/// - `drawingPolicy: .anyInput` accepts both Apple Pencil and finger.
struct PencilKitSignatureCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    // Configurable appearance
    var inkColor:        UIColor = .white
    var inkWidth:        CGFloat = 2.5
    var backgroundColor: UIColor = UIColor(red: 0.10, green: 0.10, blue: 0.16, alpha: 1)
    var cornerRadius:    CGFloat = 16

    // ── UIViewRepresentable ────────────────────────────────────────────

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas             = PKCanvasView()
        canvas.drawing         = drawing
        canvas.backgroundColor = backgroundColor
        canvas.tool            = PKInkingTool(.monoline, color: inkColor, width: inkWidth)
        canvas.drawingPolicy   = .anyInput   // Pencil + finger
        canvas.delegate        = context.coordinator
        canvas.isOpaque        = true
        canvas.alwaysBounceVertical = false

        // Visual
        canvas.layer.cornerRadius     = cornerRadius
        canvas.layer.cornerCurve      = .continuous
        canvas.layer.masksToBounds    = true

        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // Avoid feedback loop: only push if changed from outside
        if uiView.drawing.strokes.count != drawing.strokes.count {
            uiView.drawing = drawing
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    // ── Coordinator ────────────────────────────────────────────────────

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding var drawing: PKDrawing
        init(drawing: Binding<PKDrawing>) { self._drawing = drawing }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Runs on main thread per PencilKit contract
            drawing = canvasView.drawing
        }
    }

    // ── Snapshot for PDF (converts white→black for export) ────────────

    /// Renders the drawing as a `UIImage` suitable for embedding in a PDF.
    /// Inverts to black ink on transparent background.
    static func exportImage(from drawing: PKDrawing, size: CGSize, scale: CGFloat = 2) -> UIImage? {
        guard !drawing.strokes.isEmpty else { return nil }
        let bounds = CGRect(origin: .zero, size: size)

        // Render as white-on-dark first
        var raw = drawing.image(from: bounds, scale: scale)

        // Invert to black-on-transparent for PDF
        if let inverted = invertedForPDF(raw) { raw = inverted }
        return raw
    }

    private static func invertedForPDF(_ source: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: source) else { return nil }
        let filter = CIFilter(name: "CIColorInvert")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        guard let output = filter?.outputImage else { return nil }
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// ── SwiftUI Wrapper with toolbar ──────────────────────────────────────────────

struct SignatureCanvasView: View {
    @Binding var drawing:    PKDrawing
    var label:   String      = "Unterschrift"
    var height:  CGFloat     = 180

    @State private var isEmpty = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack {
                Label(label, systemImage: "pencil.and.scribble")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if !isEmpty {
                    Button(role: .destructive) {
                        withAnimation(.spring(response: 0.35)) {
                            drawing = PKDrawing()
                        }
                    } label: {
                        Label("Löschen", systemImage: "trash")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }

            // Canvas
            ZStack {
                PencilKitSignatureCanvas(drawing: $drawing)
                    .frame(height: height)
                    .onChange(of: drawing) { _, new in
                        withAnimation(.spring(response: 0.2)) {
                            isEmpty = new.strokes.isEmpty
                        }
                    }

                if isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "signature")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.25))
                        Text("Hier unterschreiben")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.25))
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.25), .white.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        }
    }
}

// =============================================================================
// MARK: - 2. RatenzahlungsPDFTemplate  (A4 SwiftUI Document Layout)
// =============================================================================

/// The full-page SwiftUI layout that becomes the PDF.
/// Dimensions are fixed at A4 (595 × 842 pt) for pixel-perfect rendering.
struct RatenzahlungsPDFTemplate: View {
    let proposal:        InstallmentProposal
    let signatureImage:  UIImage?              // from PencilKit export

    private let pageWidth:  CGFloat = 595
    private let pageHeight: CGFloat = 842
    private let margin:     CGFloat = 52

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white

            VStack(alignment: .leading, spacing: 0) {
                headerBlock
                Divider().padding(.vertical, 18)

                senderRecipientBlock
                Spacer().frame(height: 24)

                subjectBlock
                Spacer().frame(height: 20)

                openingText
                Spacer().frame(height: 20)

                debtSummaryTable
                Spacer().frame(height: 20)

                installmentTable
                Spacer().frame(height: 20)

                Text(proposal.reason)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer().frame(height: 28)
                closingText
                Spacer().frame(height: 32)

                signatureBlock
                Spacer()

                footerBlock
            }
            .padding(margin)
        }
        .frame(width: pageWidth, height: pageHeight)
        .environment(\.colorScheme, .light)
    }

    // ── Header ─────────────────────────────────────────────────────────

    private var headerBlock: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ratenzahlungsantrag")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color(red: 0.18, green: 0.35, blue: 0.85))
                Text("gemäß § 802b ZPO – Gütliche Einigung")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Dok.-Nr.: \(proposal.documentId.uuidString.prefix(8).uppercased())")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(proposal.documentDate.formatted(date: .long, time: .omitted))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // ── Sender / Recipient ─────────────────────────────────────────────

    private var senderRecipientBlock: some View {
        HStack(alignment: .top, spacing: 0) {
            // Sender
            VStack(alignment: .leading, spacing: 3) {
                pdfSectionLabel("ABSENDER (SCHULDNER)")
                Text(proposal.senderName)
                    .font(.system(size: 10, weight: .semibold))
                Text(proposal.senderAddress)
                    .font(.system(size: 10))
                if let email = proposal.senderEmail {
                    Text(email).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if let phone = proposal.senderPhone {
                    Text(phone).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Recipient
            VStack(alignment: .leading, spacing: 3) {
                pdfSectionLabel("EMPFÄNGER (GLÄUBIGER)")
                Text(proposal.creditorName)
                    .font(.system(size: 10, weight: .semibold))
                if let addr = proposal.creditorAddress {
                    Text(addr).font(.system(size: 10))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // ── Subject line ───────────────────────────────────────────────────

    private var subjectBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Betrifft:")
                    .font(.system(size: 10, weight: .semibold))
                Text("Ratenzahlungsantrag | Aktenzeichen: \(proposal.fileNumber)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(red: 0.18, green: 0.35, blue: 0.85))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.93, green: 0.96, blue: 1.0))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // ── Opening ────────────────────────────────────────────────────────

    private var openingText: some View {
        Text("""
        Sehr geehrte Damen und Herren,

        hiermit beantrage ich die Begleichung der oben genannten Forderung durch monatliche Ratenzahlungen. \
        Aufgrund meiner aktuellen wirtschaftlichen Lage ist mir eine Einmalzahlung nicht möglich. \
        Ich bitte um Ihre Zustimmung zu folgendem Zahlungsplan:
        """)
        .font(.system(size: 10))
        .lineSpacing(4)
        .fixedSize(horizontal: false, vertical: true)
    }

    // ── Debt summary ───────────────────────────────────────────────────

    private var debtSummaryTable: some View {
        VStack(spacing: 0) {
            pdfSectionLabel("FORDERUNGSÜBERSICHT")
            Spacer().frame(height: 6)
            pdfTableRow("Aktenzeichen",         value: proposal.fileNumber, mono: true)
            pdfTableRow("Gläubiger",            value: proposal.creditorName)
            pdfTableRow("Aktuelle Hauptforderung",
                        value: formatDecimal(proposal.totalAmount), bold: true)
        }
    }

    // ── Installment table ──────────────────────────────────────────────

    private var installmentTable: some View {
        VStack(spacing: 0) {
            pdfSectionLabel("VORGESCHLAGENER RATENZAHLUNGSPLAN")
            Spacer().frame(height: 6)

            pdfTableRow("Monatliche Rate",
                        value: formatDecimal(proposal.monthlyRate), bold: true,
                        valueColor: Color(red: 0.18, green: 0.35, blue: 0.85))
            pdfTableRow("Laufzeit",             value: "\(proposal.numberOfMonths) Monate")
            pdfTableRow("Erster Termin",         value: proposal.startDate.formatted(date: .long, time: .omitted))
            pdfTableRow("Letzter Termin",        value: proposal.endDate.formatted(date: .long, time: .omitted))
            pdfTableRow("Gesamtbetrag (Angebot)",value: formatDecimal(proposal.totalProposed))
            if proposal.discountDelta > 0 {
                pdfTableRow("Erlass-Differenz",  value: formatDecimal(proposal.discountDelta),
                            valueColor: .green)
            }
        }
    }

    // ── Closing ────────────────────────────────────────────────────────

    private var closingText: some View {
        Text("""
        Ich verpflichte mich, die Raten pünktlich zum ersten Werktag eines jeden Monats zu überweisen. \
        Bei Ausbleiben einer Rate behalte ich mir vor, unverzüglich Kontakt aufzunehmen. \
        Ich bitte um schriftliche Bestätigung dieses Angebots.

        Mit freundlichen Grüßen
        """)
        .font(.system(size: 10))
        .lineSpacing(4)
        .fixedSize(horizontal: false, vertical: true)
    }

    // ── Signature block ────────────────────────────────────────────────

    private var signatureBlock: some View {
        HStack(alignment: .bottom, spacing: 48) {
            // Signature image or blank field
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.08))
                        .frame(width: 220, height: 80)
                        .overlay(
                            Rectangle()
                                .frame(height: 1)
                                .foregroundStyle(Color.gray.opacity(0.3)),
                            alignment: .bottom
                        )

                    if let sig = signatureImage {
                        Image(uiImage: sig)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 220, height: 72)
                            .padding(.bottom, 4)
                    }
                }
                Text("\(proposal.senderName), \(proposal.documentDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                Text("Unterschrift Schuldner")
                    .font(.system(size: 9, weight: .semibold))
            }

            // Date field
            VStack(alignment: .leading, spacing: 4) {
                Rectangle()
                    .fill(Color.gray.opacity(0.08))
                    .frame(width: 160, height: 80)
                    .overlay(
                        Rectangle()
                            .frame(height: 1)
                            .foregroundStyle(Color.gray.opacity(0.3)),
                        alignment: .bottom
                    )
                Text("Datum / Stempel Gläubiger")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
    }

    // ── Footer ─────────────────────────────────────────────────────────

    private var footerBlock: some View {
        VStack(spacing: 4) {
            Divider()
            HStack {
                Text("Erstellt mit Schulden & Haushalt App • \(proposal.documentDate.formatted(date: .abbreviated, time: .shortened))")
                Spacer()
                Text("Dok. \(proposal.documentId.uuidString.prefix(8).uppercased())")
            }
            .font(.system(size: 7))
            .foregroundStyle(Color.gray.opacity(0.5))
        }
    }

    // ── Shared sub-components ──────────────────────────────────────────

    private func pdfSectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 7.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.gray.opacity(0.6))
    }

    private func pdfTableRow(
        _ label: String,
        value: String,
        mono:       Bool  = false,
        bold:       Bool  = false,
        valueColor: Color = .primary
    ) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .frame(width: 180, alignment: .leading)
            Text(value)
                .font(mono
                      ? .system(size: 9.5, weight: bold ? .semibold : .regular, design: .monospaced)
                      : .system(size: 9.5, weight: bold ? .semibold : .regular))
                .foregroundStyle(valueColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.gray.opacity(0.04))
        .overlay(Divider(), alignment: .bottom)
    }

    // ── Number Formatter ───────────────────────────────────────────────

    private func formatDecimal(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle     = .currency
        f.currencyCode    = "EUR"
        f.locale          = Locale(identifier: "de_DE")
        return f.string(for: d) ?? "\(d) €"
    }
}

// =============================================================================
// MARK: - 3. PDFDocumentRenderer
// =============================================================================

/// Converts `RatenzahlungsPDFTemplate` into a flat, password-owner-locked PDF.
enum PDFDocumentRenderer {

    // A4 page dimensions in points (72 dpi)
    static let pageSize = CGSize(width: 595, height: 842)

    // ── Public entry point ─────────────────────────────────────────────

    /// Renders the proposal + signature to a PDF `Data` blob.
    /// Uses `ImageRenderer` (iOS 16+) for SwiftUI → raster → PDF pipeline.
    /// Applies `CGPDFContext` owner password to prevent editing.
    ///
    /// - Returns: PDF `Data` or `nil` if rendering fails.
    @MainActor
    static func render(
        proposal:       InstallmentProposal,
        signatureImage: UIImage?
    ) async -> Data? {

        // 1. Render SwiftUI template → UIImage at 2× scale (≈ 144 dpi)
        let template = RatenzahlungsPDFTemplate(
            proposal:       proposal,
            signatureImage: signatureImage
        )

        let imageRenderer = ImageRenderer(content: template)
        imageRenderer.scale = 2.0   // retina quality

        guard let pageImage = imageRenderer.uiImage,
              let cgPage    = pageImage.cgImage else { return nil }

        // 2. Build PDF with CGPDFContext for metadata + owner-password lock
        let data = NSMutableData()
        // CGContext(consumer:mediaBox:) requires an inout CGRect;
        // use a local var so Swift can take its address legally.
        var mediaBox = CGRect(origin: .zero, size: pageSize)

        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdfCtx   = CGContext(
                consumer: consumer,
                mediaBox: &mediaBox,
                pdfMetadata(for: proposal)
              )
        else { return nil }

        // 3. Draw page
        pdfCtx.beginPDFPage(nil)
        pdfCtx.saveGState()

        // Scale rendered image to fit A4
        let scaleX = pageSize.width  / pageImage.size.width
        let scaleY = pageSize.height / pageImage.size.height
        pdfCtx.scaleBy(x: scaleX, y: scaleY)

        // UIImage coordinate system is flipped vs. PDF
        pdfCtx.translateBy(x: 0, y: pageImage.size.height)
        pdfCtx.scaleBy(x: 1, y: -1)

        pdfCtx.draw(cgPage, in: CGRect(origin: .zero, size: pageImage.size))

        pdfCtx.restoreGState()
        pdfCtx.endPDFPage()
        pdfCtx.closePDF()

        // 4. Verify with PDFKit and return
        let pdfData = data as Data
        guard PDFDocument(data: pdfData) != nil else { return nil }
        return pdfData
    }

    // ── PDF Metadata ───────────────────────────────────────────────────

    private static func pdfMetadata(for proposal: InstallmentProposal) -> CFDictionary {
        let ownerPwd = "owner-\(proposal.documentId.uuidString)"   // unique per doc

        return [
            kCGPDFContextTitle           as String: "Ratenzahlungsantrag – \(proposal.fileNumber)",
            kCGPDFContextAuthor          as String: proposal.senderName,
            kCGPDFContextCreator         as String: "Schulden & Haushalt iOS App",
            kCGPDFContextSubject         as String: "Ratenzahlungsantrag AZ \(proposal.fileNumber)",
            kCGPDFContextKeywords        as String: "Ratenzahlung Schuldner \(proposal.creditorName)",
            "CreationDate"                as String: proposal.documentDate,
            kCGPDFContextOwnerPassword   as String: ownerPwd,   // blocks editing in Acrobat
            kCGPDFContextUserPassword    as String: "",          // no password to open
            kCGPDFContextAllowsCopying   as String: false,
            kCGPDFContextAllowsPrinting  as String: true,
        ] as CFDictionary
    }
}


// =============================================================================
// MARK: - 4. ShareSheet
// =============================================================================

/// Presents `UIActivityViewController` with the PDF.
/// WhatsApp appears automatically if installed; Mail and AirDrop are always present.
struct ShareSheet: UIViewControllerRepresentable {
    let items:    [Any]
    /// Custom mail subject/body (used by `UIActivityItemSource` pattern below).
    var subject:  String?
    var onResult: ((Bool) -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Wrap items to inject subject/body for Mail
        let sources: [Any] = subject != nil
            ? items.map { MailableItem(payload: $0, subject: subject!) }
            : items

        let vc = UIActivityViewController(
            activityItems: sources,
            applicationActivities: nil
        )

        // Exclude irrelevant activity types
        vc.excludedActivityTypes = [
            .assignToContact,
            .addToReadingList,
            .openInIBooks,
            .markupAsPDF,        // prevent re-markup of our locked PDF
            .postToFlickr,
            .postToVimeo,
        ]

        vc.completionWithItemsHandler = { _, completed, _, _ in
            onResult?(completed)
        }

        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: UIActivityItemSource for Mail subject injection

private final class MailableItem: NSObject, UIActivityItemSource {
    let payload: Any
    let subject: String

    init(payload: Any, subject: String) {
        self.payload = payload
        self.subject = subject
    }

    func activityViewControllerPlaceholderItem(_ vc: UIActivityViewController) -> Any {
        payload
    }

    func activityViewController(
        _ vc: UIActivityViewController,
        itemForActivityType type: UIActivity.ActivityType?
    ) -> Any? {
        payload
    }

    func activityViewController(
        _ vc: UIActivityViewController,
        subjectForActivityType type: UIActivity.ActivityType?
    ) -> String {
        subject
    }
}

// =============================================================================
// MARK: - ExportCoordinatorView  (wires all three modules together)
// =============================================================================

struct ExportCoordinatorView: View {
    let proposal: InstallmentProposal

    @State private var drawing:      PKDrawing  = PKDrawing()
    @State private var pdfData:      Data?
    @State private var isRendering:  Bool       = false
    @State private var showShare:    Bool       = false
    @State private var renderError:  String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {

                    // ── Document preview card ──────────────────────────
                    documentPreviewCard

                    // ── Signature canvas ───────────────────────────────
                    SignatureCanvasView(drawing: $drawing)
                        .liquidGlassCard()
                        .padding(.horizontal)

                    // ── Action buttons ─────────────────────────────────
                    actionButtons
                }
                .padding(.vertical)
            }
            .navigationTitle("Ratenzahlungsantrag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isRendering {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button("PDF erstellen", action: generatePDF)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.primaryAccent)
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                if let data = pdfData {
                    let filename = "Ratenzahlung_\(proposal.fileNumber)_\(proposal.documentId.uuidString.prefix(6)).pdf"
                    let url = saveToTemp(data: data, filename: filename)
                    ShareSheet(
                        items: [url as Any],
                        subject: "Ratenzahlungsantrag AZ \(proposal.fileNumber)",
                        onResult: { _ in showShare = false }
                    )
                    .ignoresSafeArea()
                }
            }
            .alert("Fehler", isPresented: Binding(
                get: { renderError != nil },
                set: { if !$0 { renderError = nil } }
            )) {
                Button("OK") { renderError = nil }
            } message: {
                Text(renderError ?? "")
            }
        }
    }

    // ── Document Preview Card ─────────────────────────────────────────

    private var documentPreviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Vorschau", systemImage: "doc.richtext.fill")
                .font(.subheadline.weight(.semibold))

            // Inline scaled preview
            RatenzahlungsPDFTemplate(
                proposal: proposal,
                signatureImage: drawing.strokes.isEmpty
                    ? nil
                    : PencilKitSignatureCanvas.exportImage(
                        from: drawing,
                        size: CGSize(width: 220, height: 80)
                    )
            )
            .scaleEffect(0.45, anchor: .topLeading)
            .frame(
                width:  595 * 0.45,
                height: 842 * 0.45
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .frame(maxWidth: .infinity)
        }
        .liquidGlassCard()
        .padding(.horizontal)
    }

    // ── Action Buttons ─────────────────────────────────────────────────

    private var actionButtons: some View {
        VStack(spacing: 12) {
            // Generate + Share
            Button(action: generatePDF) {
                HStack {
                    if isRendering {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.up.doc.fill")
                    }
                    Text(isRendering ? "PDF wird erstellt…" : "PDF erstellen & teilen")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    isRendering
                        ? AnyShapeStyle(Theme.primaryAccent.opacity(0.5))
                        : AnyShapeStyle(Theme.primaryGradient),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
            .disabled(isRendering)

            // Share last PDF if available
            if pdfData != nil {
                Button {
                    showShare = true
                } label: {
                    Label("Letztes PDF erneut teilen", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.primaryAccent)
                }
            }
        }
        .padding(.horizontal)
    }

    // ── PDF Generation ─────────────────────────────────────────────────

    private func generatePDF() {
        guard !isRendering else { return }
        isRendering = true

        Task { @MainActor in
            defer { isRendering = false }

            let sigImage = drawing.strokes.isEmpty
                ? nil
                : PencilKitSignatureCanvas.exportImage(
                    from: drawing,
                    size: CGSize(width: 220, height: 80)
                  )

            if let data = await PDFDocumentRenderer.render(
                proposal: proposal,
                signatureImage: sigImage
            ) {
                pdfData   = data
                showShare = true
            } else {
                renderError = "PDF konnte nicht erstellt werden. Bitte erneut versuchen."
            }
        }
    }

    // ── File persistence ────────────────────────────────────────────────

    /// Saves `data` to both the temp directory (for the immediate share sheet)
    /// and the user's Documents/PDFs directory (for persistent Files.app access).
    /// Returns the stable Documents URL.
    private func saveToTemp(data: Data, filename: String) -> URL {
        // ── Temp (share sheet lifetime) ────────────────────────────────
        let tmpURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(filename)
        try? data.write(to: tmpURL, options: .atomic)

        // ── Documents/Schulden PDFs (permanent) ────────────────────────
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Schulden PDFs", conformingTo: .folder)
        try? FileManager.default.createDirectory(at: docs,
                                                 withIntermediateDirectories: true)
        let docURL = docs.appendingPathComponent(filename)
        try? data.write(to: docURL, options: .atomic)

        return tmpURL   // share sheet uses temp; Documents copy stays for Files.app
    }
}

// =============================================================================
// MARK: - 5. Schuldnerberatungs-Dossier (Blueprint §4)
// =============================================================================

struct DebtCounselingDossierSheet: View {
    let debts: [Debt]
    let userName: String
    let userAddress: String
    @Environment(\.dismiss) private var dismiss
    @State private var pdfURL: URL? = nil
    @State private var isGenerating = false

    init(debts: [Debt], userName: String, userAddress: String) {
        self.debts = debts
        self.userName = userName
        self.userAddress = userAddress
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Header card
                VStack(alignment: .leading, spacing: 10) {
                    Label("Schuldnerberatungs-Dossier", systemImage: "briefcase.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.primaryAccent)
                    Text("Tabellarische Gesamtaufstellung aller aktiven Gläubiger, Aktenzeichen und Forderungen zur direkten Vorlage bei der Schuldnerberatungsstelle oder dem Rechtsanwalt.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 20) {
                        VStack(alignment: .leading) {
                            Text("Gläubiger").font(.caption).foregroundStyle(.secondary)
                            Text("\(debts.count)").font(.title2.bold())
                        }
                        VStack(alignment: .leading) {
                            Text("Gesamtschulden").font(.caption).foregroundStyle(.secondary)
                            let total = debts.reduce(Decimal.zero) { $0 + $1.currentPrincipal }
                            Text(total, format: .currency(code: "EUR")).font(.title2.bold()).foregroundStyle(.red)
                        }
                        VStack(alignment: .leading) {
                            Text("Verjährungsverdacht").font(.caption).foregroundStyle(.secondary)
                            let expCount = debts.filter(\.limitationStatus.isPotentiallyExpired).count
                            Text("\(expCount)").font(.title2.bold()).foregroundStyle(.orange)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding()
                .liquidGlassCard(cornerRadius: 18)
                .padding(.horizontal)

                // List of items
                List(debts) { debt in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(debt.creditorName).font(.subheadline.bold())
                            Text(debt.fileNumber).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(debt.currentPrincipal, format: .currency(code: "EUR")).font(.subheadline.bold())
                            if debt.limitationStatus.isPotentiallyExpired {
                                Text("§ 195 BGB prüfen").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .listStyle(.plain)

                // Export Button
                if let url = pdfURL {
                    ShareLink(item: url) {
                        Label("Dossier als PDF teilen / drucken", systemImage: "square.and.arrow.up.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.primaryGradient, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .padding(.horizontal)
                } else {
                    Button {
                        generatePDF()
                    } label: {
                        if isGenerating {
                            ProgressView().tint(.white)
                        } else {
                            Label("Dossier als PDF generieren", systemImage: "doc.badge.plus")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Theme.primaryGradient, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    .disabled(isGenerating)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
            .navigationTitle("Dossier Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
            .onAppear {
                generatePDF()
            }
        }
    }

    private func generatePDF() {
        isGenerating = true
        Task {
            let fileURL = await DebtCounselingExportService.generateDossierPDF(
                debts: debts,
                userName: userName,
                userAddress: userAddress
            )
            await MainActor.run {
                self.pdfURL = fileURL
                self.isGenerating = false
            }
        }
    }
}

enum DebtCounselingExportService {
    @MainActor
    static func generateDossierPDF(
        debts: [Debt],
        userName: String,
        userAddress: String
    ) async -> URL? {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("Schuldnerberatung_Dossier_\(Date().formatted(date: .numeric, time: .omitted).replacingOccurrences(of: ".", with: "-")).pdf")

        do {
            try renderer.writePDF(to: tmpURL) { ctx in
                ctx.beginPage()
                var y: CGFloat = 50

                // Header
                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 18),
                    .foregroundColor: UIColor.black
                ]
                ("GESAMTAUFSTELLUNG FÜR DIE SCHULDNERBERATUNG" as NSString).draw(at: CGPoint(x: 50, y: y), withAttributes: titleAttrs)
                y += 26

                let subAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 10),
                    .foregroundColor: UIColor.darkGray
                ]
                ("Erstellt am: \(Date().formatted(date: .long, time: .omitted)) | Mandant: \(userName), \(userAddress)" as NSString).draw(at: CGPoint(x: 50, y: y), withAttributes: subAttrs)
                y += 24

                // Separator
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 50, y: y))
                path.addLine(to: CGPoint(x: 545, y: y))
                UIColor.lightGray.setStroke()
                path.stroke()
                y += 18

                // Table Header
                let thAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 10),
                    .foregroundColor: UIColor.black
                ]
                ("Gläubiger / Inkasso" as NSString).draw(at: CGPoint(x: 50, y: y), withAttributes: thAttrs)
                ("Aktenzeichen" as NSString).draw(at: CGPoint(x: 230, y: y), withAttributes: thAttrs)
                ("Status" as NSString).draw(at: CGPoint(x: 360, y: y), withAttributes: thAttrs)
                ("Forderung" as NSString).draw(at: CGPoint(x: 460, y: y), withAttributes: thAttrs)
                y += 18

                // Table Rows
                let rowAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 10),
                    .foregroundColor: UIColor.black
                ]
                for debt in debts {
                    if y > 760 {
                        ctx.beginPage()
                        y = 50
                    }
                    (debt.creditorName.prefix(25) as NSString).draw(at: CGPoint(x: 50, y: y), withAttributes: rowAttrs)
                    (debt.fileNumber.prefix(18) as NSString).draw(at: CGPoint(x: 230, y: y), withAttributes: rowAttrs)
                    (debt.status.displayName as NSString).draw(at: CGPoint(x: 360, y: y), withAttributes: rowAttrs)
                    (debt.currentPrincipal.formatted(.currency(code: "EUR")) as NSString).draw(at: CGPoint(x: 460, y: y), withAttributes: rowAttrs)
                    y += 18
                }

                // Total Summary
                y += 18
                let total = debts.reduce(Decimal.zero) { $0 + $1.currentPrincipal }
                let totalAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 12),
                    .foregroundColor: UIColor.black
                ]
                ("GESAMTFORDERUNG:" as NSString).draw(at: CGPoint(x: 230, y: y), withAttributes: totalAttrs)
                (total.formatted(.currency(code: "EUR")) as NSString).draw(at: CGPoint(x: 460, y: y), withAttributes: totalAttrs)
            }
            return tmpURL
        } catch {
            return nil
        }
    }
}

// =============================================================================
// MARK: - Preview
// =============================================================================

#Preview("Export Coordinator") {
    let proposal = InstallmentProposal(
        fileNumber:      "AZ-2024-00123",
        creditorName:    "Inkasso GmbH München",
        creditorAddress: "Musterstraße 1, 80331 München",
        totalAmount:     3_450.00,
        monthlyRate:     120.00,
        numberOfMonths:  24,
        startDate:       Calendar.current.date(byAdding: .month, value: 1, to: Date())!,
        reason:          "Aufgrund meiner aktuellen Einkommenssituation (Kurzarbeit seit 03/2024) ist mir eine Einmalzahlung der Gesamtforderung nicht möglich. Ich bitte um Verständnis und Zustimmung zu dem vorgeschlagenen Ratenzahlungsplan.",
        senderName:      "Kim Musterfrau",
        senderAddress:   "Hauptstraße 42, 10115 Berlin",
        senderEmail:     "kim@example.com",
        senderPhone:     "+49 30 12345678",
        documentDate:    Date(),
        documentId:      UUID()
    )

    ExportCoordinatorView(proposal: proposal)
        .preferredColorScheme(.dark)
}

#Preview("PDF Template – A4") {
    let proposal = InstallmentProposal(
        fileNumber: "AZ-2024-00123",
        creditorName: "Inkasso GmbH München",
        creditorAddress: "Musterstraße 1, 80331 München",
        totalAmount: 3_450.00,
        monthlyRate: 120.00,
        numberOfMonths: 24,
        startDate: Date(),
        reason: "Kurzarbeit seit 03/2024.",
        senderName: "Kim Musterfrau",
        senderAddress: "Hauptstraße 42, 10115 Berlin",
        senderEmail: "kim@example.com",
        senderPhone: nil,
        documentDate: Date(),
        documentId: UUID()
    )
    ScrollView {
        RatenzahlungsPDFTemplate(proposal: proposal, signatureImage: nil)
            .scaleEffect(0.5, anchor: .top)
            .frame(height: 842 * 0.5)
    }
}
