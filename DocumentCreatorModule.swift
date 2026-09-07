// =============================================================================
// DocumentCreatorModule.swift
// Digitales Büro – Dokumenten-Ersteller im Assistentenmodus
// Requires: iOS 17+, Swift 5.9+, PencilKit, PDFKit, UIKit
// =============================================================================

import SwiftUI
import PencilKit
import PDFKit
import UIKit

// =============================================================================
// MARK: - 1. Vorlagen & Dokument-Typen
// =============================================================================

public enum DocumentTemplateType: String, CaseIterable, Identifiable, Sendable {
    case objectionDebt        = "Widerspruch Inkasso / Mahnung"
    case terminationContract  = "Kündigung Vertrag / Abo"
    case installmentProposal  = "Ratenzahlungsangebot & Stundung"
    case deadlineExtension    = "Fristverlängerung (Behörde / Gläubiger)"
    case gdprRequest          = "DSGVO-Auskunft & Löschung (Art. 15)"
    case statuteOfLimitations = "Einrede der Verjährung (§ 214 BGB)"
    case customAI             = "Freies Schreiben (KI-Assistent)"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .objectionDebt:        return "exclamationmark.shield.fill"
        case .terminationContract:  return "scissors.badge.ellipsis"
        case .installmentProposal:  return "chart.line.downtrend.xyaxis.circle.fill"
        case .deadlineExtension:    return "calendar.badge.clock"
        case .gdprRequest:          return "lock.shield.fill"
        case .statuteOfLimitations: return "hourglass.bottomhalf.filled"
        case .customAI:             return "sparkles"
        }
    }

    public var color: Color {
        switch self {
        case .objectionDebt:        return .orange
        case .terminationContract:  return .red
        case .installmentProposal:  return .green
        case .deadlineExtension:    return .blue
        case .gdprRequest:          return .purple
        case .statuteOfLimitations: return .yellow
        case .customAI:             return Theme.primaryAccent
        }
    }

    public var description: String {
        switch self {
        case .objectionDebt:
            return "Rechtssicherer Widerspruch gegen unberechtigte Haupt- oder Inkassogebühren mit Vollmachtsrüge."
        case .terminationContract:
            return "Fristgerechte Kündigung von Verträgen, Abonnements oder Mitgliedschaften mit Bestätigungsbitte."
        case .installmentProposal:
            return "Konkreter Ratenzahlungsvorschlag mit Bitte um Zinsstopp und Aussetzung von Mahnmaßnahmen."
        case .deadlineExtension:
            return "Formeller Antrag auf Fristverlängerung zur Klärung von Sachverhalten bei Behörden oder Inkasso."
        case .gdprRequest:
            return "Auskunftsersuchen nach Art. 15 DSGVO sowie Sperrung/Löschung gespeicherter personenbezogener Daten."
        case .statuteOfLimitations:
            return "Einrede der regelmäßigen Verjährung (§§ 195, 199 BGB) für unbegründete Altforderungen."
        case .customAI:
            return "Beschreibe dein Anliegen in Alltagssprache – der Assistent formuliert ein formelles DIN-Anschreiben."
        }
    }

    public var defaultCategory: DocumentCategory {
        switch self {
        case .objectionDebt, .installmentProposal, .statuteOfLimitations:
            return .debts
        case .terminationContract:
            return .contracts
        case .deadlineExtension:
            return .authorities
        case .gdprRequest:
            return .other
        case .customAI:
            return .contracts
        }
    }

    /// Erzeugt standardmäßige DIN-5008-Absätze basierend auf Vorlage und Parametern
    public func generateStandardDraft(
        senderName: String,
        senderAddress: String,
        recipientName: String,
        recipientAddress: String,
        referenceNumber: String,
        extraNote: String,
        amount: String
    ) -> (subject: String, body: String) {
        let refText = referenceNumber.isEmpty ? "Ohne Aktenzeichen" : referenceNumber
        let amtText = amount.isEmpty ? "" : " in Höhe von \(amount) €"

        switch self {
        case .objectionDebt:
            let subject = "Widerspruch gegen Zahlungsaufforderung – Aktenzeichen: \(refText)"
            let body = """
            Sehr geehrte Damen und Herren,

            in vorbezeichneter Angelegenheit nehme ich Bezug auf Ihr Schreiben vom \(Date().formatted(date: .numeric, time: .omitted)).

            Gegen die von Ihnen geltend gemachte Forderung\(amtText) lege ich hiermit ausdrücklich

            W I D E R S P R U C H

            ein.

            Die Forderung wird sowohl dem Grunde als auch der Höhe nach vollumfänglich bestritten. Insbesondere werden die geltend gemachten Inkassogebühren und Nebenkosten als unberechtigt und überhöht zurückgewiesen (vgl. § 4 Abs. 5 RDGEG sowie § 254 BGB).

            Zudem fordere ich Sie hiermit gemäß § 174 BGB auf, mir unverzüglich eine ordnungsgemäße, im Original unterzeichnete Vollmachtsurkunde Ihres Auftraggebers vorzulegen.

            Bis zur abschließenden Klärung und Vorlage der Unterlagen fordere ich Sie auf, von weiteren Mahnmaßnahmen sowie einer unzulässigen Datenübermittlung an Auskunfteien (z. B. SCHUFA) gemäß § 31 BDSG abzusehen.

            Mit freundlichen Grüßen
            """
            return (subject, body)

        case .terminationContract:
            let subject = "Kündigung meines Vertrages – Vertrags-/Kundennummer: \(refText)"
            let body = """
            Sehr geehrte Damen und Herren,

            hiermit kündige ich den mit Ihnen bestehenden Vertrag zum nächstmöglichen Zeitpunkt ordentlich und fristgerecht.

            Vertrags- / Kundennummer: \(refText)
            \(extraNote.isEmpty ? "" : "Zusatzhinweis: " + extraNote + "\n")
            Gleichzeitig widerrufe ich die Ihnen erteilte Einzugsermächtigung bzw. das SEPA-Lastschriftmandat mit Wirkung zum Beendigungszeitpunkt.

            Bitte senden Sie mir eine schriftliche Bestätigung dieser Kündigung unter Angabe des genauen Vertragsbeendigungsdatums innerhalb der nächsten 14 Tage zu.

            Von telefonischen oder postalischen Angeboten zur Kundenrückgewinnung bitte ich ausdrücklich abzusehen.

            Mit freundlichen Grüßen
            """
            return (subject, body)

        case .installmentProposal:
            let rate = extraNote.isEmpty ? "50,00" : extraNote
            let subject = "Ratenzahlungsvereinbarung & Stundungsantrag – Az: \(refText)"
            let body = """
            Sehr geehrte Damen und Herren,

            in vorbezeichneter Angelegenheit bezüglich Ihrer Forderung\(amtText) (Aktenzeichen: \(refText)) nehme ich wie folgt Stellung.

            Aufgrund meiner aktuellen wirtschaftlichen Situation ist es mir derzeit leider nicht möglich, den Gesamtbetrag auf einmal zu begleichen. Um die Angelegenheit dennoch einvernehmlich und zügig zu regeln, biete ich Ihnen hiermit folgenden verbindlichen Tilgungsplan an:

            Monatliche Rate: \(rate) EUR
            Beginn der Zahlung: zum 1. des Folgemonats

            Ich bitte Sie höflich, diesem Ratenzahlungsvorschlag zuzustimmen und während der laufenden Tilgung auf die Geltendmachung weiterer Verzugszinsen und Mahnkosten zu verzichten sowie etwaige Vollstreckungsmaßnahmen auszusetzen.

            Bitte teilen Sie mir Ihre Bestätigung sowie die entsprechende Bankverbindung mit dem Verwendungszweck mit.

            Mit freundlichen Grüßen
            """
            return (subject, body)

        case .deadlineExtension:
            let subject = "Antrag auf Fristverlängerung – Vorgangsnummer: \(refText)"
            let body = """
            Sehr geehrte Damen und Herren,

            in oben bezeichneter Angelegenheit habe ich Ihr Schreiben erhalten.

            Zur sorgfältigen Prüfung des Sachverhalts und Zusammenstellung der erforderlichen Unterlagen benötige ich noch etwas Zeit. Aus diesem Grund beantrage ich hiermit höflich eine

            Verlängerung der gesetzten Frist bis zum \(Calendar.current.date(byAdding: .day, value: 21, to: Date())!.formatted(date: .numeric, time: .omitted)).

            \(extraNote.isEmpty ? "" : "Begründung: " + extraNote + "\n")
            Ich danke Ihnen im Voraus für Ihr Verständnis und Ihr Entgegenkommen.

            Mit freundlichen Grüßen
            """
            return (subject, body)

        case .gdprRequest:
            let subject = "Auskunftsersuchen nach Art. 15 DSGVO – Ref: \(refText)"
            let body = """
            Sehr geehrte Damen und Herren,

            gemäß Art. 15 der Datenschutz-Grundverordnung (DSGVO) fordere ich Sie hiermit auf, mir unentgeltlich innerhalb der gesetzlichen Frist von einem Monat Auskunft darüber zu erteilen, welche personenbezogenen Daten Sie zu meiner Person verarbeiten und gespeichert haben.

            Dies umfasst insbesondere:
            1. Die Verarbeitungszwecke sowie die Kategorien personenbezogener Daten.
            2. Die Empfänger oder Kategorien von Empfängern, gegenüber denen Daten offengelegt wurden (inkl. Scoring-Werte und Auskunfteien).
            3. Die geplante Speicherdauer bzw. die Kriterien für deren Festlegung.
            4. Die Herkunft der Daten, soweit sie nicht bei mir erhoben wurden.

            Sollten Daten an Dritte übermittelt worden sein, bitte ich um namentliche Benennung.

            Mit freundlichen Grüßen
            """
            return (subject, body)

        case .statuteOfLimitations:
            let subject = "Einrede der Verjährung – Aktenzeichen: \(refText)"
            let body = """
            Sehr geehrte Damen und Herren,

            bezugnehmend auf Ihre Zahlungsaufforderung vom \(Date().formatted(date: .numeric, time: .omitted)) bezüglich der Forderung\(amtText) (Az: \(refText)) teile ich Ihnen Folgendes mit:

            Ich erhebe hiermit ausdrücklich die

            E I N R E D E   D E R   V E R J Ä H R U N G

            gemäß § 214 Abs. 1 BGB in Verbindung mit der regelmäßigen dreijährigen Verjährungsfrist nach §§ 195, 199 BGB.

            Die behaupteten Ansprüche sind verjährt. Ich werde daher keinerlei Zahlungen leisten. Ich fordere Sie auf, die Forderungsakte endgültig zu schließen und mir eine Bestätigung hierüber zukommen zu lassen.

            Mit freundlichen Grüßen
            """
            return (subject, body)

        case .customAI:
            let subject = "Schreiben bezüglich: \(refText.isEmpty ? "Angelegenheit" : refText)"
            let body = """
            Sehr geehrte Damen und Herren,

            in vorbezeichneter Angelegenheit wende ich mich mit folgendem Sachverhalt an Sie:

            \(extraNote.isEmpty ? "Bitte formulieren Sie hier Ihr Anliegen oder nutzen Sie den KI-Assistenten." : extraNote)

            Ich bitte um zeitnahe Bearbeitung und Rückmeldung.

            Mit freundlichen Grüßen
            """
            return (subject, body)
        }
    }
}

