// GeminiService.swift
// Digitales Büro — KI-Dienst (Gemini 2.0 Flash, Streaming)

import Foundation
import SwiftUI

// MARK: - Models

enum ChatRole: String, Codable {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var role: ChatRole
    var content: String
    var isStreaming: Bool = false
    var isCodeChange: Bool = false
    var commitSHA: String? = nil
    var actionsUrl: String? = nil
    var attachedImageData: Data? = nil
    var attachedFileName: String? = nil
    let timestamp: Date

    init(
        role: ChatRole,
        content: String = "",
        isCodeChange: Bool = false,
        attachedImageData: Data? = nil,
        attachedFileName: String? = nil
    ) {
        self.role = role
        self.content = content
        self.isCodeChange = isCodeChange
        self.attachedImageData = attachedImageData
        self.attachedFileName = attachedFileName
        self.timestamp = Date()
    }
}

struct CodeChangeResponse: Codable {
    var text: String
    var commitSHA: String?
    var actionsUrl: String?
}

// MARK: - Errors

enum GeminiError: LocalizedError {
    case missingAPIKey
    case networkError(String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Kein Gemini API Key hinterlegt. Bitte in Admin-Einstellungen eingeben."
        case .networkError(let msg):
            return "Netzwerkfehler: \(msg)"
        case .parseError:
            return "Antwort konnte nicht verarbeitet werden."
        }
    }
}

// MARK: - GeminiService

@MainActor
final class GeminiService: ObservableObject {
    @Published var isStreaming: Bool = false

    var apiKey: String {
        UserDefaults.standard.string(forKey: "gemini_api_key") ?? ""
    }

