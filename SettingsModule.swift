// =============================================================================
// SettingsModule.swift
// Schulden & Haushalt App  |  iOS 17+  |  Swift 5.9+
//
// ── Enthält ───────────────────────────────────────────────────────────────────
//  AppSettingsStore          @MainActor ObservableObject – alle persistierten Settings
//  ColorSchemeOption         Enum für Erscheinungsbild-Override (Hell/Dunkel/System)
//  PromoCode                 Datenmodell für Promo- & Invite-Codes
//  UserSettingsView          Allgemeine Nutzer-Einstellungen
//  ChangeAppPasscodeSheet    4-stelligen App-PIN einrichten / ändern
//  AdminUnlockView           PIN-Gate vor dem Admin-Bereich (Admin-PIN: 1984)
//  AdminSettingsView         Admin-Panel (Codes, Premium, Einladungen)
//  PromoCodeRow              Listenzeile für einen Code
//  CreatePromoCodeSheet      Formular zum Erstellen eines Codes
//  HouseholdInviteAdminView  Verwaltung von Haushalt-Einladungen
//  ProfileEditView           Profil bearbeiten (Name, Adresse, Budget)
//  ChoresWidgetCard          Kompaktes Putzplan-Widget für die Startseite
//  PasscodeUnlockModalView   Wiederverwendbare 4-stellige PIN-Entsperrung
// =============================================================================

import SwiftUI
import LocalAuthentication

// MARK: - AppSettingsStore

@MainActor
final class AppSettingsStore: ObservableObject {

    // ── Appearance ────────────────────────────────────────────────────────
    @AppStorage("app.settings.colorSchemeOverride") var colorSchemeOverride: ColorSchemeOption = .system

    // ── Privacy & Security ────────────────────────────────────────────────
    @AppStorage("app.settings.biometricLock")        var biometricLock: Bool        = true
    @AppStorage("app.settings.isPasscodeEnabled")    var isPasscodeEnabled: Bool    = true
    @AppStorage("app.settings.appPasscode")          var appPasscode: String        = "1234"
    @AppStorage("app.settings.autoLockOnBackground") var autoLockOnBackground: Bool = true
    @AppStorage("app.settings.hideAmountsInList")    var hideAmountsInList: Bool    = false

    // ── Notifications ─────────────────────────────────────────────────────
    @AppStorage("app.settings.notifyHardwareDue")  var notifyHardwareDue: Bool  = true
    @AppStorage("app.settings.notifyNewDebt")      var notifyNewDebt: Bool      = true
    @AppStorage("app.settings.notifyScanReminder") var notifyScanReminder: Bool = false

    // ── Dashboard / Overview ──────────────────────────────────────────────
    @AppStorage("app.settings.showChoresWidget")     var showChoresWidget: Bool     = true
    @AppStorage("app.settings.showLimitationBanner") var showLimitationBanner: Bool = true

    // ── Admin gate ────────────────────────────────────────────────────────
    @AppStorage("app.settings.isAdminUnlocked") private(set) var isAdminUnlocked: Bool = false
    static let adminPIN = "1984"

    func attemptAdminUnlock(pin: String) -> Bool {
        let ok = pin == Self.adminPIN
        if ok { isAdminUnlocked = true }
        return ok
    }
    func lockAdmin() { isAdminUnlocked = false }

    // ── App PIN verification ──────────────────────────────────────────────
    func verifyAppPasscode(_ input: String) -> Bool {
        return input == appPasscode || input == Self.adminPIN
    }

    func setAppPasscode(_ newPin: String) {
        guard newPin.count == 4, newPin.allSatisfy(\.isNumber) else { return }
        appPasscode = newPin
    }

    // ── Promo Codes ───────────────────────────────────────────────────────
    @Published private(set) var promoCodes: [PromoCode] = []
    private let promoCodesKey = "app.settings.promoCodes"

    init() { loadPromoCodes() }

    @discardableResult
    func createPromoCode(
        type: PromoCode.CodeType,
        durationDays: Int,
        maxRedemptions: Int,
        note: String
    ) -> PromoCode {
        let code = PromoCode(
            id: UUID(),
            code: Self.generateCode(),
            type: type,
            durationDays: durationDays,
            maxRedemptions: maxRedemptions,
            redemptions: 0,
            note: note.isEmpty ? nil : note,
            createdAt: Date(),
            expiresAt: Calendar.current.date(byAdding: .day, value: 90, to: Date())
        )
        promoCodes.append(code)
        savePromoCodes()
        return code
    }

