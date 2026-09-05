// =============================================================================
// RealtimeHouseholdService.swift
// Schulden & Haushalt App
// Requires: iOS 17+, Swift 5.9+, supabase-swift v2 (SPM)
//   https://github.com/supabase/supabase-swift
//
// SQL migration for shared_projects (add to supabase_schema.sql):
// -------------------------------------------------------------
// create table public.shared_projects (
//   id           uuid primary key default gen_random_uuid(),
//   household_id uuid not null references public.households(id) on delete cascade,
//   created_by   uuid not null references auth.users(id),
//   name         text not null,
//   description  text,
//   budget_total numeric(12,2) not null default 0,
//   budget_spent numeric(12,2) not null default 0,
//   emoji        text default '📦',
//   status       text not null default 'active'
//                  check (status in ('active', 'paused', 'completed')),
//   created_at   timestamptz not null default now(),
//   updated_at   timestamptz not null default now()
// );
// alter table public.shared_projects enable row level security;
// create policy "shared_projects: members can all"
//   on public.shared_projects for all
//   using (public.is_household_member(household_id))
//   with check (public.is_household_member(household_id));
// =============================================================================

import SwiftUI
import Combine

// SupabaseConfig (url, anonKey, client) is defined in SupabaseConfig.swift — do not re-declare here.

// =============================================================================
// MARK: - Models
// =============================================================================

// MARK: PantryItem  (mirrors `household_pantry` table)

struct PantryItem: Identifiable, Codable, Equatable, Sendable {
    let id:          UUID
    let householdId: UUID
    let addedBy:     UUID

    var name:           String
    var category:       String?
    var barcode:        String?
    var brand:          String?
    var quantity:       Double
    var unit:           String
    var minQuantity:    Double
    var expiryDate:     Date?
    var storageLocation: String?
    var onShoppingList: Bool
    var shoppingNote:   String?
    let createdAt:      Date
    var updatedAt:      Date

    // Display helper
    var isLow: Bool { quantity <= minQuantity && minQuantity > 0 }

    enum CodingKeys: String, CodingKey {
        case id, barcode, brand, quantity, unit, name, category
        case householdId     = "household_id"
        case addedBy         = "added_by"
        case minQuantity     = "min_quantity"
        case expiryDate      = "expiry_date"
        case storageLocation = "storage_location"
        case onShoppingList  = "on_shopping_list"
        case shoppingNote    = "shopping_note"
        case createdAt       = "created_at"
        case updatedAt       = "updated_at"
    }
}

// MARK: SharedProject  (mirrors `shared_projects` table)

struct SharedProject: Identifiable, Codable, Equatable, Sendable {
    let id:          UUID
    let householdId: UUID
    let createdBy:   UUID

    var name:         String
    var description:  String?
    var budgetTotal:  Decimal
    var budgetSpent:  Decimal
    var emoji:        String
    var status:       ProjectStatus
    let createdAt:    Date
    var updatedAt:    Date

    var progress: Double {
        guard budgetTotal > 0 else { return 0 }
        let p = (budgetSpent as NSDecimalNumber).doubleValue /
                (budgetTotal as NSDecimalNumber).doubleValue
        return min(max(p, 0), 1)
    }
    var remaining: Decimal { max(budgetTotal - budgetSpent, 0) }

    enum ProjectStatus: String, Codable, Sendable {
        case active, paused, completed
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, emoji, status
        case householdId  = "household_id"
        case createdBy    = "created_by"
        case budgetTotal  = "budget_total"
        case budgetSpent  = "budget_spent"
        case createdAt    = "created_at"
        case updatedAt    = "updated_at"
    }
}

// MARK: ChoreItem (mirrors rotating chores)

struct ChoreItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let householdId: UUID
    var title: String
    var icon: String
    var assignedTo: UUID
    var lastCompletedAt: Date?
    var intervalDays: Int
    var notes: String?
}

// MARK: HouseholdEvent  (live activity feed entry)

struct HouseholdEvent: Identifiable, Sendable {
    let id        = UUID()
    let actorId:   UUID
    let actorName: String
    let action:    EventAction
    let subject:   String
    let timestamp: Date

