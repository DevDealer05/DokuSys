// =============================================================================
// WorkTimeTrackerModule.swift
// Digitales Büro – Smarte, standortbasierte Arbeitszeiterfassung (ADHS-optimiert)
// Requires: iOS 17+, Swift 5.9+, CoreLocation, UserNotifications, UIKit, PDFKit
// =============================================================================

import SwiftUI
import CoreLocation
import UserNotifications
import UIKit
import PDFKit

// =============================================================================
// MARK: - 1. Datenmodelle
// =============================================================================

public struct WorkShift: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var startTime: Date
    public var endTime: Date?
    public var breakMinutes: Int
    public var workplaceName: String
    public var hourlyRate: Decimal?
    public var notes: String?
    public var isAutoGeofenced: Bool

    public init(
        id: UUID = UUID(),
        startTime: Date = Date(),
        endTime: Date? = nil,
        breakMinutes: Int = 0,
        workplaceName: String = "Arbeitsplatz",
        hourlyRate: Decimal? = nil,
        notes: String? = nil,
        isAutoGeofenced: Bool = false
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.breakMinutes = breakMinutes
        self.workplaceName = workplaceName
        self.hourlyRate = hourlyRate
        self.notes = notes
        self.isAutoGeofenced = isAutoGeofenced
    }

    public var durationSeconds: TimeInterval {
        let end = endTime ?? Date()
        let raw = max(0, end.timeIntervalSince(startTime) - TimeInterval(breakMinutes * 60))
        return raw
    }

    public var netWorkingHours: Double {
        return durationSeconds / 3600.0
    }

    public var formattedDuration: String {
        let totalSecs = Int(durationSeconds)
        let hours = totalSecs / 3600
        let minutes = (totalSecs % 3600) / 60
        return String(format: "%dh %02dm", hours, minutes)
    }

    public var estimatedEarnings: Decimal? {
        guard let rate = hourlyRate else { return nil }
        return Decimal(netWorkingHours) * rate
    }
}

public struct WorkplaceLocation: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var radiusMeters: Double
    public var autoPromptOnEntry: Bool
    public var autoPromptOnExit: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = 150.0,
        autoPromptOnEntry: Bool = true,
        autoPromptOnExit: Bool = true
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.autoPromptOnEntry = autoPromptOnEntry
        self.autoPromptOnExit = autoPromptOnExit
    }
}

public struct PlannedShift: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var date: Date
    public var startTimeString: String
    public var endTimeString: String
    public var roleOrNote: String?
    public var isCompleted: Bool

    public init(
        id: UUID = UUID(),
        date: Date,
        startTimeString: String,
        endTimeString: String,
        roleOrNote: String? = nil,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.date = date
        self.startTimeString = startTimeString
        self.endTimeString = endTimeString
        self.roleOrNote = roleOrNote
        self.isCompleted = isCompleted
    }
}

// =============================================================================
// MARK: - 2. WorkTimeService (CoreLocation & Geofencing)
// =============================================================================

