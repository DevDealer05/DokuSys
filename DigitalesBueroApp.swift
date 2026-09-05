// =============================================================================
// DigitalesBueroApp.swift
// Schulden & Haushalt App — @main entry point
// Requires: iOS 17+, Swift 5.9+
//
// Wires together:
//   LiquidGlass.swift          – Design system + FloatingTabBarView
//   DebtEngineService.swift    – Business logic + models
//   ScannerModule.swift        – Camera + OCR + TriageCardDeckView
//   RealtimeHouseholdService.swift – Supabase Realtime + SharedHouseholdHubView
//   ExportModule.swift         – PDF + PencilKit + ShareSheet
// =============================================================================

import SwiftUI

// =============================================================================
// MARK: - Persistent Identity Helpers
// (Replace with Supabase Auth session in production)
// =============================================================================

private enum PersistentIdentity {
    static func loadOrCreate(key: String) -> UUID {
        if let stored = UserDefaults.standard.string(forKey: key),
           let uuid = UUID(uuidString: stored) { return uuid }
        let new = UUID()
        UserDefaults.standard.set(new.uuidString, forKey: key)
        return new
    }

    static var userId:      UUID { loadOrCreate(key: "app.userId") }
    static var householdId: UUID { loadOrCreate(key: "app.householdId") }
}

// =============================================================================
// MARK: - Notification Names
// =============================================================================

extension Notification.Name {
    /// Posted when the app receives a household invite deep-link.
    static let householdInviteReceived = Notification.Name("householdInviteReceived")
}

// =============================================================================
// MARK: - Decimal Helper
// =============================================================================

extension Decimal {
    /// Rounds to `scale` decimal places using banker's rounding.
    func rounded(scale: Int, roundingMode: NSDecimalNumber.RoundingMode = .plain) -> Decimal {
        var result = Decimal()
        var mutableSelf = self
        NSDecimalRound(&result, &mutableSelf, scale, roundingMode)
        return result
    }
}

// =============================================================================
// MARK: - @main Entry Point
// =============================================================================

@main
struct DigitalesBueroApp: App {
    @StateObject private var authService = AuthService()
    @StateObject private var sessionManager = UserSessionManager()

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let session = authService.session {
                    AuthenticatedScopeView(userId: session.user.id)
                        .id(session.user.id.uuidString + "\(sessionManager.hasCompletedOnboarding)")
                        .transition(.opacity)
                } else {
                    LoginView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: authService.session != nil)
            .environmentObject(authService)
            .environmentObject(sessionManager)
        }
    }
}

/// A scope that guarantees a valid authenticated user.
/// It instantiates all data-layer services that depend on the `userId`.
struct AuthenticatedScopeView: View {
    let userId: UUID
    let householdId: UUID

    @StateObject private var debtEngine:         DebtEngineService
    @StateObject private var userProfileService: UserProfileService
    @StateObject private var appSettings:        AppSettingsStore

    @EnvironmentObject private var sessionManager: UserSessionManager

    @Environment(\.scenePhase) private var scenePhase
    @State private var isSensitiveRevealed = false

    init(userId: UUID) {
        self.userId      = userId
        self.householdId = userId
        self._debtEngine         = StateObject(wrappedValue: DebtEngineService(userId: userId))
        self._userProfileService = StateObject(wrappedValue: UserProfileService())
        self._appSettings        = StateObject(wrappedValue: AppSettingsStore())
    }

    var body: some View {
        Group {
            if sessionManager.hasCompletedOnboarding {
                AppRootView(
                    currentUserId:       userId,
                    householdId:         householdId,
                    isSensitiveRevealed: $isSensitiveRevealed
                )
                .transition(.opacity)
            } else {
                OnboardingView()
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: sessionManager.hasCompletedOnboarding)
        .environmentObject(debtEngine)
        .environmentObject(userProfileService)
        .environmentObject(appSettings)
        .preferredColorScheme(appSettings.colorSchemeOverride.colorScheme)
        .task {
            await debtEngine.load()
            await userProfileService.load()
        }
        .onChange(of: scenePhase) { _, phase in
            if (phase == .background || phase == .inactive) && appSettings.autoLockOnBackground {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSensitiveRevealed = false
                }
            }
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
    }

    // MARK: Deep-link handler
    private func handleDeepLink(_ url: URL) {
        guard
            url.scheme?.lowercased() == "schulden",
            url.host?.lowercased()   == "join",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
            !code.isEmpty
        else { return }

        Task {
            do {
                struct RpcArgs: Encodable { let p_invite_code: String }
                let args = RpcArgs(p_invite_code: code)
                try await SupabaseConfig.client
                    .rpc("join_household_by_invite", params: args)
                    .execute()
                
                // Notify UI to refresh household data
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .householdInviteReceived,
                        object: nil,
                        userInfo: ["code": code]
                    )
                }
            } catch {
                print("Failed to join household: \(error)")
            }
        }
    }
}

