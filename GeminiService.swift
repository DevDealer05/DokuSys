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

    /// Sends a code-change request to the Supabase Edge Function
    func sendCodeChangeRequest(prompt: String, agentURL: String) async throws -> CodeChangeResponse {
        guard let url = URL(string: agentURL) else {
            throw GeminiError.networkError("Ungültige Agent-URL: \(agentURL)")
        }

        let body: [String: Any] = ["prompt": prompt, "repo": "DevDealer05/DokuSys"]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw GeminiError.networkError("Agent HTTP \(status)")
        }
        guard let result = try? JSONDecoder().decode(CodeChangeResponse.self, from: data) else {
            throw GeminiError.parseError
        }
        return result
    }
}