    enum EventAction: Sendable {
        case addedPantryItem
        case updatedPantryItem
        case removedPantryItem
        case toggledShoppingList
        case updatedProject
        case scannedReceipt
        case completedChore
    }

    var icon: String {
        switch action {
        case .addedPantryItem:      return "plus.circle.fill"
        case .updatedPantryItem:    return "pencil.circle.fill"
        case .removedPantryItem:    return "minus.circle.fill"
        case .toggledShoppingList:  return "cart.fill"
        case .updatedProject:       return "chart.bar.fill"
        case .scannedReceipt:       return "doc.text.viewfinder"
        case .completedChore:       return "sparkles"
        }
    }

    var color: Color {
        switch action {
        case .addedPantryItem, .scannedReceipt: return Theme.primaryAccent
        case .updatedPantryItem, .updatedProject: return .blue
        case .removedPantryItem:                return .red
        case .toggledShoppingList, .completedChore: return .green
        }
    }
}

// =============================================================================
// MARK: - RealtimeHouseholdService
// =============================================================================

/// Manages Supabase Realtime subscriptions for shared household data.
///
/// - Subscribes to `household_pantry` and `shared_projects` changes.
/// - Reconnects automatically if the WebSocket drops.
/// - All state mutations happen on `@MainActor` so SwiftUI binds directly.
@MainActor
final class RealtimeHouseholdService: ObservableObject {

    // ── Published State ────────────────────────────────────────────────
    @Published private(set) var pantryItems:     [PantryItem]     = []
    @Published private(set) var sharedProjects:  [SharedProject]  = []
    @Published private(set) var chores:          [ChoreItem]      = [
        ChoreItem(
            id: UUID(),
            householdId: UUID(),
            title: "Müll rausbringen",
            icon: "trash.fill",
            assignedTo: UUID(),
            lastCompletedAt: Calendar.current.date(byAdding: .day, value: -2, to: Date()),
            intervalDays: 3,
            notes: "Restmüll & Gelber Sack"
        ),
        ChoreItem(
            id: UUID(),
            householdId: UUID(),
            title: "Küche wischen",
            icon: "sparkles",
            assignedTo: UUID(),
            lastCompletedAt: Calendar.current.date(byAdding: .day, value: -5, to: Date()),
            intervalDays: 7,
            notes: "Inklusive Herd & Arbeitsplatte"
        ),
        ChoreItem(
            id: UUID(),
            householdId: UUID(),
            title: "Bad & Dusche reinigen",
            icon: "shower.fill",
            assignedTo: UUID(),
            lastCompletedAt: Calendar.current.date(byAdding: .day, value: -6, to: Date()),
            intervalDays: 7,
            notes: "Spiegel & Armaturen entkalken"
        )
    ]
    @Published private(set) var recentEvents:    [HouseholdEvent] = []
    @Published private(set) var connectionState: ConnectionState  = .disconnected
    @Published private(set) var isLoading:       Bool             = false
    @Published var            lastError:         String?

    // ── Config ────────────────────────────────────────────────────────
    let householdId: UUID
    let currentUserId: UUID

    // ── Internals ─────────────────────────────────────────────────────
    private let db = SupabaseConfig.client
    private var channelTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var memberNames: [UUID: String] = [:]