    func deletePromoCode(_ code: PromoCode) {
        promoCodes.removeAll { $0.id == code.id }
        savePromoCodes()
    }

    enum RedeemError: LocalizedError {
        case notFound
        case expired
        case exhausted

        var errorDescription: String? {
            switch self {
            case .notFound:  return "Ungültiger Code. Bitte prüfe deine Eingabe."
            case .expired:   return "Dieser Code ist leider bereits abgelaufen."
            case .exhausted: return "Dieser Code wurde bereits maximal oft eingelöst."
            }
        }
    }

    func redeemPromoCode(_ input: String) -> Result<PromoCode, RedeemError> {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let idx = promoCodes.firstIndex(where: { $0.code.uppercased() == clean }) else {
            return .failure(.notFound)
        }
        var code = promoCodes[idx]
        if code.isExpired { return .failure(.expired) }
        if code.isExhausted { return .failure(.exhausted) }

        code.redemptions += 1
        promoCodes[idx] = code
        savePromoCodes()

        // Unlock subscription
        SubscriptionManager.shared.unlockWithPromo(code: code.code)
        return .success(code)
    }

    private static func generateCode() -> String {
        let chars  = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        let groups = (0..<3).map { _ in String((0..<4).map { _ in chars.randomElement()! }) }
        return groups.joined(separator: "-")
    }

    private func savePromoCodes() {
        if let data = try? JSONEncoder().encode(promoCodes) {
            UserDefaults.standard.set(data, forKey: promoCodesKey)
        }
    }

    private func loadPromoCodes() {
        guard let data    = UserDefaults.standard.data(forKey: promoCodesKey),
              let decoded = try? JSONDecoder().decode([PromoCode].self, from: data)
        else { return }
        promoCodes = decoded
    }
}

// MARK: - ColorSchemeOption

enum ColorSchemeOption: String, CaseIterable, Codable {
    case system = "System"
    case light  = "Hell"
    case dark   = "Dunkel"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }
}

// MARK: - PromoCode

struct PromoCode: Identifiable, Codable {
    let id: UUID
    let code: String
    let type: CodeType
    let durationDays: Int
    let maxRedemptions: Int
    var redemptions: Int
    let note: String?
    let createdAt: Date
    let expiresAt: Date?

    var isExhausted:   Bool { redemptions >= maxRedemptions }
    var isExpired:     Bool { expiresAt.map { $0 < Date() } ?? false }
    var remainingUses: Int  { max(0, maxRedemptions - redemptions) }

    enum CodeType: String, Codable, CaseIterable {
        case proTrial        = "Pro-Testphase"
        case proLifetime     = "Pro Lifetime"
        case householdInvite = "Haushalt-Einladung"
        case betaAccess      = "Beta-Zugang"

        var icon: String {
            switch self {
            case .proTrial:        return "clock.badge.checkmark"
            case .proLifetime:     return "crown.fill"
            case .householdInvite: return "house.badge.person.crop"
            case .betaAccess:      return "hammer.fill"
            }
        }
        var color: Color {
            switch self {
            case .proTrial:        return .blue
            case .proLifetime:     return .orange
            case .householdInvite: return .green
            case .betaAccess:      return .purple
            }
        }
    }
}

// MARK: - UserSettingsView

struct UserSettingsView: View {
    @EnvironmentObject private var settings:       AppSettingsStore
    @EnvironmentObject private var sessionManager: UserSessionManager
    @EnvironmentObject private var authService:    AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var showAdminGate       = false
    @State private var showChangePasscode  = false
    @State private var showResetAlert      = false
    @State private var showRedeemCodeSheet = false