// =============================================================================
// MARK: - AppRootView
// =============================================================================

/// Root container. Holds the `FloatingTabBarView` and switches between tabs.
/// Owns the scanner sheet and export sheet so they can be triggered from
/// anywhere (including the FAB and swipe-actions on `DebtRowView`).
struct AppRootView: View {

    let currentUserId:       UUID
    let householdId:         UUID
    @Binding var isSensitiveRevealed: Bool

    @EnvironmentObject private var debtEngine: DebtEngineService
    @EnvironmentObject private var userProfileService: UserProfileService
    @EnvironmentObject private var sessionManager: UserSessionManager
    @EnvironmentObject private var appSettings: AppSettingsStore

    @State private var selectedTab:  AppTab = .overview
    @State private var showScanner:  Bool   = false
    @State private var exportTarget: Debt?  = nil

    @StateObject private var documentService: DocumentArchiveService
    @StateObject private var devModeStore = DevModeStore()

    init(
        currentUserId: UUID,
        householdId: UUID,
        isSensitiveRevealed: Binding<Bool>
    ) {
        self.currentUserId = currentUserId
        self.householdId   = householdId
        self._isSensitiveRevealed = isSensitiveRevealed
        self._documentService = StateObject(wrappedValue: DocumentArchiveService(userId: currentUserId))
    }

    var body: some View {
        ZStack(alignment: .bottom) {

            // ── Global background ──────────────────────────────────────
            appBackground.ignoresSafeArea()

            // ── Tab content ────────────────────────────────────────────
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Leave room for the floating tab bar + home indicator
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 90)
                }
                .safeAreaInset(edge: .top) {
                    // Dev mode orange banner at the very top
                    if devModeStore.isDevMode {
                        DevModeBanner()
                            .environmentObject(devModeStore)
                    }
                }

