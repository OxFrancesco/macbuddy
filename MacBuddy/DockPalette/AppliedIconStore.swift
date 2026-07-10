import Foundation

/// Generation-indexed persistence for icons MacBuddy has successfully
/// applied. The index is the commit point: readers see either the previous
/// complete generation or the new complete generation, never a partial pair.
actor AppliedIconStore {
    nonisolated enum FaultInjection: Equatable, Sendable {
        case beforeRetryStateWrite
        case beforeApplicationEvidenceWrite
        case afterCommitJournalWriteBeforeMove
        case afterGenerationMoveBeforeIndexCommit
        case afterIndexCommitBeforeCleanup
        case afterPreviousGenerationCleanupBeforeJournalRemoval
        case afterCommitCleanupBeforeReturn
        case afterRestoreJournalWriteBeforeReturn
        case afterRestoreIndexCommitBeforeCleanup
        case afterRestoreGenerationCleanupBeforeJournalRemoval
        case afterRestoreCleanupBeforeReturn
    }

    nonisolated struct StagedWrite: Equatable, Sendable {
        let transactionID: String
        let recordID: String
    }

    nonisolated struct RecoverableApplicationIntent: Equatable, Sendable {
        let stage: StagedWrite
        let record: AppliedIconRecord
        let priorCustomIconFingerprint: String?
        let observedAppliedFingerprint: String?
        let recoveryAction: RecoveryAction

        var requiresPreviousIconRestore: Bool {
            recoveryAction == .restorePreviousIcon
        }
    }

    nonisolated enum RecoveryAction: String, Codable, Equatable, Sendable {
        case completeApplication
        case restorePreviousIcon
        case removeUncommittedIcon
    }

    nonisolated struct RestoreTransaction: Codable, Equatable, Sendable {
        nonisolated struct Entry: Codable, Equatable, Sendable {
            let record: AppliedIconRecord
            let generationID: String
        }

        nonisolated enum Phase: String, Codable, Equatable, Sendable {
            case prepared
            case removalVerified
        }

        let schemaVersion: Int
        let id: String
        let path: String
        let entries: [Entry]
        var phase: Phase
        let createdAt: Date
        let retirementSequence: UInt64?
    }

    nonisolated enum StoreError: Error, Equatable, LocalizedError, Sendable {
        case unsupportedSchema(Int)
        case missingRecord(String)
        case invalidStage(String)
        case supersededTransaction(String)
        case iconHashMismatch(String)
        case injectedCrash(FaultInjection)

        var errorDescription: String? {
            switch self {
            case let .unsupportedSchema(version):
                "Unsupported applied-icon store schema \(version)."
            case let .missingRecord(id):
                "Applied-icon record \(id) is missing."
            case let .invalidStage(id):
                "Applied-icon transaction \(id) is incomplete."
            case let .supersededTransaction(id):
                "Applied-icon transaction \(id) was superseded by a newer generation."
            case let .iconHashMismatch(id):
                "The persisted PNG for applied-icon record \(id) is corrupt."
            case let .injectedCrash(point):
                "Applied-icon store fault injected at \(String(describing: point))."
            }
        }
    }

    private nonisolated struct StoreIndex: Codable, Sendable {
        let schemaVersion: Int
        var generations: [String: String]
        var retiredThroughSequence: [String: UInt64]

        static let empty = StoreIndex(
            schemaVersion: AppliedIconRecord.schemaVersion,
            generations: [:],
            retiredThroughSequence: [:]
        )

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case generations
            case retiredThroughSequence
        }

        init(
            schemaVersion: Int,
            generations: [String: String],
            retiredThroughSequence: [String: UInt64]
        ) {
            self.schemaVersion = schemaVersion
            self.generations = generations
            self.retiredThroughSequence = retiredThroughSequence
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            generations = try container.decode(
                [String: String].self,
                forKey: .generations
            )
            retiredThroughSequence = try container.decodeIfPresent(
                [String: UInt64].self,
                forKey: .retiredThroughSequence
            ) ?? [:]
        }
    }

    private nonisolated struct StoredGeneration: Codable, Sendable {
        enum CommitEvidence: String, Codable, Sendable {
            case pendingApplication
            case verifiedApplication
            case metadataOnly
        }

        var record: AppliedIconRecord
        var commitEvidence: CommitEvidence
        let transactionIntent: TransactionIntent?
        var externalWriteIntent: ExternalWriteIntent?
    }

    private nonisolated struct ExternalWriteIntent: Codable, Equatable, Sendable {
        let priorCustomIconFingerprint: String?
        var observedAppliedFingerprint: String?
        var recoveryAction: RecoveryAction
    }

    private nonisolated struct TransactionIntent: Codable, Equatable, Sendable {
        let sequence: UInt64
        let previousGeneration: String?
        let previousSequence: UInt64
    }

    private nonisolated struct TransactionClock: Codable, Sendable {
        let schemaVersion: Int
        let lastIssuedSequence: UInt64
    }

    /// Written before a verified generation leaves staging and removed only
    /// after the index commit. It makes the move/index crash boundary
    /// recoverable without guessing which unindexed generation should win.
    private nonisolated struct CommitJournal: Codable, Sendable {
        let schemaVersion: Int
        let transactionID: String
        let recordID: String
        let previousGeneration: String?
        let preparedAt: TimeInterval
        let representsExternalWrite: Bool
        let transactionIntent: TransactionIntent?
    }

    static let shared = AppliedIconStore()

    private let rootURL: URL
    private let fileManager: FileManager
    private let faultInjection: FaultInjection?

    init(
        rootURL: URL = AppliedIconStore.defaultRootURL,
        fileManager: FileManager = .default,
        faultInjection: FaultInjection? = nil
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.faultInjection = faultInjection
    }

    /// This v1 namespace deliberately does not inspect or import the legacy
    /// path-only UserDefaults entry. An explicit re-apply creates a record.
    nonisolated static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MacBuddy/AppliedIcons/v1", directoryHint: .isDirectory)
    }

    func stageNewApplication(
        pngData: Data,
        path: String,
        metadata: SignedAppMetadata,
        now: Date = .now
    ) throws -> StagedWrite {
        try ensureLayout()
        let existing = try recordsInternal().first {
            $0.lastPath == path
                && $0.bundleIdentifier == metadata.bundleIdentifier
                && $0.signingIdentity.matches(metadata.identity)
        }
        let pending = try existing == nil
            ? pendingRecordForNewApplication(path: path, metadata: metadata)
            : nil
        let record = AppliedIconRecord(
            schemaVersion: AppliedIconRecord.schemaVersion,
            id: existing?.id ?? pending?.id ?? UUID().uuidString.lowercased(),
            lastPath: path,
            bundleIdentifier: metadata.bundleIdentifier,
            signingIdentity: metadata.identity,
            signedRevision: metadata.revision,
            appliedPNG_SHA256: AppliedIconSHA256.hexDigest(pngData),
            customIconFingerprint: "",
            retryState: .ready,
            createdAt: existing?.createdAt ?? pending?.createdAt ?? now,
            updatedAt: now
        )
        return try writeStage(
            record: record,
            pngData: pngData,
            commitEvidence: .pendingApplication
        )
    }

    /// Creates the next record generation before a reconciliation write. The
    /// currently indexed generation remains authoritative until finalize.
    func stageReconciliation(
        record: AppliedIconRecord,
        pngData: Data,
        path: String,
        metadata: SignedAppMetadata,
        now: Date = .now
    ) throws -> StagedWrite {
        guard AppliedIconSHA256.hexDigest(pngData) == record.appliedPNG_SHA256 else {
            throw StoreError.iconHashMismatch(record.id)
        }
        var next = record
        next.lastPath = path
        next.signedRevision = metadata.revision
        next.customIconFingerprint = ""
        next.retryState = .ready
        next.updatedAt = now
        return try writeStage(
            record: next,
            pngData: pngData,
            commitEvidence: .pendingApplication
        )
    }

    /// Records the externally verified setIcon result in the staged
    /// generation. Finalize is intentionally impossible before this step.
    func markExternalWriteIntent(
        _ stage: StagedWrite,
        priorCustomIconFingerprint: String?
    ) throws {
        let url = stagingURL.appending(path: stage.transactionID, directoryHint: .isDirectory)
        var generation = try readGeneration(at: url)
        guard generation.record.id == stage.recordID,
              generation.commitEvidence == .pendingApplication else {
            throw StoreError.invalidStage(stage.transactionID)
        }
        generation.externalWriteIntent = ExternalWriteIntent(
            priorCustomIconFingerprint: priorCustomIconFingerprint,
            observedAppliedFingerprint: nil,
            recoveryAction: generation.transactionIntent?.previousGeneration == nil
                ? .completeApplication
                : .restorePreviousIcon
        )
        try writeJSON(generation, to: url.appending(path: "record.json"))
    }

    func markRollbackRequired(
        _ stage: StagedWrite,
        observedAppliedFingerprint: String?
    ) throws {
        let url = stagingURL.appending(path: stage.transactionID, directoryHint: .isDirectory)
        var generation = try readGeneration(at: url)
        guard generation.record.id == stage.recordID,
              generation.commitEvidence == .pendingApplication,
              var externalWriteIntent = generation.externalWriteIntent else {
            throw StoreError.invalidStage(stage.transactionID)
        }
        externalWriteIntent.observedAppliedFingerprint = observedAppliedFingerprint
        externalWriteIntent.recoveryAction = generation.transactionIntent?.previousGeneration == nil
            ? .removeUncommittedIcon
            : .restorePreviousIcon
        generation.externalWriteIntent = externalWriteIntent
        try writeJSON(generation, to: url.appending(path: "record.json"))
    }

    /// Records the externally verified setIcon result in the staged
    /// generation. Finalize is intentionally impossible before this step.
    func markApplicationSucceeded(
        _ stage: StagedWrite,
        customIconFingerprint: String
    ) throws {
        guard !customIconFingerprint.isEmpty else {
            throw StoreError.invalidStage(stage.transactionID)
        }
        let url = stagingURL.appending(path: stage.transactionID, directoryHint: .isDirectory)
        var generation = try readGeneration(at: url)
        guard generation.record.id == stage.recordID else {
            throw StoreError.invalidStage(stage.transactionID)
        }
        if faultInjection == .beforeApplicationEvidenceWrite {
            throw StoreError.injectedCrash(.beforeApplicationEvidenceWrite)
        }
        generation.record.customIconFingerprint = customIconFingerprint
        generation.record.retryState = .ready
        generation.record.updatedAt = .now
        generation.commitEvidence = .verifiedApplication
        try writeJSON(generation, to: url.appending(path: "record.json"))
    }

    @discardableResult
    func finalize(_ stage: StagedWrite) throws -> AppliedIconRecord {
        try ensureLayout()
        let source = stagingURL.appending(path: stage.transactionID, directoryHint: .isDirectory)

        if !fileManager.fileExists(atPath: source.path(percentEncoded: false)) {
            var index = try loadIndex()
            if index.generations[stage.recordID] == stage.transactionID {
                return try readGeneration(
                    at: recordsURL.appending(path: stage.transactionID, directoryHint: .isDirectory)
                ).record
            }
            if fileManager.fileExists(atPath: journalURL(for: stage.transactionID).path(percentEncoded: false)) {
                _ = try recoverJournal(transactionID: stage.transactionID)
                index = try loadIndex()
                if index.generations[stage.recordID] == stage.transactionID {
                    return try readGeneration(
                        at: recordsURL.appending(path: stage.transactionID, directoryHint: .isDirectory)
                    ).record
                }
            }
            throw StoreError.invalidStage(stage.transactionID)
        }

        let generation = try readGeneration(at: source)
        guard generation.record.id == stage.recordID,
              generation.commitEvidence != .pendingApplication,
              !generation.record.customIconFingerprint.isEmpty else {
            throw StoreError.invalidStage(stage.transactionID)
        }
        let pngData = try Data(contentsOf: source.appending(path: "icon.png"))
        guard AppliedIconSHA256.hexDigest(pngData) == generation.record.appliedPNG_SHA256 else {
            throw StoreError.iconHashMismatch(stage.recordID)
        }

        let index = try loadIndex()
        if try isSuperseded(
            transactionID: stage.transactionID,
            generation: generation,
            index: index
        ) {
            try? fileManager.removeItem(at: source)
            throw StoreError.supersededTransaction(stage.transactionID)
        }
        let journal = CommitJournal(
            schemaVersion: AppliedIconRecord.schemaVersion,
            transactionID: stage.transactionID,
            recordID: stage.recordID,
            previousGeneration: generation.transactionIntent?.previousGeneration
                ?? index.generations[stage.recordID],
            preparedAt: Date().timeIntervalSinceReferenceDate,
            representsExternalWrite: generation.commitEvidence == .verifiedApplication,
            transactionIntent: generation.transactionIntent
        )
        try writeJSON(journal, to: journalURL(for: stage.transactionID))
        if faultInjection == .afterCommitJournalWriteBeforeMove {
            throw StoreError.injectedCrash(.afterCommitJournalWriteBeforeMove)
        }

        let destination = recordsURL.appending(path: stage.transactionID, directoryHint: .isDirectory)
        try fileManager.moveItem(at: source, to: destination)

        if faultInjection == .afterGenerationMoveBeforeIndexCommit {
            throw StoreError.injectedCrash(.afterGenerationMoveBeforeIndexCommit)
        }

        var committedIndex = try loadIndex()
        if try isSuperseded(
            transactionID: stage.transactionID,
            generation: generation,
            index: committedIndex
        ) {
            try? fileManager.removeItem(at: destination)
            try? fileManager.removeItem(at: journalURL(for: stage.transactionID))
            throw StoreError.supersededTransaction(stage.transactionID)
        }
        let previousGeneration = committedIndex.generations[stage.recordID]
        committedIndex.generations[stage.recordID] = stage.transactionID
        committedIndex.retiredThroughSequence.removeValue(forKey: stage.recordID)
        try writeIndex(committedIndex)

        if faultInjection == .afterIndexCommitBeforeCleanup {
            throw StoreError.injectedCrash(.afterIndexCommitBeforeCleanup)
        }

        if let previousGeneration, previousGeneration != stage.transactionID {
            try? fileManager.removeItem(
                at: recordsURL.appending(path: previousGeneration, directoryHint: .isDirectory)
            )
        }
        if faultInjection == .afterPreviousGenerationCleanupBeforeJournalRemoval {
            throw StoreError.injectedCrash(
                .afterPreviousGenerationCleanupBeforeJournalRemoval
            )
        }
        try fileManager.removeItem(at: journalURL(for: stage.transactionID))
        try garbageCollectUnreachableGenerations()
        if faultInjection == .afterCommitCleanupBeforeReturn {
            throw StoreError.injectedCrash(.afterCommitCleanupBeforeReturn)
        }
        return generation.record
    }

    func abort(_ stage: StagedWrite) {
        try? fileManager.removeItem(
            at: stagingURL.appending(path: stage.transactionID, directoryHint: .isDirectory)
        )
    }

    /// Finishes only transactions already durably marked as applied. An
    /// unmarked crash-stage remains unindexed and cannot be mistaken for a
    /// successful application.
    @discardableResult
    func finalizeSucceededStages() throws -> Int {
        try ensureLayout()
        var finalized = try recoverInterruptedCommits()
        let stageURLs = try fileManager.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).sorted { lhs, rhs in
            let lhsSequence = (try? readGeneration(at: lhs).transactionIntent?.sequence) ?? 0
            let rhsSequence = (try? readGeneration(at: rhs).transactionIntent?.sequence) ?? 0
            if lhsSequence == rhsSequence {
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
            return lhsSequence < rhsSequence
        }
        for stageURL in stageURLs {
            guard let generation = try? readGeneration(at: stageURL),
                  generation.commitEvidence != .pendingApplication,
                  !generation.record.customIconFingerprint.isEmpty else { continue }
            let stage = StagedWrite(
                transactionID: stageURL.lastPathComponent,
                recordID: generation.record.id
            )
            do {
                _ = try finalize(stage)
                if generation.commitEvidence == .verifiedApplication {
                    finalized += 1
                }
            } catch {
                // Leave this transaction intact for a later launch while
                // allowing independent completed transactions to recover.
                continue
            }
        }
        try garbageCollectUnreachableGenerations()
        return finalized
    }

    func records() throws -> [AppliedIconRecord] {
        try ensureLayout()
        return try recordsInternal()
    }

    func recoverableApplicationIntents() throws -> [RecoverableApplicationIntent] {
        try ensureLayout()
        let index = try loadIndex()
        let stageURLs = try fileManager.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try stageURLs.compactMap { url in
            let generation = try readGeneration(at: url)
            guard generation.commitEvidence == .pendingApplication,
                  let externalWriteIntent = generation.externalWriteIntent,
                  generation.record.customIconFingerprint.isEmpty else {
                return nil
            }
            if try isSuperseded(
                transactionID: url.lastPathComponent,
                generation: generation,
                index: index
            ) {
                try? fileManager.removeItem(at: url)
                return nil
            }
            let pngData = try Data(contentsOf: url.appending(path: "icon.png"))
            guard AppliedIconSHA256.hexDigest(pngData)
                    == generation.record.appliedPNG_SHA256 else {
                throw StoreError.iconHashMismatch(generation.record.id)
            }
            return RecoverableApplicationIntent(
                stage: StagedWrite(
                    transactionID: url.lastPathComponent,
                    recordID: generation.record.id
                ),
                record: generation.record,
                priorCustomIconFingerprint: externalWriteIntent.priorCustomIconFingerprint,
                observedAppliedFingerprint: externalWriteIntent.observedAppliedFingerprint,
                recoveryAction: externalWriteIntent.recoveryAction
            )
        }.sorted {
            if $0.record.updatedAt == $1.record.updatedAt {
                return $0.stage.transactionID < $1.stage.transactionID
            }
            return $0.record.updatedAt < $1.record.updatedAt
        }
    }

    func hasRestorableState() throws -> Bool {
        try ensureLayout()
        if try !recordsInternal().isEmpty {
            return true
        }
        if try !recoverableApplicationIntents().isEmpty {
            return true
        }
        let stageURLs = try fileManager.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if stageURLs.contains(where: { url in
            guard let generation = try? readGeneration(at: url) else { return false }
            return generation.commitEvidence == .verifiedApplication
                && !generation.record.customIconFingerprint.isEmpty
        }) {
            return true
        }
        let journalURLs = try fileManager.contentsOfDirectory(
            at: journalsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return journalURLs.contains { url in
            guard let journal: CommitJournal = try? readJSON(from: url) else { return false }
            let source = stagingURL.appending(
                path: journal.transactionID,
                directoryHint: .isDirectory
            )
            let destination = recordsURL.appending(
                path: journal.transactionID,
                directoryHint: .isDirectory
            )
            let generationURL = fileManager.fileExists(
                atPath: destination.path(percentEncoded: false)
            ) ? destination : source
            guard let generation = try? readGeneration(at: generationURL),
                  generation.record.id == journal.recordID,
                  generation.commitEvidence == .verifiedApplication,
                  !generation.record.customIconFingerprint.isEmpty,
                  let pngData = try? Data(contentsOf: generationURL.appending(path: "icon.png")) else {
                return false
            }
            return AppliedIconSHA256.hexDigest(pngData)
                == generation.record.appliedPNG_SHA256
        }
    }

    /// Distinguishes ordinary indexed records from incomplete durable work.
    /// Startup uses this after a best-effort pass so a transient per-item
    /// failure does not permanently trip its same-process idempotence guard.
    func hasPendingStartupRecovery() throws -> Bool {
        try ensureLayout()
        if try !pendingRestoreTransactions().isEmpty {
            return true
        }
        if try !fileManager.contentsOfDirectory(
            at: journalsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).isEmpty {
            return true
        }
        return try fileManager.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).contains { url in
            guard let generation = try? readGeneration(at: url) else { return false }
            return generation.commitEvidence != .pendingApplication
                || generation.externalWriteIntent != nil
        }
    }

    func beginRestore(
        recordIDs: [String],
        path: String,
        now: Date = .now
    ) throws -> RestoreTransaction {
        try ensureLayout()
        let requestedIDs = Set(recordIDs)
        if let existing = try pendingRestoreTransactions().first(where: {
            $0.path == path && Set($0.entries.map(\.record.id)) == requestedIDs
        }) {
            return existing
        }
        let index = try loadIndex()
        let entries = try recordIDs.map { recordID -> RestoreTransaction.Entry in
            guard let generationID = index.generations[recordID] else {
                throw StoreError.missingRecord(recordID)
            }
            let record = try readGeneration(
                at: recordsURL.appending(path: generationID, directoryHint: .isDirectory)
            ).record
            return RestoreTransaction.Entry(record: record, generationID: generationID)
        }
        let transaction = RestoreTransaction(
            schemaVersion: AppliedIconRecord.schemaVersion,
            id: UUID().uuidString.lowercased(),
            path: path,
            entries: entries,
            phase: .prepared,
            createdAt: now,
            retirementSequence: try issueTransactionSequence()
        )
        try writeJSON(transaction, to: restoreJournalURL(for: transaction.id))
        if faultInjection == .afterRestoreJournalWriteBeforeReturn {
            throw StoreError.injectedCrash(.afterRestoreJournalWriteBeforeReturn)
        }
        return transaction
    }

    func markRestoreRemovalVerified(_ transaction: RestoreTransaction) throws {
        var stored = try readRestoreTransaction(id: transaction.id)
        guard stored.path == transaction.path,
              stored.entries == transaction.entries else {
            throw StoreError.invalidStage(transaction.id)
        }
        stored.phase = .removalVerified
        try writeJSON(stored, to: restoreJournalURL(for: stored.id))
    }

    func finalizeRestore(_ transaction: RestoreTransaction) throws {
        let stored = try readRestoreTransaction(id: transaction.id)
        guard stored.path == transaction.path,
              stored.entries == transaction.entries,
              stored.phase == .removalVerified else {
            throw StoreError.invalidStage(transaction.id)
        }
        var index = try loadIndex()
        let retirementSequence: UInt64
        if let storedSequence = stored.retirementSequence {
            retirementSequence = storedSequence
        } else {
            retirementSequence = try highestObservedTransactionSequence()
        }
        for entry in stored.entries {
            if let indexedGeneration = index.generations[entry.record.id],
               indexedGeneration != entry.generationID {
                throw StoreError.supersededTransaction(transaction.id)
            }
            index.generations.removeValue(forKey: entry.record.id)
            index.retiredThroughSequence[entry.record.id] = max(
                index.retiredThroughSequence[entry.record.id] ?? 0,
                retirementSequence
            )
        }
        try writeIndex(index)
        if faultInjection == .afterRestoreIndexCommitBeforeCleanup {
            throw StoreError.injectedCrash(.afterRestoreIndexCommitBeforeCleanup)
        }
        for entry in stored.entries {
            try? fileManager.removeItem(
                at: recordsURL.appending(
                    path: entry.generationID,
                    directoryHint: .isDirectory
                )
            )
        }
        if faultInjection == .afterRestoreGenerationCleanupBeforeJournalRemoval {
            throw StoreError.injectedCrash(
                .afterRestoreGenerationCleanupBeforeJournalRemoval
            )
        }
        try fileManager.removeItem(at: restoreJournalURL(for: stored.id))
        if faultInjection == .afterRestoreCleanupBeforeReturn {
            throw StoreError.injectedCrash(.afterRestoreCleanupBeforeReturn)
        }
    }

    func pendingRestoreTransactions() throws -> [RestoreTransaction] {
        try ensureLayout()
        return try fileManager.contentsOfDirectory(
            at: restoreJournalsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).map { url in
            let transaction: RestoreTransaction = try readJSON(from: url)
            guard transaction.schemaVersion == AppliedIconRecord.schemaVersion else {
                throw StoreError.unsupportedSchema(transaction.schemaVersion)
            }
            return transaction
        }.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id < $1.id
            }
            return $0.createdAt < $1.createdAt
        }
    }

    func iconData(for record: AppliedIconRecord) throws -> Data {
        let index = try loadIndex()
        guard let generationID = index.generations[record.id] else {
            throw StoreError.missingRecord(record.id)
        }
        let generationURL = recordsURL.appending(path: generationID, directoryHint: .isDirectory)
        let stored = try readGeneration(at: generationURL).record
        let data = try Data(contentsOf: generationURL.appending(path: "icon.png"))
        guard stored.appliedPNG_SHA256 == record.appliedPNG_SHA256,
              AppliedIconSHA256.hexDigest(data) == stored.appliedPNG_SHA256 else {
            throw StoreError.iconHashMismatch(record.id)
        }
        return data
    }

    func committedRecord(for stage: StagedWrite) throws -> AppliedIconRecord? {
        let index = try loadIndex()
        guard index.generations[stage.recordID] == stage.transactionID else {
            return nil
        }
        let generationURL = recordsURL.appending(
            path: stage.transactionID,
            directoryHint: .isDirectory
        )
        let generation = try readGeneration(at: generationURL)
        let pngData = try Data(contentsOf: generationURL.appending(path: "icon.png"))
        guard generation.record.id == stage.recordID,
              AppliedIconSHA256.hexDigest(pngData)
                == generation.record.appliedPNG_SHA256 else {
            throw StoreError.iconHashMismatch(stage.recordID)
        }
        return generation.record
    }

    func recordSuccessfulRollback(
        recordID: String,
        path: String,
        customIconFingerprint: String,
        now: Date = .now
    ) throws {
        guard !customIconFingerprint.isEmpty else {
            throw StoreError.invalidStage(recordID)
        }
        try mutateRecord(recordID: recordID) { record in
            record.lastPath = path
            record.customIconFingerprint = customIconFingerprint
            record.retryState = .ready
            record.updatedAt = now
        }
    }

    func updateLocation(
        recordID: String,
        path: String,
        now: Date = .now
    ) throws {
        try mutateRecord(recordID: recordID) { record in
            record.lastPath = path
            record.retryState = .ready
            record.updatedAt = now
        }
    }

    /// Called only after the current custom icon fingerprint has been verified
    /// as MacBuddy-owned, so advancing the signed revision cannot mask a lost
    /// icon.
    func acceptObservedRevision(
        recordID: String,
        path: String,
        revision: SignedAppRevision,
        now: Date = .now
    ) throws {
        try mutateRecord(recordID: recordID) { record in
            record.lastPath = path
            record.signedRevision = revision
            record.retryState = .ready
            record.updatedAt = now
        }
    }

    func markRetry(
        recordID: String,
        kind: AppliedIconRetryKind,
        detail: String?,
        path: String? = nil,
        now: Date = .now
    ) throws {
        if faultInjection == .beforeRetryStateWrite {
            throw StoreError.injectedCrash(.beforeRetryStateWrite)
        }
        if kind == .storedIconCorrupt || kind == .restoreNeeded {
            try mutateRecordInPlace(recordID: recordID) { record in
                if let path {
                    record.lastPath = path
                }
                record.retryState = AppliedIconRetryState(
                    kind: kind,
                    detail: detail,
                    lastAttemptAt: now
                )
                record.updatedAt = now
            }
            return
        }
        try mutateRecord(recordID: recordID) { record in
            if let path {
                record.lastPath = path
            }
            record.retryState = AppliedIconRetryState(
                kind: kind,
                detail: detail,
                lastAttemptAt: now
            )
            record.updatedAt = now
        }
    }

    /// A corrupt PNG cannot be copied into a verified next generation. The
    /// retry marker still changes atomically, while the corrupt bytes and
    /// their expected digest remain untouched for diagnosis or replacement.
    private func mutateRecordInPlace(
        recordID: String,
        mutation: (inout AppliedIconRecord) -> Void
    ) throws {
        let index = try loadIndex()
        guard let generationID = index.generations[recordID] else {
            throw StoreError.missingRecord(recordID)
        }
        let generationURL = recordsURL.appending(path: generationID, directoryHint: .isDirectory)
        var generation = try readGeneration(at: generationURL)
        mutation(&generation.record)
        try writeJSON(generation, to: generationURL.appending(path: "record.json"))
    }

    /// Retirement switches the index first, then removes the now-unreachable
    /// generation. A failed icon removal never calls this method.
    func retire(recordID: String) throws {
        try retire(recordIDs: [recordID])
    }

    /// Batch retirement gives Restore Originals one atomic index update for
    /// every record attached to the successfully cleared path.
    func retire(recordIDs: [String]) throws {
        var index = try loadIndex()
        let generationIDs = recordIDs.compactMap { index.generations.removeValue(forKey: $0) }
        guard !generationIDs.isEmpty else { return }
        try writeIndex(index)
        for generationID in generationIDs {
            try? fileManager.removeItem(
                at: recordsURL.appending(path: generationID, directoryHint: .isDirectory)
            )
        }
    }

    private func mutateRecord(
        recordID: String,
        mutation: (inout AppliedIconRecord) -> Void
    ) throws {
        try ensureLayout()
        let index = try loadIndex()
        guard let generationID = index.generations[recordID] else {
            throw StoreError.missingRecord(recordID)
        }
        let currentURL = recordsURL.appending(path: generationID, directoryHint: .isDirectory)
        var generation = try readGeneration(at: currentURL)
        mutation(&generation.record)
        let data = try Data(contentsOf: currentURL.appending(path: "icon.png"))
        let stage = try writeStage(
            record: generation.record,
            pngData: data,
            commitEvidence: .metadataOnly,
            verifyPNG: false
        )
        _ = try finalize(stage)
    }

    /// Completes every verified journal in preparation order. The latest
    /// successfully applied generation therefore wins even if more than one
    /// transaction was interrupted before a subsequent launch.
    private func recoverInterruptedCommits() throws -> Int {
        let journalURLs = try fileManager.contentsOfDirectory(
            at: journalsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let journals = journalURLs.compactMap { url -> CommitJournal? in
            try? readJSON(from: url)
        }.filter {
            $0.schemaVersion == AppliedIconRecord.schemaVersion
        }.sorted {
            let lhsSequence = $0.transactionIntent?.sequence ?? 0
            let rhsSequence = $1.transactionIntent?.sequence ?? 0
            if lhsSequence == rhsSequence, $0.preparedAt == $1.preparedAt {
                return $0.transactionID < $1.transactionID
            }
            if lhsSequence == rhsSequence {
                return $0.preparedAt < $1.preparedAt
            }
            return lhsSequence < rhsSequence
        }

        var recoveredExternalWrites = 0
        for journal in journals {
            do {
                recoveredExternalWrites += try recoverJournal(
                    transactionID: journal.transactionID
                )
            } catch {
                // Keep an incomplete or temporarily unreadable journal for a
                // later launch while recovering independent transactions.
                continue
            }
        }
        return recoveredExternalWrites
    }

    @discardableResult
    private func recoverJournal(transactionID: String) throws -> Int {
        let journal: CommitJournal = try readJSON(from: journalURL(for: transactionID))
        guard journal.schemaVersion == AppliedIconRecord.schemaVersion,
              journal.transactionID == transactionID else {
            throw StoreError.invalidStage(transactionID)
        }

        let source = stagingURL.appending(path: transactionID, directoryHint: .isDirectory)
        let destination = recordsURL.appending(path: transactionID, directoryHint: .isDirectory)
        let destinationExists = fileManager.fileExists(
            atPath: destination.path(percentEncoded: false)
        )
        let sourceExists = fileManager.fileExists(atPath: source.path(percentEncoded: false))

        let generationURL: URL
        if destinationExists {
            generationURL = destination
        } else if sourceExists {
            generationURL = source
        } else {
            throw StoreError.invalidStage(transactionID)
        }
        let generation = try readGeneration(at: generationURL)
        guard generation.record.id == journal.recordID,
              generation.commitEvidence != .pendingApplication,
              !generation.record.customIconFingerprint.isEmpty,
              journal.representsExternalWrite
                == (generation.commitEvidence == .verifiedApplication),
              journal.transactionIntent == generation.transactionIntent else {
            throw StoreError.invalidStage(transactionID)
        }
        let pngData = try Data(contentsOf: generationURL.appending(path: "icon.png"))
        guard AppliedIconSHA256.hexDigest(pngData) == generation.record.appliedPNG_SHA256 else {
            throw StoreError.iconHashMismatch(journal.recordID)
        }

        let currentIndex = try loadIndex()
        if try isSuperseded(
            transactionID: transactionID,
            generation: generation,
            index: currentIndex,
            legacyPreviousGeneration: journal.previousGeneration
        ) {
            if sourceExists {
                try? fileManager.removeItem(at: source)
            }
            if destinationExists {
                try? fileManager.removeItem(at: destination)
            }
            try fileManager.removeItem(at: journalURL(for: transactionID))
            try garbageCollectUnreachableGenerations()
            return 0
        }

        if !destinationExists {
            try fileManager.moveItem(at: source, to: destination)
        }

        var index = try loadIndex()
        if index.generations[journal.recordID] != transactionID {
            let previousGeneration = index.generations[journal.recordID]
            index.generations[journal.recordID] = transactionID
            index.retiredThroughSequence.removeValue(forKey: journal.recordID)
            try writeIndex(index)
            if let previousGeneration, previousGeneration != transactionID {
                try? fileManager.removeItem(
                    at: recordsURL.appending(path: previousGeneration, directoryHint: .isDirectory)
                )
            }
        } else if let previousGeneration = journal.previousGeneration,
                  previousGeneration != transactionID {
            try? fileManager.removeItem(
                at: recordsURL.appending(path: previousGeneration, directoryHint: .isDirectory)
            )
        }

        try fileManager.removeItem(at: journalURL(for: transactionID))
        try garbageCollectUnreachableGenerations()
        return journal.representsExternalWrite ? 1 : 0
    }

    /// An index is the only reader-visible root. Unindexed generations with
    /// no active journal are stale cleanup from a previously completed commit.
    private func garbageCollectUnreachableGenerations() throws {
        let restoreProtected = Set(
            try pendingRestoreTransactions().flatMap { transaction in
                transaction.entries.map(\.generationID)
            }
        )
        let reachable = Set(try loadIndex().generations.values).union(restoreProtected)
        let activeTransactions = Set(
            try fileManager.contentsOfDirectory(
                at: journalsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).map { $0.deletingPathExtension().lastPathComponent }
        )
        let generationURLs = try fileManager.contentsOfDirectory(
            at: recordsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for generationURL in generationURLs
        where !reachable.contains(generationURL.lastPathComponent)
            && !activeTransactions.contains(generationURL.lastPathComponent) {
            try? fileManager.removeItem(at: generationURL)
        }
    }

    private func writeStage(
        record: AppliedIconRecord,
        pngData: Data,
        commitEvidence: StoredGeneration.CommitEvidence,
        verifyPNG: Bool = true
    ) throws -> StagedWrite {
        try ensureLayout()
        if verifyPNG,
           AppliedIconSHA256.hexDigest(pngData) != record.appliedPNG_SHA256 {
            throw StoreError.iconHashMismatch(record.id)
        }
        let transactionID = UUID().uuidString.lowercased()
        let transactionIntent = try makeTransactionIntent(recordID: record.id)
        let directory = stagingURL.appending(path: transactionID, directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            let iconURL = directory.appending(path: "icon.png")
            try pngData.write(to: iconURL, options: .atomic)
            if verifyPNG {
                let persisted = try Data(contentsOf: iconURL)
                guard AppliedIconSHA256.hexDigest(persisted) == record.appliedPNG_SHA256 else {
                    throw StoreError.iconHashMismatch(record.id)
                }
            }
            try writeJSON(
                StoredGeneration(
                    record: record,
                    commitEvidence: commitEvidence,
                    transactionIntent: transactionIntent,
                    externalWriteIntent: nil
                ),
                to: directory.appending(path: "record.json")
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return StagedWrite(transactionID: transactionID, recordID: record.id)
    }

    private func makeTransactionIntent(recordID: String) throws -> TransactionIntent {
        let index = try loadIndex()
        let previousGeneration = index.generations[recordID]
        let previousSequence = try previousGeneration.map(transactionSequence(for:))
            ?? index.retiredThroughSequence[recordID]
            ?? 0
        return TransactionIntent(
            sequence: try issueTransactionSequence(),
            previousGeneration: previousGeneration,
            previousSequence: previousSequence
        )
    }

    private func issueTransactionSequence() throws -> UInt64 {
        let clock: TransactionClock?
        if fileManager.fileExists(atPath: clockURL.path(percentEncoded: false)) {
            clock = try readJSON(from: clockURL)
        } else {
            clock = nil
        }
        if let clock,
           clock.schemaVersion != AppliedIconRecord.schemaVersion {
            throw StoreError.unsupportedSchema(clock.schemaVersion)
        }
        let observedMaximum = try highestObservedTransactionSequence()
        let lastIssued = max(clock?.lastIssuedSequence ?? 0, observedMaximum)
        let (next, overflow) = lastIssued.addingReportingOverflow(1)
        guard !overflow else {
            throw StoreError.invalidStage("transaction-sequence-overflow")
        }
        try writeJSON(
            TransactionClock(
                schemaVersion: AppliedIconRecord.schemaVersion,
                lastIssuedSequence: next
            ),
            to: clockURL
        )
        return next
    }

    private func highestObservedTransactionSequence() throws -> UInt64 {
        let index = try loadIndex()
        var maximum = index.retiredThroughSequence.values.max() ?? 0
        for parent in [recordsURL, stagingURL] {
            let urls = try fileManager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for url in urls {
                maximum = max(
                    maximum,
                    (try? readGeneration(at: url).transactionIntent?.sequence) ?? 0
                )
            }
        }
        let journalURLs = try fileManager.contentsOfDirectory(
            at: journalsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in journalURLs {
            let journal: CommitJournal? = try? readJSON(from: url)
            maximum = max(maximum, journal?.transactionIntent?.sequence ?? 0)
        }
        let restoreJournalURLs = try fileManager.contentsOfDirectory(
            at: restoreJournalsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in restoreJournalURLs {
            let transaction: RestoreTransaction? = try? readJSON(from: url)
            maximum = max(maximum, transaction?.retirementSequence ?? 0)
        }
        return maximum
    }

    private func transactionSequence(for generationID: String) throws -> UInt64 {
        let generationURL = recordsURL.appending(
            path: generationID,
            directoryHint: .isDirectory
        )
        return try readGeneration(at: generationURL).transactionIntent?.sequence ?? 0
    }

    private func isSuperseded(
        transactionID: String,
        generation: StoredGeneration,
        index: StoreIndex,
        legacyPreviousGeneration: String? = nil
    ) throws -> Bool {
        if let retirementSequence = index.retiredThroughSequence[generation.record.id] {
            guard let intent = generation.transactionIntent else {
                return true
            }
            if intent.sequence <= retirementSequence {
                return true
            }
        }
        guard let currentGeneration = index.generations[generation.record.id],
              currentGeneration != transactionID else {
            return false
        }
        guard let intent = generation.transactionIntent else {
            guard currentGeneration == legacyPreviousGeneration else {
                throw StoreError.invalidStage(transactionID)
            }
            return false
        }
        return try transactionSequence(for: currentGeneration) >= intent.sequence
    }

    private func recordsInternal() throws -> [AppliedIconRecord] {
        let index = try loadIndex()
        return try index.generations
            .sorted { $0.key < $1.key }
            .map { _, generationID in
                try readGeneration(
                    at: recordsURL.appending(path: generationID, directoryHint: .isDirectory)
                ).record
            }
    }

    /// A first application has no index entry yet. Reusing the newest durable
    /// pending record ID keeps later explicit attempts in the same monotonic
    /// transaction chain, including when the older generation already moved
    /// behind a commit journal.
    private func pendingRecordForNewApplication(
        path: String,
        metadata: SignedAppMetadata
    ) throws -> AppliedIconRecord? {
        let stagedURLs = try fileManager.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let journaledRecordURLs = try fileManager.contentsOfDirectory(
            at: recordsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter {
            fileManager.fileExists(
                atPath: journalURL(for: $0.lastPathComponent).path(percentEncoded: false)
            )
        }
        var newest: (sequence: UInt64, record: AppliedIconRecord)?
        for url in stagedURLs + journaledRecordURLs {
            guard let generation = try? readGeneration(at: url) else { continue }
            let record = generation.record
            guard record.lastPath == path,
                  record.bundleIdentifier == metadata.bundleIdentifier,
                  record.signingIdentity.matches(metadata.identity) else {
                continue
            }

            let sequence = generation.transactionIntent?.sequence ?? 0
            if let newest, newest.sequence >= sequence { continue }
            newest = (sequence, record)
        }
        return newest?.record
    }

    private func readGeneration(at url: URL) throws -> StoredGeneration {
        let generation: StoredGeneration = try readJSON(from: url.appending(path: "record.json"))
        guard generation.record.schemaVersion == AppliedIconRecord.schemaVersion else {
            throw StoreError.unsupportedSchema(generation.record.schemaVersion)
        }
        return generation
    }

    private func loadIndex() throws -> StoreIndex {
        guard fileManager.fileExists(atPath: indexURL.path(percentEncoded: false)) else {
            return .empty
        }
        let index: StoreIndex = try readJSON(from: indexURL)
        guard index.schemaVersion == AppliedIconRecord.schemaVersion else {
            throw StoreError.unsupportedSchema(index.schemaVersion)
        }
        return index
    }

    private func writeIndex(_ index: StoreIndex) throws {
        try writeJSON(index, to: indexURL)
    }

    private func readJSON<T: Decodable>(from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func ensureLayout() throws {
        try fileManager.createDirectory(at: recordsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: journalsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: restoreJournalsURL,
            withIntermediateDirectories: true
        )
    }

    private var indexURL: URL { rootURL.appending(path: "index.json") }
    private var clockURL: URL { rootURL.appending(path: "transaction-clock.json") }
    private func journalURL(for transactionID: String) -> URL {
        journalsURL.appending(path: transactionID).appendingPathExtension("json")
    }
    private func restoreJournalURL(for transactionID: String) -> URL {
        restoreJournalsURL.appending(path: transactionID).appendingPathExtension("json")
    }
    private func readRestoreTransaction(id: String) throws -> RestoreTransaction {
        let transaction: RestoreTransaction = try readJSON(
            from: restoreJournalURL(for: id)
        )
        guard transaction.schemaVersion == AppliedIconRecord.schemaVersion,
              transaction.id == id else {
            throw StoreError.invalidStage(id)
        }
        return transaction
    }
    private var recordsURL: URL {
        rootURL.appending(path: "records", directoryHint: .isDirectory)
    }
    private var stagingURL: URL {
        rootURL.appending(path: "staging", directoryHint: .isDirectory)
    }
    private var journalsURL: URL {
        rootURL.appending(path: "journals", directoryHint: .isDirectory)
    }
    private var restoreJournalsURL: URL {
        rootURL.appending(path: "restore-journals", directoryHint: .isDirectory)
    }
}
