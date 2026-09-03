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
    let timestamp: Date

    init(role: ChatRole, content: String = "", isCodeChange: Bool = false) {
        self.role = role
        self.content = content
        self.isCodeChange = isCodeChange
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

    /// Streams a Gemini response chunk by chunk
    func streamResponse(
        prompt: String,
        systemContext: String,
        history: [ChatMessage]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard !self.apiKey.isEmpty else {
                    continuation.finish(throwing: GeminiError.missingAPIKey)
                    return
                }

                let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:streamGenerateContent?alt=sse&key=\(self.apiKey)"
                guard let url = URL(string: urlString) else {
                    continuation.finish(throwing: GeminiError.networkError("Ungültige URL"))
                    return
                }

                var contents: [[String: Any]] = history.filter { !$0.isStreaming && !$0.content.isEmpty }.map { msg in
                    ["role": msg.role == .user ? "user" : "model",
                     "parts": [["text": msg.content]]]
                }
                contents.append(["role": "user", "parts": [["text": prompt]]])

                let body: [String: Any] = [
                    "contents": contents,
                    "systemInstruction": ["parts": [["text": systemContext]]],
                    "generationConfig": ["temperature": 0.7, "maxOutputTokens": 4096]
                ]

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard statusCode == 200 else {
                        continuation.finish(throwing: GeminiError.networkError("HTTP \(statusCode)"))
                        return
                    }

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
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: GeminiError.networkError(error.localizedDescription))
                }
            }
        }
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
