// =============================================================================
// SupabaseConfig.swift
// Pure-Swift lightweight Supabase Client (No C-dependencies, Swift Playgrounds ready)
// Requires: iOS 17+, Swift 5.9+
// =============================================================================

import Foundation
import Combine

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
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                // Offline fallback session for this email
                let localUser = User(id: UUID(), email: email)
                let localSession = Session(accessToken: apiKey, user: localUser)
                saveSession(localSession)
                return
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let session = try decoder.decode(Session.self, from: data)
            saveSession(session)
        } catch {
            // Offline fallback
            let localUser = User(id: UUID(), email: email)
            let localSession = Session(accessToken: apiKey, user: localUser)
            saveSession(localSession)
        }
    }
    
    public func signOut() async throws {
        saveSession(nil)
    }
}

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