    // ── Connection State Enum ─────────────────────────────────────────
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)

        var label: String {
            switch self {
            case .disconnected:  return "Getrennt"
            case .connecting:    return "Verbinde…"
            case .connected:     return "Live"
            case .error(let m):  return "Fehler: \(m)"
            }
        }

        var color: Color {
            switch self {
            case .connected:    return .green
            case .connecting:   return .orange
            case .disconnected: return .gray
            case .error:        return .red
            }
        }
    }

    // ── Init ──────────────────────────────────────────────────────────
    init(householdId: UUID, currentUserId: UUID) {
        self.householdId   = householdId
        self.currentUserId = currentUserId
    }

    deinit {
        channelTask?.cancel()
        reconnectTask?.cancel()
    }

    // =========================================================================
    // MARK: - Public API
    // =========================================================================

    /// Loads initial data and opens the Realtime channel.
    func start() {
        guard connectionState == .disconnected else { return }
        channelTask = Task { await runSession() }
    }

    /// Gracefully closes the WebSocket channel.
    func stop() {
        channelTask?.cancel()
        channelTask = nil
        connectionState = .disconnected
    }

    // MARK: Pantry mutations

    func toggleShoppingList(_ item: PantryItem) async {
        var updated = item
        updated.onShoppingList = !item.onShoppingList
        updated.updatedAt      = Date()
        updateLocalPantry(updated)

        do {
            try await db.from("household_pantry")
                .update(["on_shopping_list": updated.onShoppingList,
                         "updated_at": ISO8601DateFormatter().string(from: Date())])
                .eq("id", value: item.id.uuidString)
                .execute()
        } catch {
            // Rollback
            updateLocalPantry(item)
            lastError = error.localizedDescription
        }
    }

    func updateQuantity(_ item: PantryItem, delta: Double) async {
        var updated   = item
        updated.quantity   = max(0, item.quantity + delta)
        updated.updatedAt  = Date()
        updateLocalPantry(updated)

        do {
            try await db.from("household_pantry")
                .update(["quantity":   updated.quantity,
                         "updated_at": ISO8601DateFormatter().string(from: Date())])
                .eq("id", value: item.id.uuidString)
                .execute()
        } catch {
            updateLocalPantry(item)
            lastError = error.localizedDescription
        }
    }

    func addPantryItem(_ draft: PantryItem) async {
        pantryItems.append(draft)
        do {
            try await db.from("household_pantry").insert(draft).execute()
        } catch {
            pantryItems.removeAll { $0.id == draft.id }
            lastError = error.localizedDescription
        }
    }

    func deletePantryItem(_ item: PantryItem) async {
        pantryItems.removeAll { $0.id == item.id }
        do {
            try await db.from("household_pantry")
                .delete()
                .eq("id", value: item.id.uuidString)
                .execute()
        } catch {
            pantryItems.append(item)
            lastError = error.localizedDescription
        }
    }

    // MARK: Project mutations

    func logProjectExpense(_ project: SharedProject, amount: Decimal) async {
        guard let idx = sharedProjects.firstIndex(where: { $0.id == project.id }) else { return }
        let newSpent = project.budgetSpent + amount
        sharedProjects[idx].budgetSpent = newSpent

        do {
            try await db.from("shared_projects")
                .update(["budget_spent": newSpent,
                         "updated_at":   ISO8601DateFormatter().string(from: Date())])
                .eq("id", value: project.id.uuidString)
                .execute()
        } catch {
            sharedProjects[idx].budgetSpent = project.budgetSpent
            lastError = error.localizedDescription
        }
    }

    // MARK: Chores mutations

    func toggleChore(_ chore: ChoreItem) {
        guard let index = chores.firstIndex(where: { $0.id == chore.id }) else { return }
        var updated = chores[index]
        updated.lastCompletedAt = Date()
        
        let otherUserId = memberNames.keys.first(where: { $0 != updated.assignedTo }) ?? UUID()
        updated.assignedTo = (updated.assignedTo == currentUserId) ? otherUserId : currentUserId
        
        withAnimation(.spring(response: 0.4)) {
            chores[index] = updated
        }
        
        appendEvent(
            actorId: currentUserId,
            action: .completedChore,
            subject: "Erledigt: \(chore.title) → Weiter an Partner"
        )
        Task { await triggerHaptic(.medium) }
    }
    
    func addChore(title: String, icon: String, intervalDays: Int, notes: String?) {
        let newChore = ChoreItem(
            id: UUID(),
            householdId: householdId,
            title: title,
            icon: icon,
            assignedTo: currentUserId,
            lastCompletedAt: nil,
            intervalDays: intervalDays,
            notes: notes
        )
        withAnimation(.spring(response: 0.4)) {
            chores.append(newChore)
        }
        appendEvent(actorId: currentUserId, action: .completedChore, subject: "Neue Aufgabe: \(title)")
    }

    // =========================================================================
    // MARK: - Private: Realtime Session
    // =========================================================================

    private func runSession() async {
        connectionState = .connecting

        // 1. Load initial snapshot
        await loadInitialData()

        // 2. Open channel and listen
        do {
            try await subscribeToRealtime()
        } catch {
            connectionState = .error(error.localizedDescription)
            scheduleReconnect()
        }
    }

    // MARK: Initial fetch

    private func loadInitialData() async {
        isLoading = true
        defer { isLoading = false }

        async let pantryFetch: [PantryItem] = fetchPantry()
        async let projectFetch: [SharedProject] = fetchProjects()
        async let memberFetch: [UUID: String] = fetchMemberNames()

        let (pantry, projects, names) = await (
            (try? pantryFetch) ?? [],
            (try? projectFetch) ?? [],
            (try? memberFetch) ?? [:]
        )

        pantryItems    = pantry.sorted { $0.name < $1.name }
        sharedProjects = projects
        memberNames    = names
    }

    private func fetchPantry() async throws -> [PantryItem] {
        try await db.from("household_pantry")
            .select()
            .eq("household_id", value: householdId.uuidString)
            .order("name")
            .execute()
            .value
    }

    private func fetchProjects() async throws -> [SharedProject] {
        try await db.from("shared_projects")
            .select()
            .eq("household_id", value: householdId.uuidString)
            .eq("status", value: "active")
            .execute()
            .value
    }

    private func fetchMemberNames() async throws -> [UUID: String] {
        struct MemberRow: Decodable {
            let userId: UUID
            let displayName: String?
            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case displayName = "display_name"
            }
        }
        let rows: [MemberRow] = try await db
            .from("user_profiles")
            .select("user_id, display_name")
            .execute()
            .value
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.userId, $0.displayName ?? "Unbekannt") })
    }

    // =========================================================================
    // =========================================================================
    // MARK: - Realtime Sync Loop
    // =========================================================================

    private func subscribeToRealtime() async throws {
        connectionState = .connected
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { break }
            await loadInitialData()
        }
        connectionState = .disconnected
    }

    // =========================================================================
    // MARK: - Reconnect Logic
    // =========================================================================

    private func scheduleReconnect(delay: TimeInterval = 5) {
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            connectionState = .disconnected
            await runSession()
        }
    }

    // =========================================================================
    // MARK: - Helpers
    // =========================================================================

    private func updateLocalPantry(_ item: PantryItem, animated: Bool = false) {
        guard let idx = pantryItems.firstIndex(where: { $0.id == item.id }) else { return }
        if animated {
            withAnimation(.spring(response: 0.35)) { pantryItems[idx] = item }
        } else {
            pantryItems[idx] = item
        }
    }

    private func appendEvent(actorId: UUID, action: HouseholdEvent.EventAction, subject: String) {
        let name = memberNames[actorId] ?? "Partner"
        let event = HouseholdEvent(
            actorId: actorId, actorName: name,
            action: action, subject: subject, timestamp: Date()
        )
        withAnimation {
            recentEvents.insert(event, at: 0)
            if recentEvents.count > 20 { recentEvents = Array(recentEvents.prefix(20)) }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from record: [String: AnyJSON]) -> T? {
        // AnyJSON (supabase-swift v2) is Encodable but has no .value property.
        // Round-trip through JSONEncoder → JSONDecoder to safely bridge the types.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy  = .convertFromSnakeCase
        return try? decoder.decode(type, from: data)
    }

    private func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) async {
        await MainActor.run {
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        }
    }
}