            // ── Floating tab bar ───────────────────────────────────────
            FloatingTabBarView(
                selectedTab: $selectedTab,
                onCameraAction: { showScanner = true }
            )
        }
        .ignoresSafeArea(edges: .bottom)
        .environmentObject(devModeStore)

        // ── Scanner sheet ──────────────────────────────────────────────
        .sheet(isPresented: $showScanner) {
            ScannerCoordinatorView(engine: debtEngine)
        }

        // ── Export sheet (triggered by swipe action or Export tab) ─────
        .sheet(item: $exportTarget) { debt in
            ExportCoordinatorView(proposal: proposal(from: debt))
        }
    }

    // ── Tab switching ──────────────────────────────────────────────────

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:
            NavigationStack {
                OverviewView(
                    currentUserId:       currentUserId,
                    householdId:         householdId,
                    isSensitiveRevealed: $isSensitiveRevealed,
                    onExportDebt: { debt in
                        exportTarget = debt
                    }
                )
            }

        case .documents:
            NavigationStack {
                DocumentArchiveView(service: documentService)
            }

        case .camera:
            // The camera FAB is handled by onCameraAction above;
            // .camera is never set as a navigation destination.
            Color.clear

        case .household:
            // SharedHouseholdHubView creates its own RealtimeHouseholdService
            SharedHouseholdHubView(
                householdId:   householdId,
                currentUserId: currentUserId
            )

        case .export:
            NavigationStack {
                ExportTabView(
                    onExportDebt: { debt in exportTarget = debt }
                )
            }

        case .chat:
            AIChatView()

        case .devMode:
            NavigationStack {
                DevModePanel()
                    .navigationTitle("Entwickler-Modus")
                    .navigationBarTitleDisplayMode(.large)
            }
            .environmentObject(devModeStore)
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────

    private var appBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.07, green: 0.07, blue: 0.13),
                Color(red: 0.04, green: 0.04, blue: 0.10)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Builds an `InstallmentProposal` from a `Debt` with sensible defaults.
    private func proposal(from debt: Debt) -> InstallmentProposal {
        let months: Int = 24
        
        let localProfile = sessionManager.profile
        let dbProfile = userProfileService.profile
        
        // Priority: Local Onboarding Data -> DB Profile Data -> Fallbacks
        let senderName = localProfile?.name ?? dbProfile?.displayName ?? "Nutzer"
        let senderAddress = localProfile?.address ?? ""
        let senderPhone = localProfile?.phone ?? ""
        
        // Calculate rate based on installment budget if possible
        var rate = (debt.currentPrincipal / Decimal(months)).rounded(scale: 2)
        if let budget = localProfile?.installmentBudget, Decimal(budget) > 0 {
            rate = min(rate, Decimal(budget))
        }
        
        let start = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()

        return InstallmentProposal(
            fileNumber:      debt.fileNumber,
            creditorName:    debt.creditorName,
            creditorAddress: debt.creditorAddress,
            totalAmount:     debt.currentPrincipal,
            monthlyRate:     rate,
            numberOfMonths:  months,
            startDate:       start,
            reason:          debt.notes
                ?? "Aufgrund meiner aktuellen finanziellen Situation bitte ich um die Möglichkeit zur Ratenzahlung.",
            senderName:      senderName,
            senderAddress:   senderAddress,
            senderEmail:     nil,
            senderPhone:     senderPhone.isEmpty ? nil : senderPhone,
            documentDate:    Date(),
            documentId:      UUID()
        )
    }
}

// =============================================================================
// MARK: - OverviewView
// =============================================================================

struct OverviewView: View {

    let currentUserId: UUID
    let householdId: UUID
    @Binding var isSensitiveRevealed: Bool
    var onExportDebt: (Debt) -> Void = { _ in }

    @EnvironmentObject private var debtEngine:  DebtEngineService
    @EnvironmentObject private var appSettings: AppSettingsStore
    @StateObject private var householdService:  RealtimeHouseholdService
    @State private var showSettingsSheet: Bool = false

    init(
        currentUserId: UUID = UUID(),
        householdId: UUID = UUID(),
        isSensitiveRevealed: Binding<Bool>,
        onExportDebt: @escaping (Debt) -> Void = { _ in }
    ) {
        self.currentUserId = currentUserId
        self.householdId   = householdId
        self._isSensitiveRevealed = isSensitiveRevealed
        self.onExportDebt  = onExportDebt
        self._householdService = StateObject(
            wrappedValue: RealtimeHouseholdService(householdId: householdId, currentUserId: currentUserId)
        )
    }