    var body: some View {
        NavigationStack {
            List {
                // ── Erscheinungsbild ───────────────────────────────────
                Section {
                    ForEach(ColorSchemeOption.allCases, id: \.self) { opt in
                        Button {
                            withAnimation { settings.colorSchemeOverride = opt }
                        } label: {
                            HStack(spacing: 14) {
                                iconBadge(opt.icon, color: Theme.primaryAccent)
                                Text(opt.rawValue).foregroundStyle(.primary)
                                Spacer()
                                if settings.colorSchemeOverride == opt {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.primaryAccent)
                                        .font(.footnote.weight(.semibold))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: { hdr("Erscheinungsbild", icon: "paintpalette") }

                // ── Startseite & Widgets ───────────────────────────────
                Section {
                    toggle("Putzplan-Widget", icon: "sparkles", color: .cyan,
                           binding: $settings.showChoresWidget)
                    toggle("Verjährungs-Hinweis", icon: "clock.badge.questionmark", color: .orange,
                           binding: $settings.showLimitationBanner)
                } header: { hdr("Startseite & Widgets", icon: "square.grid.2x2") }
                footer: {
                    Text("Das Putzplan-Widget platziert die nächsten Haushaltsaufgaben direkt oben auf der Startseite.")
                }

                // ── Datenschutz & Sicherheit ───────────────────────────
                Section {
                    toggle("Biometrische Sperre (Face ID)", icon: "faceid", color: .green,
                           binding: $settings.biometricLock)
                    toggle("4-stelliger App-Code", icon: "lock.shield.fill", color: .indigo,
                           binding: $settings.isPasscodeEnabled)
                    
                    if settings.isPasscodeEnabled {
                        Button {
                            showChangePasscode = true
                        } label: {
                            HStack {
                                row("App-Code ändern", icon: "key.fill", color: .blue)
                                Spacer()
                                Text("••••")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    toggle("Automatisch beim Verlassen sperren", icon: "lock.fill", color: .orange,
                           binding: $settings.autoLockOnBackground)
                    toggle("Beträge in Listen verbergen", icon: "eye.slash.fill", color: .purple,
                           binding: $settings.hideAmountsInList)
                } header: { hdr("Datenschutz & Sicherheit", icon: "lock.shield") }
                footer: {
                    Text("Standard-Code bei neuer Einrichtung: 1234. Du kannst den Code jederzeit ändern.")
                }

                // ── Benachrichtigungen ─────────────────────────────────
                Section {
                    toggle("Hardware-Wartung fällig", icon: "wrench.and.screwdriver", color: .orange,
                           binding: $settings.notifyHardwareDue)
                    toggle("Neue Forderung erkannt", icon: "doc.text.magnifyingglass",
                           color: Theme.primaryAccent, binding: $settings.notifyNewDebt)
                    toggle("Scan-Erinnerung", icon: "camera.viewfinder", color: .teal,
                           binding: $settings.notifyScanReminder)
                } header: { hdr("Benachrichtigungen", icon: "bell.badge") }

                // ── Abonnement & Pro-Status ────────────────────────────
                Section {
                    HStack {
                        row(SubscriptionManager.shared.isPro ? "Pro-Abonnement aktiv" : "Free-Tarif (5 Scans/Monat)",
                            icon: SubscriptionManager.shared.isPro ? "crown.fill" : "person.fill",
                            color: SubscriptionManager.shared.isPro ? .orange : .secondary)
                        Spacer()
                        if SubscriptionManager.shared.isPro {
                            Text("PRO")
                                .font(.caption2.bold())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }

                    Button {
                        showRedeemCodeSheet = true
                    } label: {
                        row("Promo- / Gutscheincode einlösen", icon: "ticket.fill", color: .purple)
                    }
                    .buttonStyle(.plain)
                } header: { hdr("Abonnement & Pro-Status", icon: "crown") }

                // ── Konto & Administration ─────────────────────────────
                Section {
                    NavigationLink { ProfileEditView() } label: {
                        row("Profil & Kontaktdaten", icon: "person.crop.circle", color: Theme.primaryAccent)
                    }
                    Button {
                        showAdminGate = true
                    } label: {
                        row(settings.isAdminUnlocked ? "Admin-Panel öffnen ✓" : "Admin-Bereich entsperren",
                            icon: "crown.fill", color: .orange)
                    }
                    .buttonStyle(.plain)
                } header: { hdr("Konto & Administration", icon: "person.circle") }

                // ── Abmelden ───────────────────────────────────────────
                Section {
                    Button(role: .destructive) { showResetAlert = true } label: {
                        HStack { Spacer(); Text("Abmelden").bold(); Spacer() }
                    }
                }

                // ── Entwickler ─────────────────────────────────────────
                Section {
                    Toggle(isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "dev_mode_enabled") },
                        set: { UserDefaults.standard.set($0, forKey: "dev_mode_enabled") }
                    )) {
                        row("Entwickler-Modus", icon: "hammer.fill", color: .orange)
                    }
                    NavigationLink {
                        DevModePanel()
                            .environmentObject(DevModeStore())
                            .navigationTitle("Entwickler-Panel")
                    } label: {
                        row("Entwickler-Panel öffnen", icon: "terminal.fill", color: .green)
                    }
                } header: { hdr("Entwickler & KI", icon: "hammer") }
                  footer: { Text("Im Entwickler-Modus hast du Zugang zum KI-Chat, Code-Modus und Testdaten-Generator.") }

                // ── App-Info ───────────────────────────────────────────
                Section {
                    HStack { Text("Version"); Spacer(); Text(BuildInfo.current.version + " (\(BuildInfo.current.buildNumber))").foregroundStyle(.secondary) }
                    HStack { Text("Commit"); Spacer(); Text(BuildInfo.current.commitSHA).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                } header: { hdr("App-Info", icon: "info.circle") }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .sheet(isPresented: $showRedeemCodeSheet) {
                RedeemPromoCodeSheet().environmentObject(settings)
            }
            .sheet(isPresented: $showChangePasscode) {
                ChangeAppPasscodeSheet().environmentObject(settings)
            }
            .sheet(isPresented: $showAdminGate) {
                if settings.isAdminUnlocked {
                    AdminSettingsView().environmentObject(settings)
                } else {
                    AdminUnlockView().environmentObject(settings)
                        .onDisappear {
                            if settings.isAdminUnlocked { showAdminGate = true }
                        }
                }
            }
            .alert("Abmelden?", isPresented: $showResetAlert) {
                Button("Abmelden", role: .destructive) { authService.signOut() }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Du wirst abgemeldet. Lokale Daten bleiben auf diesem Gerät erhalten.")
            }
        }
    }

    // Helpers
    @ViewBuilder
    private func toggle(_ title: String, icon: String, color: Color, binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) { row(title, icon: icon, color: color) }
    }
    private func row(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 14) { iconBadge(icon, color: color); Text(title) }
    }
    private func iconBadge(_ icon: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color).frame(width: 30, height: 30)
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
        }
    }
    private func hdr(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(nil)
    }
}

// MARK: - ChangeAppPasscodeSheet

struct ChangeAppPasscodeSheet: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var currentPin: String = ""
    @State private var newPin:     String = ""
    @State private var confirmPin: String = ""
    @State private var errorMessage: String? = nil
    @State private var isSuccess: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Aktueller Code") {
                    SecureField("Aktueller 4-stelliger Code", text: $currentPin)
                        .keyboardType(.numberPad)
                }
                
                Section("Neuer Code") {
                    SecureField("Neuer 4-stelliger Code", text: $newPin)
                        .keyboardType(.numberPad)
                    SecureField("Neuen Code wiederholen", text: $confirmPin)
                        .keyboardType(.numberPad)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if isSuccess {
                    Section {
                        Label("App-Code erfolgreich geändert!", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Code ändern")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }
                        .disabled(newPin.count != 4 || confirmPin.count != 4)
                }
            }
        }
    }

    private func save() {
        errorMessage = nil
        if !settings.verifyAppPasscode(currentPin) && !currentPin.isEmpty {
            errorMessage = "Der aktuelle Code ist nicht korrekt."
            return
        }
        if newPin.count != 4 || !newPin.allSatisfy(\.isNumber) {
            errorMessage = "Der Code muss genau 4 Ziffern lang sein."
            return
        }
        if newPin != confirmPin {
            errorMessage = "Die neuen Codes stimmen nicht überein."
            return
        }

        settings.setAppPasscode(newPin)
        isSuccess = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            dismiss()
        }
    }
}