@MainActor
public final class WorkTimeService: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published public var activeShift: WorkShift? = nil
    @Published public var savedWorkplaces: [WorkplaceLocation] = []
    @Published public var shiftHistory: [WorkShift] = []
    @Published public var plannedShifts: [PlannedShift] = []
    @Published public var isPaused: Bool = false
    @Published public var currentPauseStart: Date? = nil
    @Published public var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined

    // Einstellungen via UserDefaults
    @AppStorage("worktime_break_reminder_minutes") public var breakReminderMinutes: Int = 150 // 2.5 Std
    @AppStorage("worktime_daily_target_hours") public var dailyTargetHours: Double = 8.0
    @AppStorage("worktime_default_hourly_rate") public var defaultHourlyRateString: String = ""

    private let locationManager = CLLocationManager()
    private let activeShiftKey = "app_active_work_shift"
    private let workplacesKey = "app_saved_workplaces"
    private let historyKey = "app_work_shift_history"
    private let plannedShiftsKey = "app_planned_shifts"

    public override init() {
        super.init()
        self.locationManager.delegate = self
        self.locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        self.locationAuthorizationStatus = locationManager.authorizationStatus
        loadPersistedData()
        setupNotificationCategories()
    }

    // ── Persistenz ───────────────────────────────────────────────────────

    private func loadPersistedData() {
        if let data = UserDefaults.standard.data(forKey: activeShiftKey),
           let shift = try? JSONDecoder().decode(WorkShift.self, from: data) {
            self.activeShift = shift
        }

        if let data = UserDefaults.standard.data(forKey: workplacesKey),
           let places = try? JSONDecoder().decode([WorkplaceLocation].self, from: data) {
            self.savedWorkplaces = places
        }

        if let data = UserDefaults.standard.data(forKey: historyKey),
           let history = try? JSONDecoder().decode([WorkShift].self, from: data) {
            self.shiftHistory = history
        }

        if let data = UserDefaults.standard.data(forKey: plannedShiftsKey),
           let planned = try? JSONDecoder().decode([PlannedShift].self, from: data) {
            self.plannedShifts = planned
        }
    }

    private func saveActiveShift() {
        if let shift = activeShift, let data = try? JSONEncoder().encode(shift) {
            UserDefaults.standard.set(data, forKey: activeShiftKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeShiftKey)
        }
    }

    private func saveWorkplaces() {
        if let data = try? JSONEncoder().encode(savedWorkplaces) {
            UserDefaults.standard.set(data, forKey: workplacesKey)
        }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(shiftHistory) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private func savePlannedShifts() {
        if let data = try? JSONEncoder().encode(plannedShifts) {
            UserDefaults.standard.set(data, forKey: plannedShiftsKey)
        }
    }

    // ── Schicht-Steuerung ────────────────────────────────────────────────

    public func startShift(workplaceName: String = "Arbeitsplatz", hourlyRate: Decimal? = nil, isAuto: Bool = false) {
        guard activeShift == nil else { return }

        let rate = hourlyRate ?? Decimal(string: defaultHourlyRateString.replacingOccurrences(of: ",", with: "."))
        let newShift = WorkShift(
            startTime: Date(),
            workplaceName: workplaceName,
            hourlyRate: rate,
            isAutoGeofenced: isAuto
        )

        withAnimation(.spring(response: 0.35)) {
            self.activeShift = newShift
            self.isPaused = false
            self.currentPauseStart = nil
        }
        saveActiveShift()
        scheduleBreakReminderNotification()

        AppLogger.shared.info("Zeiterfassung", "Schicht gestartet bei '\(workplaceName)'.")
    }

    public func pauseShift() {
        guard activeShift != nil, !isPaused else { return }
        withAnimation {
            isPaused = true
            currentPauseStart = Date()
        }
    }

    public func resumeShift() {
        guard activeShift != nil, isPaused, let pauseStart = currentPauseStart else { return }
        let elapsedPauseMinutes = Int(Date().timeIntervalSince(pauseStart) / 60)
        withAnimation {
            activeShift?.breakMinutes += max(1, elapsedPauseMinutes)
            isPaused = false
            currentPauseStart = nil
        }
        saveActiveShift()
    }

    public func endShift(notes: String? = nil) {
        guard var shift = activeShift else { return }

        if isPaused, let pauseStart = currentPauseStart {
            let elapsedPauseMinutes = Int(Date().timeIntervalSince(pauseStart) / 60)
            shift.breakMinutes += max(1, elapsedPauseMinutes)
        }

        shift.endTime = Date()
        if let n = notes, !n.isEmpty {
            shift.notes = n
        }

        withAnimation(.spring(response: 0.35)) {
            shiftHistory.insert(shift, at: 0)
            activeShift = nil
            isPaused = false
            currentPauseStart = nil
        }

        saveActiveShift()
        saveHistory()
        cancelBreakReminderNotification()

        AppLogger.shared.info("Zeiterfassung", "Schicht beendet: Dauer \(shift.formattedDuration).")
    }

    public func deleteShift(_ id: UUID) {
        withAnimation {
            shiftHistory.removeAll(where: { $0.id == id })
        }
        saveHistory()
    }

    // ── Geofencing & Standorte ───────────────────────────────────────────

    public func requestLocationPermissions() {
        locationManager.requestAlwaysAuthorization()
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        self.locationAuthorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            updateAllGeofences()
        }
    }

    public func addWorkplace(name: String, coordinate: CLLocationCoordinate2D, radiusMeters: Double = 150.0) {
        let place = WorkplaceLocation(
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusMeters: radiusMeters
        )
        savedWorkplaces.append(place)
        saveWorkplaces()
        startMonitoringWorkplace(place)
    }

    public func deleteWorkplace(_ id: UUID) {
        if let place = savedWorkplaces.first(where: { $0.id == id }) {
            stopMonitoringWorkplace(place)
        }
        savedWorkplaces.removeAll(where: { $0.id == id })
        saveWorkplaces()
    }

    private func startMonitoringWorkplace(_ place: WorkplaceLocation) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }

        let center = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        let region = CLCircularRegion(center: center, radius: place.radiusMeters, identifier: place.id.uuidString)
        region.notifyOnEntry = place.autoPromptOnEntry
        region.notifyOnExit = place.autoPromptOnExit

        locationManager.startMonitoring(for: region)
        AppLogger.shared.info("Geofencing", "Überwache Arbeitsplatz: \(place.name) (Radius: \(Int(place.radiusMeters))m)")
    }

    private func stopMonitoringWorkplace(_ place: WorkplaceLocation) {
        for region in locationManager.monitoredRegions {
            if region.identifier == place.id.uuidString {
                locationManager.stopMonitoring(for: region)
            }
        }
    }

    private func updateAllGeofences() {
        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }
        for place in savedWorkplaces {
            startMonitoringWorkplace(place)
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in
            guard let place = self.savedWorkplaces.first(where: { $0.id.uuidString == region.identifier }) else { return }
            if self.activeShift == nil {
                self.sendLocalNotification(
                    title: "Arbeitsplatz erreicht 📍",
                    body: "Du bist bei '\(place.name)' eingetroffen. Schicht jetzt starten?",
                    category: "WORK_ENTRY_CATEGORY",
                    userInfo: ["workplaceName": place.name]
                )
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in
            guard let place = self.savedWorkplaces.first(where: { $0.id.uuidString == region.identifier }) else { return }
            if let shift = self.activeShift {
                self.sendLocalNotification(
                    title: "Arbeitsplatz verlassen 🚶‍♂️",
                    body: "Du hast '\(place.name)' verlassen. Schicht beenden? Bisherige Zeit: \(shift.formattedDuration)",
                    category: "WORK_EXIT_CATEGORY",
                    userInfo: [:]
                )
            }
        }
    }

    // ── Benachrichtigungen ───────────────────────────────────────────────

    private func setupNotificationCategories() {
        let center = UNUserNotificationCenter.current()

        let startAction = UNNotificationAction(identifier: "START_SHIFT", title: "▶️ Einstempeln", options: [.foreground])
        let snoozeAction = UNNotificationAction(identifier: "SNOOZE_15", title: "⏳ 15 Min erinnern", options: [])
        let entryCategory = UNNotificationCategory(identifier: "WORK_ENTRY_CATEGORY", actions: [startAction, snoozeAction], intentIdentifiers: [])

        let endAction = UNNotificationAction(identifier: "END_SHIFT", title: "⏹️ Feierabend buchen", options: [.foreground])
        let exitCategory = UNNotificationCategory(identifier: "WORK_EXIT_CATEGORY", actions: [endAction], intentIdentifiers: [])

        center.setNotificationCategories([entryCategory, exitCategory])
    }

    private func sendLocalNotification(title: String, body: String, category: String, userInfo: [String: Any]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = userInfo

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    private func scheduleBreakReminderNotification() {
        guard breakReminderMinutes > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Zeit für eine Pause! ☕️"
        content.body = "Du arbeitest seit \(breakReminderMinutes / 60) Stunden. Trink ein Glas Wasser und entspanne deine Augen."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(breakReminderMinutes * 60), repeats: false)
        let request = UNNotificationRequest(identifier: "break_reminder", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    private func cancelBreakReminderNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["break_reminder"])
    }

    // ── Dienstplan / Schichtplan Scanner Extraktion ──────────────────────

    public func parseScheduleFromOCR(text: String) {
        var results: [PlannedShift] = []
        let lines = text.components(separatedBy: "\n")

        let timeRegex = try? NSRegularExpression(pattern: #"(\d{1,2}[:.]\d{2})\s*[-–—]\s*(\d{1,2}[:.]\d{2})"#, options: [])

        var dayOffset = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let match = timeRegex?.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) {
                let startRange = match.range(at: 1)
                let endRange = match.range(at: 2)

                let startStr = (trimmed as NSString).substring(with: startRange).replacingOccurrences(of: ".", with: ":")
                let endStr = (trimmed as NSString).substring(with: endRange).replacingOccurrences(of: ".", with: ":")

                let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
                let shift = PlannedShift(
                    date: date,
                    startTimeString: startStr,
                    endTimeString: endStr,
                    roleOrNote: trimmed
                )
                results.append(shift)
                dayOffset += 1
            }
        }

        if !results.isEmpty {
            withAnimation {
                self.plannedShifts.append(contentsOf: results)
            }
            savePlannedShifts()
            AppLogger.shared.info("Dienstplan-Scan", "\(results.count) Schichten aus Dokument extrahiert.")
        }
    }

    public func markPlannedShiftCompleted(_ id: UUID) {
        if let idx = plannedShifts.firstIndex(where: { $0.id == id }) {
            plannedShifts[idx].isCompleted.toggle()
            savePlannedShifts()
        }
    }

    public func deletePlannedShift(_ id: UUID) {
        plannedShifts.removeAll(where: { $0.id == id })
        savePlannedShifts()
    }

    // ── Stundenzettel PDF Generator ──────────────────────────────────────

    public func generateMonthlyTimesheetPDF(for month: Date, userName: String) -> URL? {
        let calendar = Calendar.current
        let monthShifts = shiftHistory.filter { shift in
            calendar.isDate(shift.startTime, equalTo: month, toGranularity: .month)
        }.sorted(by: { $0.startTime < $1.startTime })

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "Digitales Büro – Stundenzettel Generator",
            kCGPDFContextAuthor as String: userName,
            kCGPDFContextTitle as String: "Stundenzettel \(month.formatted(.dateTime.month().year()))"
        ]

        let pageWidth: CGFloat = 595.2
        let pageHeight: CGFloat = 841.8
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)

        let pdfData = renderer.pdfData { context in
            context.beginPage()
            let margin: CGFloat = 50.0

            // 1. Titel
            let title = "STUNDENNACHWEIS / ARBEITSZEITERFASSUNG"
            (title as NSString).draw(
                at: CGPoint(x: margin, y: 50),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 16), .foregroundColor: UIColor.black]
            )

            // 2. Metadaten
            let sub = "Mitarbeiter: \(userName)  |  Monat: \(month.formatted(.dateTime.month(.wide).year()))"
            (sub as NSString).draw(
                at: CGPoint(x: margin, y: 75),
                withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.darkGray]
            )

            // Tabellen-Header
            let tableY: CGFloat = 110
            let headerAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 9), .foregroundColor: UIColor.white]
            let headerRect = CGRect(x: margin, y: tableY, width: pageWidth - 2 * margin, height: 20)
            UIColor.darkGray.setFill()
            context.cgContext.fill(headerRect)

            ("Datum" as NSString).draw(at: CGPoint(x: margin + 6, y: tableY + 4), withAttributes: headerAttrs)
            ("Arbeitsplatz" as NSString).draw(at: CGPoint(x: margin + 90, y: tableY + 4), withAttributes: headerAttrs)
            ("Beginn" as NSString).draw(at: CGPoint(x: margin + 220, y: tableY + 4), withAttributes: headerAttrs)
            ("Ende" as NSString).draw(at: CGPoint(x: margin + 280, y: tableY + 4), withAttributes: headerAttrs)
            ("Pause" as NSString).draw(at: CGPoint(x: margin + 340, y: tableY + 4), withAttributes: headerAttrs)
            ("Netto-Zeit" as NSString).draw(at: CGPoint(x: margin + 410, y: tableY + 4), withAttributes: headerAttrs)

            // Tabellen-Zeilen
            var curY = tableY + 22
            var totalSeconds: TimeInterval = 0

            for (idx, s) in monthShifts.prefix(30).enumerated() {
                totalSeconds += s.durationSeconds
                let rowBg = idx % 2 == 0 ? UIColor(white: 0.95, alpha: 1) : UIColor.white
                rowBg.setFill()
                context.cgContext.fill(CGRect(x: margin, y: curY, width: pageWidth - 2 * margin, height: 18))

                let rowAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8.5), .foregroundColor: UIColor.black]
                (s.startTime.formatted(date: .numeric, time: .omitted) as NSString).draw(at: CGPoint(x: margin + 6, y: curY + 3), withAttributes: rowAttrs)
                (s.workplaceName as NSString).draw(at: CGPoint(x: margin + 90, y: curY + 3), withAttributes: rowAttrs)
                (s.startTime.formatted(date: .omitted, time: .shortened) as NSString).draw(at: CGPoint(x: margin + 220, y: curY + 3), withAttributes: rowAttrs)
                ((s.endTime?.formatted(date: .omitted, time: .shortened) ?? "-") as NSString).draw(at: CGPoint(x: margin + 280, y: curY + 3), withAttributes: rowAttrs)
                ("\(s.breakMinutes)m" as NSString).draw(at: CGPoint(x: margin + 340, y: curY + 3), withAttributes: rowAttrs)
                (s.formattedDuration as NSString).draw(at: CGPoint(x: margin + 410, y: curY + 3), withAttributes: rowAttrs)

                curY += 19
            }

            // Summen-Zeile
            curY += 8
            UIColor.black.setStroke()
            context.cgContext.setLineWidth(1)
            context.cgContext.move(to: CGPoint(x: margin, y: curY))
            context.cgContext.addLine(to: CGPoint(x: pageWidth - margin, y: curY))
            context.cgContext.strokePath()

            curY += 8
            let totalHours = Int(totalSeconds) / 3600
            let totalMins = (Int(totalSeconds) % 3600) / 60
            let sumStr = String(format: "GESAMTE ARBEITSZEIT: %dh %02dm (%d Schichten)", totalHours, totalMins, monthShifts.count)
            (sumStr as NSString).draw(
                at: CGPoint(x: margin + 6, y: curY),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 10), .foregroundColor: UIColor.black]
            )

            // Unterschriftenfeld unten
            let signY = pageHeight - 90
            ("Datum, Unterschrift Mitarbeiter" as NSString).draw(
                at: CGPoint(x: margin, y: signY + 20),
                withAttributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.darkGray]
            )
            context.cgContext.move(to: CGPoint(x: margin, y: signY + 15))
            context.cgContext.addLine(to: CGPoint(x: margin + 180, y: signY + 15))
            context.cgContext.strokePath()

            ("Datum, Unterschrift Arbeitgeber" as NSString).draw(
                at: CGPoint(x: pageWidth - margin - 180, y: signY + 20),
                withAttributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.darkGray]
            )
            context.cgContext.move(to: CGPoint(x: pageWidth - margin - 180, y: signY + 15))
            context.cgContext.addLine(to: CGPoint(x: pageWidth - margin, y: signY + 15))
            context.cgContext.strokePath()
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Stundenzettel_\(month.formatted(.dateTime.month().year())).pdf")
        try? pdfData.write(to: tempURL)
        return tempURL
    }
}