    var body: some View {
        List {
            // ── Putzplan / Chores Widget (Optional on Home) ───────────
            if appSettings.showChoresWidget {
                Section {
                    ChoresWidgetCard(service: householdService)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(.init(top: 8, leading: 16, bottom: 4, trailing: 16))
                }
            }

            // ── Privacy-shielded total balance ─────────────────────────
            Section {
                totalBalanceCard
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(.init(top: 6, leading: 16, bottom: 0, trailing: 16))
            }

            // ── Limitation notice (neutral info, never red) ────────────
            if appSettings.showLimitationBanner {
                let expired = debtEngine.potentiallyExpiredDebts
                if !expired.isEmpty {
                    Section {
                        limitationNoticeCard(count: expired.count)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(.init(top: 0, leading: 16, bottom: 0, trailing: 16))
                    }
                }
            }

            // ── Debt list ──────────────────────────────────────────────
            Section {
                if debtEngine.debts.isEmpty {
                    emptyDebtsState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(debtEngine.debts.sorted { $0.currentPrincipal > $1.currentPrincipal }) { debt in
                        NavigationLink(destination: DebtDetailView(debt: debt)) {
                            DebtRowView(debt: debt, onExport: onExportDebt)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(.init(top: 3, leading: 16, bottom: 3, trailing: 16))
                    }
                }
            } header: {
                HStack {
                    Text("Forderungen")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(debtEngine.debts.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.primaryAccent)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Theme.primaryAccent.opacity(0.12), in: Capsule())
                }
                .textCase(nil)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle("Übersicht")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.primaryAccent)
                }
                .accessibilityLabel("Einstellungen")
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            UserSettingsView()
                .environmentObject(appSettings)
        }
        .onAppear {
            householdService.start()
        }
        .onDisappear {
            householdService.stop()
        }
        .animation(.spring(response: 0.4), value: debtEngine.debts.map(\.id))
    }

    // ── Total balance card ─────────────────────────────────────────────

    private var totalBalanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Aktive Gesamtforderungen", systemImage: "eurosign.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // The actual balance is wrapped by PrivacyShieldView
            Text(formatCurrency(debtEngine.totalActivePrincipal))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .privacyShield(isRevealed: $isSensitiveRevealed)

            // Quick stats row
            HStack(spacing: 20) {
                statPill(
                    value: "\(debtEngine.debts.filter { $0.status == .active }.count)",
                    label: "Aktiv",
                    color: .orange
                )
                statPill(
                    value: "\(debtEngine.debts.filter { $0.status == .negotiating }.count)",
                    label: "Verhandlung",
                    color: .blue
                )
                statPill(
                    value: "\(debtEngine.debts.filter { $0.status == .paid }.count)",
                    label: "Bezahlt",
                    color: .green
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard()
    }

    private func statPill(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // ── Limitation notice ──────────────────────────────────────────────

    private func limitationNoticeCard(count: Int) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.badge.questionmark.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Mögliche Verjährung prüfen")
                    .font(.subheadline.weight(.semibold))
                Text("\(count) Forderung\(count == 1 ? "" : "en") könnte\(count == 1 ? "" : "n") nach § 195 BGB (3 Jahre) verjährt sein. Rechtliche Beratung empfohlen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.orange.opacity(0.25), lineWidth: 1)
        )
    }

    // ── Empty state ────────────────────────────────────────────────────

    private var emptyDebtsState: some View {
        ContentUnavailableView {
            Label("Keine Forderungen", systemImage: "checkmark.seal.fill")
        } description: {
            Text("Tippe auf den Kamera-Button, um deinen ersten Brief zu scannen.")
        }
        .padding(.top, 32)
    }

    // ── Formatter ──────────────────────────────────────────────────────

    private func formatCurrency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.locale = Locale(identifier: "de_DE")
        return f.string(for: d) ?? "—"
    }
}

// =============================================================================
// MARK: - DebtRowView
// =============================================================================

private struct DebtRowView: View {

    let debt:     Debt
    var onExport: (Debt) -> Void

    @EnvironmentObject private var debtEngine: DebtEngineService

    var body: some View {
        HStack(spacing: 14) {
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .padding(.leading, 4)

            // Name + reference
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(debt.creditorName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)

                    if debt.limitationStatus.isPotentiallyExpired {
                        Text(debt.limitationStatus.hint)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.12), in: Capsule())
                    }
                }
                Text(debt.fileNumber)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Amount + status label
            VStack(alignment: .trailing, spacing: 3) {
                Text(formatCurrency(debt.currentPrincipal))
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.primaryAccent)
                Text(debt.status.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(statusColor)
            }
        }
        .padding(.vertical, 12)
        .padding(.trailing, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.glassEdgeGradient, lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                withAnimation(.spring(response: 0.35)) {
                    debtEngine.deleteDebt(debt.id)
                }
            } label: {
                Label("Löschen", systemImage: "trash")
            }

            Button {
                onExport(debt)
            } label: {
                Label("Antrag", systemImage: "doc.text.fill")
            }
            .tint(Theme.primaryAccent)
        }
        .swipeActions(edge: .leading) {
            Button {
                debtEngine.updateDebtStatus(debt.id, newStatus: debt.status == .paid ? .active : .paid)
            } label: {
                Label(
                    debt.status == .paid ? "Reaktivieren" : "Als bezahlt",
                    systemImage: debt.status == .paid ? "arrow.uturn.left" : "checkmark.circle.fill"
                )
            }
            .tint(debt.status == .paid ? .orange : .green)
        }
    }

    private var statusColor: Color {
        switch debt.status {
        case .active:      return .orange
        case .negotiating: return .blue
        case .paid:        return .green
        case .disputed:    return .red
        case .writtenOff:  return .gray
        }
    }

    private func formatCurrency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle  = .currency
        f.currencyCode = "EUR"
        f.locale       = Locale(identifier: "de_DE")
        return f.string(for: d) ?? "—"
    }
}

