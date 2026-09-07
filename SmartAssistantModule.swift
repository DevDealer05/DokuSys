// =============================================================================
// SmartAssistantModule.swift
// Digitales Büro – Anti-ADHS Fokus-Assistent, Magic Breakdown & Brain Dump
// Requires: iOS 17+, Swift 5.9+, UIKit
// =============================================================================

import SwiftUI
import UIKit

// =============================================================================
// MARK: - 1. Datenmodelle
// =============================================================================

enum TaskCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case work         = "Arbeit & Beruf"
    case finance      = "Finanzen & Post"
    case household    = "Haushalt"
    case bureaucracy  = "Behörden & Recht"
    case personal     = "Persönlich"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .work:        return "briefcase.fill"
        case .finance:     return "creditcard.fill"
        case .household:   return "house.fill"
        case .bureaucracy: return "building.columns.fill"
        case .personal:    return "heart.fill"
        }
    }

    var color: Color {
        switch self {
        case .work:        return .blue
        case .finance:     return .orange
        case .household:   return .green
        case .bureaucracy: return .purple
        case .personal:    return .pink
        }
    }
}

struct FocusSubStep: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var title: String
    var isCompleted: Bool
    var durationMinutes: Int

    init(
        id: UUID = UUID(),
        title: String,
        isCompleted: Bool = false,
        durationMinutes: Int = 3
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.durationMinutes = durationMinutes
    }
}

struct FocusTask: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var title: String
    var category: TaskCategory
    var estimatedMinutes: Int
    var subSteps: [FocusSubStep]
    var isCompleted: Bool
    var snoozedUntil: Date?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        category: TaskCategory = .work,
        estimatedMinutes: Int = 10,
        subSteps: [FocusSubStep] = [],
        isCompleted: Bool = false,
        snoozedUntil: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.estimatedMinutes = estimatedMinutes
        self.subSteps = subSteps
        self.isCompleted = isCompleted
        self.snoozedUntil = snoozedUntil
        self.createdAt = createdAt
    }

    var isSnoozed: Bool {
        guard let s = snoozedUntil else { return false }
        return s > Date()
    }

    var completedStepsCount: Int {
        subSteps.filter { $0.isCompleted }.count
    }

    var progress: Double {
        guard !subSteps.isEmpty else { return isCompleted ? 1.0 : 0.0 }
        return Double(completedStepsCount) / Double(subSteps.count)
    }
}

struct BrainDumpItem: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var rawText: String
    var suggestedCategory: String
    let createdAt: Date
    var isProcessed: Bool

    init(
        id: UUID = UUID(),
        rawText: String,
        suggestedCategory: String = "Gedanke",
        createdAt: Date = Date(),
        isProcessed: Bool = false
    ) {
        self.id = id
        self.rawText = rawText
        self.suggestedCategory = suggestedCategory
        self.createdAt = createdAt
        self.isProcessed = isProcessed
    }
}

// =============================================================================
// MARK: - 2. SmartAssistantService
// =============================================================================

@MainActor
final class SmartAssistantService: ObservableObject {

    @Published var tasks: [FocusTask] = []
    @Published var brainDumpItems: [BrainDumpItem] = []
    @Published var isBreakingDownTask: Bool = false
    @Published var isProcessingDump: Bool = false

    private let tasksStorageKey = "app_adhd_focus_tasks"
    private let brainDumpStorageKey = "app_adhd_brain_dump"

    init() {
        loadPersistedData()
        if tasks.isEmpty {
            seedSampleTasks()
        }
    }

    // ── Persistenz ───────────────────────────────────────────────────────

    private func loadPersistedData() {
        if let data = UserDefaults.standard.data(forKey: tasksStorageKey),
           let list = try? JSONDecoder().decode([FocusTask].self, from: data) {
            self.tasks = list
        }

        if let data = UserDefaults.standard.data(forKey: brainDumpStorageKey),
           let dumps = try? JSONDecoder().decode([BrainDumpItem].self, from: data) {
            self.brainDumpItems = dumps
        }
    }