// =============================================================================
// MARK: - 2. Datenmodell für erstellte Dokumente
// =============================================================================

public struct CreatedDocumentDraft: Sendable {
    public var templateType: DocumentTemplateType
    public var senderName: String
    public var senderAddress: String
    public var senderPhone: String
    public var senderEmail: String
    public var recipientName: String
    public var recipientAddress: String
    public var referenceNumber: String
    public var amount: String
    public var subject: String
    public var bodyText: String
    public var date: Date
    public var hasSignature: Bool
    public var userPrompt: String

    public init(
        templateType: DocumentTemplateType = .objectionDebt,
        senderName: String = "",
        senderAddress: String = "",
        senderPhone: String = "",
        senderEmail: String = "",
        recipientName: String = "",
        recipientAddress: String = "",
        referenceNumber: String = "",
        amount: String = "",
        subject: String = "",
        bodyText: String = "",
        date: Date = Date(),
        hasSignature: Bool = false,
        userPrompt: String = ""
    ) {
        self.templateType = templateType
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.senderPhone = senderPhone
        self.senderEmail = senderEmail
        self.recipientName = recipientName
        self.recipientAddress = recipientAddress
        self.referenceNumber = referenceNumber
        self.amount = amount
        self.subject = subject
        self.bodyText = bodyText
        self.date = date
        self.hasSignature = hasSignature
        self.userPrompt = userPrompt
    }
}

