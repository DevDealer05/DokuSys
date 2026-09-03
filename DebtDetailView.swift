// =============================================================================
// DebtDetailView.swift
// Schulden & Haushalt App
// Requires: iOS 17+, Swift 5.9+
// =============================================================================

import SwiftUI

struct DebtDetailView: View {
    let debt: Debt
    @EnvironmentObject private var debtEngine: DebtEngineService
    @State private var showingAddTimeline = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Top Card: Summary
                DebtSummaryCard(debt: debt)
                
                // Section: Interest & Terms
                VStack(alignment: .leading, spacing: 12) {
                    Text("Zinsen & Laufzeit")
                        .font(.headline)
                        .padding(.horizontal)
                    
                    VStack(spacing: 12) {
                        HStack {
                            Text("Zinssatz")
                            Spacer()
                            Text("\(debt.interestRatePct.formatted()) %")
                                .bold()
                        }
                        if let next = debt.nextPaymentDate {
                            Divider()
                            HStack {
                                Text("Nächste Rate")
                                Spacer()
                                Text(next.formatted(date: .abbreviated, time: .omitted))
                                    .bold()
                            }
                        }
                    }
                    .padding()
                    .liquidGlassCard()
                }
                
                // Section: Timeline
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Verlauf")
                            .font(.headline)
                        Spacer()
                        Button(action: { showingAddTimeline = true }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Theme.primaryAccent)
                        }
                    }
                    .padding(.horizontal)
                    
                    let timeline = debtEngine.timeline(for: debt.id)
                    if timeline.isEmpty {
                        ContentUnavailableView(
                            "Kein Verlauf",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Füge einen neuen Eintrag hinzu oder scanne ein Dokument.")
                        )
                        .padding()
                        .liquidGlassCard()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(timeline) { entry in
                                TimelineEntryRow(entry: entry)
                                if entry.id != timeline.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        .liquidGlassCard()
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Status", selection: Binding(
                        get: { debt.status },
                        set: { debtEngine.updateDebtStatus(debt.id, newStatus: $0) }
                    )) {
                        ForEach(DebtStatus.allCases, id: \.self) { status in
                            Text(status.displayName).tag(status)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingAddTimeline) {
            AddTimelineEntrySheet(debtId: debt.id)
        }
    }
}

// MARK: - Components

struct DebtSummaryCard: View {
    let debt: Debt
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(debt.creditorName)
                        .font(.title2.bold())
                    Text(debt.fileNumber)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                
                Text(debt.status.displayName)
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(statusColor(debt.status).opacity(0.2))
                    .foregroundStyle(statusColor(debt.status))
                    .clipShape(Capsule())
            }
            
            Divider()
            
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text("Aktueller Betrag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(debt.currentPrincipal, format: .currency(code: "EUR"))
                        .font(.largeTitle.bold())
                        .foregroundStyle(Theme.primaryAccent)
                }
                
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text("Ursprünglich")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(debt.originalAmount, format: .currency(code: "EUR"))
                        .font(.headline)
                }
            }
            
            if debt.limitationStatus.isPotentiallyExpired {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(debt.limitationStatus.hint)
                        .font(.caption.bold())
                }
                .foregroundStyle(.orange)
                .padding(.top, 4)
            }
        }
        .padding()
        .liquidGlassCard()
    }
    
    private func statusColor(_ status: DebtStatus) -> Color {
        switch status {
        case .active: return .blue
        case .negotiating: return .orange
        case .paid: return .green
        case .disputed: return .red
        case .writtenOff: return .gray
        }
    }
}

struct TimelineEntryRow: View {
    let entry: DebtTimeline
    @State private var showingDetail = false
    
    var body: some View {
        Button(action: { showingDetail = true }) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.entryType.icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(entry.entryType.color)
                    .clipShape(Circle())
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.entryType.displayName)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        
                        Spacer()
                        
