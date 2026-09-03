// =============================================================================
// UserSessionManager.swift
// Schulden & Haushalt App
// Requires: iOS 17+, Swift 5.9+
// =============================================================================

import SwiftUI
import Combine

/// Lokales Profil für den Benutzer. 
/// Wird genutzt, um z.B. Rechnungs-/Absenderdaten lokal zu persistieren.
struct UserProfile: Codable, Equatable {
    var name: String
    var address: String
    var phone: String
    /// Maximales Budget für Ratenzahlungen (monatlich)
    var installmentBudget: Double
}

@MainActor
final class UserSessionManager: ObservableObject {
    
    /// Speichert persistent, ob der Benutzer das Onboarding abgeschlossen hat.
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    
    /// Aktuelles lokal gespeichertes Profil.
    @Published private(set) var profile: UserProfile?
    
    private let profileKey = "app_user_profile_data"
    
    init() {
        loadProfile()
    }
    
    /// Speichert das Profil persistent in den UserDefaults via JSONEncoder.
    func saveProfile(_ profile: UserProfile) {
        self.profile = profile
        do {
            let data = try JSONEncoder().encode(profile)
            UserDefaults.standard.set(data, forKey: profileKey)
        } catch {
            print("Fehler beim Speichern des Profils: \(error)")
        }
    }
    
    /// Lädt das Profil via JSONDecoder aus den UserDefaults.
    func loadProfile() {
        guard let data = UserDefaults.standard.data(forKey: profileKey) else {
            self.profile = nil
            return
        }
        
        do {
            let decoded = try JSONDecoder().decode(UserProfile.self, from: data)
            self.profile = decoded
        } catch {
            print("Fehler beim Laden des Profils: \(error)")
        }
    }
    
    /// Hilfsfunktion, um das Profil gezielt zu löschen
    func clearProfile() {
        self.profile = nil
        UserDefaults.standard.removeObject(forKey: profileKey)
    }
}