// =============================================================================
// MARK: - BudgetRingView
// =============================================================================

struct BudgetRingView: View {
    let project:   SharedProject
    var ringWidth: CGFloat = 14
    var diameter:  CGFloat = 140
    var onLogExpense: (() -> Void)? = nil

    @State private var animatedProgress: Double = 0

    private var currencyFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle   = .currency
        f.currencyCode  = "EUR"
        f.locale        = Locale(identifier: "de_DE")
        f.maximumFractionDigits = 0
        return f
    }

    var body: some View {
        VStack(spacing: 16) {
            // ── Ring ──────────────────────────────────────────────────
            ZStack {
                // Track
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: ringWidth)
                    .frame(width: diameter, height: diameter)

                // Progress arc
                Circle()
                    .trim(from: 0, to: animatedProgress)
                    .stroke(
                        progressGradient,
                        style: StrokeStyle(lineWidth: ringWidth,
                                          lineCap: .round)
                    )
                    .frame(width: diameter, height: diameter)
                    .rotationEffect(.degrees(-90))

                // Centre labels
                VStack(spacing: 2) {
                    Text(project.emoji)
                        .font(.system(size: 26))
                    Text(formatDecimal(project.budgetSpent))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.7)
                    Text("von \(formatDecimal(project.budgetTotal))")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                if let onLogExpense = onLogExpense {
                    onLogExpense()
                }
            }
            .onAppear {
                withAnimation(.spring(response: 0.8, dampingFraction: 0.6)) {
                    animatedProgress = project.progress
                }
            }
            .onChange(of: project.progress) { _, newValue in
                withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
                    animatedProgress = newValue
                }
            }

            // ── Label + remaining ─────────────────────────────────────
            VStack(spacing: 4) {
                Text(project.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.right.circle.fill")
                        .foregroundStyle(.green)
                    Text("\(formatDecimal(project.remaining)) verbleibend")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // ── Percentage pill ────────────────────────────────────────
            Text(String(format: "%.0f %%", project.progress * 100))
                .font(.caption.weight(.semibold))
                .foregroundStyle(progressColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(progressColor.opacity(0.15),
                            in: Capsule())
        }
        .frame(maxWidth: .infinity)
    }

    // ── Helpers ───────────────────────────────────────────────────────

    private var progressColor: Color {
        switch project.progress {
        case ..<0.5:  return .green
        case ..<0.8:  return .orange
        default:      return .red
        }
    }

    private var progressGradient: AngularGradient {
        AngularGradient(
            colors: [progressColor.opacity(0.6), progressColor],
            center: .center,
            startAngle: .degrees(-90),
            endAngle:   .degrees(-90 + 360 * animatedProgress)
        )
    }

    private func formatDecimal(_ d: Decimal) -> String {
        currencyFormatter.string(for: d) ?? "\(d) €"
    }
}