// =============================================================================
// MARK: - 3. DocumentAssistantCreatorView (Haupt-Assistent)
// =============================================================================

public struct DocumentAssistantCreatorView: View {
    @ObservedObject public var service: DocumentArchiveService
    public var initialDocument: AppDocument?
    @Environment(\.dismiss) private var dismiss

    // Wizard-Schritte: 0 = Zweck / Vorlage, 1 = Daten & Details, 2 = Schreiben & Feinschliff, 3 = DIN 5008 Vorschau & Signatur
    @State private var currentStep: Int = 0

    // Entwurfsdaten
    @State private var draft = CreatedDocumentDraft()
    @State private var signatureDrawing: PKDrawing = PKDrawing()
    @State private var isGeneratingAI: Bool = false
    @State private var aiStatusText: String = ""
    @State private var showShareSheet: Bool = false
    @State private var generatedPDFURL: URL? = nil
    @State private var generatedPDFData: Data? = nil
    @State private var isSavedToDMS: Bool = false
    @State private var showSaveSuccessToast: Bool = false

    // Assistenten-Tonfall
    @State private var selectedTone: Int = 0 // 0 = Bestimmt & Rechtssicher, 1 = Kooperativ & Höflich, 2 = Prägnant & Direkt

    public init(service: DocumentArchiveService, initialDocument: AppDocument? = nil) {
        self.service = service
        self.initialDocument = initialDocument
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Schritt-Indikator
                    stepHeaderView
                        .padding(.top, 8)
                        .padding(.bottom, 12)

                    // Haupt-Inhalt je nach Schritt
                    TabView(selection: $currentStep) {
                        step1TemplateSelection.tag(0)
                        step2DataInput.tag(1)
                        step3EditorAndAI.tag(2)
                        step4PreviewAndSign.tag(3)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    // Untere Navigationsleiste
                    bottomButtonBar
                }
            }
            .navigationTitle("Doku-Ersteller")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if currentStep == 3 {
                        Button {
                            finalizeAndSave()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isSavedToDMS ? "checkmark.circle.fill" : "arrow.down.doc.fill")
                                Text(isSavedToDMS ? "Gespeichert" : "Speichern")
                            }
                            .font(.subheadline.bold())
                        }
                        .tint(isSavedToDMS ? .green : Theme.primaryAccent)
                    }
                }
            }
            .onAppear {
                setupInitialData()
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = generatedPDFURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    // ── Initialisierung ──────────────────────────────────────────────────

    private func setupInitialData() {
        // Lade Profil-Absenderdaten
        if let data = UserDefaults.standard.data(forKey: "app_user_profile_data"),
           let profile = try? JSONDecoder().decode(UserProfile.self, from: data) {
            draft.senderName = profile.name
            draft.senderAddress = profile.address
            draft.senderPhone = profile.phone
        } else {
            draft.senderName = "Max Mustermann"
            draft.senderAddress = "Musterstraße 1, 12345 Musterstadt"
        }

        // Falls aus einem Bestandsdokument aufgerufen:
        if let doc = initialDocument {
            draft.recipientName = doc.sender ?? ""
            draft.referenceNumber = doc.fileNumber ?? ""
            if let amt = doc.amount {
                draft.amount = "\(amt)".replacingOccurrences(of: ".", with: ",")
            }

            // Passende Vorlage vorwählen
            if doc.category == .debts {
                draft.templateType = .objectionDebt
            } else if doc.category == .contracts {
                draft.templateType = .terminationContract
            } else if doc.category == .authorities {
                draft.templateType = .deadlineExtension
            }

            // Sofort mit Schritt 1 oder 2 starten
            currentStep = 1
            applyTemplateDraft()
        } else {
            applyTemplateDraft()
        }
    }

    private func applyTemplateDraft() {
        let result = draft.templateType.generateStandardDraft(
            senderName: draft.senderName,
            senderAddress: draft.senderAddress,
            recipientName: draft.recipientName,
            recipientAddress: draft.recipientAddress,
            referenceNumber: draft.referenceNumber,
            extraNote: draft.userPrompt,
            amount: draft.amount
        )
        draft.subject = result.subject
        draft.bodyText = result.body
    }

    // ── 1. Schritt-Leiste ────────────────────────────────────────────────

    private var stepHeaderView: some View {
        HStack(spacing: 8) {
            stepIndicatorPill(step: 0, title: "Zweck", icon: "list.bullet")
            stepDivider
            stepIndicatorPill(step: 1, title: "Daten", icon: "person.text.rectangle")
            stepDivider
            stepIndicatorPill(step: 2, title: "Text & KI", icon: "pencil.line")
            stepDivider
            stepIndicatorPill(step: 3, title: "Vorschau", icon: "doc.richtext")
        }
        .padding(.horizontal, 16)
    }

    private func stepIndicatorPill(step: Int, title: String, icon: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                currentStep = step
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: currentStep == step ? icon + ".fill" : icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.caption2.bold())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                currentStep == step
                    ? Theme.primaryAccent.opacity(0.2)
                    : Color.white.opacity(0.04),
                in: Capsule()
            )
            .overlay {
                if currentStep == step {
                    Capsule().strokeBorder(Theme.primaryAccent, lineWidth: 1)
                }
            }
            .foregroundStyle(currentStep == step ? Theme.primaryAccent : .secondary)
        }
    }

    private var stepDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .frame(maxWidth: 16)
    }

    // ── SCHRITT 1: Vorlagenauswahl ───────────────────────────────────────

    private var step1TemplateSelection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Intro Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Theme.primaryAccent)
                        Text("Assistenten-Modus")
                            .font(.subheadline.bold())
                            .foregroundStyle(Theme.primaryAccent)
                        Spacer()
                    }
                    Text("Was möchtest du erstellen?")
                        .font(.title3.bold())
                    Text("Wähle ein Anliegen. Der Assistent bereitet das Anschreiben automatisch formell und rechtssicher nach DIN 5008 vor.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .liquidGlassCard(cornerRadius: 18)

                // Vorlagen-Liste
                VStack(spacing: 12) {
                    ForEach(DocumentTemplateType.allCases) { tpl in
                        templateSelectionCard(tpl)
                    }
                }
            }
            .padding(16)
        }
    }

    private func templateSelectionCard(_ tpl: DocumentTemplateType) -> some View {
        let isSelected = draft.templateType == tpl
        return Button {
            withAnimation(.spring(response: 0.3)) {
                draft.templateType = tpl
                applyTemplateDraft()
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(tpl.color.opacity(isSelected ? 0.25 : 0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: tpl.icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(tpl.color)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(tpl.rawValue)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text(tpl.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Theme.primaryAccent : .secondary.opacity(0.4))
            }
            .padding(14)
            .background(
                isSelected ? Theme.primaryAccent.opacity(0.1) : Color.white.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(Theme.primaryAccent) : AnyShapeStyle(Theme.glassEdgeGradient),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
    }

    // ── SCHRITT 2: Daten & Adressen ─────────────────────────────────────

    private var step2DataInput: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Info Banner
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Theme.primaryAccent)
                    Text("Alle Felder sind vorbefüllt, können aber jederzeit manuell angepasst werden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                // Absender
                VStack(alignment: .leading, spacing: 10) {
                    Label("Absender (Deine Angaben)", systemImage: "person.fill")
                        .font(.headline)

                    customTextField(title: "Dein Name", text: $draft.senderName, placeholder: "Max Mustermann")
                    customTextField(title: "Deine Anschrift", text: $draft.senderAddress, placeholder: "Musterstr. 1, 12345 Musterstadt")
                    HStack(spacing: 10) {
                        customTextField(title: "Telefon (optional)", text: $draft.senderPhone, placeholder: "0151 1234567")
                        customTextField(title: "E-Mail (optional)", text: $draft.senderEmail, placeholder: "max@beispiel.de")
                    }
                }
                .padding(16)
                .liquidGlassCard(cornerRadius: 18)

                // Empfänger
                VStack(alignment: .leading, spacing: 10) {
                    Label("Empfänger (Firma / Inkasso / Behörde)", systemImage: "building.2.fill")
                        .font(.headline)

                    customTextField(title: "Empfänger / Firmenname", text: $draft.recipientName, placeholder: "z. B. EOS Deutscher Inkassodienst GmbH")
                    customTextField(title: "Anschrift des Empfängers", text: $draft.recipientAddress, placeholder: "Postfach 57 04 20, 22773 Hamburg")
                }
                .padding(16)
                .liquidGlassCard(cornerRadius: 18)

                // Bezugsdaten
                VStack(alignment: .leading, spacing: 10) {
                    Label("Aktenzeichen & Betrag", systemImage: "number.circle.fill")
                        .font(.headline)

                    HStack(spacing: 10) {
                        customTextField(title: "Aktenzeichen / Kundennr.", text: $draft.referenceNumber, placeholder: "z. B. EOS-2026-99410")
                        customTextField(title: "Betrag (€)", text: $draft.amount, placeholder: "z. B. 742,50", keyboardType: .decimalPad)
                    }

                    if draft.templateType == .customAI || draft.templateType == .objectionDebt {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Besondere Hinweise / Begründung an den Assistenten")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("z. B. Ware wurde am 12. zurückgesendet, Nachweis vorhanden...", text: $draft.userPrompt, axis: .vertical)
                                .lineLimit(2...4)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .padding(16)
                .liquidGlassCard(cornerRadius: 18)
            }
            .padding(16)
        }
    }

    // ── SCHRITT 3: Text-Editor & KI-Feinschliff ──────────────────────────

    private var step3EditorAndAI: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // KI-Assistenz Leiste
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Theme.primaryAccent)
                        Text("KI-Formulierungshilfe")
                            .font(.headline)
                        Spacer()

                        if isGeneratingAI {
                            ProgressView()
                                .tint(Theme.primaryAccent)
                        }
                    }

                    // Tonalität
                    Picker("Tonfall", selection: $selectedTone) {
                        Text("Rechtssicher").tag(0)
                        Text("Kooperativ").tag(1)
                        Text("Prägnant").tag(2)
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 10) {
                        Button {
                            regenerateWithStandardTemplate()
                        } label: {
                            Label("Vorlage neu laden", systemImage: "arrow.counterclockwise")
                                .font(.caption.bold())
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.white.opacity(0.08), in: Capsule())
                        }

                        Button {
                            generateWithAIAssistant()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "wand.and.stars")
                                Text("Mit KI verfeinern")
                            }
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.primaryGradient, in: Capsule())
                        }
                    }

                    if !aiStatusText.isEmpty {
                        Text(aiStatusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .liquidGlassCard(cornerRadius: 18)

                // Betreff-Zeile (Editierbar)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Betreffzeile (Wird fett gedruckt)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    TextField("Betreff...", text: $draft.subject)
                        .font(.subheadline.bold())
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(14)
                .liquidGlassCard(cornerRadius: 16)

                // Fließtext (Vollständig frei editierbar)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Brieftext (Vollständig bearbeitbar)")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(draft.bodyText.count) Zeichen")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    TextEditor(text: $draft.bodyText)
                        .font(.system(.body, design: .default))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 260)
                        .padding(10)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(14)
                .liquidGlassCard(cornerRadius: 16)
            }
            .padding(16)
        }
    }

    // ── SCHRITT 4: DIN 5008 Briefvorschau & Signatur ─────────────────────

    private var step4PreviewAndSign: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Brief-Vorschau (DIN A4 Karte)
                din5008PaperPreview

                // Digitale Signatur Karte
                signatureBox
            }
            .padding(16)
        }
    }

    /// Echtes DIN 5008 Briefpapier-Rendering
    private var din5008PaperPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Absender klein oben
            Text("\(draft.senderName) • \(draft.senderAddress)")
                .font(.system(size: 9))
                .underline()
                .foregroundStyle(Color.black.opacity(0.6))
                .padding(.bottom, 4)

            // Empfänger Anschriftenfeld
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.recipientName.isEmpty ? "Firma / Empfänger" : draft.recipientName)
                    .font(.system(size: 13, weight: .bold))
                Text(draft.recipientAddress.isEmpty ? "Anschrift, PLZ Ort" : draft.recipientAddress)
                    .font(.system(size: 12))
            }
            .foregroundStyle(.black)
            .frame(height: 55, alignment: .topLeading)

            // Datum rechts
            HStack {
                Spacer()
                Text("Datum: \(draft.date.formatted(date: .long, time: .omitted))")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.black.opacity(0.7))
            }

            Divider()
                .background(Color.black.opacity(0.2))

            // Betreff
            Text(draft.subject)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.black)
                .padding(.vertical, 4)

            // Textkörper
            Text(draft.bodyText)
                .font(.system(size: 11, design: .serif))
                .foregroundStyle(Color.black.opacity(0.88))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            // Unterschriften-Vorschau
            VStack(alignment: .leading, spacing: 4) {
                if !signatureDrawing.bounds.isEmpty {
                    Image(uiImage: renderSignatureImage())
                        .resizable()
                        .scaledToFit()
                        .frame(height: 40)
                }
                Text(draft.senderName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
            }
            .padding(.top, 10)
        }
        .padding(20)
        .background(Color(red: 0.98, green: 0.98, blue: 0.96)) // Briefpapier-Weiß
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.25), radius: 10, y: 5)
    }

    /// Signatur-Box mit PencilKit Canvas
    private var signatureBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Digitale Unterschrift (Optional)", systemImage: "signature")
                    .font(.subheadline.bold())
                Spacer()
                if !signatureDrawing.bounds.isEmpty {
                    Button("Löschen") {
                        signatureDrawing = PKDrawing()
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }

            Text("Unterschreibe mit Finger oder Apple Pencil. Sie wird automatisch in das PDF-Anschreiben eingefügt.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            PencilKitSignatureCanvas(
                drawing: $signatureDrawing,
                inkColor: .white,
                inkWidth: 2.0,
                backgroundColor: UIColor(red: 0.12, green: 0.12, blue: 0.18, alpha: 1.0),
                cornerRadius: 12
            )
            .frame(height: 120)
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.glassEdgeGradient, lineWidth: 1)
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 16)
    }

    // ── Untere Navigationsleiste ─────────────────────────────────────────

    private var bottomButtonBar: some View {
        HStack(spacing: 12) {
            if currentStep > 0 {
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        currentStep -= 1
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Zurück")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                }
            }

            Spacer()

            if currentStep < 3 {
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        if currentStep == 0 {
                            applyTemplateDraft()
                        }
                        currentStep += 1
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(currentStep == 2 ? "Zur Vorschau" : "Weiter")
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Theme.primaryGradient, in: RoundedRectangle(cornerRadius: 14))
                }
            } else {
                // Auf Schritt 3: Teilen & Export
                Button {
                    generatePDFAndShare()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Teilen / Drucken")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Theme.primaryAccent, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // ── Hilfsfunktionen ──────────────────────────────────────────────────

    private func customTextField(title: String, text: Binding<String>, placeholder: String, keyboardType: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .keyboardType(keyboardType)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func regenerateWithStandardTemplate() {
        withAnimation {
            applyTemplateDraft()
            aiStatusText = "Standardvorlage wiederhergestellt."
        }
    }

    private func generateWithAIAssistant() {
        let toneName = selectedTone == 0 ? "bestimmt, sachlich und rechtssicher" : (selectedTone == 1 ? "kooperativ und höflich" : "prägnant und direkt")
        isGeneratingAI = true
        aiStatusText = "KI optimiert Anschreiben (\(toneName))…"

        Task {
            let gemini = GeminiService()
            let prompt = """
            Verfasse ein formelles, fehlerfreies Anschreiben nach deutschem Standard (DIN 5008).
            Zweck: \(draft.templateType.rawValue)
            Absender: \(draft.senderName), \(draft.senderAddress)
            Empfänger: \(draft.recipientName), \(draft.recipientAddress)
            Aktenzeichen / Referenz: \(draft.referenceNumber)
            Betrag: \(draft.amount)
            Hinweise des Nutzers: \(draft.userPrompt)
            Tonalität: \(toneName).

            Antworte bitte ZWINGEND in zwei Abschnitten:
            BETREFF: [Hier eine präzise Betreffzeile]
            TEXT:
            [Hier der vollständige, professionelle Brieftext inklusive Anrede und Grußformel]
            """

            do {
                let stream = gemini.streamResponse(
                    prompt: prompt,
                    systemContext: "Du bist ein erfahrener juristischer Assistent für deutsches Zivil- und Vertragsrecht. Antworte immer auf Deutsch und formuliere rechtssicher.",
                    history: []
                )

                var fullAnswer = ""
                for try await chunk in stream {
                    fullAnswer += chunk
                }

                if fullAnswer.contains("BETREFF:") && fullAnswer.contains("TEXT:") {
                    let parts = fullAnswer.components(separatedBy: "TEXT:")
                    let subjectPart = parts[0].replacingOccurrences(of: "BETREFF:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let textPart = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : draft.bodyText

                    await MainActor.run {
                        withAnimation {
                            draft.subject = subjectPart
                            draft.bodyText = textPart
                            aiStatusText = "✓ Text erfolgreich mit KI verfeinert!"
                            isGeneratingAI = false
                        }
                    }
                } else if !fullAnswer.isEmpty {
                    await MainActor.run {
                        withAnimation {
                            draft.bodyText = fullAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                            aiStatusText = "✓ Text mit KI formuliert!"
                            isGeneratingAI = false
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    aiStatusText = "⚠️ KI-Optimierung nicht verfügbar: Lokale Standardvorlage aktiv."
                    isGeneratingAI = false
                }
            }
        }
    }

    private func renderSignatureImage() -> UIImage {
        let bounds = signatureDrawing.bounds
        guard bounds.width > 0, bounds.height > 0 else { return UIImage() }
        let image = signatureDrawing.image(from: bounds, scale: 2.0)
        return image
    }

    // ── PDF-Erstellung & DMS-Ablage ──────────────────────────────────────

    private func buildPDFData() -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "Digitales Büro – Doku-Ersteller",
            kCGPDFContextAuthor as String: draft.senderName,
            kCGPDFContextTitle as String: draft.subject
        ]

        // DIN A4 @ 72 DPI: 595.2 x 841.8 pt
        let pageWidth: CGFloat = 595.2
        let pageHeight: CGFloat = 841.8
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)

        return renderer.pdfData { context in
            context.beginPage()

            let margin: CGFloat = 54.0 // ca. 2 cm

            // 1. Absenderzeile klein oben (DIN 5008 Anschriftenfeld)
            let returnAddress = "\(draft.senderName) • \(draft.senderAddress)"
            let returnAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 8, weight: .regular),
                .foregroundColor: UIColor.darkGray,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            (returnAddress as NSString).draw(at: CGPoint(x: margin, y: 50), withAttributes: returnAttrs)

            // 2. Empfänger Anschrift
            var curY: CGFloat = 72
            let recipientAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            let recipientSubAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: UIColor.black
            ]

            (draft.recipientName as NSString).draw(at: CGPoint(x: margin, y: curY), withAttributes: recipientAttrs)
            curY += 15
            (draft.recipientAddress as NSString).draw(at: CGPoint(x: margin, y: curY), withAttributes: recipientSubAttrs)

            // 3. Datum rechts
            let dateString = "Datum: \(draft.date.formatted(date: .long, time: .omitted))"
            let dateAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: UIColor.darkGray
            ]
            let dateSize = (dateString as NSString).size(withAttributes: dateAttrs)
            (dateString as NSString).draw(at: CGPoint(x: pageWidth - margin - dateSize.width, y: 150), withAttributes: dateAttrs)

            // 4. Betreff (Fett)
            curY = 190
            let subjectAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 13),
                .foregroundColor: UIColor.black
            ]
            let subjectRect = CGRect(x: margin, y: curY, width: pageWidth - 2 * margin, height: 40)
            (draft.subject as NSString).draw(in: subjectRect, withAttributes: subjectAttrs)

            // 5. Fließtext
            curY = 230
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 4
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "Georgia", size: 11) ?? UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraphStyle
            ]
            let bodyRect = CGRect(x: margin, y: curY, width: pageWidth - 2 * margin, height: pageHeight - curY - 140)
            (draft.bodyText as NSString).draw(in: bodyRect, withAttributes: bodyAttrs)

            // 6. Unterschrift
            let signY = pageHeight - 120
            if !signatureDrawing.bounds.isEmpty {
                let signImage = renderSignatureImage()
                let signRect = CGRect(x: margin, y: signY - 45, width: 140, height: 40)
                signImage.draw(in: signRect)
            }

            (draft.senderName as NSString).draw(
                at: CGPoint(x: margin, y: signY),
                withAttributes: [.font: UIFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: UIColor.black]
            )
        }
    }

    private func generatePDFAndShare() {
        let pdfData = buildPDFData()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Schreiben_\(UUID().uuidString.prefix(6)).pdf")
        do {
            try pdfData.write(to: tempURL)
            self.generatedPDFURL = tempURL
            self.generatedPDFData = pdfData
            self.showShareSheet = true
        } catch {
            print("Fehler beim Erzeugen des PDFs: \(error)")
        }
    }

    private func finalizeAndSave() {
        let pdfData = buildPDFData()
        let parsedAmount: Decimal? = Decimal(string: draft.amount.replacingOccurrences(of: ",", with: "."))
        let docId = UUID()
        let localName = "\(docId.uuidString).pdf"

        // PDF lokal im Dokumentenverzeichnis speichern
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dms_files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let localURL = dir.appendingPathComponent(localName)
        try? pdfData.write(to: localURL)

        // Speichert das Schreiben als neues Dokument im Archiv
        let newDoc = AppDocument(
            id: docId,
            userId: service.userId,
            title: draft.subject.isEmpty ? draft.templateType.rawValue : draft.subject,
            category: draft.templateType.defaultCategory,
            documentDate: draft.date,
            dueDate: Calendar.current.date(byAdding: .day, value: 14, to: Date()),
            sender: draft.recipientName.isEmpty ? "Erstelltes Schreiben" : draft.recipientName,
            fileNumber: draft.referenceNumber.isEmpty ? nil : draft.referenceNumber,
            amount: parsedAmount,
            storagePath: nil,
            localFileName: localName,
            fileType: .pdf,
            ocrText: draft.bodyText,
            tags: ["Erstellt", draft.templateType.rawValue.components(separatedBy: " ").first ?? "Schreiben"],
            status: .inProgress,
            notes: "Vom Büro-Assistenten erstelltes DIN 5008 Schreiben an \(draft.recipientName)."
        )

        service.addDocument(newDoc)

        withAnimation {
            isSavedToDMS = true
            showSaveSuccessToast = true
        }

        // Nach kurzer Verzögerung schließen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            dismiss()
        }
    }
}
