// =============================================================================
// HardwareLogModule.swift
// Schulden & Haushalt App
// Requires: iOS 17+, Swift 5.9+
// =============================================================================

import SwiftUI

// MARK: - HardwareLogEntry

struct HardwareLogEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let userId: UUID
    
    var deviceName: String
    var deviceType: DeviceType
    var serialNumber: String?
    var purchaseDate: Date?
    
    var logType: LogType
    var performedAt: Date
    var performedBy: String?
    var cost: Decimal
    
    var mileageKm: Decimal?
    var nextServiceAt: Date?
    var nextServiceKm: Decimal?
    
    var description: String
    var documentUrl: String?
    
    let createdAt: Date
    let updatedAt: Date
    
    enum DeviceType: String, Codable, CaseIterable, Sendable {
        case eScooter = "e_scooter"
        case coffeeMachine = "coffee_machine"
        case appliance = "appliance"
        case vehicle = "vehicle"
        case other = "other"
        
        var displayName: String {
            switch self {
            case .eScooter: return "E-Scooter"
            case .coffeeMachine: return "Kaffeemaschine"
            case .appliance: return "Haushaltsgerät"
            case .vehicle: return "Fahrzeug"
            case .other: return "Sonstiges"
            }
        }
        
        var icon: String {
            switch self {
            case .eScooter: return "scooter"
            case .coffeeMachine: return "cup.and.saucer.fill"
            case .appliance: return "washer.fill"
            case .vehicle: return "car.fill"
            case .other: return "cube.box.fill"
            }
        }
    }
    
    enum LogType: String, Codable, CaseIterable, Sendable {
        case maintenance = "maintenance"
        case repair = "repair"
        case inspection = "inspection"
        case consumable = "consumable"
        case issue = "issue"
        case note = "note"
        
        var displayName: String {
            switch self {
            case .maintenance: return "Wartung"
            case .repair: return "Reparatur"
            case .inspection: return "Inspektion"
            case .consumable: return "Verbrauchsmaterial"
            case .issue: return "Problem"
            case .note: return "Notiz"
            }
        }
        
        var color: Color {
            switch self {
            case .maintenance: return .blue
            case .repair: return .red
            case .inspection: return .orange
            case .consumable: return .green
            case .issue: return .purple
            case .note: return .gray
            }
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case deviceName = "device_name"
        case deviceType = "device_type"
        case serialNumber = "serial_number"
        case purchaseDate = "purchase_date"
        case logType = "log_type"
        case performedAt = "performed_at"
        case performedBy = "performed_by"
        case cost
        case mileageKm = "mileage_km"
        case nextServiceAt = "next_service_at"
        case nextServiceKm = "next_service_km"
        case description
        case documentUrl = "document_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
    
    var costFormatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.locale = Locale(identifier: "de_DE")
        return formatter.string(from: NSDecimalNumber(decimal: cost)) ?? "\(cost) €"
    }

    // ── Transient upload staging ─────────────────────────────────────────
    // Not persisted to DB / not Codable — used only to carry image bytes
    // from the AddHardwareEntrySheet into HardwareLogService.addEntry.

    /// Raw image data to be uploaded to Supabase Storage before DB insert.
    /// Excluded from `CodingKeys` so it is never serialised.
    var documentImageData: Data? = nil

    /// Returns a copy of this entry with `documentUrl` set to `url`
    /// and `documentImageData` cleared (upload already done).
    func withDocumentURL(_ url: String) -> HardwareLogEntry {
        var copy = self
        copy.documentUrl      = url
        copy.documentImageData = nil
        return copy
    }
}

// MARK: - HardwareLogService

@MainActor
final class HardwareLogService: ObservableObject {
    @Published private(set) var entries: [HardwareLogEntry] = []
    @Published private(set) var isLoading = false
    @Published var lastError: String?
    
    private let userId: UUID
    private let db = SupabaseConfig.client
    
    init(userId: UUID) {
        self.userId = userId
    }
    
