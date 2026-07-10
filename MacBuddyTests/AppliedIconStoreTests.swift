import Foundation
import Testing

struct AppliedIconStoreTests {
    @Test func stagedPNGIsInvisibleUntilApplicationIsVerified() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Self.pngData())

        let stage = try await store.stageNewApplication(
            pngData: png,
            path: "/Applications/Fixture.app",
            metadata: Self.metadata(revision: "v1"),
            now: Self.date(1)
        )
        #expect(try await store.records().isEmpty)

        do {
            _ = try await store.finalize(stage)
            Issue.record("An unverified stage must not finalize")
        } catch let error as AppliedIconStore.StoreError {
            #expect(error == .invalidStage(stage.transactionID))
        }

        try await store.markApplicationSucceeded(stage, customIconFingerprint: "finder-v1")
        let committed = try await store.finalize(stage)
        let records = try await store.records()

        #expect(records == [committed])
        #expect(committed.appliedPNG_SHA256 == AppliedIconSHA256.hexDigest(png))
        #expect(try await store.iconData(for: committed) == png)
    }

    @Test func replacementKeepsV1AuthoritativeUntilV2Commits() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Self.pngData())
        let v1 = try await commitInitial(store: store, png: png)

        let v2Metadata = Self.metadata(revision: "v2")
        let v2Stage = try await store.stageReconciliation(
            record: v1,
            pngData: png,
            path: "/Applications/Fixture.app",
            metadata: v2Metadata,
            now: Self.date(2)
        )

        let beforeCommit = try #require(try await store.records().first)
        #expect(beforeCommit.signedRevision.cdHash == "v1")
        #expect(try await store.iconData(for: beforeCommit) == png)

        try await store.markApplicationSucceeded(v2Stage, customIconFingerprint: "finder-v2")
        let v2 = try await store.finalize(v2Stage)
        let afterCommit = try #require(try await store.records().first)

        #expect(v2.signedRevision.cdHash == "v2")
        #expect(afterCommit.signedRevision.cdHash == "v2")
        #expect(afterCommit.customIconFingerprint == "finder-v2")
        #expect(try await store.iconData(for: afterCommit) == png)
    }

    @Test func successfullyAppliedCrashStageCanFinalizeIdempotently() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Self.pngData())
        let stage = try await store.stageNewApplication(
            pngData: png,
            path: "/Applications/Fixture.app",
            metadata: Self.metadata(revision: "v1")
        )
        try await store.markApplicationSucceeded(stage, customIconFingerprint: "finder-v1")

        #expect(try await store.finalizeSucceededStages() == 1)
        #expect(try await store.finalize(stage).id == stage.recordID)
        #expect(try await store.records().count == 1)
    }

    @Test func movedGenerationRecoversAfterCrashBeforeIndexCommit() async throws {
        let (_, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Self.pngData())
        let initialStore = AppliedIconStore(rootURL: root)
        let v1 = try await commitInitial(store: initialStore, png: png)
        let crashingStore = AppliedIconStore(
            rootURL: root,
            faultInjection: .afterGenerationMoveBeforeIndexCommit
        )
        let stage = try await crashingStore.stageReconciliation(
            record: v1,
            pngData: png,
            path: "/Applications/Fixture.app",
            metadata: Self.metadata(revision: "v2"),
            now: Self.date(2)
        )
        try await crashingStore.markApplicationSucceeded(
            stage,
            customIconFingerprint: "finder-v2"
        )

        do {
            _ = try await crashingStore.finalize(stage)
            Issue.record("The injected crash boundary must interrupt finalization")
        } catch let error as AppliedIconStore.StoreError {
            #expect(error == .injectedCrash(.afterGenerationMoveBeforeIndexCommit))
        }

        let recoveredStore = AppliedIconStore(rootURL: root)
        #expect(try await recoveredStore.finalizeSucceededStages() == 1)
        let recovered = try #require(try await recoveredStore.records().first)

        #expect(recovered.signedRevision.cdHash == "v2")
        #expect(recovered.customIconFingerprint == "finder-v2")
        #expect(try await recoveredStore.iconData(for: recovered) == png)
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: root.appending(path: "records"),
                includingPropertiesForKeys: nil
            ).count == 1
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: root.appending(path: "journals"),
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    @Test func firstApplyMovedGenerationRecoversIdempotently() async throws {
        let (_, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Self.pngData())
        let crashingStore = AppliedIconStore(
            rootURL: root,
            faultInjection: .afterGenerationMoveBeforeIndexCommit
        )
        let stage = try await crashingStore.stageNewApplication(
            pngData: png,
            path: "/Applications/Fixture.app",
            metadata: Self.metadata(revision: "v1"),
            now: Self.date(1)
        )
        try await crashingStore.markApplicationSucceeded(
            stage,
            customIconFingerprint: "finder-v1"
        )
        await #expect(throws: AppliedIconStore.StoreError.injectedCrash(
            .afterGenerationMoveBeforeIndexCommit
        )) {
            _ = try await crashingStore.finalize(stage)
        }

        let recoveredStore = AppliedIconStore(rootURL: root)
        #expect(try await recoveredStore.finalizeSucceededStages() == 1)
        let recovered = try #require(try await recoveredStore.records().first)

        #expect(recovered.signedRevision.cdHash == "v1")
        #expect(recovered.customIconFingerprint == "finder-v1")
        #expect(try await recoveredStore.finalizeSucceededStages() == 0)
    }

    @Test func newerFirstApplicationSupersedesOlderFirstApplicationJournal() async throws {
        let (_, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Self.pngData())
        let crashingStore = AppliedIconStore(
            rootURL: root,
            faultInjection: .afterGenerationMoveBeforeIndexCommit
        )
        let v1Stage = try await crashingStore.stageNewApplication(
            pngData: png,
            path: "/Applications/Fixture.app",
            metadata: Self.metadata(revision: "v1"),
            now: Self.date(1)
        )
        try await crashingStore.markApplicationSucceeded(
            v1Stage,
            customIconFingerprint: "finder-v1"
        )
        await #expect(throws: AppliedIconStore.StoreError.injectedCrash(
            .afterGenerationMoveBeforeIndexCommit
        )) {
            _ = try await crashingStore.finalize(v1Stage)
        }

        let currentStore = AppliedIconStore(rootURL: root)
        let v2Stage = try await currentStore.stageNewApplication(
            pngData: png,
            path: "/Applications/Fixture.app",
            metadata: Self.metadata(revision: "v2"),
            now: Self.date(2)
        )
        try await currentStore.markApplicationSucceeded(
            v2Stage,
            customIconFingerprint: "finder-v2"
        )
        _ = try await currentStore.finalize(v2Stage)

        let recoveredStore = AppliedIconStore(rootURL: root)
        #expect(try await recoveredStore.finalizeSucceededStages() == 0)
        let records = try await recoveredStore.records()
        #expect(records.count == 1)
        #expect(records.first?.signedRevision.cdHash == "v2")
        #expect(records.first?.customIconFingerprint == "finder-v2")
        #expect(try Self.directoryEntries(root, "records").count == 1)
        #expect(try Self.directoryEntries(root, "journals").isEmpty)
    }

    @Test func staleV2JournalNeverReplacesCommittedV3() async throws {
        let (_, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Self.pngData())
        let initialStore = AppliedIconStore(rootURL: root)
        let v1 = try await commitInitial(store: initialStore, png: png)
        let crashingStore = AppliedIconStore(
            rootURL: root,
            faultInjection: .afterGenerationMoveBeforeIndexCommit
        )
        let v2Stage = try await crashingStore.stageReconciliation(
            record: v1,
            pngData: png,
            path: "/Applications/Fixture.app",
            metadata: Self.metadata(revision: "v2"),
            now: Self.date(2)
        )
        try await crashingStore.markApplicationSucceeded(
            v2Stage,
            customIconFingerprint: "finder-v2"
        )
        await #expect(throws: AppliedIconStore.StoreError.injectedCrash(
            .afterGenerationMoveBeforeIndexCommit
        )) {
            _ = try await crashingStore.finalize(v2Stage)
        }

        let currentStore = AppliedIconStore(rootURL: root)
        let v3Stage = try await currentStore.stageNewApplication(
            pngData: png,
            path: "/Applications/Fixture.app",
            metadata: Self.metadata(revision: "v3"),
            now: Self.date(3)
        )
        try await currentStore.markApplicationSucceeded(
            v3Stage,
            customIconFingerprint: "finder-v3"
        )
        _ = try await currentStore.finalize(v3Stage)

        let recoveredStore = AppliedIconStore(rootURL: root)
        #expect(try await recoveredStore.finalizeSucceededStages() == 0)
        let recovered = try #require(try await recoveredStore.records().first)

        #expect(recovered.signedRevision.cdHash == "v3")
        #expect(recovered.customIconFingerprint == "finder-v3")
        #expect(try await recoveredStore.finalizeSucceededStages() == 0)
    }

    @Test func staleVerifiedV2StageNeverReplacesCommittedV3() async throws {
        let (_, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Self.pngData())
        let store = AppliedIconStore(rootURL: root)
        let v1 = try await commitInitial(store: store, png: png)
        let v2Stage = try await store.stageReconciliation(
            record: v1,
            pngData: png,
            path: "/Applications/Fixture.app",
            metadata: Self.metadata(revision: "v2"),
            now: Self.date(2)
        )
        try await store.markApplicationSucceeded(
            v2Stage,
            customIconFingerprint: "finder-v2"
        )

        let v3Stage = try await store.stageNewApplication(
            pngData: png,
            path: "/Applications/Fixture.app",
            metadata: Self.metadata(revision: "v3"),
            now: Self.date(3)
        )
        try await store.markApplicationSucceeded(
            v3Stage,
            customIconFingerprint: "finder-v3"
        )
        _ = try await store.finalize(v3Stage)

        #expect(try await store.finalizeSucceededStages() == 0)
        let current = try #require(try await store.records().first)
        #expect(current.signedRevision.cdHash == "v3")
        #expect(current.customIconFingerprint == "finder-v3")
        #expect(try await store.finalizeSucceededStages() == 0)
    }

    @Test(arguments: [
        AppliedIconStore.FaultInjection.afterCommitJournalWriteBeforeMove,
        .afterPreviousGenerationCleanupBeforeJournalRemoval,
        .afterCommitCleanupBeforeReturn
    ])
    func everyCommitBoundaryRecoversToOneValidatedGeneration(
        fault: AppliedIconStore.FaultInjection
    ) async throws {
        let (_, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Self.pngData())
        let initialStore = AppliedIconStore(rootURL: root)
        let v1 = try await commitInitial(store: initialStore, png: png)
        let crashingStore = AppliedIconStore(rootURL: root, faultInjection: fault)
        let stage = try await crashingStore.stageReconciliation(
            record: v1,
            pngData: png,
            path: "/Applications/Fixture.app",
            metadata: Self.metadata(revision: "v2"),
            now: Self.date(2)
        )
        try await crashingStore.markApplicationSucceeded(
            stage,
            customIconFingerprint: "finder-v2"
        )

        await #expect(throws: AppliedIconStore.StoreError.injectedCrash(fault)) {
            _ = try await crashingStore.finalize(stage)
        }

        let recoveredStore = AppliedIconStore(rootURL: root)
        let expectedRecoveredWriteCount = fault == .afterCommitCleanupBeforeReturn ? 0 : 1
        #expect(
            try await recoveredStore.finalizeSucceededStages()
                == expectedRecoveredWriteCount
        )
        let recovered = try #require(try await recoveredStore.records().first)
        #expect(recovered.signedRevision.cdHash == "v2")
        #expect(recovered.customIconFingerprint == "finder-v2")
        #expect(try await recoveredStore.iconData(for: recovered) == png)
        #expect(try await recoveredStore.finalizeSucceededStages() == 0)
        #expect(try Self.directoryEntries(root, "records").count == 1)
        #expect(try Self.directoryEntries(root, "staging").isEmpty)
        #expect(try Self.directoryEntries(root, "journals").isEmpty)
    }

    @Test func restoreJournalSurvivesItsWriteReturnBoundary() async throws {
        let (_, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Self.pngData())
        let initialStore = AppliedIconStore(rootURL: root)
        let record = try await commitInitial(store: initialStore, png: png)
        let crashingStore = AppliedIconStore(
            rootURL: root,
            faultInjection: .afterRestoreJournalWriteBeforeReturn
        )

        await #expect(throws: AppliedIconStore.StoreError.injectedCrash(
            .afterRestoreJournalWriteBeforeReturn
        )) {
            _ = try await crashingStore.beginRestore(
                recordIDs: [record.id],
                path: record.lastPath
            )
        }

        let recoveredStore = AppliedIconStore(rootURL: root)
        let transaction = try #require(
            try await recoveredStore.pendingRestoreTransactions().first
        )
        #expect(transaction.phase == .prepared)
        #expect(try await recoveredStore.iconData(for: record) == png)
        try await recoveredStore.markRestoreRemovalVerified(transaction)
        try await recoveredStore.finalizeRestore(transaction)
        #expect(try await recoveredStore.records().isEmpty)
        #expect(try await recoveredStore.pendingRestoreTransactions().isEmpty)
    }

    @Test(arguments: [
        AppliedIconStore.FaultInjection.afterRestoreGenerationCleanupBeforeJournalRemoval,
        .afterRestoreCleanupBeforeReturn
    ])
    func restoreCleanupAndReturnBoundariesNeverResurrectARecord(
        fault: AppliedIconStore.FaultInjection
    ) async throws {
        let (_, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Self.pngData())
        let initialStore = AppliedIconStore(rootURL: root)
        let record = try await commitInitial(store: initialStore, png: png)
        let transaction = try await initialStore.beginRestore(
            recordIDs: [record.id],
            path: record.lastPath
        )
        try await initialStore.markRestoreRemovalVerified(transaction)
        let crashingStore = AppliedIconStore(rootURL: root, faultInjection: fault)

        await #expect(throws: AppliedIconStore.StoreError.injectedCrash(fault)) {
            try await crashingStore.finalizeRestore(transaction)
        }
        #expect(try await crashingStore.records().isEmpty)

        let recoveredStore = AppliedIconStore(rootURL: root)
        for pending in try await recoveredStore.pendingRestoreTransactions() {
            try await recoveredStore.finalizeRestore(pending)
        }
        #expect(try await recoveredStore.records().isEmpty)
        #expect(try await recoveredStore.pendingRestoreTransactions().isEmpty)
        #expect(try Self.directoryEntries(root, "records").isEmpty)
    }

    @Test func successfulRestoreSupersedesOlderApplicationJournalButAllowsExplicitReapply() async throws {
        let (_, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Self.pngData())
        let initialStore = AppliedIconStore(rootURL: root)
        let v1 = try await commitInitial(store: initialStore, png: png)
        let crashingStore = AppliedIconStore(
            rootURL: root,
            faultInjection: .afterGenerationMoveBeforeIndexCommit
        )
        let staleStage = try await crashingStore.stageReconciliation(
            record: v1,
            pngData: png,
            path: v1.lastPath,
            metadata: Self.metadata(revision: "v2"),
            now: Self.date(2)
        )
        try await crashingStore.markApplicationSucceeded(
            staleStage,
            customIconFingerprint: "finder-v2"
        )
        await #expect(throws: AppliedIconStore.StoreError.injectedCrash(
            .afterGenerationMoveBeforeIndexCommit
        )) {
            _ = try await crashingStore.finalize(staleStage)
        }

        let restoringStore = AppliedIconStore(rootURL: root)
        let restore = try await restoringStore.beginRestore(
            recordIDs: [v1.id],
            path: v1.lastPath
        )
        try await restoringStore.markRestoreRemovalVerified(restore)
        try await restoringStore.finalizeRestore(restore)

        let recoveredStore = AppliedIconStore(rootURL: root)
        #expect(try await recoveredStore.finalizeSucceededStages() == 0)
        #expect(try await recoveredStore.records().isEmpty)
        #expect(try Self.directoryEntries(root, "journals").isEmpty)

        let v3Stage = try await recoveredStore.stageNewApplication(
            pngData: png,
            path: v1.lastPath,
            metadata: Self.metadata(revision: "v3"),
            now: Self.date(3)
        )
        try await recoveredStore.markApplicationSucceeded(
            v3Stage,
            customIconFingerprint: "finder-v3"
        )
        let v3 = try await recoveredStore.finalize(v3Stage)
        #expect(v3.signedRevision.cdHash == "v3")
        #expect(try await recoveredStore.records() == [v3])
    }

    @Test func corruptPNGRemainsRecordedAndGetsRetryState() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Self.pngData())
        let record = try await commitInitial(store: store, png: png)
        let generation = try #require(
            try FileManager.default.contentsOfDirectory(
                at: root.appending(path: "records"),
                includingPropertiesForKeys: nil
            ).first
        )
        try Data("damaged".utf8).write(to: generation.appending(path: "icon.png"), options: .atomic)

        do {
            _ = try await store.iconData(for: record)
            Issue.record("A changed PNG must fail digest verification")
        } catch let error as AppliedIconStore.StoreError {
            #expect(error == .iconHashMismatch(record.id))
        }

        try await store.markRetry(
            recordID: record.id,
            kind: .storedIconCorrupt,
            detail: "digest mismatch",
            now: Self.date(3)
        )
        let retained = try #require(try await store.records().first)
        #expect(retained.id == record.id)
        #expect(retained.retryState.kind == .storedIconCorrupt)
    }

    @Test func restoreRetiresOnlyTheSelectedRecord() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Self.pngData())
        let record = try await commitInitial(store: store, png: png)

        try await store.retire(recordID: record.id)

        #expect(try await store.records().isEmpty)
    }

    @Test func retryableDeletionOrPermissionFailureRetainsPNGAndRevision() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Self.pngData())
        let record = try await commitInitial(store: store, png: png)

        try await store.markRetry(
            recordID: record.id,
            kind: .applicationFailed,
            detail: "permission denied",
            now: Self.date(4)
        )
        let retained = try #require(try await store.records().first)

        #expect(retained.id == record.id)
        #expect(retained.signedRevision == record.signedRevision)
        #expect(retained.retryState.kind == .applicationFailed)
        #expect(try await store.iconData(for: retained) == png)
    }

    private func commitInitial(store: AppliedIconStore, png: Data) async throws -> AppliedIconRecord {
        let stage = try await store.stageNewApplication(
            pngData: png,
            path: "/Applications/Fixture.app",
            metadata: Self.metadata(revision: "v1"),
            now: Self.date(1)
        )
        try await store.markApplicationSucceeded(stage, customIconFingerprint: "finder-v1")
        return try await store.finalize(stage)
    }

    private func makeStore() -> (AppliedIconStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "applied-icon-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (AppliedIconStore(rootURL: root), root)
    }

    private static func metadata(revision: String) -> SignedAppMetadata {
        SignedAppMetadata(
            bundleIdentifier: "com.example.fixture",
            identity: SignedAppIdentity(
                teamIdentifier: "TEAM123",
                signingIdentifier: "com.example.fixture",
                designatedRequirement: "anchor apple generic and identifier com.example.fixture"
            ),
            revision: SignedAppRevision(
                cdHash: revision,
                bundleVersion: revision,
                shortVersion: "1.0"
            )
        )
    }

    private static func pngData() -> Data? {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=")
    }

    private static func date(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }

    private static func directoryEntries(_ root: URL, _ name: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root.appending(path: name),
            includingPropertiesForKeys: nil
        )
    }
}
