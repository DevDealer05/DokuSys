// =============================================================================
// LoginView.swift
// Schulden & Haushalt App
// Requires: iOS 17+, Swift 5.9+
// =============================================================================

import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var sessionManager: UserSessionManager
    
    @State private var showEmailLogin: Bool = false
    @State private var showMagicLink: Bool = false
    
    @State private var emailInput: String = ""
    @State private var passwordInput: String = ""
    @State private var otpCodeInput: String = ""
    @State private var isRegisterMode: Bool = false
    @State private var magicLinkSent: Bool = false
    
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var showDevCodeAlert: Bool = false
    @State private var devCodeInput: String = ""
    
    var body: some View {
        ZStack {
            Theme.appBackground.ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 40)
                    
                    // Logo
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 76))
                        .foregroundStyle(Theme.primaryGradient)
                    
                    VStack(spacing: 8) {
                        Text("Digitales Büro")
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(.white)
                        
                        Text("Dein sicherer Begleiter für Haushalt & Schuldenmanagement.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    
                    Spacer(minLength: 16)
                    
                    // ── 1. Kostenloser Sofortstart (Lokal & Offline) ────────
                    VStack(spacing: 12) {
                        Button {
                            authService.signInAsGuest()
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "play.circle.fill")
                                    .font(.title2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Direkt & kostenlos starten")
                                        .font(.headline.weight(.bold))
                                    Text("Ohne Account • 100% lokal auf deinem Gerät")
                                        .font(.caption2)
                                        .opacity(0.9)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.subheadline.bold())
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 15)
                            .background(Theme.primaryGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: Theme.primaryAccent.opacity(0.35), radius: 10, y: 5)
                        }
                    }
                    .padding(.horizontal, 24)

                    // ── 2. Mit Apple & Google anmelden (Live OAuth) ───────────
                    VStack(spacing: 12) {
                        Button {
                            handleAppleLogin()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "apple.logo")
                                    .font(.system(size: 20, weight: .semibold))
                                Text("Mit Apple anmelden")
                                    .font(.body.weight(.semibold))
                                Spacer()
                                Text("Live")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.black.opacity(0.12), in: Capsule())
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .disabled(isSubmitting)

                        Button {
                            handleGoogleLogin()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 24, height: 24)
                                    Image(systemName: "g.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(Color.red)
                                }
                                
                                Text("Mit Google anmelden")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.white)
                                
                                Spacer()
                                
                                Text("Live")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                            )
                        }
                        .disabled(isSubmitting)
                    }
                    .padding(.horizontal, 24)

                    // ── 3. Magic Link (Passwortlos per E-Mail) ───────────────
                    VStack(spacing: 12) {
                        Button {
                            withAnimation(.spring(response: 0.35)) {
                                showMagicLink.toggle()
                                if showMagicLink { showEmailLogin = false }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.yellow)
                                Text(showMagicLink ? "Magic Link schließen" : "Passwortlos anmelden (Magic Link)")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Image(systemName: showMagicLink ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        }
                        
                        if showMagicLink {
                            VStack(spacing: 14) {
                                if magicLinkSent {
                                    VStack(spacing: 12) {
                                        HStack(spacing: 10) {
                                            Image(systemName: "envelope.badge.shield.half.filled")
                                                .font(.title2)
                                                .foregroundStyle(Color.green)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("E-Mail versendet!")
                                                    .font(.headline.weight(.bold))
                                                Text("an \(emailInput)")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }

                                        Text("Tippe auf den Link in deiner E-Mail oder gib den 6-stelligen Bestätigungscode hier ein:")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        TextField("6-stelliger Code (z.B. 123456)", text: $otpCodeInput)
                                            .keyboardType(.numberPad)
                                            .font(.system(.title3, design: .monospaced).weight(.bold))
                                            .multilineTextAlignment(.center)
                                            .padding(12)
                                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                                        Button {
                                            submitVerifyOTP()
                                        } label: {
                                            if isSubmitting {
                                                ProgressView().tint(.white)
                                            } else {
                                                Text("Code bestätigen & einloggen")
                                                    .font(.subheadline.weight(.bold))
                                                    .foregroundStyle(.white)
                                                    .frame(maxWidth: .infinity)
                                                    .padding(.vertical, 12)
                                                    .background(Theme.primaryAccent, in: RoundedRectangle(cornerRadius: 12))
                                            }
                                        }
                                        .disabled(otpCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).count < 4 || isSubmitting)

                                        HStack(spacing: 16) {
                                            Button("Erneut senden") {
                                                submitMagicLink()
                                            }
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Theme.primaryAccent)

                                            Text("•").foregroundStyle(.secondary)

                                            Button("Andere E-Mail") {
                                                withAnimation {
                                                    magicLinkSent = false
                                                    otpCodeInput = ""
                                                }
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                        .padding(.top, 4)

                                        Divider().background(Color.white.opacity(0.1))

                                        Button {
                                            handleGuestLogin()
                                        } label: {
                                            Text("E-Mail kommt nicht an? Sofort ohne E-Mail starten")
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                } else {
                                    Text("Gib deine E-Mail-Adresse ein. Supabase sendet dir einen sicheren 1-Klick-Link und einen 6-stelligen Bestätigungscode.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    
                                    TextField("name@beispiel.de", text: $emailInput)
                                        .textContentType(.emailAddress)
                                        .keyboardType(.emailAddress)
                                        .autocapitalization(.none)
                                        .autocorrectionDisabled(true)
                                        .padding(12)
                                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                    
                                    Button {
                                        submitMagicLink()
                                    } label: {
                                        if isSubmitting {
                                            ProgressView().tint(.white)
                                        } else {
                                            HStack(spacing: 8) {
                                                Image(systemName: "paperplane.fill")
                                                Text("Anmelde-Link & Code anfordern")
                                                    .font(.subheadline.weight(.bold))
                                            }
                                            .foregroundStyle(.white)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                            .background(Theme.primaryAccent, in: RoundedRectangle(cornerRadius: 12))
                                        }
                                    }
                                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                                }
                            }
                            .padding(16)
                            .liquidGlassCard(cornerRadius: 16)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                    }
                    .padding(.horizontal, 24)

                    // ── 4. E-Mail & Passwort (Klassisch) ────────────────────
                    VStack(spacing: 12) {
                        Button {
                            withAnimation(.spring(response: 0.35)) {
                                showEmailLogin.toggle()
                                if showEmailLogin { showMagicLink = false }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "envelope.fill")
                                    .foregroundStyle(Theme.primaryAccent)
                                Text(showEmailLogin ? "E-Mail-Login schließen" : "Klassisch mit E-Mail & Passwort")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Image(systemName: showEmailLogin ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        }
                        
                        if showEmailLogin {
                            VStack(spacing: 14) {
                                Picker("Modus", selection: $isRegisterMode) {
                                    Text("Anmelden").tag(false)
                                    Text("Neu registrieren").tag(true)
                                }
                                .pickerStyle(.segmented)

                                TextField("E-Mail Adresse", text: $emailInput)
                                    .textContentType(.emailAddress)
                                    .keyboardType(.emailAddress)
                                    .autocapitalization(.none)
                                    .autocorrectionDisabled(true)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                
                                SecureField(isRegisterMode ? "Neues Passwort (min. 6 Zeichen)" : "Passwort", text: $passwordInput)
                                    .textContentType(isRegisterMode ? .newPassword : .password)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                
                                Button {
                                    submitEmailLogin()
                                } label: {
                                    if isSubmitting {
                                        ProgressView().tint(.white)
                                    } else {
                                        Text(isRegisterMode ? "Konto kostenlos erstellen" : "Jetzt anmelden")
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(.white)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                            .background(Theme.primaryAccent, in: RoundedRectangle(cornerRadius: 12))
                                    }
                                }
                                .disabled(emailInput.isEmpty || passwordInput.isEmpty || isSubmitting)
                            }
                            .padding(16)
                            .liquidGlassCard(cornerRadius: 16)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.horizontal, 24)
                    
                    if let err = errorMessage ?? authService.error?.localizedDescription {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }

                    // ── 5. Entwickler-Code / PIN ────────────
                    Button {
                        showDevCodeAlert = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "key.horizontal.fill")
                                .font(.system(size: 11))
                            Text("Mit Entwickler-Code (PIN 0505) starten")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                    }

                    Spacer(minLength: 30)
                }
            }
        }
        .alert("Entwickler- & Ersteller-Code", isPresented: $showDevCodeAlert) {
            TextField("PIN oder Code (z.B. 0505)", text: $devCodeInput)
                .textInputAutocapitalization(.characters)
            Button("Einloggen & Starten") {
                let code = devCodeInput
                devCodeInput = ""
                if SubscriptionManager.shared.unlockWithCreatorCode(code) {
                    authService.signInAsGuest()
                } else {
                    errorMessage = "Ungültiger Entwickler-Code. Bitte '0505' oder 'KIM-CREATOR-2026' eingeben."
                }
            }
            Button("Abbrechen", role: .cancel) { devCodeInput = "" }
        } message: {
            Text("Gib deinen Entwickler-Code oder die PIN 0505 ein, um dich sofort mit unbegrenzten Rechten & allen Features einzuloggen.")
        }
    }

    // MARK: - Actions

    private func handleAppleLogin() {
        errorMessage = nil
        isSubmitting = true
        Task {
            await authService.signInWithApple()
            await MainActor.run { isSubmitting = false }
        }
    }

    private func handleGoogleLogin() {
        errorMessage = nil
        isSubmitting = true
        Task {
            await authService.signInWithGoogle()
            await MainActor.run { isSubmitting = false }
        }
    }

    private func submitMagicLink() {
        errorMessage = nil
        isSubmitting = true
        Task {
            do {
                try await authService.sendMagicLink(email: emailInput)
                await MainActor.run {
                    withAnimation {
                        magicLinkSent = true
                        isSubmitting = false
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }

    private func submitVerifyOTP() {
        errorMessage = nil
        isSubmitting = true
        Task {
            do {
                try await authService.verifyOTP(email: emailInput, token: otpCodeInput)
                await MainActor.run {
                    isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }

    private func submitEmailLogin() {
        errorMessage = nil
        isSubmitting = true
        Task {
            if isRegisterMode {
                await authService.signUpWithEmail(email: emailInput, password: passwordInput)
            } else {
                await authService.signInWithEmail(email: emailInput, password: passwordInput)
            }
            await MainActor.run {
                isSubmitting = false
            }
        }
    }

    private func handleGuestLogin() {
        errorMessage = nil
        authService.signInAsGuest()
    }
}


#if DEBUG
#Preview {
    LoginView()
        .environmentObject(AuthService())
        .environmentObject(UserSessionManager())
        .preferredColorScheme(.dark)
}
#endif
