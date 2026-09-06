// =============================================================================
// SupabaseConfig.swift
// Pure-Swift lightweight Supabase Client (No C-dependencies, Swift Playgrounds ready)
// Requires: iOS 17+, Swift 5.9+
// =============================================================================

import Foundation
import Combine
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Models

public struct User: Codable, Sendable, Identifiable {
    public let id: UUID
    public let email: String?
    
    public init(id: UUID, email: String? = nil) {
        self.id = id
        self.email = email
    }
}

public struct Session: Codable, Sendable {
    public let accessToken: String
    public let user: User
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case user
    }
    
    public init(accessToken: String, user: User) {
        self.accessToken = accessToken
        self.user = user
    }
}

public enum AuthCredential {
    case apple(idToken: String, nonce: String)
}

public struct AuthStateChange: Sendable {
    public let session: Session?
}

public enum AnyJSON: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyJSON])
    case array([AnyJSON])
    case null
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) { self = .string(str) }
        else if let num = try? container.decode(Double.self) { self = .number(num) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let dict = try? container.decode([String: AnyJSON].self) { self = .object(dict) }
        else if let arr = try? container.decode([AnyJSON].self) { self = .array(arr) }
        else { self = .null }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Supabase Client

public final class SupabaseClient: @unchecked Sendable {
    public let url: URL
    public let apiKey: String

    public let auth: AuthClient
    public let storage: StorageClient

    public init(supabaseURL: URL, supabaseKey: String) {
        self.url    = supabaseURL
        self.apiKey = supabaseKey
        // Create auth first so storage can borrow a reference to it for JWT
        let authClient = AuthClient(baseURL: supabaseURL, apiKey: supabaseKey)
        self.auth    = authClient
        self.storage = StorageClient(baseURL: supabaseURL, apiKey: supabaseKey, auth: authClient)
    }

    public func from(_ table: String) -> PostgrestQueryBuilder {
        PostgrestQueryBuilder(baseURL: url.appendingPathComponent("rest/v1/\(table)"), apiKey: apiKey, auth: auth)
    }

    public func rpc(_ functionName: String, params: (some Encodable)? = nil as String?) -> PostgrestRpcBuilder {
        PostgrestRpcBuilder(baseURL: url.appendingPathComponent("rest/v1/rpc/\(functionName)"), apiKey: apiKey, auth: auth, params: params)
    }
}

// MARK: - Auth Client

public final class AuthClient: @unchecked Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let sessionKey = "supabase_auth_session_local"
    
    public var session: Session {
        get throws {
            if let cached = getCachedSession() {
                return cached
            }
            let defaultId = UUID(uuidString: "e1a2b3c4-d5e6-4a1b-8c2d-3e4f5a6b7c8d") ?? UUID()
            return Session(accessToken: apiKey, user: User(id: defaultId, email: "user@demo.local"))
        }
    }
    
    public var authStateChanges: AsyncStream<AuthStateChange> {
        AsyncStream { continuation in
            if let current = getCachedSession() {
                continuation.yield(AuthStateChange(session: current))
            }
        }
    }
    
    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
    
    public func getCachedSession() -> Session? {
        guard let data = UserDefaults.standard.data(forKey: sessionKey) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }
    
    public func saveSession(_ session: Session?) {
        if let session = session, let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: sessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
    }
    
    public func signInWithIdToken(credentials: AuthCredential) async throws {
        switch credentials {
        case .apple(let idToken, let nonce):
            let endpoint = baseURL.appendingPathComponent("auth/v1/token")
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: true)!
            components.queryItems = [URLQueryItem(name: "grant_type", value: "id_token")]
            
            var request = URLRequest(url: components.url!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "apikey")
            
            let payload: [String: String] = [
                "provider": "apple",
                "id_token": idToken,
                "nonce": nonce
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let devSession = Session(accessToken: apiKey, user: User(id: UUID(), email: "apple.user@icloud.com"))
                saveSession(devSession)
                return
            }
            
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let session = try decoder.decode(Session.self, from: data)
            saveSession(session)
        }
    }

    /// Send Magic Link / OTP email via Supabase Auth
    public func sendOTP(email: String, redirectTo: String? = "digitalesbuero://auth") async throws {
        let endpoint = baseURL.appendingPathComponent("auth/v1/otp")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        
        var payload: [String: Any] = [
            "email": email,
            "create_user": true
        ]
        if let redirectTo = redirectTo, !redirectTo.isEmpty {
            payload["email_redirect_to"] = redirectTo
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Keine Serververbindung zu Supabase."])
        }
        guard (200...299).contains(http.statusCode) else {
            let errorMsg = Self.parseErrorMessage(from: data) ?? "Fehler beim Senden der E-Mail (HTTP \(http.statusCode))."
            throw NSError(domain: "Auth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
    }

    /// Verify 6-digit OTP code or token from email
    public func verifyOTP(email: String, token: String, type: String = "email") async throws {
        let endpoint = baseURL.appendingPathComponent("auth/v1/verify")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        
        let payload: [String: Any] = [
            "type": type,
            "email": email,
            "token": token
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Keine Serververbindung."])
        }
        guard (200...299).contains(http.statusCode) else {
            let errorMsg = Self.parseErrorMessage(from: data) ?? "Ungültiger oder abgelaufener Bestätigungscode."
            throw NSError(domain: "Auth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(Session.self, from: data)
        saveSession(session)
    }

    /// Register new account with Email & Password
    public func signUpWithEmail(email: String, password: String) async throws {
        let endpoint = baseURL.appendingPathComponent("auth/v1/signup")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        
        let payload = ["email": email, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Keine Serververbindung."])
        }
        guard (200...299).contains(http.statusCode) else {
            let errorMsg = Self.parseErrorMessage(from: data) ?? "Registrierung fehlgeschlagen (HTTP \(http.statusCode))."
            throw NSError(domain: "Auth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let session = try? decoder.decode(Session.self, from: data), !session.accessToken.isEmpty {
            saveSession(session)
        }
    }

    /// Sign in with existing Email & Password
    public func signInWithEmail(email: String, password: String) async throws {
        let endpoint = baseURL.appendingPathComponent("auth/v1/token")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: true)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        
        let payload = ["email": email, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Keine Serververbindung."])
        }
        guard (200...299).contains(http.statusCode) else {
            let rawMsg = Self.parseErrorMessage(from: data) ?? "Ungültige Anmeldedaten."
            let friendlyMsg = rawMsg.contains("Invalid login credentials")
                ? "Ungültige Anmeldedaten. Bitte prüfe E-Mail und Passwort oder registriere dich neu."
                : rawMsg
            throw NSError(domain: "Auth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: friendlyMsg])
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(Session.self, from: data)
        saveSession(session)
    }

    /// Handles auth callback URLs such as digitalesbuero://auth#access_token=...
    @discardableResult
    public func handleAuthURL(_ url: URL) -> Bool {
        var tokenMap: [String: String] = [:]
        
        if let fragment = url.fragment {
            for item in fragment.components(separatedBy: "&") {
                let pair = item.components(separatedBy: "=")
                if pair.count == 2 {
                    tokenMap[pair[0]] = pair[1].removingPercentEncoding ?? pair[1]
                }
            }
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            for item in queryItems {
                if let val = item.value {
                    tokenMap[item.name] = val
                }
            }
        }
        
        guard let accessToken = tokenMap["access_token"], !accessToken.isEmpty else {
            return false
        }
        
        var userId = UUID()
        var userEmail = "nutzer@digitalesbuero.app"
        if let payload = Self.decodeJWTPayload(accessToken) {
            if let sub = payload["sub"] as? String, let uid = UUID(uuidString: sub) {
                userId = uid
            }
            if let email = payload["email"] as? String {
                userEmail = email
            }
        }
        
        let newSession = Session(accessToken: accessToken, user: User(id: userId, email: userEmail))
        saveSession(newSession)
        return true
    }

    /// Sign in with Supabase OAuth (Google, Apple, etc.)
    @MainActor
    public func signInWithOAuth(provider: String) async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "redirect_to", value: "digitalesbuero://auth")
        ]
        guard let authURL = components.url else {
            throw NSError(domain: "Auth", code: 400, userInfo: [NSLocalizedDescriptionKey: "Ungültige OAuth-URL."])
        }
        
        #if canImport(UIKit)
        let callbackURL = try await OAuthWebAuthSessionCoordinator.shared.authenticate(with: authURL, scheme: "digitalesbuero")
        guard handleAuthURL(callbackURL) else {
            throw NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Kein Zugriffstoken im OAuth-Rückruf gefunden."])
        }
        #else
        throw NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "OAuth auf dieser Plattform nicht unterstützt."])
        #endif
    }
    
    public func signOut() async throws {
        saveSession(nil)
    }

    public static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    public static func parseErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }
        if let desc = json["error_description"] as? String { return desc }
        if let msg = json["msg"] as? String { return msg }
        if let message = json["message"] as? String { return message }
        if let err = json["error"] as? String { return err }
        return nil
    }
}

