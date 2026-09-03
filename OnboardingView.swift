// =============================================================================
// OnboardingView.swift
// Schulden & Haushalt App
// Requires: iOS 17+, Swift 5.9+
// =============================================================================

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var sessionManager: UserSessionManager
    
    @State private var currentTab = 0
    
    // User Profile State
    @State private var name: String = ""
    @State private var address: String = ""
    @State private var phone: String = ""
    @State private var installmentBudget: Double = 250.0
    
    var body: some View {
        ZStack {
            // Background
            Theme.appBackground.ignoresSafeArea()
            
            TabView(selection: $currentTab) {
                welcomeStep.tag(0)
                masterDataStep.tag(1)
                budgetStep.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .animation(.easeInOut, value: currentTab)
        }
    }
    
    // MARK: - Step 1: Welcome (GDPR & Local AI)
    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 80))
                .foregroundStyle(Theme.primaryGradient)
            
            Text("Willkommen bei\nSchulden & Haushalt")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            
            Text("Deine Daten gehören dir. Dank lokaler KI (Vision OCR) bleiben sensible Dokumente und Aktenzeichen direkt auf deinem Gerät. Streng nach DSGVO konzipiert.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Spacer()
            
            Button("Weiter") {
                currentTab = 1
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .padding(.horizontal, 32)
            .padding(.bottom, 60)
        }
    }
    
    // MARK: - Step 2: Stammdaten
    private var masterDataStep: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "person.text.rectangle")
                .font(.system(size: 64))
                .foregroundStyle(Theme.primaryAccent)
            
            Text("Deine Stammdaten")
                .font(.title.weight(.bold))
            
            Text("Diese Daten werden ausschließlich lokal gespeichert und genutzt, um automatisiert Antwortschreiben für dich zu generieren.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            VStack(spacing: 16) {
                TextField("Max Mustermann", text: $name)
                    .modifier(LiquidGlassTextFieldModifier())

                TextField("Musterstraße 1, 12345 Musterstadt", text: $address)
                    .modifier(LiquidGlassTextFieldModifier())

                TextField("0151 00000000", text: $phone)
                    .keyboardType(.phonePad)
                    .modifier(LiquidGlassTextFieldModifier())
            }
            .padding(.horizontal, 32)
            
            Spacer()
            
            Button("Weiter") {
                currentTab = 2
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .padding(.horizontal, 32)
            .padding(.bottom, 60)
        }
    }
    
    // MARK: - Step 3: Schmerzgrenze (Raten-Budget)
    private var budgetStep: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.primaryGradient)
            
            Text("Deine Schmerzgrenze")
                .font(.title.weight(.bold))
            
            Text("Wie viel Budget hast du monatlich maximal für Ratenzahlungen zur Verfügung?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            VStack(spacing: 16) {
                Text("\(Int(installmentBudget)) €")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryAccent)
                
                Slider(value: $installmentBudget, in: 10...1000, step: 10)
                    .tint(Theme.primaryAccent)
                    .padding(.horizontal, 16)
            }
            .padding(.vertical, 24)
            .liquidGlassCard(cornerRadius: 24, padding: .init(top: 8, leading: 16, bottom: 8, trailing: 16))
            .padding(.horizontal, 32)
            
            Spacer()
            
            Button("Starten") {
                finishOnboarding()
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .padding(.horizontal, 32)
            .padding(.bottom, 60)
        }
    }
    
    private func finishOnboarding() {
        let profile = UserProfile(
            name: name,
            address: address,
            phone: phone,
            installmentBudget: installmentBudget
        )
        sessionManager.saveProfile(profile)
        sessionManager.hasCompletedOnboarding = true
    }
}

// MARK: - View Modifiers

/// Liquid Glass Styling für Textfelder
struct LiquidGlassTextFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.glassEdgeGradient, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
    }
}

/// Einheitlicher Button-Style für das Onboarding
struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.primaryGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .shadow(color: Theme.primaryAccent.opacity(0.3), radius: 10, x: 0, y: 5)
    }
}

#Preview {
    OnboardingView()
        .environmentObject(UserSessionManager())
        .preferredColorScheme(.dark)
}
