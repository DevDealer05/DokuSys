// =============================================================================
// SubscriptionManager.swift
// Monetization & Subscription Management (Free vs. Pro Tier)
// Requires: iOS 17+, Swift 5.9+, SwiftUI
// =============================================================================

import SwiftUI
import Combine

@MainActor
final class SubscriptionManager: ObservableObject {
    public static let shared = SubscriptionManager()
    
    // ── Persistent State ───────────────────────────────────────────────
    @AppStorage("subscription_is_pro") var isPro: Bool = false
    @AppStorage("subscription_scans_used") var scansUsedThisMonth: Int = 0
    @AppStorage("subscription_last_reset") private var lastResetMonthTimestamp: Double = Date().timeIntervalSince1970
    
    // ── Constants ──────────────────────────────────────────────────────
    public static let freeTierScanLimit: Int = 5
    
    @Published var isPresentingPaywall: Bool = false
    @Published var isPurchasing: Bool = false
    @Published var purchaseError: String?
    
    init() {
        checkAndResetMonthlyQuota()
    }
    
    // ── Quota Check ────────────────────────────────────────────────────
    
    private func checkAndResetMonthlyQuota() {
        let lastDate = Date(timeIntervalSince1970: lastResetMonthTimestamp)
        let calendar = Calendar.current
        if !calendar.isDate(lastDate, equalTo: Date(), toGranularity: .month) {
            scansUsedThisMonth = 0
            lastResetMonthTimestamp = Date().timeIntervalSince1970
        }
    }
    
    // ── Feature Gates ──────────────────────────────────────────────────
    
    var canScanDocument: Bool {
        if isPro { return true }
        checkAndResetMonthlyQuota()
        return scansUsedThisMonth < Self.freeTierScanLimit
    }
    
    var remainingFreeScans: Int {
        if isPro { return Int.max }
        checkAndResetMonthlyQuota()
        return max(0, Self.freeTierScanLimit - scansUsedThisMonth)
    }
    
    var canUseSharedHousehold: Bool {
        return isPro
    }
    
    var canUseAIRatenantrag: Bool {
        return isPro
    }
    
    // ── Actions ────────────────────────────────────────────────────────
    
    func recordScan() {
        guard !isPro else { return }
        checkAndResetMonthlyQuota()
        scansUsedThisMonth += 1
    }
    
    func purchasePro(monthly: Bool = false) async {
        isPurchasing = true
        defer { isPurchasing = false }
        
        // Simulating StoreKit 2 transaction verification
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        
        withAnimation(.spring(response: 0.4)) {
            self.isPro = true
            self.isPresentingPaywall = false
        }
    }
    
    func restorePurchases() async {
        isPurchasing = true
        defer { isPurchasing = false }
        
        try? await Task.sleep(nanoseconds: 800_000_000)
        
        withAnimation(.spring(response: 0.4)) {
            self.isPro = true
            self.isPresentingPaywall = false
        }
    }

    func unlockWithPromo(code: String) {
        withAnimation(.spring(response: 0.4)) {
            self.isPro = true
            self.isPresentingPaywall = false
        }
    }
}

// =============================================================================
// MARK: - PaywallView
// =============================================================================

struct PaywallView: View {
    @ObservedObject var subscription = SubscriptionManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTier: PlanTier = .yearly
    @State private var showRedeemSheet = false
    
    enum PlanTier {
        case monthly
        case yearly
    }
    
    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 24) {
                    // Header close
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 16)
                    
                    // Crown / Icon
                    ZStack {
                        Circle()
                            .fill(Theme.primaryGradient.opacity(0.2))
                            .frame(width: 90, height: 90)
                        Image(systemName: "crown.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(Theme.primaryGradient)
                    }
                    
                    // Titles
                    VStack(spacing: 8) {
                        Text("Digitales Büro Pro")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        
                        Text("Volle Kontrolle über deine Finanzen, Belege & Haushalt.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    
                    // Features List
                    VStack(spacing: 16) {
                        featureRow(icon: "doc.viewfinder.fill", title: "Unbegrenzte Scans", desc: "Kein 5-Scans-Limit mehr – ganze Ordner archivieren.")
                        featureRow(icon: "sparkles", title: "KI-Ratenzahlungsantrag", desc: "Rechtskonforme Anträge mit Tilgungsrechner & PDF-Export.")
                        featureRow(icon: "house.fill", title: "Shared Household Sync", desc: "Vorräte, Putzpläne & Budgets in Echtzeit mit Partnern teilen.")
                        featureRow(icon: "lock.shield.fill", title: "Prioritäts-Support & Backup", desc: "Vollverschlüsseltes Cloud-Backup & schneller Support.")
                    }
                    .padding(20)
                    .liquidGlassCard(cornerRadius: 20)
                    .padding(.horizontal)
                    
                    // Pricing Options
                    VStack(spacing: 12) {
                        // Yearly Option
                        pricingCard(
                            tier: .yearly,
                            title: "Jahresabo",
                            price: "39,99 € / Jahr",
                            subtitle: "Nur 3,33 € / Monat (Spare 33%)",
                            badge: "BELIEBTEST"
                        )
                        
                        // Monthly Option
                        pricingCard(
                            tier: .monthly,
                            title: "Monatsabo",
                            price: "4,99 € / Monat",
                            subtitle: "Jederzeit flexibel kündbar",
                            badge: nil
                        )
                    }
                    .padding(.horizontal)
                    
                    // CTA Button
                    Button {
                        Task {
                            await subscription.purchasePro(monthly: selectedTier == .monthly)
                        }
                    } label: {
                        HStack {
                            if subscription.isPurchasing {
                                ProgressView().tint(.white).padding(.trailing, 8)
                            }
                            Text(subscription.isPurchasing ? "Wird aktiviert…" : "Jetzt Pro freischalten")
                                .font(.headline.bold())
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.primaryGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: Theme.primaryAccent.opacity(0.4), radius: 12, y: 6)
                    }
                    .disabled(subscription.isPurchasing)
                    .padding(.horizontal)
                    
                    // Restore & Terms
                    HStack(spacing: 20) {
                        Button("Käufe wiederherstellen") {
                            Task { await subscription.restorePurchases() }
                        }
                        Text("•")
                        Button("AGB & Datenschutz") {}
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    // Redeem Promo Code Button
                    Button {
                        showRedeemSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "ticket.fill")
                            Text("Hast du einen Code? Hier einlösen")
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.primaryAccent)
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
            }
        }
        .sheet(isPresented: $showRedeemSheet) {
            RedeemPromoCodeSheet().environmentObject(AppSettingsStore())
        }
    }
    
    private func featureRow(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.primaryAccent)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
    
    private func pricingCard(tier: PlanTier, title: String, price: String, subtitle: String, badge: String?) -> some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                selectedTier = tier
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.white)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.primaryAccent, in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Text(price)
                    .font(.subheadline.bold())
                    .foregroundStyle(selectedTier == tier ? Theme.primaryAccent : .white)
                
                Image(systemName: selectedTier == tier ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedTier == tier ? Theme.primaryAccent : Color.secondary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selectedTier == tier ? Theme.primaryAccent.opacity(0.12) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selectedTier == tier ? Theme.primaryAccent : Color.white.opacity(0.1), lineWidth: selectedTier == tier ? 1.5 : 1.0)
            )
        }
        .buttonStyle(.plain)
    }
}