                        if let date = entry.letterDate ?? Optional(entry.createdAt) {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    if let desc = entry.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    
                    HStack {
                        if entry.amountDelta != 0 {
                            let isReduction = entry.amountDelta < 0
                            Text(entry.amountDelta, format: .currency(code: "EUR"))
                                .font(.caption.bold())
                                .foregroundStyle(isReduction ? .green : .red)
                        }
                        Spacer()
                        if entry.documentURL != nil {
                            Image(systemName: "paperclip")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingDetail) {
            TimelineEntryDetailSheet(entry: entry)
        }
    }
}

struct AddTimelineEntrySheet: View {
    let debtId: UUID
    @EnvironmentObject private var debtEngine: DebtEngineService
    @Environment(\.dismiss) private var dismiss

    @State private var entryType    = TimelineEntryType.note
    @State private var amountString = ""
    @State private var description  = ""
    @State private var letterDate   = Date()
    @State private var sender       = ""

    // ── Document / Image attachment ──────────────────────────────────────
    @State private var selectedImageData: Data?    = nil
    @State private var selectedImageName: String?  = nil
    @State private var showImagePicker             = false
    @State private var isUploading                 = false
    @State private var uploadError: String?        = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Art des Eintrags") {
                    Picker("Typ", selection: $entryType) {
                        ForEach(TimelineEntryType.allCases.filter { $0 != .superseded && $0 != .statusChange }, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                }

                Section("Details") {
                    TextField("Beschreibung", text: $description, axis: .vertical)
                        .lineLimit(3...6)

                    if entryType == .payment || entryType == .fee || entryType == .interest {
                        TextField("Betrag (€)", text: $amountString)
                            .keyboardType(.numbersAndPunctuation)
                    }

                    if entryType == .letterReceived || entryType == .letterSent {
                        DatePicker("Briefdatum", selection: $letterDate, displayedComponents: .date)
                        TextField("Absender / Empfänger", text: $sender)
                    }
                }

                // ── Document upload section ──────────────────────────────
                Section("Dokument / Scan anhängen") {
                    Button {
                        showImagePicker = true
                    } label: {
                        Label(
                            selectedImageData == nil ? "Bild oder Scan anhängen" : "Anhang ändern",
                            systemImage: selectedImageData == nil ? "doc.badge.plus" : "doc.badge.checkmark"
                        )
                        .foregroundStyle(selectedImageData == nil ? Theme.primaryAccent : .green)
                    }

                    if let data = selectedImageData, let uiImg = UIImage(data: data) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        if let name = selectedImageName {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button("Anhang entfernen", role: .destructive) {
                            selectedImageData = nil
                            selectedImageName = nil
                            uploadError = nil
                        }
                    }

                    if let err = uploadError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
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
                        .disabled(description.isEmpty || isUploading)
                }
            }
            .overlay {
                if isUploading {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Dokument wird hochgeladen…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .sheet(isPresented: $showImagePicker) {
                DebtDocumentPickerView { image in
                    if let img = image {
                        selectedImageData = img.jpegData(compressionQuality: 0.82)
                        selectedImageName = "Scan_\(Date().formatted(date: .numeric, time: .omitted)).jpg"
                    }
                }
            }
        }
    }

