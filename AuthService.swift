// =============================================================================
// AuthService.swift
// Schulden & Haushalt App
// Requires: iOS 17+, Swift 5.9+, AuthenticationServices, CryptoKit
// =============================================================================

import SwiftUI
import AuthenticationServices
import CryptoKit

@MainActor
final class AuthService: ObservableObject {
    @Published var session: Session?
    @Published var isLoading = false
    @Published var error: Error?
    
    private let client = SupabaseConfig.client
    
    init() {
        self.session = client.auth.getCachedSession()
    }

    /// Sign in with Google OAuth (Live via Supabase Auth)
    func signInWithGoogle() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            try await client.auth.signInWithOAuth(provider: "google")
            withAnimation(.easeInOut(duration: 0.3)) {
                self.session = client.auth.getCachedSession()
                self.error = nil
            }
            AppLogger.shared.success("Auth", "Google Login erfolgreich abgeschlossen.")
        } catch {
            AppLogger.shared.error("Auth", "Google Login fehlgeschlagen: \(error.localizedDescription)")
            self.error = error
        }
    }

    /// Sign in with Apple OAuth (Live via Supabase Auth)
    func signInWithApple() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            try await client.auth.signInWithOAuth(provider: "apple")
            withAnimation(.easeInOut(duration: 0.3)) {
                self.session = client.auth.getCachedSession()
                self.error = nil
            }
            AppLogger.shared.success("Auth", "Apple Login erfolgreich abgeschlossen.")
        } catch {
            AppLogger.shared.error("Auth", "Apple Login fehlgeschlagen: \(error.localizedDescription)")
            self.error = error
        }
    }

    /// Send Magic Link & OTP confirmation code via Supabase Auth email server
    func sendMagicLink(email: String) async throws {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanEmail.isEmpty else {
            let err = NSError(domain: "Auth", code: 400, userInfo: [NSLocalizedDescriptionKey: "Bitte gib eine gültige E-Mail-Adresse ein."])
            self.error = err
            throw err
        }
        do {
            try await client.auth.sendOTP(email: cleanEmail, redirectTo: "digitalesbuero://auth")
            AppLogger.shared.info("Auth", "Magic Link & 6-stelliger Code per E-Mail an '\(cleanEmail)' versendet.")
        } catch {
            AppLogger.shared.error("Auth", "E-Mail-Versand fehlgeschlagen: \(error.localizedDescription)")
            self.error = error
            throw error
        }
    }

    /// Verify 6-digit confirmation code received via email
    func verifyOTP(email: String, token: String) async throws {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.auth.verifyOTP(email: cleanEmail, token: cleanToken)
            withAnimation(.easeInOut(duration: 0.3)) {
                self.session = client.auth.getCachedSession()
                self.error = nil
            }
            AppLogger.shared.success("Auth", "E-Mail-Code erfolgreich bestätigt für '\(cleanEmail)'.")
        } catch {
            AppLogger.shared.error("Auth", "Code-Verifikation fehlgeschlagen: \(error.localizedDescription)")
            self.error = error
            throw error
        }
    }
    
    /// Quick guest / demo login to test the app instantly without internet or email
    func signInAsGuest() {
        let defaultId = UUID(uuidString: "e1a2b3c4-d5e6-4a1b-8c2d-3e4f5a6b7c8d") ?? UUID()
        let guestSession = Session(
            accessToken: SupabaseConfig.anonKey,
            user: User(id: defaultId, email: "gast@digitalesbuero.app")
        )
        client.auth.saveSession(guestSession)
        withAnimation(.easeInOut(duration: 0.3)) {
            self.session = guestSession
            self.isLoading = false
            self.error = nil
        }
        AppLogger.shared.info("Auth", "Lokale Gast-Sitzung gestartet.")
    }

    /// Sign in with Email & Password
    func signInWithEmail(email: String, password: String) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.auth.signInWithEmail(email: cleanEmail, password: password)
            withAnimation(.easeInOut(duration: 0.3)) {
                self.session = client.auth.getCachedSession()
                self.error = nil
            }
            AppLogger.shared.success("Auth", "Erfolgreich angemeldet mit '\(cleanEmail)'.")
        } catch {
            AppLogger.shared.error("Auth", "Anmeldung fehlgeschlagen: \(error.localizedDescription)")
            self.error = error
        }
    }

    /// Register a new account with Email & Password
    func signUpWithEmail(email: String, password: String) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.auth.signUpWithEmail(email: cleanEmail, password: password)
            withAnimation(.easeInOut(duration: 0.3)) {
                self.session = client.auth.getCachedSession()
                self.error = nil
            }
            AppLogger.shared.success("Auth", "Neues Konto erfolgreich erstellt für '\(cleanEmail)'.")
        } catch {
            AppLogger.shared.error("Auth", "Registrierung fehlgeschlagen: \(error.localizedDescription)")
            self.error = error
        }
    }

    /// Handles incoming auth deep-links like digitalesbuero://auth#access_token=...
    @discardableResult
    func handleDeepLinkURL(_ url: URL) -> Bool {
        if client.auth.handleAuthURL(url) {
            withAnimation(.easeInOut(duration: 0.3)) {
                self.session = client.auth.getCachedSession()
                self.error = nil
            }
            AppLogger.shared.success("Auth", "Deep-Link Authentifizierung erfolgreich abgeschlossen.")
            return true
        }
        return false
    }

    
    func signOut() {
        isLoading = true
        defer { isLoading = false }
        
        client.auth.saveSession(nil)
        withAnimation(.easeInOut(duration: 0.3)) {
            self.session = nil
        }
    }
    
    private func updateDisplayName(_ name: String) async {
        guard let userId = try? client.auth.session.user.id.uuidString else { return }
        do {
            try await client
                .from("user_profiles")
                .update(["display_name": name])
                .eq("user_id", value: userId)
                .execute()
        } catch {
            print("Failed to save Apple fullName to profile: \(error)")
        }
    }
    
    // MARK: - Nonce Generation (Required by Apple Sign In)
    
    static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        
        while remainingLength > 0 {
            let randoms: [UInt8] = (0 ..< 16).map { _ in
                var random: UInt8 = 0
                let errorCode = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
                if errorCode != errSecSuccess {
                    fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
                }
                return random
            }
            randoms.forEach { random in
                if remainingLength == 0 { return }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }
    
    static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        let hashString = hashedData.compactMap {
            String(format: "%02x", $0)
        }.joined()
        return hashString
    }
}
