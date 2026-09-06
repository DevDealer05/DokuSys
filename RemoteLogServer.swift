// =============================================================================
// RemoteLogServer.swift
// Digitales Büro — Lokaler WLAN-Diagnose- & HTTP-Log-Server
// Pure-Swift NWListener Server (Network.framework, iOS 17+, Swift 5.9+)
// =============================================================================

import Foundation
import Network
import Combine

// =============================================================================
// MARK: - RemoteLogServer
// =============================================================================

final class RemoteLogServer: ObservableObject {
    static let shared = RemoteLogServer()

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var localIP: String? = nil
    @Published private(set) var port: UInt16 = 8080
    @Published private(set) var lastRequestTimestamp: Date? = nil
    @Published private(set) var requestCount: Int = 0

    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "de.kim.DigitalesBuero.logserver", qos: .userInitiated)

    var serverURL: String? {
        guard let ip = localIP, isRunning else { return nil }
        return "http://\(ip):\(port)"
    }

    private init() {
        self.localIP = Self.resolveLocalWiFiIP()
    }

    // ── Server Lifecycle ──────────────────────────────────────────────

    func start(onPort targetPort: UInt16 = 8080) {
        guard !isRunning else { return }
        self.port = targetPort
        self.localIP = Self.resolveLocalWiFiIP()

        do {
            let parameters = NWParameters.tcp
            guard let nwPort = NWEndpoint.Port(rawValue: targetPort) else {
                AppLogger.shared.error("Diagnose-Server", "Ungültiger Port: \(targetPort)")
                return
            }

            let newListener = try NWListener(using: parameters, on: nwPort)

            // Bonjour Advertisement für automatische Mac-Erkennung
            newListener.service = NWListener.Service(
                name: "DigitalesBuero-Diagnostic",
                type: "_db-logs._tcp"
            )

            newListener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        let ipStr = self?.localIP ?? "127.0.0.1"
                        AppLogger.shared.success("Diagnose-Server", "WLAN-Server läuft auf http://\(ipStr):\(targetPort)")
                    case .failed(let error):
                        self?.isRunning = false
                        AppLogger.shared.error("Diagnose-Server", "Server-Fehler: \(error.localizedDescription)")
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection)
            }

            newListener.start(queue: serverQueue)
            self.listener = newListener

        } catch {
            AppLogger.shared.error("Diagnose-Server", "Konnte Server nicht starten: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
            AppLogger.shared.info("Diagnose-Server", "WLAN-Server gestoppt.")
        }
    }

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    // ── Connection & HTTP Handling ────────────────────────────────────

    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: serverQueue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self else {
                connection.cancel()
                return
            }

            if let error = error {
                print("RemoteLogServer receive error: \(error)")
                connection.cancel()
                return
            }

            guard let data = data, let requestString = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            DispatchQueue.main.async {
                self.requestCount += 1
                self.lastRequestTimestamp = Date()
            }

            let responseData = self.processHTTPRequest(requestString)

            connection.send(content: responseData, completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        }
    }

    private func processHTTPRequest(_ requestString: String) -> Data {
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return makeHTTPResponse(statusCode: 400, statusText: "Bad Request", contentType: "text/plain", body: "Bad Request")
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            return makeHTTPResponse(statusCode: 400, statusText: "Bad Request", contentType: "text/plain", body: "Malformed Request Line")
        }

        let method = parts[0].uppercased()
        let rawPath = parts[1]
        let path = rawPath.components(separatedBy: "?").first ?? "/"

        switch (method, path) {
        case ("GET", "/logs/text"):
            let logText = AppLogger.shared.exportLogText()
            return makeHTTPResponse(statusCode: 200, statusText: "OK", contentType: "text/plain; charset=utf-8", body: logText)

        case ("GET", "/logs"):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let jsonData = try? encoder.encode(AppLogger.shared.entries),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return makeHTTPResponse(statusCode: 200, statusText: "OK", contentType: "application/json; charset=utf-8", body: jsonString)
            } else {
                return makeHTTPResponse(statusCode: 500, statusText: "Internal Error", contentType: "application/json", body: "{\"error\":\"Serialization failed\"}")
            }

        case ("GET", "/status"):
            let info = BuildInfo.current
            let statusDict: [String: Any] = [
                "appName": "Digitales Büro",
                "version": info.version,
                "build": info.buildNumber,
                "commit": info.commitSHA,
                "buildDate": info.buildDate,
                "totalLogs": AppLogger.shared.entries.count,
                "errorCount": AppLogger.shared.errorCount,
                "warningCount": AppLogger.shared.warningCount,
                "serverUptimeTimestamp": Date().formatted(date: .numeric, time: .standard)
            ]
            if let data = try? JSONSerialization.data(withJSONObject: statusDict, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                return makeHTTPResponse(statusCode: 200, statusText: "OK", contentType: "application/json; charset=utf-8", body: str)
            }
            return makeHTTPResponse(statusCode: 200, statusText: "OK", contentType: "text/plain", body: "OK")

        case ("POST", "/clear"):
            AppLogger.shared.clear()
            return makeHTTPResponse(statusCode: 200, statusText: "OK", contentType: "application/json", body: "{\"cleared\":true}")

        case ("GET", "/"):
            let html = generateDashboardHTML()
            return makeHTTPResponse(statusCode: 200, statusText: "OK", contentType: "text/html; charset=utf-8", body: html)

        default:
            return makeHTTPResponse(statusCode: 404, statusText: "Not Found", contentType: "text/plain", body: "Not Found: \(path)")
        }
    }

    private func makeHTTPResponse(statusCode: Int, statusText: String, contentType: String, body: String) -> Data {
        let bodyData = body.data(using: .utf8) ?? Data()
        let header = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Content-Type: \(contentType)\r
        Content-Length: \(bodyData.count)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Connection: close\r
        \r\n
        """
        var data = header.data(using: .utf8) ?? Data()
        data.append(bodyData)
        return data
    }

    // ── HTML Web Terminal ─────────────────────────────────────────────

    private func generateDashboardHTML() -> String {
        let info = BuildInfo.current
        let logText = AppLogger.shared.exportLogText()
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        return """
        <!DOCTYPE html>
        <html lang="de">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>Digitales Büro — Live-Konsole</title>
          <style>
            :root {
              --bg: #090A10;
              --card: #121420;
              --border: #232738;
              --primary: #6E5BE8;
              --text: #F3F4F6;
              --muted: #9CA3AF;
              --red: #EF4444;
              --orange: #F59E0B;
              --green: #10B981;
            }
            body {
              background: var(--bg);
              color: var(--text);
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace;
              margin: 0;
              padding: 24px;
            }
            .header {
              display: flex;
              justify-content: space-between;
              align-items: center;
              padding-bottom: 16px;
              border-bottom: 1px solid var(--border);
            }
            .title { font-size: 20px; font-weight: 700; color: var(--primary); }
            .badge {
              display: inline-block;
              padding: 4px 10px;
              border-radius: 999px;
              font-size: 12px;
              font-weight: 700;
              background: rgba(110, 91, 232, 0.2);
              color: var(--primary);
            }
            .kpis {
              display: flex;
              gap: 16px;
              margin: 20px 0;
            }
            .kpi {
              background: var(--card);
              border: 1px solid var(--border);
              border-radius: 12px;
              padding: 14px 18px;
              flex: 1;
            }
            .kpi-label { font-size: 11px; color: var(--muted); text-transform: uppercase; }
            .kpi-val { font-size: 22px; font-weight: 700; margin-top: 4px; }
            .actions {
              display: flex;
              gap: 10px;
              margin-bottom: 16px;
            }
            button, a.btn {
              background: var(--primary);
              color: white;
              padding: 8px 14px;
              border-radius: 8px;
              text-decoration: none;
              font-size: 13px;
              font-weight: 600;
              border: none;
              cursor: pointer;
            }
            a.btn-secondary {
              background: var(--card);
              border: 1px solid var(--border);
              color: var(--text);
            }
            pre {
              background: var(--card);
              border: 1px solid var(--border);
              border-radius: 12px;
              padding: 16px;
              font-size: 13px;
              line-height: 1.5;
              overflow-x: auto;
              white-space: pre-wrap;
              color: #A7F3D0;
              max-height: 70vh;
              overflow-y: auto;
            }
          </style>
        </head>
        <body>
          <div class="header">
            <div class="title">⚡ Digitales Büro — Remote Live-Konsole</div>
            <div class="badge">v\(info.version) (Build \(info.buildNumber))</div>
          </div>
          <div class="kpis">
            <div class="kpi">
              <div class="kpi-label">Gesamt-Logs</div>
              <div class="kpi-val">\(AppLogger.shared.entries.count)</div>
            </div>
            <div class="kpi">
              <div class="kpi-label">Fehler</div>
              <div class="kpi-val" style="color: var(--red);">\(AppLogger.shared.errorCount)</div>
            </div>
            <div class="kpi">
              <div class="kpi-label">Warnungen</div>
              <div class="kpi-val" style="color: var(--orange);">\(AppLogger.shared.warningCount)</div>
            </div>
          </div>
          <div class="actions">
            <a class="btn" href="javascript:location.reload()">🔄 Neu laden</a>
            <a class="btn btn-secondary" href="/logs/text" target="_blank">📄 Text-Log (curl)</a>
            <a class="btn btn-secondary" href="/logs" target="_blank">📦 JSON-Log</a>
            <a class="btn btn-secondary" href="/status" target="_blank">ℹ️ Status</a>
          </div>
          <pre id="logStream">\(logText.isEmpty ? "Keine Logs vorhanden." : logText)</pre>
        </body>
        </html>
        """
    }

    // ── Local IP Resolution ───────────────────────────────────────────

    static func resolveLocalWiFiIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" { // Standard Wi-Fi interface on iOS
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        socklen_t(0),
                        NI_NUMERICHOST
                    )
                    address = String(cString: hostname)
                    break
                }
            }
        }
        return address
    }
}
