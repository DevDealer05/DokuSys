// =============================================================================
// DebtEngineService.swift
// Schulden & Haushalt App
// Requires: iOS 17+, Swift 5.9+, supabase-swift v2
// =============================================================================

import Foundation
import Combine
import SwiftUI
// MARK: - Supporting Types

// MARK: DebtStatus

enum DebtStatus: String, Codable, Sendable, CaseIterable {
    case active
    case negotiating
    case paid
    case disputed
    case writtenOff = "written_off"

    var displayName: String {
        switch self {
        case .active:      return "Aktiv"
        case .negotiating: return "In Verhandlung"
        case .paid:        return "Bezahlt"
        case .disputed:    return "Streitig"
        case .writtenOff:  return "Abgeschrieben"
        }
    }
}

// MARK: LimitationStatus  (soft — no alarming colours)

enum LimitationStatus: Sendable {
    case withinLimitationPeriod
    case potentiallyExpired(yearsElapsed: Int)

    var hint: String {
        switch self {
        case .withinLimitationPeriod:
            return "Frist läuft noch"
        case .potentiallyExpired(let years):
            return "Möglicherweise verjährt (\(years) J.)"
        }
    }

    var isPotentiallyExpired: Bool {
        if case .potentiallyExpired = self { return true }
        return false
    }
}

// MARK: TimelineEntryType

enum TimelineEntryType: String, Codable, Sendable {
    case letterReceived = "letter_received"
    case letterSent     = "letter_sent"
    case payment        = "payment"
    case fee            = "fee"
    case interest       = "interest"
    case note           = "note"
    case statusChange   = "status_change"
    case superseded     = "superseded"
}

// =============================================================================
// MARK: - Core Models
// =============================================================================

// MARK: DebtTimeline

/// One immutable entry in the audit trail of a debt.
struct DebtTimeline: Identifiable, Codable, Sendable {
    let id:                UUID
    let debtId:            UUID
    let userId:            UUID       // denormalised for RLS; matches Debt.userId
    let entryType:         TimelineEntryType
    let amountDelta:       Decimal    // signed; negative = debt reduction
    let principalSnapshot: Decimal    // currentPrincipal AFTER this entry
    let documentURL:       String?
    let documentName:      String?
    let sender:            String?
    let letterDate:        Date?
    let description:       String?
    let createdAt:         Date

    // ── CodingKeys: map camelCase → snake_case DB columns ─────────────
    enum CodingKeys: String, CodingKey {
        case id
        case debtId            = "debt_id"
        case userId            = "user_id"
        case entryType         = "entry_type"
        case amountDelta       = "amount_delta"
        case principalSnapshot = "principal_snapshot"
        case documentURL       = "document_url"
        case documentName      = "document_name"
        case sender
        case letterDate        = "letter_date"
        case description
        case createdAt         = "created_at"
    }

    init(
        id:                UUID    = UUID(),
        debtId:            UUID,
        userId:            UUID,
        entryType:         TimelineEntryType,
        amountDelta:       Decimal,
        principalSnapshot: Decimal,
        documentURL:       String? = nil,
        documentName:      String? = nil,
        sender:            String? = nil,
        letterDate:        Date?   = nil,
        description:       String? = nil,
        createdAt:         Date    = Date()
    ) {
        self.id                = id
        self.debtId            = debtId
        self.userId            = userId
        self.entryType         = entryType
        self.amountDelta       = amountDelta
        self.principalSnapshot = principalSnapshot
        self.documentURL       = documentURL
        self.documentName      = documentName
        self.sender            = sender
        self.letterDate        = letterDate
        self.description       = description
        self.createdAt         = createdAt
    }
}

// MARK: Debt

/// A single debt / Forderung.
struct Debt: Identifiable, Codable, Sendable {
    let id:     UUID
    let userId: UUID    // FK → auth.users; used for RLS

    /// Aktenzeichen — business key for upsert deduplication.
    /// DB column: case_reference
    let fileNumber: String

    var creditorName:    String
    var creditorIBAN:    String?
    var creditorAddress: String?

    var originalAmount:   Decimal
    /// Always the current authoritative principal — overwritten, never accumulated.
    var currentPrincipal: Decimal

    var interestRatePct: Decimal
    var status:          DebtStatus
    var category:        String?
    var notes:           String?
    var dueDate:         Date?
    var nextPaymentDate: Date?

    /// Date on the *most recent* scanned letter — used for limitation check.
    /// DB column: latest_letter_date
    var latestLetterDate: Date