// =============================================================================
// MARK: - 3. WorkTimeHomeWidget (Kompaktkarte für den Homescreen)
// =============================================================================

public struct WorkTimeHomeWidget: View {
    @ObservedObject public var service: WorkTimeService
    public var onTapOpenDashboard: () -> Void

    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(service: WorkTimeService, onTapOpenDashboard: @escaping () -> Void = {}) {
        self.service = service
        self.onTapOpenDashboard = onTapOpenDashboard
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(service.activeShift == nil ? Color.secondary.opacity(0.5) : (service.isPaused ? Color.orange : Color.green))
                        .frame(width: 10, height: 10)
                        .scaleEffect(service.activeShift != nil && !service.isPaused ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: service.activeShift != nil)

                    Text(service.activeShift == nil ? "Nicht eingestempelt" : (service.isPaused ? "Schicht pausiert" : "Schicht aktiv"))
                        .font(.caption.bold())
                        .foregroundStyle(service.activeShift == nil ? .secondary : (service.isPaused ? .orange : .green))
                }

                Spacer()

                Button {
                    onTapOpenDashboard()
                } label: {
                    HStack(spacing: 4) {
                        Text("Zeiterfassung")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption2.bold())
                    .foregroundStyle(Theme.primaryAccent)
                }
            }

            if let shift = service.activeShift {
                // Aktive Schicht Live-Timer
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shift.workplaceName)
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text("Seit \(shift.startTime.formatted(date: .omitted, time: .shortened)) Uhr")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(shift.formattedDuration)
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundStyle(service.isPaused ? .orange : Theme.primaryAccent)
                }

                // Quick Buttons
                HStack(spacing: 10) {
                    Button {
                        if service.isPaused {
                            service.resumeShift()
                        } else {
                            service.pauseShift()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: service.isPaused ? "play.fill" : "pause.fill")
                            Text(service.isPaused ? "Fortsetzen" : "Pause")
                        }
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }

                    Button {
                        service.endShift()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                            Text("Ausstempeln")
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            } else {
                // 1-Tap Schnell-Einstempeln
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Arbeitszeit starten")
                            .font(.subheadline.bold())
                        Text(service.savedWorkplaces.isEmpty ? "Kein Geofence hinterlegt" : "Nächster Ort: \(service.savedWorkplaces.first?.name ?? "Büro")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        let name = service.savedWorkplaces.first?.name ?? "Arbeitsplatz"
                        service.startShift(workplaceName: name)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("Einstempeln")
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.primaryGradient, in: Capsule())
                    }
                }
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 18)
        .onReceive(timer) { input in
            self.now = input
        }
    }
}

