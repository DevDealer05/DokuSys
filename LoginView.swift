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
    @State private var magicLinkSent: Bool = false
    
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    
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

                    // ── 2. Mit Google anmelden (100% Kostenlos) ─────────────
                    VStack(spacing: 12) {
                        Button {
                            handleGoogleLogin()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 28, height: 28)
                                    Image(systemName: "g.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(Color.red)
                                }
                                
                                Text("Mit Google anmelden")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.white)
                                
                                Spacer()
                                
                                Text("Kostenlos")
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
                            VStack(spacing: 12) {
                                if magicLinkSent {
                                    VStack(spacing: 8) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 36))
                                            .foregroundStyle(.green)
                                        Text("Bestätigt & Eingeloggt!")
                                            .font(.headline)
                                        Text("Willkommen zurück! Deine Sitzung wurde gestartet.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                    }
                                    .padding(.vertical, 8)
                                } else {
                                    Text("Gib deine E-Mail-Adresse ein. Du erhältst einen sicheren 1-Klick-Zugang ohne Passwort.")
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
                                            Text("Jetzt einloggen (1-Klick)")
                                                .font(.subheadline.weight(.bold))
                                                .foregroundStyle(.white)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 12)
                                                .background(Theme.primaryAccent, in: RoundedRectangle(cornerRadius: 12))
                                        }
                                    }
                                    .disabled(emailInput.isEmpty || isSubmitting)
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
                            VStack(spacing: 12) {
                                TextField("E-Mail Adresse", text: $emailInput)
                                    .textContentType(.emailAddress)
                                    .keyboardType(.emailAddress)
                                    .autocapitalization(.none)
                                    .autocorrectionDisabled(true)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                
                                SecureField("Passwort", text: $passwordInput)
                                    .textContentType(.password)
                                    .padding(12)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                
                                Button {
                                    submitEmailLogin()
                                } label: {
                                    if isSubmitting {
                                        ProgressView().tint(.white)
                                    } else {
                                        Text("Anmelden")
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

                    Spacer(minLength: 30)
                }
            }
        }
    }

    // MARK: - Actions

    private func handleGoogleLogin() {
        errorMessage = nil
        Task {
            await authService.signInWithGoogle()
        }
    }

    private func submitMagicLink() {
        errorMessage = nil
        isSubmitting = true
        Task {
            await authService.signInWithMagicLink(email: emailInput)
            await MainActor.run {
                withAnimation {
                    magicLinkSent = true
                    isSubmitting = false
                }
            }
        }
    }

    private func submitEmailLogin() {
        errorMessage = nil
        isSubmitting = true
        Task {
            await authService.signInWithEmail(email: emailInput, password: passwordInput)
            await MainActor.run {
                isSubmitting = false
            }
        }
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