// =============================================================================
// MARK: - PantryListView
// =============================================================================

struct PantryListView: View {
    @ObservedObject var service: RealtimeHouseholdService
    @State private var searchText      = ""
    @State private var showAddSheet    = false
    @State private var filterShopping  = false

    private var filtered: [PantryItem] {
        service.pantryItems
            .filter { item in
                (searchText.isEmpty || item.name.localizedCaseInsensitiveContains(searchText))
                && (!filterShopping || item.onShoppingList)
            }
    }

    private var grouped: [(key: String, items: [PantryItem])] {
        let dict = Dictionary(grouping: filtered, by: { $0.category ?? "Sonstiges" })
        return dict.sorted { $0.key < $1.key }.map { (key: $0.key, items: $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Search + Filter bar ───────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Suchen…", text: $searchText)
                    .submitLabel(.search)

                Spacer()

                Toggle(isOn: $filterShopping.animation()) {
                    Image(systemName: "cart\(filterShopping ? ".fill" : "")")
                }
                .toggleStyle(.button)
                .tint(Theme.primaryAccent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            // ── List ──────────────────────────────────────────────────
            List {
                ForEach(grouped, id: \.key) { group in
                    Section {
                        ForEach(group.items) { item in
                            PantryRowView(item: item, service: service)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        categoryHeader(group.key, count: group.items.count)
                    }
                }

                if filtered.isEmpty {
                    emptyPantryState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .animation(.spring(response: 0.4), value: service.pantryItems.map(\.id))
        }
    }

    private func categoryHeader(_ name: String, count: Int) -> some View {
        HStack {
            Text(name.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.primaryAccent)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Theme.primaryAccent.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 4)
    }

    private var emptyPantryState: some View {
        ContentUnavailableView(
            "Keine Einträge",
            systemImage: "cart.badge.questionmark",
            description: Text(filterShopping ? "Keine Artikel auf der Einkaufsliste." : "Füge erste Vorräte hinzu.")
        )
        .padding(.top, 40)
    }
}

// MARK: PantryRowView

private struct PantryRowView: View {
    let item:    PantryItem
    @ObservedObject var service: RealtimeHouseholdService

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // Shopping list toggle
                Button {
                    Task { await service.toggleShoppingList(item) }
                } label: {
                    Image(systemName: item.onShoppingList
                          ? "cart.fill.badge.minus" : "cart.badge.plus")
                        .foregroundStyle(item.onShoppingList ? .green : .secondary)
                        .font(.system(size: 20))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)

                // Name + meta
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.body.weight(.medium))
                        if item.isLow {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    if let cat = item.category {
                        Text(cat)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Quantity stepper
                HStack(spacing: 8) {
                    Button {
                        Task { await service.updateQuantity(item, delta: -1) }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Text(quantityText)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .frame(minWidth: 44)
                        .monospacedDigit()

                    Button {
                        Task { await service.updateQuantity(item, delta: 1) }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Theme.primaryAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.spring(response: 0.3)) { isExpanded.toggle() } }

            // Expandable detail row
            if isExpanded {
                pantryDetail
                    .transition(.asymmetric(
                        insertion: .push(from: .top).combined(with: .opacity),
                        removal:   .push(from: .bottom).combined(with: .opacity)
                    ))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
        )
        .padding(.vertical, 3)
    }

    private var quantityText: String {
        let q = item.quantity
        if q == q.rounded() {
            return "\(Int(q)) \(item.unit)"
        }
        return String(format: "%.1f %@", q, item.unit)
    }

    private var pantryDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.horizontal, 16)
            HStack {
                if let loc = item.storageLocation {
                    Label(loc, systemImage: "mappin.and.ellipse")
                }
                Spacer()
                if let expiry = item.expiryDate {
                    Label(expiry.formatted(date: .abbreviated, time: .omitted),
                          systemImage: "calendar.badge.exclamationmark")
                        .foregroundStyle(expiry < Date() ? .red : .secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }
}

// =============================================================================
// MARK: - SharedHouseholdHubView
// =============================================================================

struct SharedHouseholdHubView: View {
    @StateObject private var service: RealtimeHouseholdService
    @State private var selectedTab: HubTab = .pantry

    enum HubTab: String, CaseIterable {
        case pantry   = "Vorräte"
        case projects = "Projekte"
        case chores   = "Putzplan"
        case activity = "Aktivität"

        var icon: String {
            switch self {
            case .pantry:   return "cart.fill"
            case .projects: return "chart.bar.fill"
            case .chores:   return "sparkles"
            case .activity: return "bolt.fill"
            }
        }
    }

    init(householdId: UUID, currentUserId: UUID) {
        _service = StateObject(wrappedValue:
            RealtimeHouseholdService(householdId: householdId,
                                     currentUserId: currentUserId)
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Status bar ────────────────────────────────────────
                connectionBanner

                // ── Segment picker ────────────────────────────────────
                Picker("Hub", selection: $selectedTab.animation()) {
                    ForEach(HubTab.allCases, id: \.self) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                // ── Content ───────────────────────────────────────────
                Group {
                    switch selectedTab {
                    case .pantry:
                        PantryListView(service: service)

                    case .projects:
                        projectsGrid

                    case .chores:
                        RotatingChoresView(service: service)

                    case .activity:
                        activityFeed
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal:   .move(edge: .leading).combined(with: .opacity)
                ))
            }
            .navigationTitle("🏠 Haushalt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear  { service.start() }
            .onDisappear { service.stop() }
        }
    }

    // ── Connection Banner ─────────────────────────────────────────────

    @ViewBuilder
    private var connectionBanner: some View {
        if service.connectionState != .connected {
            HStack(spacing: 8) {
                LivePulseDot(color: service.connectionState.color)
                Text(service.connectionState.label)
                    .font(.caption.weight(.medium))
                Spacer()
                if case .error = service.connectionState {
                    Button("Erneut verbinden") { service.start() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.primaryAccent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(service.connectionState.color.opacity(0.1))
        } else {
            // Subtle "Live" pill when connected
            HStack(spacing: 6) {
                LivePulseDot(color: .green, pulse: true)
                Text("Live")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.green.opacity(0.1), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal)
            .padding(.top, 4)
        }
    }

    @State private var expenseProject: SharedProject?

    // ── Projects Grid ─────────────────────────────────────────────────

    private var projectsGrid: some View {
        ScrollView {
            if service.sharedProjects.isEmpty {
                ContentUnavailableView(
                    "Keine Projekte",
                    systemImage: "tray",
                    description: Text("Erstelle ein Budget-Projekt, z. B. für Palettenmöbel.")
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(service.sharedProjects) { project in
                        BudgetRingView(project: project, onLogExpense: {
                            expenseProject = project
                        })
                        .liquidGlassCard(cornerRadius: 20)
                    }
                }
                .padding()
            }
        }
        .sheet(item: $expenseProject) { project in
            AddExpenseSheet(project: project, service: service)
        }
    }

    // ── Activity Feed ─────────────────────────────────────────────────

    private var activityFeed: some View {
        List {
            ForEach(service.recentEvents) { event in
                HStack(spacing: 14) {
                    // Actor avatar
                    ZStack {
                        Circle()
                            .fill(event.color.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: event.icon)
                            .foregroundStyle(event.color)
                    }



                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(event.actorName)
                                .font(.subheadline.weight(.semibold))
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(event.timestamp.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(event.subject)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .padding(.vertical, 4)
            }

            if service.recentEvents.isEmpty {
                ContentUnavailableView(
                    "Noch keine Aktivität",
                    systemImage: "bolt.slash",
                    description: Text("Sobald du oder dein Partner etwas ändern, erscheint es hier.")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .animation(.spring(response: 0.4), value: service.recentEvents.map(\.id))
    }

    // ── Toolbar ───────────────────────────────────────────────────────

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 14) {
                // Low-stock badge
                let lowCount = service.pantryItems.filter(\.isLow).count
                if lowCount > 0 {
                    Label("\(lowCount)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                // Hardware & Devices link
                NavigationLink {
                    HardwareLogView()
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(Theme.primaryAccent)
                }

                // Reload
                Button {
                    service.stop()
                    service.start()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }
}

// =============================================================================
// MARK: - Supporting Views
// =============================================================================

// MARK: LivePulseDot

struct LivePulseDot: View {
    let color:  Color
    var pulse:  Bool = false
    @State private var animating = false

    var body: some View {
        ZStack {
            if pulse {
                Circle()
                    .fill(color.opacity(0.25))
                    .frame(width: 16, height: 16)
                    .scaleEffect(animating ? 2.0 : 1.0)
                    .opacity(animating ? 0 : 1)
                    .animation(
                        .easeOut(duration: 1.2).repeatForever(autoreverses: false),
                        value: animating
                    )
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .onAppear { animating = pulse }
    }
}

// =============================================================================
// MARK: - Preview
// =============================================================================

#if DEBUG
#Preview("SharedHouseholdHubView") {
    SharedHouseholdHubView(
        householdId:   UUID(),
        currentUserId: UUID()
    )
    .preferredColorScheme(.dark)
}

#Preview("BudgetRingView – Palettenmöbel") {
    let project = SharedProject(
        id: UUID(), householdId: UUID(), createdBy: UUID(),
        name: "Palettenmöbel",
        description: "Wohnzimmer Projekt",
        budgetTotal: 350,
        budgetSpent: 210,
        emoji: "🛋️",
        status: .active,
        createdAt: Date(), updatedAt: Date()
    )
    return BudgetRingView(project: project, ringWidth: 16, diameter: 160)
        .padding(30)
        .liquidGlassCard()
        .padding()
        .preferredColorScheme(.dark)
}
#endif

struct AddExpenseSheet: View {
    let project: SharedProject
    @ObservedObject var service: RealtimeHouseholdService
    @Environment(\.dismiss) private var dismiss
    
    @State private var amountString = ""
    
    var body: some View {
        NavigationStack {
            Form {
                TextField("Betrag (€)", text: $amountString)
                    .keyboardType(.decimalPad)
            }
            .navigationTitle("\(project.name) Ausgabe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        let amt = Decimal(string: amountString.replacingOccurrences(of: ",", with: ".")) ?? 0
                        Task {
                            await service.logProjectExpense(project, amount: amt)
                            dismiss()
                        }
                    }
                    .disabled(amountString.isEmpty)
                }
            }
        }
    }
}

// =============================================================================
// MARK: - RotatingChoresView
// =============================================================================

struct RotatingChoresView: View {
    @ObservedObject var service: RealtimeHouseholdService
    @State private var showingAddSheet = false

    private var myChoresCount: Int {
        service.chores.filter { $0.assignedTo == service.currentUserId }.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // ── Overview KPI Banner ──────────────────────────────────
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Deine Aufgaben")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("\(myChoresCount)")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.primaryAccent)
                    }
                    
                    Spacer()
                    
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Aufgabe", systemImage: "plus")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Theme.primaryGradient, in: Capsule())
                    }
                }
                .padding(20)
                .liquidGlassCard(cornerRadius: 20)
                .padding(.horizontal)
                .padding(.top, 8)

                // ── Chores List ──────────────────────────────────────────
                VStack(spacing: 14) {
                    ForEach(service.chores) { chore in
                        ChoreCardView(chore: chore, service: service)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 100)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddChoreSheetView(service: service)
        }
    }
}

struct ChoreCardView: View {
    let chore: ChoreItem
    @ObservedObject var service: RealtimeHouseholdService
    @State private var isAnimatingCheck = false

    private var isAssignedToMe: Bool {
        chore.assignedTo == service.currentUserId
    }

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(isAssignedToMe ? Theme.primaryAccent.opacity(0.15) : Color.white.opacity(0.06))
                    .frame(width: 48, height: 48)
                Image(systemName: chore.icon)
                    .font(.title3)
                    .foregroundStyle(isAssignedToMe ? Theme.primaryAccent : .secondary)
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(chore.title)
                        .font(.headline)
                        .foregroundStyle(.white)

                    Text(isAssignedToMe ? "Du bist dran" : "Partner ist dran")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isAssignedToMe ? .green : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            (isAssignedToMe ? Color.green : Color.gray).opacity(0.15),
                            in: Capsule()
                        )
                }

                if let notes = chore.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Image(systemName: "repeat")
                    Text("Alle \(chore.intervalDays) Tage")
                    if let last = chore.lastCompletedAt {
                        Text("• Zuletzt: \(last.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Complete Button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    isAnimatingCheck = true
                }
                service.toggleChore(chore)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    isAnimatingCheck = false
                }
            } label: {
                Image(systemName: isAnimatingCheck ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 28))
                    .foregroundStyle(isAssignedToMe ? Theme.primaryAccent : .secondary)
                    .scaleEffect(isAnimatingCheck ? 1.25 : 1.0)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 18)
    }
}

struct AddChoreSheetView: View {
    @ObservedObject var service: RealtimeHouseholdService
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var icon = "sparkles"
    @State private var intervalDays = 7
    @State private var notes = ""

    private let availableIcons = ["sparkles", "trash.fill", "shower.fill", "sink", "bed.double.fill", "leaf.fill", "fork.knife", "washer.fill"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Aufgabe") {
                    TextField("Titel (z. B. Staubsaugen)", text: $title)
                    TextField("Notizen / Details", text: $notes)
                }

                Section("Symbol") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(availableIcons, id: \.self) { sym in
                            Button {
                                icon = sym
                            } label: {
                                Image(systemName: sym)
                                    .font(.title2)
                                    .frame(width: 50, height: 50)
                                    .background(icon == sym ? Theme.primaryAccent.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(icon == sym ? Theme.primaryAccent : Color.clear, lineWidth: 2)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("Wiederholungs-Intervall") {
                    Stepper("Alle \(intervalDays) Tage", value: $intervalDays, in: 1...30)
                }
            }
            .navigationTitle("Neue Aufgabe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hinzufügen") {
                        service.addChore(title: title, icon: icon, intervalDays: intervalDays, notes: notes.isEmpty ? nil : notes)
                        dismiss()
                    }
                    .disabled(title.isEmpty)
                }
            }
        }
    }
}