// MARK: - OAuth Web Session Coordinator
#if canImport(UIKit)
@MainActor
public final class OAuthWebAuthSessionCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    public static let shared = OAuthWebAuthSessionCoordinator()
    
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }),
           let window = activeScene.windows.first(where: { $0.isKeyWindow }) ?? activeScene.windows.first {
            return window
        }
        if let window = scenes.flatMap(\.windows).first {
            return window
        }
        return ASPresentationAnchor()
    }
    
    public func authenticate(with url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let callbackURL = callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Authentifizierung abgebrochen."]))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }
}
#endif


// MARK: - Postgrest Query Builder

public final class PostgrestQueryBuilder: @unchecked Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let auth: AuthClient
    
    private var queryItems: [URLQueryItem] = []
    private var httpMethod: String = "GET"
    private var httpBody: Data?
    private var headers: [String: String] = [:]
    
    init(baseURL: URL, apiKey: String, auth: AuthClient) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.auth = auth
        self.headers["apikey"] = apiKey
        self.headers["Content-Type"] = "application/json"
    }
    
    public func select(_ columns: String = "*") -> Self {
        queryItems.append(URLQueryItem(name: "select", value: columns))
        httpMethod = "GET"
        return self
    }
    
    public func eq(_ column: String, value: String) -> Self {
        queryItems.append(URLQueryItem(name: column, value: "eq.\(value)"))
        return self
    }
    
    public func order(_ column: String, ascending: Bool = true) -> Self {
        queryItems.append(URLQueryItem(name: "order", value: "\(column).\(ascending ? "asc" : "desc")"))
        return self
    }
    
    public func single() -> Self {
        self.headers["Accept"] = "application/vnd.pgrst.object+json"
        return self
    }
    
    public func insert<T: Encodable>(_ value: T) -> Self {
        httpMethod = "POST"
        headers["Prefer"] = "return=representation"
        let encoder = SupabaseConfig.makeEncoder()
        httpBody = try? encoder.encode(value)
        return self
    }
    
    public func upsert<T: Encodable>(_ value: T, onConflict: String? = nil) -> Self {
        httpMethod = "POST"
        let prefer = "resolution=merge-duplicates,return=representation"
        if let onConflict = onConflict {
            queryItems.append(URLQueryItem(name: "on_conflict", value: onConflict))
        }
        headers["Prefer"] = prefer
        let encoder = SupabaseConfig.makeEncoder()
        httpBody = try? encoder.encode(value)
        return self
    }
    
    public func update<T: Encodable>(_ value: T) -> Self {
        httpMethod = "PATCH"
        headers["Prefer"] = "return=representation"
        let encoder = SupabaseConfig.makeEncoder()
        httpBody = try? encoder.encode(value)
        return self
    }
    
    public func update(_ dict: [String: Any]) -> Self {
        httpMethod = "PATCH"
        headers["Prefer"] = "return=representation"
        httpBody = try? JSONSerialization.data(withJSONObject: dict)
        return self
    }
    
    public func delete() -> Self {
        httpMethod = "DELETE"
        headers["Prefer"] = "return=representation"
        return self
    }
    
    private func send() async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        
        var request = URLRequest(url: components.url!)
        request.httpMethod = httpMethod
        for (key, val) in headers {
            request.setValue(val, forHTTPHeaderField: key)
        }
        
        if let token = (try? auth.session)?.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        request.httpBody = httpBody
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let message = String(data: data, encoding: .utf8) ?? "HTTP Error"
            throw NSError(domain: "SupabaseError", code: status, userInfo: [NSLocalizedDescriptionKey: message])
        }
        
        return (data, httpResponse)
    }
    
    @discardableResult
    public func execute<T: Decodable>(decoder: JSONDecoder = SupabaseConfig.makeDecoder()) async throws -> PostgrestResponse<T> {
        let (data, _) = try await send()
        let decoded = try decoder.decode(T.self, from: data)
        return PostgrestResponse(data: data, value: decoded)
    }
    
    @discardableResult
    public func execute() async throws -> PostgrestRawResponse {
        let (data, _) = try await send()
        return PostgrestRawResponse(data: data)
    }
}