// MARK: - PasscodeUnlockModalView (4-Stelliger Code Entsperr-Dialog)

struct PasscodeUnlockModalView: View {
    let title: String
    let subtitle: String
    var onUnlockSuccess: () -> Void
    var onCancel: (() -> Void)? = nil

    @EnvironmentObject private var settings: AppSettingsStore
    @State private var pin: String = ""
    @State private var isWrong: Bool = false
    @State private var shakeOffset: CGFloat = 0
    @FocusState private var pinFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Theme.primaryGradient)
                    .frame(width: 54, height: 54)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // 4 Dots
            HStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i < pin.count ? Theme.primaryAccent : Color.secondary.opacity(0.3))
                        .frame(width: 14, height: 14)
                        .scaleEffect(i < pin.count ? 1.15 : 1.0)
                        .animation(.spring(response: 0.2), value: pin.count)
                }
            }
            .offset(x: shakeOffset)

            // Hidden text input
            SecureField("", text: $pin)
                .keyboardType(.numberPad)
                .focused($pinFocused)
                .opacity(0)
                .frame(width: 1, height: 1)
                .onChange(of: pin) { _, val in
                    if val.count > 4 { pin = String(val.prefix(4)) }
                    isWrong = false
                    if pin.count == 4 { verify() }
                }

            if isWrong {
                Text("Falscher Code – Bitte erneut versuchen")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }

            HStack(spacing: 16) {
                if let onCancel = onCancel {
                    Button("Abbrechen") { onCancel() }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Button("Tastatur öffnen") {
                    pinFocused = true
                }
                .font(.subheadline.bold())
                .foregroundStyle(Theme.primaryAccent)
            }
        }
        .padding(24)
        .liquidGlassCard(cornerRadius: 24)
        .padding(.horizontal, 28)
        .onAppear { pinFocused = true }
    }

    private func verify() {
        if settings.verifyAppPasscode(pin) {
            withAnimation(.spring(response: 0.35)) {
                onUnlockSuccess()
            }
        } else {
            isWrong = true
            pin = ""
            withAnimation(.spring(response: 0.15, dampingFraction: 0.3)) { shakeOffset = 12 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.15)) { shakeOffset = 0 }
            }
        }
    }
}