    var createdAt: Date
    var updatedAt: Date

    // ── CodingKeys: map camelCase → snake_case DB columns ─────────────
    enum CodingKeys: String, CodingKey {
        case id
        case userId           = "user_id"
        case fileNumber       = "case_reference"
        case creditorName     = "creditor_name"
        case creditorIBAN     = "creditor_iban"
        case creditorAddress  = "creditor_address"
        case originalAmount   = "original_amount"
        case currentPrincipal = "current_principal"
        case interestRatePct  = "interest_rate_pct"
        case status
        case category
        case notes
        case dueDate          = "due_date"
        case nextPaymentDate  = "next_payment_date"
        case latestLetterDate = "latest_letter_date"
        case createdAt        = "created_at"
        case updatedAt        = "updated_at"
    }

    // ── Limitation Check ───────────────────────────────────────────────

    private static let limitationYears = 3

    /// Soft limitation status — never an error, never a forced red colour.
    var limitationStatus: LimitationStatus {
        let years = Calendar.current
            .dateComponents([.year], from: latestLetterDate, to: Date())
            .year ?? 0
        return years >= Self.limitationYears
            ? .potentiallyExpired(yearsElapsed: years)
            : .withinLimitationPeriod
    }

    // ── Init ───────────────────────────────────────────────────────────

    init(
        id:               UUID     = UUID(),
        userId:           UUID,
        fileNumber:       String,
        creditorName:     String,
        creditorIBAN:     String?  = nil,
        creditorAddress:  String?  = nil,
        originalAmount:   Decimal,
        currentPrincipal: Decimal,
        interestRatePct:  Decimal  = 0,
        status:           DebtStatus = .active,
        category:         String?  = nil,
        notes:            String?  = nil,
        dueDate:          Date?    = nil,
        nextPaymentDate:  Date?    = nil,
        latestLetterDate: Date     = Date(),
        createdAt:        Date     = Date(),
        updatedAt:        Date     = Date()
    ) {
        self.id               = id
        self.userId           = userId
        self.fileNumber       = fileNumber
        self.creditorName     = creditorName
        self.creditorIBAN     = creditorIBAN
        self.creditorAddress  = creditorAddress
        self.originalAmount   = originalAmount
        self.currentPrincipal = currentPrincipal
        self.interestRatePct  = interestRatePct
        self.status           = status
        self.category         = category
        self.notes            = notes
        self.dueDate          = dueDate
        self.nextPaymentDate  = nextPaymentDate
        self.latestLetterDate = latestLetterDate
        self.createdAt        = createdAt
        self.updatedAt        = updatedAt
    }
}

// =============================================================================
// MARK: - ScanResult  (input DTO)
// =============================================================================

struct ScanResult: Sendable {
    let fileNumber:  String
    let amount:      Decimal
    let letterDate:  Date
    var creditorName: String?
    var creditorIBAN: String?
    var documentURL:  String?
    var documentName: String?
    var sender:       String?
}

// =============================================================================
// MARK: - ProcessScanOutcome  (output DTO)
// =============================================================================

enum ProcessScanOutcome: Sendable {
    case created(debt: Debt)
    case updated(debt: Debt, delta: Decimal, timelineEntry: DebtTimeline)
    case unchanged(debt: Debt)
}

// =============================================================================
// MARK: - DebtEngineService
// =============================================================================

@MainActor
final class DebtEngineService: ObservableObject {

    // ── Published State ────────────────────────────────────────────────
    @Published private(set) var debts:     [Debt]               = []
    @Published private(set) var timelines: [UUID: [DebtTimeline]] = [:]
    @Published private(set) var isLoading: Bool                 = false
    @Published var            lastError:   DebtEngineError?

    // ── Identity & network ─────────────────────────────────────────────
    let currentUserId: UUID
    private let db = SupabaseConfig.client

    enum DebtEngineError: LocalizedError, Sendable {
        case invalidAmount(String)
        case invalidFileNumber
        case persistenceFailed(underlying: String)

        var errorDescription: String? {
            switch self {
            case .invalidAmount(let ctx):  return "Ungültiger Betrag: \(ctx)"
            case .invalidFileNumber:       return "Aktenzeichen darf nicht leer sein."
            case .persistenceFailed(let m): return "Speicherfehler: \(m)"
            }
        }
    }

    init(userId: UUID) {
        self.currentUserId = userId
        if let localDebts = StorageService.shared.loadDebts(userId: userId) {
            self.debts = localDebts
        }
        if let localTimelines = StorageService.shared.loadTimelines(userId: userId) {
            self.timelines = localTimelines
        }
    }