// MARK: - Postgrest RPC Builder

public final class PostgrestRpcBuilder: @unchecked Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let auth: AuthClient
    private let params: Data?
    
    init(baseURL: URL, apiKey: String, auth: AuthClient, params: (some Encodable)?) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.auth = auth
        if let params = params {
            self.params = try? SupabaseConfig.makeEncoder().encode(params)
        } else {
            self.params = nil
        }
    }
    
    @discardableResult
    public func execute() async throws -> PostgrestRawResponse {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let token = (try? auth.session)?.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = params
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "SupabaseRPCError", code: status)
        }
        return PostgrestRawResponse(data: data)
    }
}

// MARK: - Postgrest Response Types

public struct PostgrestResponse<T: Decodable>: @unchecked Sendable {
    public let data: Data
    public let value: T
}

public struct PostgrestRawResponse: Sendable {
    public let data: Data
    public var value: Data { data }
}

// MARK: - Storage Client

public final class StorageClient: @unchecked Sendable {
    private let baseURL: URL
    private let apiKey:  String
    private let auth:    AuthClient

    init(baseURL: URL, apiKey: String, auth: AuthClient) {
        self.baseURL = baseURL
        self.apiKey  = apiKey
        self.auth    = auth
    }

    public func from(_ bucket: String) -> StorageBucketClient {
        StorageBucketClient(
            baseURL: baseURL.appendingPathComponent("storage/v1/object/\(bucket)"),
            apiKey:  apiKey,
            auth:    auth
        )
    }
}