    func load() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let fetched: [HardwareLogEntry] = try await db
                .from("hardware_log")
                .select()
                .eq("user_id", value: userId.uuidString)
                .order("performed_at", ascending: false)
                .execute()
                .value
            entries = fetched
        } catch {
            lastError = error.localizedDescription
        }
    }
    
    func addEntry(_ draft: HardwareLogEntry) async throws {
        // ── 1. Upload attached document/image to Supabase Storage (if any) ──
        var entryToSave = draft
        if let imageData = draft.documentImageData {
            do {
                let userIdStr = userId.uuidString
                let fileName  = "\(userIdStr)/\(draft.id.uuidString).jpg"
                _ = try await db.storage
                    .from("hardware-documents")
                    .upload(fileName, data: imageData, contentType: "image/jpeg")
                entryToSave = draft.withDocumentURL(fileName)
            } catch {
                // Non-fatal: we still save the entry without a document URL
                print("Hardware document upload failed: \(error.localizedDescription)")
            }
        }

        // ── 2. Optimistic UI ─────────────────────────────────────────────────
        entries.insert(entryToSave, at: 0)
        entries.sort { $0.performedAt > $1.performedAt }

        do {
            try await db
                .from("hardware_log")
                .insert(entryToSave)
                .execute()
            if let nextDate = entryToSave.nextServiceAt {
                NotificationService.shared.scheduleHardwareReminder(
                    id: entryToSave.id,
                    deviceName: entryToSave.deviceName,
                    serviceDate: nextDate,
                    description: entryToSave.description
                )
            }
        } catch {
            // Rollback optimistic insert
            entries.removeAll { $0.id == entryToSave.id }
            lastError = error.localizedDescription
            throw error
        }
    }
    
    func deleteEntry(_ id: UUID) async {
        let backup = entries
        entries.removeAll { $0.id == id }
        NotificationService.shared.cancelReminder(id: id)
        
        do {
            try await db
                .from("hardware_log")
                .delete()
                .eq("id", value: id.uuidString)
                .execute()
        } catch {
            entries = backup
            lastError = error.localizedDescription
        }
    }
}

// MARK: - Views

struct SelectedDevice: Identifiable {
    let id: String
}

struct HardwareLogView: View {
    @StateObject private var service = HardwareLogService(userId: (try? SupabaseConfig.client.auth.session.user.id) ?? UUID())
    @State private var showingAddSheet = false
    @State private var selectedDevice: SelectedDevice?
    
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.primaryAccent.opacity(0.1).ignoresSafeArea()
                
                if service.isLoading && service.entries.isEmpty {
                    ProgressView()
                } else if service.entries.isEmpty {
                    ContentUnavailableView(
                        "Keine Geräte",
                        systemImage: "wrench.and.screwdriver",
                        description: Text("Füge ein Gerät hinzu, um Wartungen zu protokollieren.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(groupedDevices.keys.sorted(), id: \.self) { deviceName in
                                if let latestEntry = groupedDevices[deviceName]?.first {
                                    DeviceCard(
                                        deviceName: deviceName,
                                        latestEntry: latestEntry,
                                        entries: groupedDevices[deviceName] ?? []
                                    )
                                    .onTapGesture {
                                        selectedDevice = SelectedDevice(id: deviceName)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Geräte & Wartung")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingAddSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $selectedDevice) { item in
                DeviceTimelineSheet(
                    deviceName: item.id,
                    entries: groupedDevices[item.id] ?? [],
                    service: service
                )
            }
            .sheet(isPresented: $showingAddSheet) {
                AddHardwareEntrySheet(service: service, existingDevices: Array(groupedDevices.keys))
            }
            .task {
                await service.load()
            }
        }
    }
    
    private var groupedDevices: [String: [HardwareLogEntry]] {
        Dictionary(grouping: service.entries, by: { $0.deviceName })
    }
}

struct DeviceCard: View {
    let deviceName: String
    let latestEntry: HardwareLogEntry
    let entries: [HardwareLogEntry]
    
    private var formattedTotalCost: String {
        let totalCost = entries.reduce(Decimal(0)) { $0 + $1.cost }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.locale = Locale(identifier: "de_DE")
        return formatter.string(from: NSDecimalNumber(decimal: totalCost)) ?? ""
    }
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: latestEntry.deviceType.icon)
                .font(.largeTitle)
                .foregroundStyle(Theme.primaryAccent)
                .frame(width: 50, height: 50)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(deviceName)
                    .font(.headline)
                
                Text("Letzte Wartung: \(latestEntry.performedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if let next = latestEntry.nextServiceAt {
                    let isSoon = next.timeIntervalSinceNow < 30 * 24 * 60 * 60
                    Text("Nächste: \(next.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(isSoon ? .orange : .secondary)
                }
            }
            
            Spacer()
            
            Text(formattedTotalCost)
                .font(.subheadline.bold())
        }
        .padding()
        .liquidGlassCard()
    }
}

struct DeviceTimelineSheet: View {
    let deviceName: String
    let entries: [HardwareLogEntry]
    @ObservedObject var service: HardwareLogService
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(entry.logType.displayName, systemImage: "circle.fill")
                                .foregroundStyle(entry.logType.color)
                                .font(.subheadline.bold())
                            Spacer()
                            Text(entry.performedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Text(entry.description)
                            .font(.body)
                        
                        HStack {
                            if entry.cost > 0 {
                                Text(entry.costFormatted)
                                    .font(.caption.bold())
                            }
                            if let km = entry.mileageKm {
                                Text("• \(km.formatted()) km")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let by = entry.performedBy, !by.isEmpty {
                                Text("• \(by)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions {
                        Button("Löschen", role: .destructive) {
                            Task {
                                await service.deleteEntry(entry.id)
                            }
                        }
                    }
                }
            }
            .navigationTitle(deviceName)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await service.load()
            }
        }
    }
}

