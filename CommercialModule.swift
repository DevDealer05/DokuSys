// =============================================================================
// CommercialModule.swift
// Digitales Büro — Commercial Suite & Gewerbe-Modus
// Requires: iOS 17+, Swift 5.9+
// =============================================================================

import SwiftUI
import UniformTypeIdentifiers

// =============================================================================
// MARK: - Commercial Period Enum
// =============================================================================

public enum CommercialPeriod: String, CaseIterable, Identifiable {
    case thisMonth   = "Dieser Monat"
    case lastQuarter = "Letztes Quartal"
    case thisYear    = "Dieses Jahr"
    case all         = "Alle Belege"

    public var id: String { rawValue }

    public func contains(date: Date) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .thisMonth:
            return calendar.isDate(date, equalTo: now, toGranularity: .month)
        case .lastQuarter:
            guard let quarterAgo = calendar.date(byAdding: .month, value: -3, to: now) else { return true }
            return date >= quarterAgo && date <= now
        case .thisYear:
            return calendar.isDate(date, equalTo: now, toGranularity: .year)
        case .all:
            return true
        }
    }
}

// =============================================================================
// MARK: - CommercialHubView
// =============================================================================

public struct CommercialHubView: View {
    @ObservedObject public var documentService: DocumentArchiveService
    @EnvironmentObject private var debtEngine: DebtEngineService
    @EnvironmentObject private var sessionManager: UserSessionManager
    @ObservedObject private var subManager = SubscriptionManager.shared

    @State private var selectedPeriod: CommercialPeriod = .all
    @State private var showDossierSheet: Bool = false
    @State private var showCreatorUnlockAlert: Bool = false
    @State private var creatorCodeInput: String = ""
    @State private var feedbackMessage: String? = nil
    @State private var showFeedbackAlert: Bool = false
    @State private var shareURL: URL? = nil
    @State private var showShareSheet: Bool = false
    @State private var showSettingsSheet: Bool = false
    @State private var selectedDocForDetail: AppDocument? = nil

    public init(documentService: DocumentArchiveService) {
        self.documentService = documentService
    }

    // ── Filtered Commercial Documents ─────────────────────────────────
    private var commercialDocuments: [AppDocument] {
        documentService.documents.filter { doc in
            selectedPeriod.contains(date: doc.documentDate) &&
            (doc.amount != nil || doc.category == .invoices || doc.category == .contracts || doc.category == .authorities)
        }
    }

    private var totalRevenueSum: Decimal {
        commercialDocuments.compactMap(\.amount).reduce(0, +)
    }

    private var vat19Sum: Decimal {
        // Approximate standard 19% German VAT (Vorsteuer: total / 1.19 * 0.19)
        let rate = Decimal(19) / Decimal(119)
        return (totalRevenueSum * rate).rounded(scale: 2)
    }

