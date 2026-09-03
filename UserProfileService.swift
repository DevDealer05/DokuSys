// =============================================================================
// UserProfileService.swift
// Schulden & Haushalt App
// Requires: iOS 17+, Swift 5.9+
// =============================================================================

import SwiftUI

struct DBUserProfile: Codable, Sendable {
    let id: UUID
    let userId: UUID
    var displayName: String?
    var avatarUrl: String?
    var locale: String
    var faceIdEnabled: Bool
    
    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case locale
        case faceIdEnabled = "face_id_enabled"
    }
}

@MainActor
final class UserProfileService: ObservableObject {
    @Published private(set) var profile: DBUserProfile?
    @Published private(set) var isLoading = false
    
    private let db = SupabaseConfig.client
    private let cacheKey = "cached_db_user_profile"
    
    init() {
        loadFromCache()
        if profile == nil {
            seedDefaultProfile()
        }
    }
    
    private func loadFromCache() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(DBUserProfile.self, from: data) {
            self.profile = cached
        }
    }
    
    private func saveToCache(_ profile: DBUserProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
    
    private func seedDefaultProfile() {
        let defaultUserId = (try? db.auth.session.user.id) ?? UUID()
        let fallback = DBUserProfile(
            id: defaultUserId,
            userId: defaultUserId,
            displayName: "Max Mustermann",
            avatarUrl: nil,
            locale: "de_DE",
            faceIdEnabled: false
        )
        self.profile = fallback
        saveToCache(fallback)
    }
    
    func load() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let session = try db.auth.session
            let user = session.user
            
            let fetched: DBUserProfile = try await db
                .from("user_profiles")
                .select()
                .eq("user_id", value: user.id.uuidString)
                .single()
                .execute()
                .value
            
            self.profile = fetched
            saveToCache(fetched)
        } catch {
            // Graceful offline fallback: keep local cached profile
            if self.profile == nil {
                seedDefaultProfile()
            }
            #if DEBUG
            print("ℹ️ UserProfileService: Offline-Modus aktiv – Lokales Profil wird verwendet.")
            #endif
        }
    }
    
    func updateProfile(displayName: String) async {
        guard var profile = profile else { return }
        profile.displayName = displayName
        self.profile = profile
        saveToCache(profile)
        
        do {
            try await db
                .from("user_profiles")
                .update(["display_name": displayName])
                .eq("id", value: profile.id.uuidString)
                .execute()
        } catch {
            #if DEBUG
            print("ℹ️ UserProfileService: Profil lokal aktualisiert (Server im Offline-Modus).")
            #endif
        }
    }
}