struct AddHardwareEntrySheet: View {
    @ObservedObject var service: HardwareLogService
    let existingDevices: [String]

    @Environment(\.dismiss) private var dismiss

    @State private var deviceName    = ""
    @State private var deviceType    = HardwareLogEntry.DeviceType.other
    @State private var logType       = HardwareLogEntry.LogType.note
    @State private var performedAt   = Date()
    @State private var performedBy   = ""
    @State private var costString    = ""
    @State private var mileageString = ""
    @State private var showNextService = false
    @State private var nextServiceAt = Date().addingTimeInterval(365 * 24 * 60 * 60)
    @State private var description   = ""

    // ── Document / Image attachment ──────────────────────────────────────
    @State private var selectedImageData: Data? = nil
    @State private var showImagePicker = false

    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Gerät") {
                    TextField("Name (z.B. E-Scooter)", text: $deviceName)
                    Picker("Typ", selection: $deviceType) {
                        ForEach(HardwareLogEntry.DeviceType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                }

                Section("Wartung") {
                    Picker("Art", selection: $logType) {
                        ForEach(HardwareLogEntry.LogType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    DatePicker("Datum", selection: $performedAt, displayedComponents: .date)
                    TextField("Durchgeführt von (optional)", text: $performedBy)
                    TextField("Kosten (€)", text: $costString)
                        .keyboardType(.decimalPad)
                    TextField("Kilometerstand (optional)", text: $mileageString)
                        .keyboardType(.decimalPad)
                }

                Section("Erinnerung") {
                    Toggle("Nächste Wartung planen", isOn: $showNextService)
                    if showNextService {
                        DatePicker("Am", selection: $nextServiceAt, displayedComponents: .date)
                    }
                }

                Section("Dokument / Foto") {
                    Button {
                        showImagePicker = true
                    } label: {
                        Label(
                            selectedImageData == nil ? "Bild anhängen" : "Bild ändern",
                            systemImage: selectedImageData == nil ? "photo.badge.plus" : "photo.badge.checkmark"
                        )
                        .foregroundStyle(selectedImageData == nil ? Theme.primaryAccent : .green)
                    }
                    if let data = selectedImageData, let uiImg = UIImage(data: data) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        Button("Anhang entfernen", role: .destructive) {
                            selectedImageData = nil
                        }
                    }
                }

                Section("Details") {
                    TextField("Beschreibung", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Neuer Eintrag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }
                        .disabled(deviceName.isEmpty || description.isEmpty || isSaving)
                }
            }
            .overlay {
                if isSaving {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(selectedImageData != nil ? "Dokument wird hochgeladen…" : "Wird gespeichert…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            // ── Image picker sheet (UIImagePickerController via SwiftUI) ──
            .sheet(isPresented: $showImagePicker) {
                ImagePickerSheetView { image in
                    selectedImageData = image?.jpegData(compressionQuality: 0.8)
                }
            }
        }
    }

    private func save() {
        guard !deviceName.isEmpty, !description.isEmpty else { return }

        let cost = Decimal(string: costString.replacingOccurrences(of: ",", with: ".")) ?? 0
        let km   = Decimal(string: mileageString.replacingOccurrences(of: ",", with: "."))

        var entry = HardwareLogEntry(
            id:           UUID(),
            userId:       (try? SupabaseConfig.client.auth.session.user.id) ?? UUID(),
            deviceName:   deviceName,
            deviceType:   deviceType,
            logType:      logType,
            performedAt:  performedAt,
            performedBy:  performedBy.isEmpty ? nil : performedBy,
            cost:         cost,
            mileageKm:    km,
            nextServiceAt: showNextService ? nextServiceAt : nil,
            description:  description,
            createdAt:    Date(),
            updatedAt:    Date()
        )
        // Attach image data — will be uploaded in HardwareLogService.addEntry
        entry.documentImageData = selectedImageData

        isSaving = true
        Task {
            do {
                try await service.addEntry(entry)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run { isSaving = false }
            }
        }
    }
}

// MARK: - ImagePickerSheetView  (UIImagePickerController wrapper)

/// Lightweight UIImagePickerController wrapper for Swift Playgrounds compatibility.
/// On a full Xcode project you can replace this with PhotosPicker (PhotosUI) or
/// the new PHPickerViewController for multi-image support.
private struct ImagePickerSheetView: UIViewControllerRepresentable {
    var onPick: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType          = .photoLibrary
        picker.allowsEditing       = false
        picker.delegate            = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true) { [weak self] in
                self?.onPick(info[.originalImage] as? UIImage)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) { [weak self] in self?.onPick(nil) }
        }
    }
}