// =============================================================================
// MARK: - 4. WorkTimeDashboardView (Vollbild-Verwaltung)
// =============================================================================

public struct WorkTimeDashboardView: View {
    @ObservedObject public var service: WorkTimeService
    @Environment(\.dismiss) private var dismiss

    @State private var showAddPlaceSheet: Bool = false
    @State private var showScheduleScanner: Bool = false
    @State private var showShareSheet: Bool = false
    @State private var generatedPDFURL: URL? = nil

    public init(service: WorkTimeService) {
        self.service = service
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // 1. Live Hero Clock
                        liveShiftHero

                        // 2. Schnellauswahl & Aktionen
                        quickActionCards

                        // 3. Geplante Schichten aus Scan
                        if !service.plannedShifts.isEmpty {
                            plannedShiftsSection
                        }

                        // 4. Standorte & Geofencing
                        workplacesSection

                        // 5. Vergangene Schichten
                        recentShiftsSection
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Arbeitszeit & Schichten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        exportTimesheetPDF()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showAddPlaceSheet) {
                AddWorkplaceSheet(service: service)
            }
            .sheet(isPresented: $showScheduleScanner) {
                WorkScheduleScannerSheet(service: service)
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = generatedPDFURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    // ── Live Hero Clock ──────────────────────────────────────────────────

    private var liveShiftHero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 10)
                    .frame(width: 170, height: 170)

