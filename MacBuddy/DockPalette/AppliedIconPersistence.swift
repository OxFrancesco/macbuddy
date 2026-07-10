import CoreGraphics
import Foundation
import ImageIO

nonisolated protocol AppliedIconWriting: Sendable {
    func apply(pngData: Data, toAppAt path: String) async -> Bool
    func removeCustomIcon(atAppPath path: String) async -> Bool
}

nonisolated protocol AppliedIconInspecting: Sendable {
    func state(
        atAppPath path: String,
        expectedFingerprint: String
    ) async -> ObservedCustomIconState
    func fingerprintIfPresent(atAppPath path: String) async throws -> String?
}

nonisolated protocol AppliedIconCandidateProviding: Sendable {
    func candidate(at path: String) -> AppliedIconCandidate?
    func dockCandidates() -> [AppliedIconCandidate]
}

nonisolated protocol AppliedIconDockRefreshing: Sendable {
    func refreshDock() async
}

nonisolated protocol AppliedIconPathChecking: Sendable {
    func fileExists(atPath path: String) -> Bool
}

extension AppliedIconCandidateScanner: AppliedIconCandidateProviding {}

nonisolated struct WorkspaceAppliedIconWriter: AppliedIconWriting {
    func apply(pngData: Data, toAppAt path: String) async -> Bool {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return false
        }
        let bitmap = IconBitmap(image: image)
        return await MainActor.run {
            DockIconApplier.apply(bitmap, toAppAt: path)
        }
    }

    func removeCustomIcon(atAppPath path: String) async -> Bool {
        await MainActor.run {
            DockIconApplier.removeCustomIcon(atAppPath: path)
        }
    }
}

nonisolated struct FinderAppliedIconInspector: AppliedIconInspecting {
    func state(
        atAppPath path: String,
        expectedFingerprint: String
    ) async -> ObservedCustomIconState {
        CustomIconInspector.state(
            atAppPath: path,
            expectedFingerprint: expectedFingerprint
        )
    }

    func fingerprintIfPresent(atAppPath path: String) async throws -> String? {
        try CustomIconInspector.fingerprintIfPresent(atAppPath: path)
    }
}

nonisolated struct ProcessAppliedIconDockRefresher: AppliedIconDockRefreshing {
    func refreshDock() async {
        await MainActor.run {
            DockIconApplier.relaunchDock()
        }
    }
}

nonisolated struct FileSystemAppliedIconPathChecker: AppliedIconPathChecking {
    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

private actor AppliedIconOperationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}