    private func save() {
        guard !description.isEmpty else { return }
        isUploading = true
        uploadError = nil

        Task {
            var uploadedURL:  String? = nil
            let uploadedName: String? = selectedImageName

            // ── Upload image if one was selected ──────────────────────────
            if let data = selectedImageData {
                do {
                    let userId    = (try? SupabaseConfig.client.auth.session.user.id) ?? UUID()
                    let fileName  = "\(userId.uuidString)/\(UUID().uuidString).jpg"
                    _ = try await SupabaseConfig.client.storage
                        .from("debt-documents")
                        .upload(fileName, data: data, contentType: "image/jpeg")
                    uploadedURL  = fileName
                } catch {
                    // Non-fatal: save entry without document URL
                    await MainActor.run {
                        uploadError = "Upload fehlgeschlagen – Eintrag wird trotzdem gespeichert."
                    }
                }
            }

            let amt   = Decimal(string: amountString.replacingOccurrences(of: ",", with: ".")) ?? 0
            let delta = entryType == .payment ? -abs(amt) : abs(amt)

            guard let debt = debtEngine.debts.first(where: { $0.id == debtId }) else {
                await MainActor.run { isUploading = false }
                return
            }

            let newEntry = DebtTimeline(
                id:                UUID(),
                debtId:            debt.id,
                userId:            (try? SupabaseConfig.client.auth.session.user.id) ?? UUID(),
                entryType:         entryType,
                amountDelta:       delta,
                principalSnapshot: debt.currentPrincipal + delta,
                documentURL:       uploadedURL,
                documentName:      uploadedURL != nil ? uploadedName : nil,
                sender:            sender.isEmpty ? nil : sender,
                letterDate:        (entryType == .letterReceived || entryType == .letterSent) ? letterDate : nil,
                description:       description,
                createdAt:         Date()
            )

            await MainActor.run {
                debtEngine.addTimelineEntry(newEntry)
                isUploading = false
                dismiss()
            }
        }
    }
}

// MARK: - DebtDocumentPickerView (UIImagePickerController wrapper)

private struct DebtDocumentPickerView: UIViewControllerRepresentable {
    var onPick: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType    = .photoLibrary
        picker.allowsEditing = false
        picker.delegate      = context.coordinator
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


struct TimelineEntryDetailSheet: View {
    let entry: DebtTimeline
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: entry.entryType.icon)
                        .font(.system(size: 48))
                        .foregroundStyle(entry.entryType.color)
                        .padding()
                        .background(entry.entryType.color.opacity(0.1))
                        .clipShape(Circle())
                    
                    Text(entry.entryType.displayName)
                        .font(.title2.bold())
                    
                    VStack(alignment: .leading, spacing: 16) {
                        DetailRow(title: "Datum", value: entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        
                        if let date = entry.letterDate {
                            DetailRow(title: "Briefdatum", value: date.formatted(date: .abbreviated, time: .omitted))
                        }
                        if let sender = entry.sender {
                            DetailRow(title: "Absender", value: sender)
                        }
                        if entry.amountDelta != 0 {
                            DetailRow(
                                title: "Änderung",
                                value: entry.amountDelta.formatted(.currency(code: "EUR"))
                            )
                        }
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Beschreibung")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.description ?? "-")
                                .font(.body)
                        }
                        
                        if let docPath = entry.documentURL {
                            Divider()
                            // Build the full public storage URL from the path
                            let storageBase = SupabaseConfig.url
                                .appendingPathComponent("storage/v1/object/public/debt-documents")
                            let fullURL = storageBase.appendingPathComponent(docPath)

                            Link(destination: fullURL) {
                                Label(entry.documentName ?? "Dokument ansehen", systemImage: "doc.text.viewfinder")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.primaryAccent)
                        }
                    }
                    .padding()
                    .liquidGlassCard()
                }
                .padding()
            }
            .navigationTitle("Eintrag Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}

struct DetailRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .bold()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Extensions

extension TimelineEntryType: CaseIterable {
    public static var allCases: [TimelineEntryType] {
        return [.letterReceived, .letterSent, .payment, .fee, .interest, .note, .statusChange, .superseded]
    }
    
    var displayName: String {
        switch self {
        case .letterReceived: return "Brief erhalten"
        case .letterSent: return "Brief gesendet"
        case .payment: return "Zahlung"
        case .fee: return "Gebühr"
        case .interest: return "Zinsen"
        case .note: return "Notiz"
        case .statusChange: return "Statusänderung"
        case .superseded: return "Überschrieben"
        }
    }
    
    var icon: String {
        switch self {
        case .letterReceived: return "envelope.fill"
        case .letterSent: return "paperplane.fill"
        case .payment: return "eurosign.circle.fill"
        case .fee: return "exclamationmark.circle.fill"
        case .interest: return "chart.line.uptrend.xyaxis"
        case .note: return "note.text"
        case .statusChange: return "arrow.left.arrow.right"
        case .superseded: return "doc.on.doc.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .letterReceived: return .blue
        case .letterSent: return .cyan
        case .payment: return .green
        case .fee: return .red
        case .interest: return .orange
        case .note: return .gray
        case .statusChange: return .purple
        case .superseded: return .secondary
        }
    }
}
