// =============================================================================
// SampleDocumentGenerator.swift
// Digitales Büro – Test-Generator nach Blueprint §2
// Requires: iOS 17+, Swift 5.9+, UIKit
//
// ── Zweck ─────────────────────────────────────────────────────────────────────
// Erzeugt auf Knopfdruck realistische Musterdokumente (EOS Inkasso-Mahnung,
// REWE-Kassenbon, Jura E5 Wartungsanleitung) zum sofortigen Testen der
// 4-Wege-Triage-Engine und der OCR auf dem Mac & iOS-Simulator.
// =============================================================================

import UIKit
import SwiftUI

enum SampleDocumentGenerator {

    /// Generiert 3 realistische Testdokumente für die 4-Wege-Triage (Schulden, Vorrat, Hardware)
    static func generateSamplePages() -> [ScannedPage] {
        let page1 = generateDebtSample()
        let page2 = generatePantrySample()
        let page3 = generateHardwareSample()
        return [page1, page2, page3]
    }

    // ── 1. Inkasso-Mahnung (👉 Swipe Rechts: Schulden) ────────────────────

    private static func generateDebtSample() -> ScannedPage {
        let text = """
        EOS Deutscher Inkasso-Dienst GmbH
        Postfach 57 04 20 | 22773 Hamburg

        Herrn / Frau Max Mustermann
        Musterstraße 1
        12345 Musterstadt

        Datum: 15.08.2024
        Aktenzeichen: EOS-2026-99410-DE
        (Bitte bei jeder Zahlung angeben)

        LETZTE MAHNUNG VOR GERICHTLICHEM MAHNVERFAHREN

        Sehr geehrte(r) Frau/Herr Mustermann,

        in vorbezeichneter Angelegenheit vertreten wir die Gläubigerin Vodafone GmbH.
        Trotz mehrfacher Zahlungsaufforderung ist der nachfolgende Betrag offen:

        Hauptforderung: 580,00 EUR
        Verzugszinsen: 42,50 EUR
        Inkassokosten: 120,00 EUR
        Gesamtbetrag: 742,50 EUR

        Zahlbar bis zum: 29.08.2024
        IBAN: DE88 2004 1155 0192 8412 00
        """

        let image = renderTextImage(title: "EOS DEUTSCHER INKASSO-DIENST", subtitle: "Aktenzeichen: EOS-2026-99410-DE\nForderung: 742,50 €\nZahlungsziel: 14 Tage", icon: "exclamationmark.triangle.fill", headerColor: .systemRed)
        var page = ScannedPage(image: image)
        page.ocrResult = OCRResult(
            rawText: text,
            fileNumbers: ["EOS-2026-99410-DE"],
            euroAmounts: [ParsedAmount(raw: "742,50 €", decimal: 742.50)]
        )
        return page
    }

    // ── 2. REWE Kassenbon (👈 Swipe Links: Vorrat) ────────────────────────

    private static func generatePantrySample() -> ScannedPage {
        let text = """
        REWE Markt GmbH
        Musterstr. 42, 12345 Musterstadt
        Kassenbon / Beleg-Nr. 4482

        1x Bio Hafermilch 1L           1,69 B
        2x Vollkorn Haferflocken 500g  1,58 A
        1x Bio Röstkaffee 500g         6,99 A
        1x Hartweizen Spaghetti 500g   0,99 B
        1x Tomatensauce Basilikum      1,89 B

        SUMME EUR                      13,14
        GEGEBEN BAR                    20,00
        RÜCKGELD                        6,86

        Vielen Dank für Ihren Einkauf!
        Datum: Heute
        """

        let image = renderTextImage(title: "REWE KASSENBON", subtitle: "Hafermilch, Haferflocken, Kaffee\nSumme: 13,14 €\nKategorie: Lebensmittel", icon: "cart.fill", headerColor: .systemBlue)
        var page = ScannedPage(image: image)
        page.ocrResult = OCRResult(
            rawText: text,
            fileNumbers: ["REWE-4482"],
            euroAmounts: [ParsedAmount(raw: "13,14 €", decimal: 13.14)]
        )
        return page
    }

    // ── 3. Jura E5 Kaffeemaschine (👆 Swipe Oben: Hardware) ───────────────

    private static func generateHardwareSample() -> ScannedPage {
        let text = """
        JURA Elektrogeräte Vertriebs-GmbH
        Service- & Wartungsbeleg

        Gerät: Jura E5 Kaffeevollautomat
        Seriennummer: JU-E5-884920
        Kundendienst-Wartungsbericht

        Durchgeführte Arbeiten:
        - Austausch Brühgruppen-Dichtungen
        - Intensiv-Entkalkung durchgeführt
        - Mahlwerk kalibriert
        
        Nächster empfohlener Filterwechsel: in 60 Tagen
        Wartungskosten: 89,00 EUR
        Belegdatum: 10.08.2024
        """

        let image = renderTextImage(title: "JURA E5 WARTUNGSBELEG", subtitle: "Gerät: Jura E5 Kaffeemaschine\nFilterwechsel & Dichtungen\nWartungskosten: 89,00 €", icon: "wrench.and.screwdriver.fill", headerColor: .systemPurple)
        var page = ScannedPage(image: image)
        page.ocrResult = OCRResult(
            rawText: text,
            fileNumbers: ["JU-E5-884920"],
            euroAmounts: [ParsedAmount(raw: "89,00 €", decimal: 89.00)]
        )
        return page
    }

    // ── Synthetic Image Renderer (High-Res Card) ───────────────────────────

    private static func renderTextImage(
        title: String,
        subtitle: String,
        icon: String,
        headerColor: UIColor
    ) -> UIImage {
        let size = CGSize(width: 800, height: 1100)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { ctx in
            // Background (Papieroptik)
            UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            // Header Banner
            headerColor.setFill()
            ctx.fill(CGRect(x: 40, y: 50, width: size.width - 80, height: 120))

            // Header Title
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 34),
                .foregroundColor: UIColor.white
            ]
            (title as NSString).draw(at: CGPoint(x: 70, y: 90), withAttributes: titleAttrs)

            // Content Box
            UIColor.white.setFill()
            let contentRect = CGRect(x: 40, y: 200, width: size.width - 80, height: size.height - 260)
            UIBezierPath(roundedRect: contentRect, cornerRadius: 16).fill()

            // Subtitle / Text Body
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 26, weight: .regular),
                .foregroundColor: UIColor(red: 0.15, green: 0.15, blue: 0.20, alpha: 1.0)
            ]
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 12
            var fullAttrs = bodyAttrs
            fullAttrs[.paragraphStyle] = paragraph

            (subtitle as NSString).draw(
                in: CGRect(x: 80, y: 250, width: size.width - 160, height: size.height - 350),
                withAttributes: fullAttrs
            )

            // Watermark / Badge
            let stampAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 22),
                .foregroundColor: headerColor.withAlphaComponent(0.8)
            ]
            ("MUSTERDOKUMENT FÜR TRIAGE-TEST" as NSString).draw(
                at: CGPoint(x: 80, y: size.height - 120),
                withAttributes: stampAttrs
            )
        }
    }
}