    /// Streams a Gemini response chunk by chunk with automatic model fallback
    func streamResponse(
        prompt: String,
        systemContext: String,
        history: [ChatMessage],
        imageData: Data? = nil,
        imageMimeType: String = "image/jpeg"
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let cleanKey = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanKey.isEmpty else {
                    AppLogger.shared.error("KI-Chat", "Kein Gemini API-Key hinterlegt.")
                    continuation.finish(throwing: GeminiError.missingAPIKey)
                    return
                }

                // Model fallback chain:
                // Google explicitly requires 'gemini-3.6-flash' as of recent updates
                var candidateModels = [
                    "gemini-3.6-flash",
                    "gemini-3.6-pro",
                    "gemini-2.5-flash",
                    "gemini-2.5-pro",
                    "gemini-flash-latest",
                    "gemini-pro-latest",
                    "gemini-2.0-flash",
                    "gemini-1.5-flash"
                ]

                // If a previously working model was saved, test it first
                if let lastWorking = UserDefaults.standard.string(forKey: "last_working_gemini_model"),
                   !lastWorking.isEmpty {
                    candidateModels.removeAll { $0 == lastWorking }
                    candidateModels.insert(lastWorking, at: 0)
                }

                var lastErrorDescription = "HTTP 404 (Modell nicht gefunden)"

                // 1. Try hardcoded / cached candidates
                for (idx, model) in candidateModels.enumerated() {
                    do {
                        AppLogger.shared.info("KI-Chat", "Sende Anfrage an Modell '\(model)' (Versuch \(idx + 1)/\(candidateModels.count))...")
                        let success = try await self.executeStream(
                            model: model,
                            apiKey: cleanKey,
                            prompt: prompt,
                            systemContext: systemContext,
                            history: history,
                            imageData: imageData,
                            imageMimeType: imageMimeType,
                            continuation: continuation
                        )
                        if success {
                            UserDefaults.standard.set(model, forKey: "last_working_gemini_model")
                            AppLogger.shared.success("KI-Chat", "Gemini-Stream erfolgreich empfangen über '\(model)'.")
                            continuation.finish()
                            return
                        }
                    } catch let err as GeminiError {
                        lastErrorDescription = err.localizedDescription
                        AppLogger.shared.warn("KI-Chat", "Modell '\(model)' fehlgeschlagen: \(err.localizedDescription). Prüfe nächstes Modell...")
                        continue
                    } catch {
                        lastErrorDescription = error.localizedDescription
                        AppLogger.shared.warn("KI-Chat", "Fehler bei '\(model)': \(error.localizedDescription)")
                        continue
                    }
                }

                // 2. Dynamic discovery via ListModels API if static candidates failed
                AppLogger.shared.info("KI-Chat", "Frage verfügbare Modelle via Google Model-API ab...")
                let dynamicModels = await self.fetchAvailableModels(apiKey: cleanKey)
                for dynModel in dynamicModels {
                    guard !candidateModels.contains(dynModel) else { continue }
                    do {
                        AppLogger.shared.info("KI-Chat", "Teste dynamisch erkanntes Modell '\(dynModel)'...")
                        let success = try await self.executeStream(
                            model: dynModel,
                            apiKey: cleanKey,
                            prompt: prompt,
                            systemContext: systemContext,
                            history: history,
                            imageData: imageData,
                            imageMimeType: imageMimeType,
                            continuation: continuation
                        )
                        if success {
                            UserDefaults.standard.set(dynModel, forKey: "last_working_gemini_model")
                            AppLogger.shared.success("KI-Chat", "Gemini-Stream erfolgreich empfangen über '\(dynModel)'.")
                            continuation.finish()
                            return
                        }
                    } catch {
                        lastErrorDescription = error.localizedDescription
                        continue
                    }
                }

                AppLogger.shared.error("KI-Chat", "Alle Modelle fehlgeschlagen: \(lastErrorDescription)")
                continuation.finish(throwing: GeminiError.networkError(lastErrorDescription))
            }
        }
    }

    /// Fragt die Liste der aktuell für den API-Key freigeschalteten Modelle ab
    private func fetchAvailableModels(apiKey: String) async -> [String] {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)") else { return [] }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return [] }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelList = json["models"] as? [[String: Any]] else { return [] }

            var suitable: [String] = []
            for item in modelList {
                guard let name = item["name"] as? String else { continue }
                let supportedMethods = (item["supportedGenerationMethods"] as? [String]) ?? []
                if supportedMethods.contains("generateContent") {
                    let cleanName = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
                    if cleanName.contains("flash") {
                        suitable.insert(cleanName, at: 0)
                    } else {
                        suitable.append(cleanName)
                    }
                }
            }
            AppLogger.shared.info("KI-Chat", "Dynamisch gefundene Modelle: \(suitable.joined(separator: ", "))")
            return suitable
        } catch {
            AppLogger.shared.warn("KI-Chat", "Modell-Abfrage fehlgeschlagen: \(error.localizedDescription)")
            return []
        }
    }

    private func executeStream(
        model: String,
        apiKey: String,
        prompt: String,
        systemContext: String,
        history: [ChatMessage],
        imageData: Data?,
        imageMimeType: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> Bool {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw GeminiError.networkError("Ungültige URL für \(model)")
        }

        var contents: [[String: Any]] = history.filter { !$0.isStreaming && !$0.content.isEmpty }.map { msg in
            var parts: [[String: Any]] = [["text": msg.content]]
            if let imgData = msg.attachedImageData {
                let mime = (msg.attachedFileName?.hasSuffix(".pdf") == true) ? "application/pdf" : "image/jpeg"
                parts.append([
                    "inline_data": [
                        "mime_type": mime,
                        "data": imgData.base64EncodedString()
                    ]
                ])
            }
            return ["role": msg.role == .user ? "user" : "model", "parts": parts]
        }

        var currentParts: [[String: Any]] = [["text": prompt.isEmpty ? "Bitte analysiere dieses Dokument/Bild." : prompt]]
        if let imgData = imageData {
            currentParts.append([
                "inline_data": [
                    "mime_type": imageMimeType,
                    "data": imgData.base64EncodedString()
                ]
            ])
        }
        contents.append(["role": "user", "parts": currentParts])

        let body: [String: Any] = [
            "contents": contents,
            "systemInstruction": ["parts": [["text": systemContext]]],
            "generationConfig": ["temperature": 0.7, "maxOutputTokens": 4096]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard statusCode == 200 else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 300 { break }
            }

            if let data = errorBody.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errObj = json["error"] as? [String: Any],
               let msg = errObj["message"] as? String {
                throw GeminiError.networkError("HTTP \(statusCode) – \(msg)")
            }

            throw GeminiError.networkError("HTTP \(statusCode)")
        }

        var hasYielded = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }
            if let data = jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let candidates = json["candidates"] as? [[String: Any]],
               let content = candidates.first?["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let text = parts.first?["text"] as? String {
                continuation.yield(text)
                hasYielded = true
            }
        }
        return hasYielded
    }

    /// Sends a code-change request: first tries the Edge Function (if configured and responding),
    /// and seamlessly falls back to direct Gemini 3.6 generation + native GitHub commit.
    func sendCodeChangeRequest(prompt: String, agentURL: String) async throws -> CodeChangeResponse {
        let repo = UserDefaults.standard.string(forKey: "github_repo") ?? "DevDealer05/DokuSys"
        let token = UserDefaults.standard.string(forKey: "github_token")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // 1. Optional: Try Supabase Edge Function if URL is configured and valid
        if let url = URL(string: agentURL), !agentURL.isEmpty, !agentURL.contains("example") {
            let body: [String: Any] = ["prompt": prompt, "repo": repo]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 8

            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let result = try? JSONDecoder().decode(CodeChangeResponse.self, from: data) {
                return result
            }
        }

        // 2. Native Direct Agent: Gemini 3.6 Flash + Direct GitHub API Commit
        AppLogger.shared.info("KI-Agent", "Führe Code-Änderung direkt nativ über Gemini & GitHub API aus...")
        return try await directCodeChangeRequest(prompt: prompt, repo: repo, token: token)
    }

    /// Führt die Code-Generierung direkt über Gemini 3.6 Flash aus und committet bei Bedarf via GitHub REST API
    private func directCodeChangeRequest(prompt: String, repo: String, token: String) async throws -> CodeChangeResponse {
        let apiKey = UserDefaults.standard.string(forKey: "gemini_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            throw GeminiError.missingAPIKey
        }

        let systemContext = """
        Du bist ein erfahrener iOS Swift-Entwickler für die App "Digitales Büro" (SwiftUI iOS 17+, Repo: \(repo)).
        Wenn der Nutzer Code-Änderungen anfordert:
        1. Erkläre kurz und präzise auf Deutsch, was du änderst.
        2. Gib am Ende ZWINGEND einen JSON-Block in folgendem Format an:
        CODE_CHANGES_JSON:[{"file":"Dateiname.swift","content":"kompletter neuer Dateiinhalt"}]
        Wenn keine Code-Änderung erforderlich ist, antworte einfach mit einer hilfreichen Erklärung auf Deutsch.
        """

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw GeminiError.networkError("Ungültige Gemini-URL")
        }

        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "systemInstruction": ["parts": [["text": systemContext]]],
            "generationConfig": ["temperature": 0.3, "maxOutputTokens": 8192]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw GeminiError.networkError("Gemini API HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let fullText = parts.first?["text"] as? String else {
            throw GeminiError.parseError
        }

        // Parse CODE_CHANGES_JSON marker
        let marker = "CODE_CHANGES_JSON:"
        var displayText = fullText
        var commitSHA: String? = nil

        if let markerRange = fullText.range(of: marker) {
            displayText = String(fullText[..<markerRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let jsonString = String(fullText[markerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            if !token.isEmpty,
               let jsonData = jsonString.data(using: .utf8),
               let changes = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                do {
                    commitSHA = try await commitFilesToGitHub(repo: repo, token: token, changes: changes, message: prompt)
                    AppLogger.shared.success("KI-Agent", "Code erfolgreich zu GitHub committed: \(commitSHA ?? "")")
                } catch {
                    AppLogger.shared.warn("KI-Agent", "GitHub Commit fehlgeschlagen: \(error.localizedDescription)")
                    displayText += "\n\n*(Code wurde generiert, aber GitHub-Commit konnte nicht übertragen werden: \(error.localizedDescription))*"
                }
            }
        }

        return CodeChangeResponse(
            text: displayText,
            commitSHA: commitSHA,
            actionsUrl: commitSHA != nil ? "https://github.com/\(repo)/actions" : nil
        )
    }

    /// Führt die 5 Git-Schritte zum Committen auf GitHub aus
    private func commitFilesToGitHub(repo: String, token: String, changes: [[String: Any]], message: String) async throws -> String {
        let baseURL = "https://api.github.com/repos/\(repo)"

        // 1. Get HEAD of main branch
        let refData = try await ghJSONRequest(url: "\(baseURL)/git/ref/heads/main", method: "GET", token: token)
        guard let object = refData["object"] as? [String: Any],
              let baseSHA = object["sha"] as? String else {
            throw GeminiError.networkError("Konnte Haupt-Branch SHA nicht abrufen")
        }

        // 2. Create blobs
        var treeItems: [[String: Any]] = []
        for change in changes {
            guard let file = change["file"] as? String,
                  let content = change["content"] as? String else { continue }

            let blobBody: [String: Any] = ["content": content, "encoding": "utf-8"]
            let blobData = try await ghJSONRequest(url: "\(baseURL)/git/blobs", method: "POST", token: token, body: blobBody)
            guard let blobSHA = blobData["sha"] as? String else { continue }

            treeItems.append([
                "path": file,
                "mode": "100644",
                "type": "blob",
                "sha": blobSHA
            ])
        }

        guard !treeItems.isEmpty else {
            throw GeminiError.networkError("Keine Dateien zum Committen gefunden")
        }

        // 3. Create tree
        let treeBody: [String: Any] = ["base_tree": baseSHA, "tree": treeItems]
        let treeData = try await ghJSONRequest(url: "\(baseURL)/git/trees", method: "POST", token: token, body: treeBody)
        guard let treeSHA = treeData["sha"] as? String else {
            throw GeminiError.networkError("Konnte Git-Tree nicht erstellen")
        }

        // 4. Create commit
        let commitBody: [String: Any] = [
            "message": "KI-Agent: \(String(message.prefix(70)))",
            "tree": treeSHA,
            "parents": [baseSHA]
        ]
        let commitData = try await ghJSONRequest(url: "\(baseURL)/git/commits", method: "POST", token: token, body: commitBody)
        guard let commitSHA = commitData["sha"] as? String else {
            throw GeminiError.networkError("Konnte Git-Commit nicht erstellen")
        }

        // 5. Update ref main
        let patchBody: [String: Any] = ["sha": commitSHA]
        _ = try await ghJSONRequest(url: "\(baseURL)/git/refs/heads/main", method: "PATCH", token: token, body: patchBody)

        return commitSHA
    }

    private func ghJSONRequest(url: String, method: String, token: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let reqURL = URL(string: url) else { throw GeminiError.networkError("Ungültige URL: \(url)") }
        var req = URLRequest(url: reqURL)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body = body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw GeminiError.networkError("GitHub API HTTP \(status)")
        }

        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