    private var netSum: Decimal {
        totalRevenueSum - vat19Sum
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // ── Hero Status Card ──────────────────────────────────
                heroStatusCard

                // ── Period Picker ─────────────────────────────────────
                periodSelector

                // ── Financial KPI Dashboard ───────────────────────────
                kpiDashboard

                // ── Quick Actions (DATEV, §305 InsO, Briefkopf) ───────
                quickActionsSection

                // ── Creator / Master Access Card ──────────────────────
                creatorAccessSection

                // ── Recent Commercial Invoices ────────────────────────
                commercialInvoicesList
            }
            .padding(16)
        }
        .navigationTitle("Commercial Suite")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettingsSheet = true
                } label: {
                    Image(systemName: "building.2.crop.circle")
                        .foregroundStyle(Theme.primaryAccent)
                }
            }
        }
        .sheet(isPresented: $showDossierSheet) {
            let localProfile = sessionManager.profile
            let senderName = localProfile?.name.isEmpty == false ? localProfile!.name : (subManager.ownerName.isEmpty == false ? subManager.ownerName : "Nutzer")
            let senderAddr = localProfile?.address.isEmpty == false ? localProfile!.address : ""
            DebtCounselingDossierSheet(
                debts: debtEngine.debts,
                userName: senderName,
                userAddress: senderAddr
            )
        }
        .sheet(isPresented: $showSettingsSheet) {
            NavigationStack {
                CommercialSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") { showSettingsSheet = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .sheet(item: $selectedDocForDetail) { doc in
            NavigationStack {
                DocumentDetailView(document: doc, service: documentService)
            }
        }
        .alert("Ersteller- & Entwickler-Code", isPresented: $showCreatorUnlockAlert) {
            TextField("Code (z. B. KIM-CREATOR-2026 oder 0505)", text: $creatorCodeInput)
                .textInputAutocapitalization(.characters)
            Button("Freischalten") {
                let code = creatorCodeInput
                creatorCodeInput = ""
                if subManager.unlockWithCreatorCode(code) {
                    feedbackMessage = "🎉 Ersteller-Status aktiv! Alle Rechte, Pro-Features, Commercial-Modus und Entwickler-Tools sind jetzt freigeschaltet."
                } else {
                    feedbackMessage = "❌ Ungültiger Ersteller-Code. Bitte Eingabe prüfen."
                }
                showFeedbackAlert = true
            }
            Button("Abbrechen", role: .cancel) { creatorCodeInput = "" }
        } message: {
            Text("Gib deinen Master-Code oder PIN ein, um unbeschränkten Zugriff zu aktivieren.")
        }
        .alert("System-Status", isPresented: $showFeedbackAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(feedbackMessage ?? "")
        }
    }

    // ── Hero Status Card ──────────────────────────────────────────────
    private var heroStatusCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.primaryAccent.opacity(0.18))
                        .frame(width: 48, height: 48)
                    Image(systemName: subManager.isCommercialMode || subManager.isCreator ? "briefcase.fill" : "lock.shield.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(subManager.isCommercialMode || subManager.isCreator ? Theme.primaryAccent : .orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(subManager.companyName.isEmpty ? "Gewerbe & Commercial" : subManager.companyName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if subManager.isCreator {
                            Text("ROOT")
                                .font(.system(size: 9, weight: .black))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.primaryAccent, in: Capsule())
                                .foregroundStyle(.white)
                        } else if subManager.isCommercialMode {
                            Text("PRO")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.green.opacity(0.2), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }

                    Text(subManager.isCommercialMode || subManager.isCreator
                         ? "DATEV-Export, GoBD-Archiv & Belegmanagement aktiv"
                         : "Basis-Modus — Tippe zum Freischalten aller Features")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button {
                    withAnimation {
                        subManager.isCommercialMode.toggle()
                    }
                } label: {
                    Image(systemName: subManager.isCommercialMode || subManager.isCreator ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(subManager.isCommercialMode || subManager.isCreator ? Color.green : Color.secondary)
                }
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 18)
    }

    // ── Period Selector ───────────────────────────────────────────────
    private var periodSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CommercialPeriod.allCases) { period in
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            selectedPeriod = period
                        }
                    } label: {
                        Text(period.rawValue)
                            .font(.system(size: 13, weight: selectedPeriod == period ? .semibold : .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                selectedPeriod == period
                                    ? AnyShapeStyle(Theme.primaryAccent)
                                    : AnyShapeStyle(.ultraThinMaterial),
                                in: Capsule()
                            )
                            .foregroundStyle(selectedPeriod == period ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // ── KPI Dashboard ─────────────────────────────────────────────────
    private var kpiDashboard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                kpiCard(
                    title: "Brutto-Summe",
                    value: totalRevenueSum.formatted(.currency(code: "EUR")),
                    icon: "eurosign.circle.fill",
                    color: Theme.primaryAccent
                )

                kpiCard(
                    title: "Vorsteuer (19%)",
                    value: vat19Sum.formatted(.currency(code: "EUR")),
                    icon: "percent",
                    color: .teal
                )
            }

            HStack(spacing: 12) {
                kpiCard(
                    title: "Netto-Aufwand",
                    value: netSum.formatted(.currency(code: "EUR")),
                    icon: "chart.line.uptrend.xyaxis",
                    color: .blue
                )

                kpiCard(
                    title: "Belege im Zeitraum",
                    value: "\(commercialDocuments.count)",
                    icon: "doc.text.fill",
                    color: .purple
                )
            }
        }
    }

    private func kpiCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 16)
    }

    // ── Quick Actions Section ─────────────────────────────────────────
    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export & Behörden-Schnittstellen")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                // 1. DATEV Export Button
                Button {
                    exportDATEVCSV()
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.teal.opacity(0.18))
                                .frame(width: 40, height: 40)
                            Image(systemName: "tablecells.badge.ellipsis")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.teal)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("DATEV Buchungsstapel (.CSV)")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Text("Standardisiertes Format für den Steuerberater exportieren")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.teal)
                    }
                    .padding(12)
                    .liquidGlassCard(cornerRadius: 14)
                }
                .buttonStyle(.plain)

                // 2. § 305 InsO Gläubiger-Dossier
                Button {
                    showDossierSheet = true
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.18))
                                .frame(width: 40, height: 40)
                            Image(systemName: "briefcase.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.orange)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("§ 305 InsO Gläubiger-Dossier (PDF)")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Text("Offizielle Gesamtübersicht zur Vorlage bei Schuldnerberatung")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .liquidGlassCard(cornerRadius: 14)
                }
                .buttonStyle(.plain)

                // 3. Geschäftsprofil & Briefkopf
                Button {
                    showSettingsSheet = true
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.18))
                                .frame(width: 40, height: 40)
                            Image(systemName: "building.2.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.blue)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Geschäftsprofil & Steuernummer")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Text(subManager.taxId.isEmpty ? "Steuernummer, IBAN und Firmenname hinterlegen" : "Steuer-ID: \(subManager.taxId)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .liquidGlassCard(cornerRadius: 14)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // ── Creator & Master Access Section ───────────────────────────────
    private var creatorAccessSection: some View {
        VStack(spacing: 8) {
            if subManager.isCreator {
                HStack(spacing: 12) {
                    Image(systemName: "crown.fill")
                        .font(.title2)
                        .foregroundStyle(Color.yellow)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Creator Master-Zugang Aktiv")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                        Text("Root-Rechte, Dev-Tools und alle Pro-Lizenzen uneingeschränkt freigeschaltet.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                }
                .padding(12)
                .background(
                    LinearGradient(
                        colors: [Color.purple.opacity(0.7), Color.indigo.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16)
                )
            } else {
                Button {
                    showCreatorUnlockAlert = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(Theme.primaryAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ersteller- / Entwickler-Code einlösen")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Text("Gib deinen Master-Code ein, um alle Funktionen freizuschalten")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .liquidGlassCard(cornerRadius: 14)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // ── Commercial Invoices List ──────────────────────────────────────
    private var commercialInvoicesList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Gewerbliche Belege (\(commercialDocuments.count))")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if commercialDocuments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Keine gewerblichen Belege in diesem Zeitraum gefunden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .liquidGlassCard(cornerRadius: 16)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(commercialDocuments) { doc in
                        Button {
                            selectedDocForDetail = doc
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(doc.category.color.opacity(0.15))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: doc.category.icon)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(doc.category.color)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text("\(doc.sender ?? doc.category.rawValue) · \(doc.documentDate.formatted(date: .numeric, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if let amt = doc.amount {
                                    Text(amt, format: .currency(code: "EUR"))
                                        .font(.subheadline.bold())
                                        .foregroundStyle(Theme.primaryAccent)
                                }
                            }
                            .padding(10)
                            .liquidGlassCard(cornerRadius: 14)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // ── DATEV CSV Export Generator ────────────────────────────────────
    private func exportDATEVCSV() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let dateString = formatter.string(from: Date())

        let filename = "DATEV_Buchungsstapel_\(dateString).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        var csvLines: [String] = []

        // DATEV Header
        csvLines.append("\"EXTF\";700;21;\"Buchungsstapel\";1;\"\";\"\";\"\";\"\";\"\";1001;\"\";\"\";\"EUR\";\"\";\"\";\"\";\"\";\"\";\"\";\"\";\"\";\"\";\"\";\"\";\"\"")
        csvLines.append("\"Umsatz (ohne Soll/Haben-Kz)\";\"Soll/Haben-Kennzeichen\";\"WKZ\";\"Kurs\";\"Basis-Umsatz\";\"WKZ Basis-Umsatz\";\"Konto\";\"Gegenkonto\";\"BU-Schlüssel\";\"Belegdatum\";\"Belegfeld 1\";\"Belegfeld 2\";\"Skonto\";\"Buchungstext\"")

        let dayMonthFormatter = DateFormatter()
        dayMonthFormatter.dateFormat = "ddMM"

        for doc in commercialDocuments {
            guard let amt = doc.amount else { continue }
            let formattedAmount = String(format: "%.2f", NSDecimalNumber(decimal: amt).doubleValue).replacingOccurrences(of: ".", with: ",")
            let belegdatum = dayMonthFormatter.string(from: doc.documentDate)
            let belegfeld1 = (doc.fileNumber ?? doc.id.uuidString.prefix(8)).description
            let buchungstext = (doc.sender ?? doc.title).replacingOccurrences(of: "\"", with: "'")

            // Format standard DATEV row (Soll-Buchung auf Aufwandskonto 4900, Gegenkonto 1200 Bank)
            let line = "\"\(formattedAmount)\";\"S\";\"EUR\";\"\";\"\";\"\";\"4900\";\"1200\";\"\";\"\(belegdatum)\";\"\(belegfeld1)\";\"\";\"\";\"\(buchungstext)\""
            csvLines.append(line)
        }

        let fullCSV = csvLines.joined(separator: "\r\n")

        do {
            try fullCSV.write(to: tempURL, atomically: true, encoding: .utf8)
            self.shareURL = tempURL
            self.showShareSheet = true
        } catch {
            self.feedbackMessage = "Fehler beim Exportieren der DATEV-Datei: \(error.localizedDescription)"
            self.showFeedbackAlert = true
        }
    }
}