    private func saveTasks() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: tasksStorageKey)
        }
    }

    private func saveBrainDump() {
        if let data = try? JSONEncoder().encode(brainDumpItems) {
            UserDefaults.standard.set(data, forKey: brainDumpStorageKey)
        }
    }

    private func seedSampleTasks() {
        let sample = [
            FocusTask(
                title: "Post & Unterlagen von heute einscannen",
                category: .finance,
                estimatedMinutes: 5,
                subSteps: [
                    FocusSubStep(title: "Brief öffnen & glatt streichen", isCompleted: false, durationMinutes: 1),
                    FocusSubStep(title: "Kamera-Scanner in der App antippen", isCompleted: false, durationMinutes: 1),
                    FocusSubStep(title: "Dokument speichern", isCompleted: false, durationMinutes: 1)
                ]
            ),
            FocusTask(
                title: "Arbeitszeiten für diese Woche prüfen",
                category: .work,
                estimatedMinutes: 3,
                subSteps: [
                    FocusSubStep(title: "Zeiterfassung öffnen", isCompleted: false, durationMinutes: 1),
                    FocusSubStep(title: "Stundenzettel überfliegen", isCompleted: false, durationMinutes: 2)
                ]
            )
        ]
        self.tasks = sample
        saveTasks()
    }

    // ── Choice Paralysis Killer: Genau EINE aktive Aufgabe ────────────────

    var currentFocusTask: FocusTask? {
        tasks.first(where: { !$0.isCompleted && !$0.isSnoozed })
    }

    var activeTasksCount: Int {
        tasks.filter { !$0.isCompleted && !$0.isSnoozed }.count
    }

    var completedTodayCount: Int {
        tasks.filter { $0.isCompleted }.count
    }

    // ── Aktionen ─────────────────────────────────────────────────────────

    func addTask(title: String, category: TaskCategory = .work, estimatedMinutes: Int = 5) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let newTask = FocusTask(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            estimatedMinutes: estimatedMinutes
        )
        withAnimation(.spring(response: 0.35)) {
            tasks.append(newTask)
        }
        saveTasks()
    }

    func completeTask(_ id: UUID) {
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            // Haptisches Erfolgs-Feedback für Dopamin!
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)

            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                tasks[idx].isCompleted = true
                for sIdx in 0..<tasks[idx].subSteps.count {
                    tasks[idx].subSteps[sIdx].isCompleted = true
                }
            }
            saveTasks()
            AppLogger.shared.info("Fokus-Assistent", "Aufgabe erfolgreich abgeschlossen: \(tasks[idx].title)")
        }
    }

    func toggleSubStep(taskId: UUID, subStepId: UUID) {
        guard let tIdx = tasks.firstIndex(where: { $0.id == taskId }),
              let sIdx = tasks[tIdx].subSteps.firstIndex(where: { $0.id == subStepId }) else { return }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        withAnimation(.spring(response: 0.3)) {
            tasks[tIdx].subSteps[sIdx].isCompleted.toggle()

            // Falls alle Teilschritte fertig sind -> Hauptaufgabe abschließen!
            if tasks[tIdx].subSteps.allSatisfy({ $0.isCompleted }) {
                completeTask(taskId)
            }
        }
        saveTasks()
    }

    func snoozeTaskUntilTomorrow(_ id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // Verschiebe schuldgefühllos auf morgen früh 08:00 Uhr
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let tomorrowMorning = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)

        withAnimation(.spring(response: 0.35)) {
            tasks[idx].snoozedUntil = tomorrowMorning
        }
        saveTasks()
        AppLogger.shared.info("Fokus-Assistent", "Aufgabe ohne Schuldgefühle auf morgen verschoben: \(tasks[idx].title)")
    }

    func deleteTask(_ id: UUID) {
        withAnimation {
            tasks.removeAll(where: { $0.id == id })
        }
        saveTasks()
    }

    // ── Gemini Magic Breakdown: Grosse Aufgaben in 3-Min-Häppchen zerlegen ─

    func magicBreakdown(task: FocusTask, gemini: GeminiService) async {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }

        isBreakingDownTask = true
        let prompt = """
        Aufgabe: "\(task.title)"
        Kategorie: \(task.category.rawValue)

        Du bist ein empathischer ADHS-Assistenz-Coach. Menschen mit ADHS leiden unter Überforderung durch große Hürden.
        Zerlege die obige Aufgabe in maximal 3 bis 4 extrem einfache, mundgerechte Mikroschritte (jeweils 2 bis maximal 5 Minuten Dauer).
        Formuliere jeden Schritt positiv, extrem klar, handlungsorientiert und ermutigend.
        Antworte ZWINGEND nur mit den Aufzählungspunkten (beginnend mit einem Bindestrich '-'), kein Floskeltext vorher oder nachher.
        """

        do {
            let stream = gemini.streamResponse(
                prompt: prompt,
                systemContext: "Du bist ein spezialisierter Coach für neurodivergente Produktivität und ADHS.",
                history: []
            )

            var fullText = ""
            for try await chunk in stream {
                fullText += chunk
            }

            let lines = fullText.components(separatedBy: "\n")
            var newSubSteps: [FocusSubStep] = []

            for l in lines {
                let trimmed = l.replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    newSubSteps.append(FocusSubStep(title: trimmed, durationMinutes: 3))
                }
            }

            await MainActor.run {
                withAnimation(.spring(response: 0.4)) {
                    if !newSubSteps.isEmpty {
                        self.tasks[idx].subSteps = newSubSteps
                    }
                    self.isBreakingDownTask = false
                }
                self.saveTasks()
            }
            AppLogger.shared.info("Magic Breakdown", "Aufgabe '\(task.title)' erfolgreich in \(newSubSteps.count) Teilschritte zerlegt.")
        } catch {
            await MainActor.run {
                // Fallback ohne KI
                withAnimation {
                    self.tasks[idx].subSteps = [
                        FocusSubStep(title: "Platz schaffen & Unterlagen bereitlegen (2 Min)", durationMinutes: 2),
                        FocusSubStep(title: "Den ersten Teilschritt beginnen (3 Min)", durationMinutes: 3),
                        FocusSubStep(title: "Abschließen und kurz durchatmen (1 Min)", durationMinutes: 1)
                    ]
                    self.isBreakingDownTask = false
                }
                self.saveTasks()
            }
        }
    }

    // ── Brain Dump: Gedanken sofort abwerfen & von KI aufräumen lassen ─────

    func addBrainDump(rawText: String) {
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let item = BrainDumpItem(rawText: rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        withAnimation {
            brainDumpItems.insert(item, at: 0)
        }
        saveBrainDump()
    }

    func processBrainDump(text: String, gemini: GeminiService) async {
        guard !text.isEmpty else { return }
        isProcessingDump = true

        let prompt = """
        Hier ist ein ungeordneter Gedankenspeicher (Brain Dump) eines Nutzers mit ADHS:
        "\(text)"

        Analysiere diesen Text. Extrahiere daraus 1 bis 3 konkrete, klare Aufgaben.
        Antworte im Format:
        AUFGABE: [Titel der Aufgabe] | KATEGORIE: [Arbeit ODER Finanzen ODER Haushalt ODER Behörden ODER Persönlich]
        """

        do {
            let stream = gemini.streamResponse(
                prompt: prompt,
                systemContext: "Du bist ein präziser Strukturierungs-Assistent.",
                history: []
            )

            var fullText = ""
            for try await chunk in stream {
                fullText += chunk
            }

            let lines = fullText.components(separatedBy: "\n")
            await MainActor.run {
                for l in lines {
                    if l.contains("AUFGABE:") {
                        let parts = l.components(separatedBy: "|")
                        let taskTitle = parts[0].replacingOccurrences(of: "AUFGABE:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                        var cat: TaskCategory = .work

                        if parts.count > 1 {
                            let catText = parts[1].replacingOccurrences(of: "KATEGORIE:", with: "").lowercased()
                            if catText.contains("finanz") { cat = .finance }
                            else if catText.contains("haus") { cat = .household }
                            else if catText.contains("behörd") { cat = .bureaucracy }
                            else if catText.contains("persön") { cat = .personal }
                        }

                        if !taskTitle.isEmpty {
                            self.addTask(title: taskTitle, category: cat, estimatedMinutes: 5)
                        }
                    }
                }
                self.isProcessingDump = false
            }
        } catch {
            await MainActor.run {
                // Fallback: Als normale Aufgabe anlegen
                self.addTask(title: text, category: .personal, estimatedMinutes: 5)
                self.isProcessingDump = false
            }
        }
    }
}

// =============================================================================
// MARK: - 3. NextSingleActionCard (Homescreen Single-Focus Widget)
// =============================================================================

struct NextSingleActionCard: View {
    @ObservedObject var service: SmartAssistantService
    var gemini: GeminiService
    var onOpenAllTasks: () -> Void

    @State private var showBrainDumpSheet: Bool = false

    init(service: SmartAssistantService, gemini: GeminiService, onOpenAllTasks: @escaping () -> Void = {}) {
        self.service = service
        self.gemini = gemini
        self.onOpenAllTasks = onOpenAllTasks
    }

    var body: some View {
        VStack(spacing: 14) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.primaryAccent)
                    Text("NÄCHSTER EINZEL-FOKUS")
                        .font(.caption2.bold())
                        .foregroundStyle(Theme.primaryAccent)
                }

                Spacer()

                Button {
                    onOpenAllTasks()
                } label: {
                    HStack(spacing: 4) {
                        Text("\(service.activeTasksCount) offen")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            if let task = service.currentFocusTask {
                // Die EINE aktive Aufgabe
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.title)
                                .font(.headline)
                                .foregroundStyle(.white)

                            HStack(spacing: 6) {
                                Label(task.category.rawValue, systemImage: task.category.icon)
                                    .font(.caption2)
                                    .foregroundStyle(task.category.color)
                                Text("•")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("ca. \(task.estimatedMinutes) Min")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        // Erledigt Button
                        Button {
                            service.completeTask(task.id)
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(Color.green)
                        }
                    }

                    // Teilschritte falls vorhanden
                    if !task.subSteps.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(task.subSteps) { step in
                                Button {
                                    service.toggleSubStep(taskId: task.id, subStepId: step.id)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: step.isCompleted ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(step.isCompleted ? .green : .secondary)
                                        Text(step.title)
                                            .font(.caption)
                                            .strikethrough(step.isCompleted)
                                            .foregroundStyle(step.isCompleted ? .secondary : .primary)
                                            .multilineTextAlignment(.leading)
                                        Spacer()
                                        Text("\(step.durationMinutes)m")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    }

                    // Aktionsleiste: Magic Breakdown & Schuldgefühles Snooze
                    HStack(spacing: 8) {
                        if task.subSteps.isEmpty {
                            Button {
                                Task {
                                    await service.magicBreakdown(task: task, gemini: gemini)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    if service.isBreakingDownTask {
                                        ProgressView().tint(.white).scaleEffect(0.8)
                                    } else {
                                        Image(systemName: "wand.and.stars")
                                    }
                                    Text("In Minischritte zerlegen")
                                }
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Theme.primaryGradient, in: Capsule())
                            }
                            .disabled(service.isBreakingDownTask)
                        }

                        Spacer()

                        Button {
                            service.snoozeTaskUntilTomorrow(task.id)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "moon.zzz.fill")
                                Text("Auf morgen")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.white.opacity(0.06), in: Capsule())
                        }
                    }
                }
            } else {
                // Leerer Zustand: Kopf ist frei!
                VStack(spacing: 8) {
                    Image(systemName: "sun.max.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Color.yellow)

                    Text("Kopf ist frei! 🎉")
                        .font(.headline)
                        .foregroundStyle(.white)

                    Text("Keine offenen Aufgaben für den Moment. Genieße die Ruhe oder lade neue Gedanken im Brain Dump ab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            // Schnelltaste für Brain Dump
            Button {
                showBrainDumpSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(Theme.primaryAccent)
                    Text("Gedanken sofort abwerfen (Brain Dump)")
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 18)
        .sheet(isPresented: $showBrainDumpSheet) {
            BrainDumpSheet(service: service, gemini: gemini)
        }
    }
}

// =============================================================================
// MARK: - 4. BrainDumpSheet (Gedankenspeicher)
// =============================================================================

struct BrainDumpSheet: View {
    @ObservedObject var service: SmartAssistantService
    var gemini: GeminiService
    @Environment(\.dismiss) private var dismiss

    @State private var inputText: String = ""

    init(service: SmartAssistantService, gemini: GeminiService) {
        self.service = service
        self.gemini = gemini
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 16) {
                    Text("Gedankenspeicher (Brain Dump)")
                        .font(.headline)

                    Text("Schreib alles auf, was dir gerade durch den Kopf schießt – ohne Ordnung oder Druck. Die KI sortiert es anschließend für dich in handfeste Aufgaben.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $inputText)
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        .frame(minHeight: 180)

                    Spacer()

                    Button {
                        let text = inputText
                        Task {
                            await service.processBrainDump(text: text, gemini: gemini)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if service.isProcessingDump {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(service.isProcessingDump ? "KI sortiert Gedanken…" : "Gedanken abwerfen & sortieren")
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(inputText.isEmpty ? Color.gray : Theme.primaryAccent, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(inputText.isEmpty || service.isProcessingDump)
                }
                .padding(20)
            }
            .navigationTitle("Brain Dump")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }
}

// =============================================================================
// MARK: - 5. AllTasksManagerSheet
// =============================================================================

struct AllTasksManagerSheet: View {
    @ObservedObject var service: SmartAssistantService
    @Environment(\.dismiss) private var dismiss

    @State private var newTaskTitle: String = ""
    @State private var selectedCategory: TaskCategory = .work

    init(service: SmartAssistantService) {
        self.service = service
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        // Neue Aufgabe anlegen
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Neue Aufgabe erfassen")
                                .font(.subheadline.bold())

                            TextField("Aufgabe beschreiben...", text: $newTaskTitle)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

                            Picker("Kategorie", selection: $selectedCategory) {
                                ForEach(TaskCategory.allCases) { cat in
                                    Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                                }
                            }
                            .pickerStyle(.menu)

                            Button {
                                service.addTask(title: newTaskTitle, category: selectedCategory)
                                newTaskTitle = ""
                            } label: {
                                Text("Aufgabe hinzufügen")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Theme.primaryAccent, in: Capsule())
                            }
                            .disabled(newTaskTitle.isEmpty)
                        }
                        .padding(14)
                        .liquidGlassCard(cornerRadius: 16)

                        // Liste aller offenen Aufgaben
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Alle offenen Aufgaben (\(service.tasks.filter { !$0.isCompleted }.count))", systemImage: "checklist")
                                .font(.subheadline.bold())
                                .foregroundStyle(.secondary)

                            ForEach(service.tasks.filter { !$0.isCompleted }) { task in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(task.title)
                                            .font(.subheadline.bold())
                                        HStack(spacing: 6) {
                                            Label(task.category.rawValue, systemImage: task.category.icon)
                                                .font(.caption2)
                                                .foregroundStyle(task.category.color)
                                            if task.isSnoozed {
                                                Text("• Geschlummert bis morgen")
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                    }

                                    Spacer()

                                    Button {
                                        service.completeTask(task.id)
                                    } label: {
                                        Image(systemName: "checkmark.circle")
                                            .font(.title3)
                                            .foregroundStyle(.green)
                                    }

                                    Button {
                                        service.deleteTask(task.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                            .foregroundStyle(.secondary.opacity(0.5))
                                    }
                                }
                                .padding(10)
                                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        .padding(14)
                        .liquidGlassCard(cornerRadius: 16)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Aufgaben-Übersicht")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