// =============================================================================
// MARK: - ExportTabView
// =============================================================================

/// Lets the user pick a debt and opens `ExportCoordinatorView` as a sheet.
struct ExportTabView: View {

    var onExportDebt: (Debt) -> Void = { _ in }
    @EnvironmentObject private var debtEngine: DebtEngineService
    @EnvironmentObject private var sessionManager: UserSessionManager

    @State private var showDossierSheet = false

    // Active + negotiating debts are eligible for installment proposal
    private var eligibleDebts: [Debt] {
        debtEngine.debts
            .filter { $0.status == .active || $0.status == .negotiating }
            .sorted { $0.currentPrincipal > $1.currentPrincipal }
    }

    var body: some View {
        List {
            // ── Blueprint §4: Schuldnerberatungs-Dossier ───────────────
            if !debtEngine.debts.isEmpty {
                Section {
                    Button {
                        showDossierSheet = true
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Theme.primaryAccent.opacity(0.15))
                                    .frame(width: 44, height: 44)
                                Image(systemName: "briefcase.fill")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(Theme.primaryAccent)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Schuldnerberatungs-Dossier")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("Gesamtaufstellung aller Gläubiger & Summen als PDF exportieren")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "arrow.up.forward.app.fill")
                                .foregroundStyle(Theme.primaryAccent)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.white.opacity(0.04))
                } header: {
                    Text("Gesamtdossier")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }

            if eligibleDebts.isEmpty {
                ContentUnavailableView(
                    "Keine aktiven Forderungen",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Es sind keine aktiven Forderungen vorhanden, für die ein Ratenzahlungsantrag erstellt werden kann.")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .padding(.top, 40)
            } else {
                Section {
                    ForEach(eligibleDebts) { debt in
                        Button {
                            onExportDebt(debt)
                        } label: {
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(debt.creditorName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(debt.fileNumber)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(formatCurrency(debt.currentPrincipal))
                                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                        .foregroundStyle(Theme.primaryAccent)
                                    // Suggest monthly rate
                                    let rate = (debt.currentPrincipal / 24).rounded(scale: 2)
                                    Text("ca. \(formatCurrency(rate))/Monat")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("Forderung für Ratenzahlungsantrag wählen")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle("Ratenzahlungsantrag")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showDossierSheet) {
            DebtCounselingDossierSheet(
                debts: debtEngine.debts,
                userName: sessionManager.profile?.name ?? "Max Mustermann",
                userAddress: sessionManager.profile?.address ?? "Musterstraße 1, 12345 Musterstadt"
            )
        }
    }

    private func formatCurrency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle  = .currency
        f.currencyCode = "EUR"
        f.locale       = Locale(identifier: "de_DE")
        return f.string(for: d) ?? "—"
    }
}

// =============================================================================
// MARK: - Preview
// =============================================================================

#if DEBUG
#Preview("AppRootView") {
    let engine = DebtEngineService(userId: UUID())
    // Seed preview data
    Task { @MainActor in
        _ = try? engine.processNewScan(fileNumber: "AZ-2024-00123", amount: 3450.00, date: Date())
        _ = try? engine.processNewScan(fileNumber: "GZ-2019-99", amount: 890.50,
                                       date: Calendar.current.date(byAdding: .year, value: -4, to: Date())!)
        _ = try? engine.processNewScan(fileNumber: "12 C 78/23", amount: 1200.00, date: Date())
    }
    return AppRootView(
        currentUserId:       UUID(),
        householdId:         UUID(),
        isSensitiveRevealed: .constant(false)
    )
    .environmentObject(engine)
    .environmentObject(AppSettingsStore())
    .preferredColorScheme(.dark)
}
#endif