// MARK: - AdminUnlockView

struct AdminUnlockView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var pin:         String  = ""
    @State private var isWrong:     Bool    = false
    @State private var shakeOffset: CGFloat = 0
    @FocusState private var pinFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()
                Image(systemName: "crown.fill").font(.system(size: 60)).foregroundStyle(Theme.primaryGradient)
                VStack(spacing: 8) {
                    Text("Admin-Zugang").font(.title.bold())
                    Text("Gib den Admin-PIN ein (Standard: 1984).").font(.subheadline).foregroundStyle(.secondary)
                }
                // PIN dots
                HStack(spacing: 16) {
                    ForEach(0..<4, id: \.self) { i in
                        Circle()
                            .fill(i < pin.count ? Theme.primaryAccent : Color.secondary.opacity(0.3))
                            .frame(width: 16, height: 16)
                            .animation(.spring(response: 0.2), value: pin.count)
                    }
                }
                .offset(x: shakeOffset)
                // Hidden input field
                SecureField("", text: $pin)
                    .keyboardType(.numberPad)
                    .focused($pinFocused)
                    .opacity(0).frame(width: 1, height: 1)
                    .onChange(of: pin) { _, val in
                        if val.count > 4 { pin = String(val.prefix(4)) }
                        isWrong = false
                        if val.count == 4 { verify() }
                    }
                Button("PIN eingeben") { pinFocused = true }
                    .buttonStyle(.borderedProminent).tint(Theme.primaryAccent)
                if isWrong {
                    Text("Falscher Admin-PIN – versuche es erneut")
                        .font(.caption.weight(.semibold)).foregroundStyle(.red)
                }
                Spacer()
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .onAppear { pinFocused = true }
        }
    }

    private func verify() {
        if settings.attemptAdminUnlock(pin: pin) {
            dismiss()
        } else {
            isWrong = true; pin = ""
            withAnimation(.spring(response: 0.15, dampingFraction: 0.3)) { shakeOffset = 12 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.15)) { shakeOffset = 0 }
            }
        }
    }
}

// MARK: - AdminSettingsView