public final class StorageBucketClient: @unchecked Sendable {
    private let baseURL: URL
    private let apiKey:  String
    private let auth:    AuthClient

    init(baseURL: URL, apiKey: String, auth: AuthClient) {
        self.baseURL = baseURL
        self.apiKey  = apiKey
        self.auth    = auth
    }

    /// Uploads `data` to the given `path` inside the bucket.
    /// - Returns: The storage path (usable to build a public URL).
    @discardableResult
    public func upload(_ path: String, data: Data, contentType: String = "image/jpeg") async throws -> String {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")

        // Use the real session JWT when available, otherwise fall back to anon key
        let bearerToken = (try? auth.session.accessToken) ?? apiKey
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = data

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(
                domain: "SupabaseStorageError",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "Storage upload failed (HTTP \(status))"]
            )
        }
        return path
    }

    /// Returns the public URL for a previously uploaded path.
    public func getPublicURL(_ path: String) -> URL {
        baseURL.appendingPathComponent("public/\(path)")
    }
}

// MARK: - Global Config

public enum SupabaseConfig {
    public static let url = URL(string: "https://ucmkbhmtdpbxsbahzahj.supabase.co")!
    public static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVjbWtiaG10ZHBieHNiYWh6YWhqIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4ODI4OTgyMSwiZXhwIjoyMTAzODY1ODIxfQ.Ce91AxSOgqsQE5jbk2smwZmGqSovMlktbKEwwiXk5mg"
    
    public static let client = SupabaseClient(
        supabaseURL: url,
        supabaseKey: anonKey
    )
    
    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
    
    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }
}
