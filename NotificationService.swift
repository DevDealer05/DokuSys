// =============================================================================
// NotificationService.swift
// Local Push Notifications via UNUserNotificationCenter
// Requires: iOS 17+, UserNotifications
// =============================================================================

import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationService()
    
    private let center = UNUserNotificationCenter.current()
    @Published var isAuthorized: Bool = false
    
    private override init() {
        super.init()
        center.delegate = self
        Task { await checkPermission() }
    }
    
    // ── Permission ─────────────────────────────────────────────────────
    
    func checkPermission() async {
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }
    
    func requestPermission() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            self.isAuthorized = granted
            return granted
        } catch {
            print("Failed to request notification authorization: \(error)")
            return false
        }
    }
    
    // ── Hardware Service Reminders ─────────────────────────────────────
    
    func scheduleHardwareReminder(
        id: UUID,
        deviceName: String,
        serviceDate: Date,
        description: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = "🔧 Wartung fällig: \(deviceName)"
        content.body = description.isEmpty ? "Für dein Gerät \(deviceName) steht ein Servicetermin an." : description
        content.sound = .default
        content.badge = 1
        
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: serviceDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: "hardware-\(id.uuidString)",
            content: content,
            trigger: trigger
        )
        
        center.add(request) { error in
            if let error = error {
                print("Failed to schedule notification: \(error)")
            }
        }
    }
    
    func cancelReminder(id: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: ["hardware-\(id.uuidString)"])
    }
    
    // ── Foreground Presentation ────────────────────────────────────────
    
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .badge, .sound])
    }
}