/// Coordinates the two-phase filesystem store with NSWorkspace's external
/// custom-icon write. It owns no SwiftUI state, so startup reconciliation does
/// not depend on opening Dock Palette.
actor AppliedIconPersistence {
    nonisolated enum FaultInjection: Equatable, Sendable {
        case afterExternalIconWrite
        case afterExternalIconRemoval
    }

    nonisolated struct RestoreResult: Sendable {
        let remainingLegacyPaths: [String]
        let restoredCount: Int
        let failedPaths: [String]
    }

    nonisolated struct ApplyRequest: Sendable {
        let pngData: Data
        let path: String
    }

    nonisolated struct ApplyOutcome: Equatable, Sendable {
        let succeeded: Bool
        let didMutateIcon: Bool
    }

    static let shared = AppliedIconPersistence()

    private let store: AppliedIconStore
    private let metadataReader: any SignedAppMetadataReading
    private let iconWriter: any AppliedIconWriting
    private let customIconInspector: any AppliedIconInspecting
    private let candidateProvider: any AppliedIconCandidateProviding
    private let dockRefresher: any AppliedIconDockRefreshing
    private let pathChecker: any AppliedIconPathChecking
    private let faultInjection: FaultInjection?
    private let operationGate = AppliedIconOperationGate()
    private var didReconcileAtStartup = false

    init(
        store: AppliedIconStore = .shared,
        metadataReader: any SignedAppMetadataReading = SecuritySignedAppMetadataReader(),
        iconWriter: any AppliedIconWriting = WorkspaceAppliedIconWriter(),
        customIconInspector: any AppliedIconInspecting = FinderAppliedIconInspector(),
        candidateProvider: (any AppliedIconCandidateProviding)? = nil,
        dockRefresher: any AppliedIconDockRefreshing = ProcessAppliedIconDockRefresher(),
        pathChecker: any AppliedIconPathChecking = FileSystemAppliedIconPathChecker(),
        faultInjection: FaultInjection? = nil
    ) {
        self.store = store
        self.metadataReader = metadataReader
        self.iconWriter = iconWriter
        self.customIconInspector = customIconInspector
        if let candidateProvider {
            self.candidateProvider = candidateProvider
        } else {
            self.candidateProvider = AppliedIconCandidateScanner(metadataReader: metadataReader)
        }
        self.dockRefresher = dockRefresher
        self.pathChecker = pathChecker
        self.faultInjection = faultInjection
    }

    /// Persists and verifies the exact PNG before setIcon, then commits its
    /// record only after setIcon and the resulting Icon\r artifact both
    /// succeed.
    func apply(_ bitmap: IconBitmap, toAppAt path: String) async -> Bool {
        guard let pngData = IconPNG.data(from: bitmap.image) else { return false }
        return await applyPNGData(pngData, toAppAt: path)
    }

    /// Testable byte-level entry point. Production still enters through the
    /// bitmap overload; both paths stage and later apply the identical bytes.
    func applyPNGData(_ pngData: Data, toAppAt path: String) async -> Bool {
        await operationGate.acquire()
        let outcome = await applyPNGDataWhileLocked(pngData, toAppAt: path)
        await operationGate.release()
        return outcome.succeeded
    }

    /// Applies a user-requested batch and refreshes Dock once when any
    /// external write occurred, including compensating rollback writes or
    /// removals from applications that did not durably succeed.
    func applyPNGBatch(_ requests: [ApplyRequest]) async -> [ApplyOutcome] {
        await operationGate.acquire()
        var outcomes: [ApplyOutcome] = []
        outcomes.reserveCapacity(requests.count)
        for request in requests {
            outcomes.append(await applyPNGDataWhileLocked(
                request.pngData,
                toAppAt: request.path
            ))
        }
        if outcomes.contains(where: \.didMutateIcon) {
            await dockRefresher.refreshDock()
        }
        await operationGate.release()
        return outcomes
    }

    private func applyPNGDataWhileLocked(
        _ pngData: Data,
        toAppAt path: String
    ) async -> ApplyOutcome {
        guard let metadata = try? metadataReader.metadata(forAppAt: path),
              let stage = try? await store.stageNewApplication(
                pngData: pngData,
                path: path,
                metadata: metadata
              ) else {
            return ApplyOutcome(succeeded: false, didMutateIcon: false)
        }
        let priorPNGData = await priorPNGData(recordID: stage.recordID)
        guard await prepareExternalWrite(stage, at: path) else {
            return ApplyOutcome(succeeded: false, didMutateIcon: false)
        }

        let applied = await iconWriter.apply(pngData: pngData, toAppAt: path)
        guard applied else {
            let rollbackMutatedIcon = await rollBackUncommittedApplication(
                stage,
                path: path,
                detail: "NSWorkspace could not apply the replacement icon.",
                priorPNGData: priorPNGData,
                observedAppliedFingerprint: nil
            )
            return ApplyOutcome(
                succeeded: false,
                didMutateIcon: rollbackMutatedIcon
            )
        }
        if faultInjection == .afterExternalIconWrite {
            return ApplyOutcome(succeeded: false, didMutateIcon: true)
        }

        let fingerprint: String
        do {
            guard let observed = try await customIconInspector.fingerprintIfPresent(atAppPath: path) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            fingerprint = observed
        } catch {
            _ = await rollBackUncommittedApplication(
                stage,
                path: path,
                detail: error.localizedDescription,
                priorPNGData: priorPNGData,
                observedAppliedFingerprint: nil
            )
            return ApplyOutcome(succeeded: false, didMutateIcon: true)
        }

        do {
            try await store.markApplicationSucceeded(stage, customIconFingerprint: fingerprint)
        } catch {
            _ = await rollBackUncommittedApplication(
                stage,
                path: path,
                detail: error.localizedDescription,
                priorPNGData: priorPNGData,
                observedAppliedFingerprint: fingerprint
            )
            return ApplyOutcome(succeeded: false, didMutateIcon: true)
        }

        do {
            _ = try await store.finalize(stage)
            return ApplyOutcome(succeeded: true, didMutateIcon: true)
        } catch {
            // A committed index is durable success even if cleanup or the
            // return boundary failed. Otherwise the verified stage or journal
            // remains the recovery source and must not be rolled back.
            return ApplyOutcome(
                succeeded: (try? await store.committedRecord(for: stage)) != nil,
                didMutateIcon: true
            )
        }
    }

    /// Idempotent per process and by policy: revision advancement happens only
    /// after verified ownership or a committed restoration, so rerunning after
    /// any failure repeats no successful external write.
    func reconcileAtStartupIfNeeded() async {
        await operationGate.acquire()
        await reconcileAtStartupWhileLocked()
        await operationGate.release()
    }

    private func reconcileAtStartupWhileLocked() async {
        guard !didReconcileAtStartup else { return }

        let dockCandidates = candidateProvider.dockCandidates()
        var successfulBatchWrites = 0
        let records: [AppliedIconRecord]
        let pendingRestoreIDs: Set<String>
        do {
            successfulBatchWrites += try await recoverPendingRestores(
                dockCandidates: dockCandidates
            )
            successfulBatchWrites += try await store.finalizeSucceededStages()
            successfulBatchWrites += try await recoverExternalWriteIntents(
                dockCandidates: dockCandidates
            )
            records = try await store.records()
            pendingRestoreIDs = Set(
                try await store.pendingRestoreTransactions()
                    .flatMap { $0.entries.map(\.record.id) }
            )
        } catch {
            if successfulBatchWrites > 0 {
                await dockRefresher.refreshDock()
            }
            return
        }

        for record in records where !pendingRestoreIDs.contains(record.id) {
            let lastPathCandidate = dockCandidates.first { $0.path == record.lastPath }
                ?? candidateProvider.candidate(at: record.lastPath)
            switch AppliedIconResolver.resolve(
                record: record,
                lastPathCandidate: lastPathCandidate,
                dockCandidates: dockCandidates
            ) {
            case .missing:
                try? await store.markRetry(
                    recordID: record.id,
                    kind: .appMissing,
                    detail: "The app is not currently present in the Dock."
                )
            case .ambiguous:
                try? await store.markRetry(
                    recordID: record.id,
                    kind: .ambiguousCandidates,
                    detail: "More than one Dock app matches this signed identity."
                )
            case .signingMetadataUnavailable:
                try? await store.markRetry(
                    recordID: record.id,
                    kind: .signingMetadataUnavailable,
                    detail: "A possible app match could not be signature-validated."
                )
            case let .resolved(path, metadata, _):
                let customIcon = await customIconInspector.state(
                    atAppPath: path,
                    expectedFingerprint: record.customIconFingerprint
                )
                let decision = AppliedIconReconciliationStateMachine.decide(
                    record: record,
                    path: path,
                    metadata: metadata,
                    customIcon: customIcon
                )
                switch decision {
                case .noAction:
                    if record.retryState.kind != .ready {
                        try? await store.updateLocation(recordID: record.id, path: path)
                    }
                case .updateLocation:
                    try? await store.updateLocation(recordID: record.id, path: path)
                case .acceptObservedRevision:
                    try? await store.acceptObservedRevision(
                        recordID: record.id,
                        path: path,
                        revision: metadata.revision
                    )
                case .restoreAppliedIcon:
                    if await restore(record: record, to: path, metadata: metadata) {
                        successfulBatchWrites += 1
                    }
                case let .retry(kind):
                    try? await store.markRetry(
                        recordID: record.id,
                        kind: kind,
                        detail: retryDetail(for: kind),
                        path: path
                    )
                }
            }
        }

        if successfulBatchWrites > 0 {
            await dockRefresher.refreshDock()
        }
        if let hasPendingRecovery = try? await store.hasPendingStartupRecovery() {
            didReconcileAtStartup = !hasPendingRecovery
        }
    }

    /// Explicit user action. Legacy paths participate only as removal targets;
    /// they are never promoted into deterministic applied-icon records.
    func restoreOriginals(legacyPaths: [String]) async -> RestoreResult {
        await operationGate.acquire()
        let result = await restoreOriginalsWhileLocked(legacyPaths: legacyPaths)
        await operationGate.release()
        return result
    }

    private func restoreOriginalsWhileLocked(legacyPaths: [String]) async -> RestoreResult {
        let dockCandidates = candidateProvider.dockCandidates()
        var successfulIconMutations = 0
        if let recovered = try? await recoverPendingRestores(
            dockCandidates: dockCandidates
        ) {
            successfulIconMutations += recovered
        }
        if let finalized = try? await store.finalizeSucceededStages() {
            successfulIconMutations += finalized
        }
        if let recovered = try? await recoverExternalWriteIntents(
            dockCandidates: dockCandidates
        ) {
            successfulIconMutations += recovered
        }

        let records: [AppliedIconRecord]
        do {
            records = try await store.records()
        } catch {
            if successfulIconMutations > 0 {
                await dockRefresher.refreshDock()
            }
            return RestoreResult(
                remainingLegacyPaths: legacyPaths,
                restoredCount: 0,
                failedPaths: legacyPaths
            )
        }
        let recordsByPath = Dictionary(grouping: records, by: \AppliedIconRecord.lastPath)
        let orderedPaths = uniqued(legacyPaths + records.map(\.lastPath))

        var remainingLegacy = Set(legacyPaths)
        var failedPaths: [String] = []
        var restoredCount = 0

        for path in orderedPaths {
            let pathRecords = recordsByPath[path, default: []]
            guard pathChecker.fileExists(atPath: path) else {
                if pathRecords.isEmpty {
                    // A legacy path has no deterministic payload to retain.
                    // Do not turn it into a v1 record or keep a stale moved
                    // path after the signed record was resolved elsewhere.
                    remainingLegacy.remove(path)
                } else {
                    failedPaths.append(path)
                }
                continue
            }

            var restoreTransaction: AppliedIconStore.RestoreTransaction?
            if let record = pathRecords.first {
                let customIcon = await customIconInspector.state(
                    atAppPath: path,
                    expectedFingerprint: record.customIconFingerprint
                )
                switch customIcon {
                case .unknown, .unreadable:
                    failedPaths.append(path)
                    continue
                case .absent, .macBuddyOwned:
                    do {
                        restoreTransaction = try await store.beginRestore(
                            recordIDs: pathRecords.map(\.id),
                            path: path
                        )
                    } catch {
                        failedPaths.append(path)
                        continue
                    }
                }

                if case .absent = customIcon,
                   let restoreTransaction {
                    do {
                        try await store.markRestoreRemovalVerified(restoreTransaction)
                        try await store.finalizeRestore(restoreTransaction)
                        remainingLegacy.remove(path)
                        restoredCount += 1
                    } catch {
                        failedPaths.append(path)
                    }
                    continue
                }
            }

            let removed = await iconWriter.removeCustomIcon(atAppPath: path)
            guard removed else {
                failedPaths.append(path)
                continue
            }
            successfulIconMutations += 1

            if faultInjection == .afterExternalIconRemoval {
                failedPaths.append(path)
                return RestoreResult(
                    remainingLegacyPaths: legacyPaths.filter(remainingLegacy.contains),
                    restoredCount: restoredCount,
                    failedPaths: failedPaths
                )
            }

            do {
                guard try await customIconInspector.fingerprintIfPresent(
                    atAppPath: path
                ) == nil else {
                    throw CocoaError(.fileWriteUnknown)
                }
                if let restoreTransaction {
                    try await store.markRestoreRemovalVerified(restoreTransaction)
                    try await store.finalizeRestore(restoreTransaction)
                }
                remainingLegacy.remove(path)
                restoredCount += 1
            } catch {
                failedPaths.append(path)
                for record in pathRecords {
                    try? await store.markRetry(
                        recordID: record.id,
                        kind: .persistenceFailed,
                        detail: error.localizedDescription,
                        path: path
                    )
                }
            }
        }

        if successfulIconMutations > 0 {
            await dockRefresher.refreshDock()
        }
        return RestoreResult(
            remainingLegacyPaths: legacyPaths.filter(remainingLegacy.contains),
            restoredCount: restoredCount,
            failedPaths: failedPaths
        )
    }

    private func recoverPendingRestores(
        dockCandidates: [AppliedIconCandidate]
    ) async throws -> Int {
        let transactions = try await store.pendingRestoreTransactions()
        var recoveredRemovals = 0
        for transaction in transactions {
            if transaction.phase == .removalVerified {
                do {
                    try await store.finalizeRestore(transaction)
                    recoveredRemovals += 1
                } catch {
                    continue
                }
                continue
            }
            guard let record = transaction.entries.first?.record else {
                continue
            }
            let lastPathCandidate = dockCandidates.first {
                $0.path == transaction.path
            } ?? candidateProvider.candidate(at: transaction.path)
            guard case let .resolved(path, _, _) = AppliedIconResolver.resolve(
                record: record,
                lastPathCandidate: lastPathCandidate,
                dockCandidates: dockCandidates
            ) else {
                continue
            }
            let customIcon = await customIconInspector.state(
                atAppPath: path,
                expectedFingerprint: record.customIconFingerprint
            )
            switch customIcon {
            case .unknown, .unreadable:
                continue
            case .macBuddyOwned:
                guard await iconWriter.removeCustomIcon(atAppPath: path) else {
                    continue
                }
                do {
                    guard try await customIconInspector.fingerprintIfPresent(
                        atAppPath: path
                    ) == nil else {
                        continue
                    }
                } catch {
                    continue
                }
            case .absent:
                break
            }
            do {
                try await store.markRestoreRemovalVerified(transaction)
                try await store.finalizeRestore(transaction)
                recoveredRemovals += 1
            } catch {
                continue
            }
        }
        return recoveredRemovals
    }

    private func restore(
        record: AppliedIconRecord,
        to path: String,
        metadata: SignedAppMetadata
    ) async -> Bool {
        let pngData: Data
        do {
            pngData = try await store.iconData(for: record)
        } catch {
            try? await store.markRetry(
                recordID: record.id,
                kind: .storedIconCorrupt,
                detail: error.localizedDescription,
                path: path
            )
            return false
        }

        let stage: AppliedIconStore.StagedWrite
        do {
            stage = try await store.stageReconciliation(
                record: record,
                pngData: pngData,
                path: path,
                metadata: metadata
            )
        } catch {
            try? await store.markRetry(
                recordID: record.id,
                kind: .persistenceFailed,
                detail: error.localizedDescription,
                path: path
            )
            return false
        }
        guard await prepareExternalWrite(stage, at: path) else {
            try? await store.markRetry(
                recordID: record.id,
                kind: .persistenceFailed,
                detail: "The external icon write could not be prepared.",
                path: path
            )
            return false
        }

        let applied = await iconWriter.apply(pngData: pngData, toAppAt: path)
        guard applied else {
            _ = await rollBackUncommittedApplication(
                stage,
                path: path,
                detail: "NSWorkspace could not restore the persisted icon.",
                priorPNGData: pngData,
                observedAppliedFingerprint: nil
            )
            return false
        }
        if faultInjection == .afterExternalIconWrite {
            return false
        }

        let fingerprint: String
        do {
            guard let observed = try await customIconInspector.fingerprintIfPresent(atAppPath: path) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            fingerprint = observed
        } catch {
            _ = await rollBackUncommittedApplication(
                stage,
                path: path,
                detail: error.localizedDescription,
                priorPNGData: pngData,
                observedAppliedFingerprint: nil
            )
            return false
        }

        do {
            try await store.markApplicationSucceeded(stage, customIconFingerprint: fingerprint)
        } catch {
            _ = await rollBackUncommittedApplication(
                stage,
                path: path,
                detail: error.localizedDescription,
                priorPNGData: pngData,
                observedAppliedFingerprint: fingerprint
            )
            return false
        }

        do {
            _ = try await store.finalize(stage)
            return true
        } catch {
            return (try? await store.committedRecord(for: stage)) != nil
        }
    }

    private func rollBackUncommittedApplication(
        _ stage: AppliedIconStore.StagedWrite,
        path: String,
        detail: String,
        priorPNGData: Data?,
        observedAppliedFingerprint: String?
    ) async -> Bool {
        try? await store.markRollbackRequired(
            stage,
            observedAppliedFingerprint: observedAppliedFingerprint
        )
        _ = await markPriorRecordForRestore(
            recordID: stage.recordID,
            path: path,
            detail: detail
        )
        if let priorPNGData {
            guard await iconWriter.apply(pngData: priorPNGData, toAppAt: path) else {
                return false
            }
            do {
                guard let rollbackFingerprint = try await customIconInspector
                    .fingerprintIfPresent(atAppPath: path) else {
                    return true
                }
                try await store.recordSuccessfulRollback(
                    recordID: stage.recordID,
                    path: path,
                    customIconFingerprint: rollbackFingerprint
                )
                await store.abort(stage)
            } catch {
                return true
            }
            return true
        }
        guard await iconWriter.removeCustomIcon(atAppPath: path) else {
            return false
        }
        do {
            guard try await customIconInspector.fingerprintIfPresent(atAppPath: path) == nil else {
                return true
            }
            await store.abort(stage)
        } catch {
            return true
        }
        return true
    }

    private func prepareExternalWrite(
        _ stage: AppliedIconStore.StagedWrite,
        at path: String
    ) async -> Bool {
        do {
            let priorFingerprint = try await customIconInspector.fingerprintIfPresent(
                atAppPath: path
            )
            try await store.markExternalWriteIntent(
                stage,
                priorCustomIconFingerprint: priorFingerprint
            )
            return true
        } catch {
            await store.abort(stage)
            return false
        }
    }

    private func recoverExternalWriteIntents(
        dockCandidates: [AppliedIconCandidate]
    ) async throws -> Int {
        let intents = try await store.recoverableApplicationIntents()
        var recoveredWrites = 0
        for intent in intents {
            let lastPathCandidate = dockCandidates.first {
                $0.path == intent.record.lastPath
            } ?? candidateProvider.candidate(at: intent.record.lastPath)
            guard case let .resolved(path, _, _) = AppliedIconResolver.resolve(
                record: intent.record,
                lastPathCandidate: lastPathCandidate,
                dockCandidates: dockCandidates
            ) else {
                continue
            }

            switch intent.recoveryAction {
            case .restorePreviousIcon:
                recoveredWrites += await recoverPreviousIcon(
                    for: intent,
                    at: path
                )
                continue
            case .removeUncommittedIcon:
                recoveredWrites += await recoverUncommittedRemoval(
                    for: intent,
                    at: path
                )
                continue
            case .completeApplication:
                break
            }

            let observedFingerprint: String?
            do {
                observedFingerprint = try await customIconInspector.fingerprintIfPresent(
                    atAppPath: path
                )
            } catch {
                continue
            }
            guard let observedFingerprint else {
                if intent.priorCustomIconFingerprint == nil {
                    await store.abort(intent.stage)
                }
                continue
            }
            guard observedFingerprint != intent.priorCustomIconFingerprint else {
                continue
            }

            do {
                try await store.markApplicationSucceeded(
                    intent.stage,
                    customIconFingerprint: observedFingerprint
                )
                _ = try await store.finalize(intent.stage)
                recoveredWrites += 1
            } catch {
                continue
            }
        }
        return recoveredWrites
    }

    private func recoverPreviousIcon(
        for intent: AppliedIconStore.RecoverableApplicationIntent,
        at path: String
    ) async -> Int {
        guard let previousRecord = try? await store.records().first(where: {
            $0.id == intent.record.id
        }),
              let priorPNGData = try? await store.iconData(for: previousRecord) else {
            return 0
        }
        let observedFingerprint: String?
        do {
            observedFingerprint = try await customIconInspector.fingerprintIfPresent(
                atAppPath: path
            )
        } catch {
            return 0
        }

        if observedFingerprint == previousRecord.customIconFingerprint {
            do {
                try await store.recordSuccessfulRollback(
                    recordID: previousRecord.id,
                    path: path,
                    customIconFingerprint: previousRecord.customIconFingerprint
                )
                await store.abort(intent.stage)
            } catch {
                return 0
            }
            return 0
        }
        guard observedFingerprint == nil
                || observedFingerprint == intent.observedAppliedFingerprint else {
            return 0
        }
        guard await iconWriter.apply(pngData: priorPNGData, toAppAt: path) else {
            return 0
        }
        do {
            guard let rollbackFingerprint = try await customIconInspector
                .fingerprintIfPresent(atAppPath: path) else {
                return 0
            }
            try await store.recordSuccessfulRollback(
                recordID: previousRecord.id,
                path: path,
                customIconFingerprint: rollbackFingerprint
            )
            await store.abort(intent.stage)
            return 1
        } catch {
            return 0
        }
    }

    private func recoverUncommittedRemoval(
        for intent: AppliedIconStore.RecoverableApplicationIntent,
        at path: String
    ) async -> Int {
        let observedFingerprint: String?
        do {
            observedFingerprint = try await customIconInspector.fingerprintIfPresent(
                atAppPath: path
            )
        } catch {
            return 0
        }
        guard let observedFingerprint else {
            await store.abort(intent.stage)
            return 0
        }
        guard intent.priorCustomIconFingerprint == nil
                || observedFingerprint == intent.observedAppliedFingerprint else {
            return 0
        }
        guard await iconWriter.removeCustomIcon(atAppPath: path) else {
            return 0
        }
        do {
            guard try await customIconInspector.fingerprintIfPresent(atAppPath: path) == nil else {
                return 0
            }
            await store.abort(intent.stage)
            return 1
        } catch {
            return 0
        }
    }

    @discardableResult
    private func markPriorRecordForRestore(
        recordID: String,
        path: String,
        detail: String
    ) async -> Bool {
        do {
            try await store.markRetry(
                recordID: recordID,
                kind: .restoreNeeded,
                detail: detail,
                path: path
            )
            return true
        } catch {
            return false
        }
    }

    private func priorPNGData(recordID: String) async -> Data? {
        guard let record = try? await store.records().first(where: { $0.id == recordID }) else {
            return nil
        }
        return try? await store.iconData(for: record)
    }

    private func retryDetail(for kind: AppliedIconRetryKind) -> String {
        switch kind {
        case .unknownCustomIcon:
            "A different custom icon is present; MacBuddy left it untouched."
        case .customIconUnreadable:
            "The current custom-icon metadata could not be read."
        case .restoreNeeded:
            "The previously persisted icon needs to be restored."
        default:
            "Applied-icon reconciliation will retry on a later launch."
        }
    }

    private func uniqued(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

}