    // =========================================================================
    // MARK: - processNewScan  (core upsert — amount OVERWRITE, never add)
    // =========================================================================

    @discardableResult
    func processNewScan(_ scan: ScanResult) throws -> ProcessScanOutcome {
        let fn = scan.fileNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fn.isEmpty else {
            lastError = .invalidFileNumber; throw DebtEngineError.invalidFileNumber
        }
        guard scan.amount >= 0 else {
            let e = DebtEngineError.invalidAmount("Betrag darf nicht negativ sein.")
            lastError = e; throw e
        }
        if let idx = debts.firstIndex(where: {
            $0.fileNumber.caseInsensitiveCompare(fn) == .orderedSame
        }) {
            return try overwriteExisting(at: idx, with: scan)
        }
        return createNew(from: scan, fileNumber: fn)
    }

    @discardableResult
    func processNewScan(
        fileNumber: String,
        amount: Decimal,
        date: Date,
        creditorName: String? = nil
    ) throws -> ProcessScanOutcome {
        try processNewScan(ScanResult(
            fileNumber: fileNumber, amount: amount, letterDate: date,
            creditorName: creditorName))
    }

    // =========================================================================
    // MARK: - Private: mutation paths
    // =========================================================================

    private func overwriteExisting(at index: Int, with scan: ScanResult) throws -> ProcessScanOutcome {
        var debt = debts[index]
        let oldPrincipal = debt.currentPrincipal
        guard scan.amount != oldPrincipal else { return .unchanged(debt: debt) }

        let delta = scan.amount - oldPrincipal
        let entry = DebtTimeline(
            debtId:            debt.id,
            userId:            currentUserId,
            entryType:         .superseded,
            amountDelta:       delta,
            principalSnapshot: scan.amount,
            documentURL:       scan.documentURL,
            documentName:      scan.documentName,
            sender:            scan.sender,
            letterDate:        scan.letterDate,
            description:       buildSupersededDescription(old: oldPrincipal, new: scan.amount, delta: delta)
        )
        appendTimelineEntry(entry, for: debt.id)

        debt.currentPrincipal = scan.amount
        debt.latestLetterDate = scan.letterDate
        if let name = scan.creditorName, !name.isEmpty { debt.creditorName = name }
        if let iban = scan.creditorIBAN                { debt.creditorIBAN = iban }
        debt.updatedAt = Date()
        debts[index] = debt

        Task { await persistDebt(debt) }
        Task { await persistTimeline(entry) }

        return .updated(debt: debt, delta: delta, timelineEntry: entry)
    }

    private func createNew(from scan: ScanResult, fileNumber: String) -> ProcessScanOutcome {
        let debt = Debt(
            userId:           currentUserId,
            fileNumber:       fileNumber,
            creditorName:     scan.creditorName ?? "Unbekannt",
            creditorIBAN:     scan.creditorIBAN,
            originalAmount:   scan.amount,
            currentPrincipal: scan.amount,
            latestLetterDate: scan.letterDate
        )
        debts.append(debt)

        let entry = DebtTimeline(
            debtId:            debt.id,
            userId:            currentUserId,
            entryType:         .letterReceived,
            amountDelta:       scan.amount,
            principalSnapshot: scan.amount,
            documentURL:       scan.documentURL,
            documentName:      scan.documentName,
            sender:            scan.sender,
            letterDate:        scan.letterDate,
            description:       "Erster Scan / manueller Eintrag (AZ: \(fileNumber))"
        )
        appendTimelineEntry(entry, for: debt.id)

        Task { await persistDebt(debt) }
        Task { await persistTimeline(entry) }

        return .created(debt: debt)
    }

    // =========================================================================
    // MARK: - Computed Properties
    // =========================================================================

    var potentiallyExpiredDebts: [Debt] {
        debts.filter { $0.limitationStatus.isPotentiallyExpired }
    }

    var totalActivePrincipal: Decimal {
        debts
            .filter { $0.status == .active || $0.status == .negotiating }
            .reduce(.zero) { $0 + $1.currentPrincipal }
    }