                Circle()
                    .trim(from: 0.0, to: min(1.0, CGFloat((service.activeShift?.netWorkingHours ?? 0) / max(1.0, service.dailyTargetHours))))
                    .stroke(
                        service.isPaused ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Theme.primaryGradient),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 170, height: 170)
                    .animation(.spring(response: 0.4), value: service.activeShift?.durationSeconds)

                VStack(spacing: 4) {
                    Image(systemName: service.activeShift == nil ? "briefcase.fill" : (service.isPaused ? "pause.fill" : "stopwatch.fill"))
                        .font(.title2)
                        .foregroundStyle(service.activeShift == nil ? .secondary : (service.isPaused ? .orange : Theme.primaryAccent))

                    Text(service.activeShift?.formattedDuration ?? "0h 00m")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)

                    Text(service.activeShift == nil ? "Bereit zum Start" : (service.isPaused ? "Pausiert" : service.activeShift?.workplaceName ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 10)

            // Buttons
            if let _ = service.activeShift {
                HStack(spacing: 12) {
                    Button {
                        if service.isPaused {
                            service.resumeShift()
                        } else {
                            service.pauseShift()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: service.isPaused ? "play.fill" : "pause.fill")
                            Text(service.isPaused ? "Weiter" : "Pause")
                        }
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }

                    Button {
                        service.endShift()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                            Text("Feierabend")
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            } else {
                Button {
                    let defaultName = service.savedWorkplaces.first?.name ?? "Arbeitsplatz"
                    service.startShift(workplaceName: defaultName)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Jetzt Einstempeln")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.primaryGradient, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 22)
    }

    // ── Schnellauswahl & Aktionen ────────────────────────────────────────

    private var quickActionCards: some View {
        HStack(spacing: 10) {
            Button {
                showScheduleScanner = true
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "camera.viewfinder")
                        .font(.title3)
                        .foregroundStyle(Theme.primaryAccent)
                    Text("Dienstplan scannen")
                        .font(.caption2.bold())
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.glassEdgeGradient, lineWidth: 0.8)
                }
            }

            Button {
                showAddPlaceSheet = true
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "location.badge.plus")
                        .font(.title3)
                        .foregroundStyle(Color.green)
                    Text("Ort markieren")
                        .font(.caption2.bold())
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.glassEdgeGradient, lineWidth: 0.8)
                }
            }

            Button {
                exportTimesheetPDF()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "doc.text.fill")
                        .font(.title3)
                        .foregroundStyle(Color.blue)
                    Text("Stundenzettel")
                        .font(.caption2.bold())
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.glassEdgeGradient, lineWidth: 0.8)
                }
            }
        }
    }

    // ── Geplante Schichten ───────────────────────────────────────────────

    private var plannedShiftsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Eingescannte Schichten", systemImage: "calendar.badge.clock")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            ForEach(service.plannedShifts) { p in
                HStack(spacing: 12) {
                    Button {
                        service.markPlannedShiftCompleted(p.id)
                    } label: {
                        Image(systemName: p.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(p.isCompleted ? .green : .secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.subheadline.bold())
                            .strikethrough(p.isCompleted)
                        Text("\(p.startTimeString) - \(p.endTimeString) Uhr")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !p.isCompleted && service.activeShift == nil {
                        Button("Start") {
                            service.startShift(workplaceName: p.roleOrNote ?? "Schicht")
                        }
                        .font(.caption2.bold())
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.primaryAccent.opacity(0.2), in: Capsule())
                        .foregroundStyle(Theme.primaryAccent)
                    }

                    Button {
                        service.deletePlannedShift(p.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 18)
    }

    // ── Standorte & Geofencing ───────────────────────────────────────────

    private var workplacesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Standorte & Geofences", systemImage: "mappin.and.ellipse")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    service.requestLocationPermissions()
                } label: {
                    Text(service.locationAuthorizationStatus == .authorizedAlways ? "Aktiv (Always) ✓" : "Freigabe prüfen")
                        .font(.caption2.bold())
                        .foregroundStyle(service.locationAuthorizationStatus == .authorizedAlways ? .green : .orange)
                }
            }

            if service.savedWorkplaces.isEmpty {
                Text("Keine automatischen Geofences hinterlegt. Klicke oben auf 'Ort markieren', um z. B. deine Firma oder Baustelle einzuspeichern.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(service.savedWorkplaces) { w in
                    HStack {
                        Image(systemName: "building.2.crop.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.primaryAccent)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.name)
                                .font(.subheadline.bold())
                            Text("Radius: \(Int(w.radiusMeters))m • Auto-Prompt: \(w.autoPromptOnEntry ? "Ja" : "Nein")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            service.deleteWorkplace(w.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.7))
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 18)
    }

    // ── Vergangene Schichten ─────────────────────────────────────────────

    private var recentShiftsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Verlauf & Arbeitszeiten", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            if service.shiftHistory.isEmpty {
                Text("Noch keine Schichten erfasst.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(service.shiftHistory.prefix(10)) { shift in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shift.workplaceName)
                                .font(.subheadline.bold())
                            Text("\(shift.startTime.formatted(date: .numeric, time: .shortened)) – \(shift.endTime?.formatted(date: .omitted, time: .shortened) ?? "laufend")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(shift.formattedDuration)
                                .font(.subheadline.bold())
                                .foregroundStyle(Theme.primaryAccent)
                            if shift.breakMinutes > 0 {
                                Text("Pause: \(shift.breakMinutes)m")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            service.deleteShift(shift.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.secondary.opacity(0.5))
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 18)
    }

    private func exportTimesheetPDF() {
        let userName = UserDefaults.standard.string(forKey: "user_display_name") ?? "Max Mustermann"
        if let url = service.generateMonthlyTimesheetPDF(for: Date(), userName: userName) {
            self.generatedPDFURL = url
            self.showShareSheet = true
        }
    }
}

// =============================================================================
// MARK: - 5. Hilfs-Sheets (Ort markieren & Dienstplan-Scan)
// =============================================================================

public struct AddWorkplaceSheet: View {
    @ObservedObject public var service: WorkTimeService
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var radius: Double = 150.0
    @StateObject private var quickLocator = QuickLocationFetcher()

    public init(service: WorkTimeService) {
        self.service = service
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 16) {
                    Text("Neuen Arbeitsplatz als Geofence anlegen")
                        .font(.headline)

                    Text("Sobald du diesen Ort betrittst oder verlässt, erinnert dich die App automatisch mit einer 1-Tap-Mitteilung ans Ein- und Ausstempeln.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bezeichnung")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        TextField("z. B. Büro Hauptsitz, Baustelle Nord...", text: $name)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Erkennungs-Radius: \(Int(radius)) Meter")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        Slider(value: $radius, in: 50...500, step: 25)
                            .tint(Theme.primaryAccent)
                    }

                    if let coord = quickLocator.coordinate {
                        HStack {
                            Image(systemName: "location.fill")
                                .foregroundStyle(.green)
                            Text(String(format: "Aktuelle GPS-Koordinaten erfasst (%.4f, %.4f)", coord.latitude, coord.longitude))
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    } else {
                        HStack {
                            ProgressView()
                            Text("Ermittle aktuellen Standort...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button {
                        if let coord = quickLocator.coordinate {
                            let placeName = name.isEmpty ? "Arbeitsplatz" : name
                            service.addWorkplace(name: placeName, coordinate: coord, radiusMeters: radius)
                            dismiss()
                        }
                    } label: {
                        Text("Standort speichern & Geofence aktivieren")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(quickLocator.coordinate == nil ? Color.gray : Theme.primaryAccent, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(quickLocator.coordinate == nil)
                }
                .padding(20)
            }
            .navigationTitle("Standort hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .onAppear {
                quickLocator.start()
            }
        }
    }
}

public struct WorkScheduleScannerSheet: View {
    @ObservedObject public var service: WorkTimeService
    @Environment(\.dismiss) private var dismiss

    @State private var manualText: String = ""

    public init(service: WorkTimeService) {
        self.service = service
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 16) {
                    Text("Dienstplan & Schichten einlesen")
                        .font(.headline)

                    Text("Kopiere den Text deines Dienstplans hier hinein oder nutze OCR. Die App erkennt Schichtzeiten (z. B. '08:00 - 16:30') automatisch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $manualText)
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        .frame(minHeight: 180)

                    Button {
                        manualText = """
                        Mo 08.09.: 07:00 - 15:30 Frühschicht Station 2
                        Di 09.09.: 07:00 - 15:30 Frühschicht Station 2
                        Mi 10.09.: 14:00 - 22:00 Spätschicht
                        Do 11.09.: 14:00 - 22:00 Spätschicht
                        Fr 12.09.: 07:00 - 15:30 Frühschicht
                        """
                    } label: {
                        Text("Beispiel-Dienstplan einfügen")
                            .font(.caption.bold())
                            .foregroundStyle(Theme.primaryAccent)
                    }

                    Spacer()

                    Button {
                        service.parseScheduleFromOCR(text: manualText)
                        dismiss()
                    } label: {
                        Text("Schichten extrahieren & speichern")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(manualText.isEmpty ? Color.gray : Theme.primaryAccent, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(manualText.isEmpty)
                }
                .padding(20)
            }
            .navigationTitle("Dienstplan erfassen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }
}

// ── Einmaliger Standort-Ermittler ────────────────────────────────────────────

public final class QuickLocationFetcher: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published public var coordinate: CLLocationCoordinate2D? = nil
    private let manager = CLLocationManager()

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    public func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        self.coordinate = loc.coordinate
        manager.stopUpdatingLocation()
    }
}