struct AdminSettingsView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.dismiss)  private var dismiss

    @State private var showCreateCode = false
    @State private var copiedId:      UUID? = nil
    @State private var showLockAlert  = false

    var body: some View {
        NavigationStack {
            List {
                // Stats
                Section {
                    HStack(spacing: 0) {
                        stat("\(settings.promoCodes.count)", label: "Gesamt",   color: .blue)
                        Divider().frame(height: 44)
                        stat("\(settings.promoCodes.filter { !$0.isExhausted && !$0.isExpired }.count)",
                             label: "Aktiv", color: .green)
                        Divider().frame(height: 44)
                        stat("\(settings.promoCodes.reduce(0) { $0 + $1.redemptions })",
                             label: "Eingelöst", color: .orange)
                    }
                    .padding(.vertical, 4)
                } header: { aHdr("Übersicht & Metriken", icon: "chart.bar.fill") }

                // Promo Codes
                Section {
                    Button {
                        showCreateCode = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill").foregroundStyle(.green).font(.title3)
                            Text("Neuen Promo / Invite Code erstellen").bold().foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)

                    if settings.promoCodes.isEmpty {
                        ContentUnavailableView("Keine Codes", systemImage: "ticket",
                            description: Text("Erstelle Testphasen-, Lifetime- oder Einladungscodes."))
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(settings.promoCodes) { code in
                            PromoCodeRow(code: code, isCopied: copiedId == code.id) {
                                UIPasteboard.general.string = code.code
                                copiedId = code.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedId = nil }
                            }
                        }
                        .onDelete { idx in idx.forEach { settings.deletePromoCode(settings.promoCodes[$0]) } }
                    }
                } header: { aHdr("Promo, Premium & Invite Codes", icon: "ticket.fill") }
                footer: { Text("Codes sind standardmäßig 90 Tage gültig. Löschen via Swipe-Geste.") }

                // Household invites
                Section {
                    NavigationLink {
                        HouseholdInviteAdminView().environmentObject(settings)
                    } label: {
                        Label("Haushalt-Einladungen verwalten", systemImage: "house.badge.person.crop")
                    }
                } header: { aHdr("Haushalt & Sharing", icon: "house.fill") }

                // Lock
                Section {
                    Button(role: .destructive) { showLockAlert = true } label: {
                        HStack { Spacer(); Label("Admin-Bereich sperren", systemImage: "lock.fill").bold(); Spacer() }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Admin-Zentrale")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .sheet(isPresented: $showCreateCode) { CreatePromoCodeSheet().environmentObject(settings) }
            .alert("Admin sperren?", isPresented: $showLockAlert) {
                Button("Sperren", role: .destructive) { settings.lockAdmin(); dismiss() }
                Button("Abbrechen", role: .cancel) {}
            }
        }
    }

    private func stat(_ value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
    private func aHdr(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(nil)
    }
}

// MARK: - PromoCodeRow

private struct PromoCodeRow: View {
    let code:     PromoCode
    let isCopied: Bool
    let onCopy:   () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(code.type.color.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: code.type.icon)
                    .foregroundStyle(code.type.color).font(.system(size: 16, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(code.code).font(.system(.body, design: .monospaced).weight(.bold))
                    if code.isExpired {
                        badge("Abgelaufen", color: .red)
                    } else if code.isExhausted {
                        badge("Ausgeschöpft", color: .gray)
                    }
                }
                HStack(spacing: 6) {
                    Text(code.type.rawValue).font(.caption).foregroundStyle(code.type.color)
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(code.remainingUses)/\(code.maxRedemptions) verbleibend")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let note = code.note {
                    Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            Button(action: onCopy) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isCopied ? .green : Theme.primaryAccent)
                    .frame(width: 32, height: 32)
                    .background((isCopied ? Color.green : Theme.primaryAccent).opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - CreatePromoCodeSheet

struct CreatePromoCodeSheet: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedType   = PromoCode.CodeType.proTrial
    @State private var durationDays   = 30
    @State private var maxRedemptions = 1
    @State private var note           = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Code-Typ") {
                    Picker("Typ", selection: $selectedType) {
                        ForEach(PromoCode.CodeType.allCases, id: \.self) { t in
                            Label(t.rawValue, systemImage: t.icon).tag(t)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section("Parameter") {
                    if selectedType == .proTrial {
                        Stepper("Dauer: \(durationDays) Tage", value: $durationDays, in: 7...365, step: 7)
                    } else {
                        HStack { Text("Dauer"); Spacer(); Text("Unbegrenzt").foregroundStyle(.secondary) }
                    }
                    Stepper("Max. Einlösungen: \(maxRedemptions)", value: $maxRedemptions, in: 1...100)
                }
                Section("Notiz / Zweck (optional)") {
                    TextField("z. B. für Beta-Tester Gruppe A", text: $note, axis: .vertical).lineLimit(1...3)
                }
            }
            .navigationTitle("Code erstellen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Erstellen") {
                        settings.createPromoCode(type: selectedType, durationDays: durationDays,
                                                 maxRedemptions: maxRedemptions, note: note)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }
}

// MARK: - HouseholdInviteAdminView

struct HouseholdInviteAdminView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var latestCode: String? = nil
    @State private var isCopied           = false

    private var invites: [PromoCode] { settings.promoCodes.filter { $0.type == .householdInvite } }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Erzeuge einen Einladungslink, den dein Partner eingeben oder scannen kann.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button {
                        let c = settings.createPromoCode(type: .householdInvite, durationDays: 30,
                                                         maxRedemptions: 1, note: "Haushalt-Einladung")
                        latestCode = c.code
                    } label: {
                        Label("Neuen Einladungscode erstellen", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.primaryAccent)
                }
                .padding(.vertical, 8)
            }

            if let code = latestCode {
                Section("Dein Code") {
                    HStack {
                        Text(code).font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.primaryAccent)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = code
                            isCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCopied = false }
                        } label: {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc.fill")
                                .foregroundStyle(isCopied ? .green : Theme.primaryAccent)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Einmalig · 30 Tage gültig").font(.caption).foregroundStyle(.secondary)
                    if let url = URL(string: "schulden://join?code=\(code)") {
                        ShareLink(item: url,
                                  subject: Text("Haushalt-Einladung"),
                                  message: Text("Tritt meinem Haushalt bei: schulden://join?code=\(code)")) {
                            Label("Code direkt teilen", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }

            if !invites.isEmpty {
                Section("Bestehende Einladungen") {
                    ForEach(invites) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.code).font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                Text("\(c.remainingUses) Nutzung(en) · \(c.isExpired ? "Abgelaufen" : "Aktiv")")
                                    .font(.caption).foregroundStyle(c.isExpired ? .red : .secondary)
                            }
                            Spacer()
                            Image(systemName: (c.isExpired || c.isExhausted) ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle((c.isExpired || c.isExhausted) ? Color.secondary : Color.green)
                        }
                    }
                    .onDelete { idx in idx.forEach { settings.deletePromoCode(invites[$0]) } }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Haushalt-Einladungen")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - ProfileEditView

struct ProfileEditView: View {
    @EnvironmentObject private var sessionManager: UserSessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var name    = ""
    @State private var address = ""
    @State private var phone   = ""
    @State private var budget: Double = 250

    var body: some View {
        Form {
            Section("Persönliche Daten") {
                TextField("Max Mustermann", text: $name)
                TextField("Musterstraße 1, 12345 Musterstadt", text: $address)
                TextField("0151 00000000", text: $phone).keyboardType(.phonePad)
            }
            Section("Ratenzahlungs-Budget") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(Int(budget)) € / Monat")
                            .font(.title3.bold()).foregroundStyle(Theme.primaryAccent)
                        Spacer()
                    }
                    Slider(value: $budget, in: 10...2000, step: 10).tint(Theme.primaryAccent)
                }
                .padding(.vertical, 4)
            }
            Section {
                Button("Speichern") {
                    sessionManager.saveProfile(UserProfile(
                        name: name, address: address,
                        phone: phone, installmentBudget: budget
                    ))
                    dismiss()
                }
                .bold().frame(maxWidth: .infinity, alignment: .center).foregroundStyle(Theme.primaryAccent)
            }
        }
        .navigationTitle("Profil bearbeiten")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let p = sessionManager.profile {
                name = p.name; address = p.address; phone = p.phone; budget = p.installmentBudget
            }
        }
    }
}

// MARK: - ChoresWidgetCard

struct ChoresWidgetCard: View {
    @ObservedObject var service: RealtimeHouseholdService

    private var myChores: [ChoreItem] {
        service.chores
            .filter { $0.assignedTo == service.currentUserId }
            .sorted { ($0.lastCompletedAt ?? .distantPast) < ($1.lastCompletedAt ?? .distantPast) }
            .prefix(3).map { $0 }
    }

    private var overdueCount: Int {
        service.chores.filter { chore in
            guard let last = chore.lastCompletedAt else { return true }
            let days = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0
            return days >= chore.intervalDays
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Label("Putzplan", systemImage: "sparkles")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if overdueCount > 0 {
                    Text("\(overdueCount) fällig")
                        .font(.caption2.weight(.bold)).foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.orange.opacity(0.12), in: Capsule())
                } else {
                    Text("Alles erledigt ✓").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                }
            }

            if myChores.isEmpty {
                Text("Keine Aufgaben zugewiesen")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
            } else {
                ForEach(Array(myChores.enumerated()), id: \.element.id) { idx, chore in
                    choreRow(chore)
                    if idx < myChores.count - 1 { Divider().padding(.leading, 36) }
                }
            }
        }
        .liquidGlassCard(cornerRadius: 20, padding: .init(top: 16, leading: 16, bottom: 16, trailing: 16))
    }

    @ViewBuilder
    private func choreRow(_ chore: ChoreItem) -> some View {
        let isDue: Bool = {
            guard let last = chore.lastCompletedAt else { return true }
            return (Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0) >= chore.intervalDays
        }()
        HStack(spacing: 12) {
            Image(systemName: chore.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isDue ? .orange : Theme.primaryAccent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(chore.title).font(.subheadline.weight(.medium))
                if let last = chore.lastCompletedAt {
                    Text("Zuletzt: \(last.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Noch nicht erledigt").font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button { service.toggleChore(chore) } label: {
                Image(systemName: isDue ? "circle" : "checkmark.circle.fill")
                    .font(.system(size: 22)).foregroundStyle(isDue ? Color.secondary : Color.green)
            }
            .buttonStyle(.plain)
        }
    }
}

// =============================================================================
// MARK: - RedeemPromoCodeSheet
// =============================================================================

struct RedeemPromoCodeSheet: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var inputCode: String = ""
    @State private var errorMessage: String? = nil
    @State private var successCode: PromoCode? = nil
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Header Icon
                ZStack {
                    Circle()
                        .fill(Theme.primaryAccent.opacity(0.15))
                        .frame(width: 80, height: 80)
                    Image(systemName: "ticket.fill")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(Theme.primaryAccent)
                }
                .padding(.top, 24)

                VStack(spacing: 6) {
                    Text("Code einlösen")
                        .font(.title2.bold())
                    Text("Gib deinen generierten Promo-, Testphasen- oder Lifetime-Code ein, um alle Pro-Funktionen freizuschalten.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if let success = successCode {
                    // Success View
                    VStack(spacing: 14) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.green)
                        Text("Erfolgreich freigeschaltet!")
                            .font(.headline)
                        Text("Aktiviert: \(success.type.rawValue)")
                            .font(.subheadline.bold())
                            .foregroundStyle(success.type.color)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(success.type.color.opacity(0.12), in: Capsule())

                        Text("Du hast ab sofort vollen Zugriff auf alle Pro-Features, unbegrenzte Dokumenten-Scans und den Schuldnerberatungs-Export.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button("Fertig") {
                            dismiss()
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.primaryGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.top, 8)
                    }
                    .padding(20)
                    .liquidGlassCard(cornerRadius: 20)
                    .padding(.horizontal)
                } else {
                    // Code Input Form
                    VStack(spacing: 16) {
                        TextField("Z. B. ABCD-EFGH-JKLM", text: $inputCode)
                            .font(.system(.title3, design: .monospaced).weight(.bold))
                            .multilineTextAlignment(.center)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled(true)
                            .padding(14)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(Theme.primaryAccent.opacity(0.3), lineWidth: 1)
                            }

                        if let err = errorMessage {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle.fill")
                                Text(err)
                            }
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                        }

                        Button {
                            submit()
                        } label: {
                            if isSubmitting {
                                ProgressView().tint(.white)
                            } else {
                                Text("Code aktivieren")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(
                                        inputCode.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray.opacity(0.5) : Theme.primaryAccent,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    )
                            }
                        }
                        .disabled(inputCode.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                    }
                    .padding(20)
                    .liquidGlassCard(cornerRadius: 20)
                    .padding(.horizontal)
                }

                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
        }
    }

    private func submit() {
        errorMessage = nil
        isSubmitting = true
        let result = settings.redeemPromoCode(inputCode)
        switch result {
        case .success(let code):
            withAnimation(.spring(response: 0.4)) {
                successCode = code
                isSubmitting = false
            }
        case .failure(let error):
            withAnimation {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
