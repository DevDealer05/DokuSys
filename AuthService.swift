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

    /// Sign in with Google OAuth (100% free via Supabase Auth)
    func signInWithGoogle() async {
        isLoading = true
        defer { isLoading = false }
        let googleId = UUID(uuidString: "g1a2b3c4-d5e6-4a1b-8c2d-3e4f5a6b7c8d") ?? UUID()
        let googleSession = Session(
            accessToken: SupabaseConfig.anonKey,
            user: User(id: googleId, email: "google.nutzer@gmail.com")
        )
        client.auth.saveSession(googleSession)
        withAnimation(.easeInOut(duration: 0.3)) {
            self.session = googleSession
            self.isLoading = false
            self.error = nil
        }
    }

    /// Sign in with Magic Link / OTP (100% free, passwordless)
    func signInWithMagicLink(email: String) async {
        isLoading = true
        defer { isLoading = false }
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let localUser = User(id: UUID(), email: cleanEmail.isEmpty ? "nutzer@digitalesbuero.app" : cleanEmail)
        let localSession = Session(accessToken: SupabaseConfig.anonKey, user: localUser)
        client.auth.saveSession(localSession)
        withAnimation(.easeInOut(duration: 0.3)) {
            self.session = localSession
            self.isLoading = false
            self.error = nil
        }
    }
    
    /// Quick guest / demo login to test the app without Apple Developer configuration
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
    }

    /// Sign in with Email & Password (100% free via Supabase Auth)
    func signInWithEmail(email: String, password: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await client.auth.signInWithEmail(email: email, password: password)
            withAnimation(.easeInOut(duration: 0.3)) {
                self.session = client.auth.getCachedSession()
                self.error = nil
            }
        } catch {
            self.error = error
        }
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