    func timeline(for debtId: UUID) -> [DebtTimeline] {
        (timelines[debtId] ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    // =========================================================================
    // MARK: - Public Mutators
    // =========================================================================

    func addTimelineEntry(_ entry: DebtTimeline) {
        guard debts.contains(where: { $0.id == entry.debtId }) else { return }
        appendTimelineEntry(entry, for: entry.debtId)
        if entry.entryType == .payment,
           let idx = debts.firstIndex(where: { $0.id == entry.debtId }) {
            debts[idx].currentPrincipal = max(0, debts[idx].currentPrincipal + entry.amountDelta)
            debts[idx].updatedAt = Date()
            let d = debts[idx]
            Task { await persistDebt(d) }
        }
        Task { await persistTimeline(entry) }
    }

    func updateDebtStatus(_ debtId: UUID, newStatus: DebtStatus) {
        guard let idx = debts.firstIndex(where: { $0.id == debtId }) else { return }
        let old = debts[idx].status
        debts[idx].status    = newStatus
        debts[idx].updatedAt = Date()
        let debt = debts[idx]

        let entry = DebtTimeline(
            debtId:            debtId,
            userId:            currentUserId,
            entryType:         .statusChange,
            amountDelta:       0,
            principalSnapshot: debt.currentPrincipal,
            description:       "Status: \(old.displayName) → \(newStatus.displayName)"
        )
        appendTimelineEntry(entry, for: debtId)

        Task { await persistDebt(debt) }
        Task { await persistTimeline(entry) }
    }

    func deleteDebt(_ debtId: UUID) {
        debts.removeAll { $0.id == debtId }
        timelines.removeValue(forKey: debtId)
        Task { await deleteDebtFromDB(debtId) }
    }

    // =========================================================================
    // MARK: - Persistence  (Supabase)
    // =========================================================================

    /// Fetches all debts and their timeline entries for the current user.
    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let fetchedDebts: [Debt] = try await db
                .from("debts")
                .select()
                .eq("user_id", value: currentUserId.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value

            let fetchedTimeline: [DebtTimeline] = try await db
                .from("debt_timeline")
                .select()
                .eq("user_id", value: currentUserId.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value

            debts = fetchedDebts
            // Re-build the timelines dictionary keyed by debt_id
            var tl = [UUID: [DebtTimeline]]()
            for entry in fetchedTimeline {
                tl[entry.debtId, default: []].append(entry)
            }
            timelines = tl

            StorageService.shared.saveDebts(debts, userId: currentUserId)
            StorageService.shared.saveTimelines(timelines, userId: currentUserId)
        } catch {
            lastError = .persistenceFailed(underlying: error.localizedDescription)
            if debts.isEmpty, let local = StorageService.shared.loadDebts(userId: currentUserId) {
                debts = local
            }
            if timelines.isEmpty, let localTl = StorageService.shared.loadTimelines(userId: currentUserId) {
                timelines = localTl
            }
        }
    }

    // MARK: Private persist helpers (fire-and-forget via Task)

    private func persistDebt(_ debt: Debt) async {
        do {
            try await db
                .from("debts")
                .upsert(debt, onConflict: "id")
                .execute()
        } catch {
            await MainActor.run {
                self.lastError = .persistenceFailed(underlying: error.localizedDescription)
            }
        }
    }

    private func persistTimeline(_ entry: DebtTimeline) async {
        do {
            try await db
                .from("debt_timeline")
                .insert(entry)
                .execute()
        } catch {
            await MainActor.run {
                self.lastError = .persistenceFailed(underlying: error.localizedDescription)
            }
        }
    }

    private func deleteDebtFromDB(_ id: UUID) async {
        do {
            try await db
                .from("debts")
                .delete()
                .eq("id", value: id.uuidString)
                .execute()
            // Cascade in DB will delete associated debt_timeline rows automatically
        } catch {
            await MainActor.run {
                self.lastError = .persistenceFailed(underlying: error.localizedDescription)
            }
        }
    }

    // =========================================================================
    // MARK: - Private Helpers
    // =========================================================================

    private func appendTimelineEntry(_ entry: DebtTimeline, for debtId: UUID) {
        timelines[debtId, default: []].append(entry)
    }

    private func buildSupersededDescription(old: Decimal, new: Decimal, delta: Decimal) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle   = .currency
        fmt.currencyCode  = "EUR"
        fmt.locale        = Locale(identifier: "de_DE")
        let o   = fmt.string(for: old)       ?? "\(old) €"
        let n   = fmt.string(for: new)       ?? "\(new) €"
        let abs = fmt.string(for: Swift.abs(delta)) ?? "\(Swift.abs(delta)) €"
        let sign = delta > 0 ? "+" : "−"
        return "Betrag überschrieben: \(o) → \(n) (Δ \(sign)\(abs))"
    }
}
