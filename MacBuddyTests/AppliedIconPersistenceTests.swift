import Foundation
import Testing

struct AppliedIconPersistenceTests {
    @Test func firstApplyInterruptedAfterExternalWriteIsRecoverableAndAvailable() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppliedIconStore(rootURL: root)
        let path = "/Applications/Fixture.app"
        let metadata = Self.metadata(revision: "v1")
        let png = try #require(Self.pngData())
        let writer = RecordingAppliedIconWriter(applyResults: [true], removeResults: [])
        let interrupted = AppliedIconPersistence(
            store: store,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: writer,
            customIconInspector: StubAppliedIconInspector(
                states: [path: .absent],
                fingerprints: [path: nil]
            ),
            faultInjection: .afterExternalIconWrite
        )

        #expect(await interrupted.applyPNGData(png, toAppAt: path) == false)
        #expect(try await store.records().isEmpty)

        let availability = AppliedIconAvailability(store: store)
        await availability.refresh()
        #expect(availability.hasDurableRecords)

        let dockRefresher = RecordingDockRefresher()
        let recovered = AppliedIconPersistence(
            store: store,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: writer,
            customIconInspector: StubAppliedIconInspector(
                states: [path: .macBuddyOwned(fingerprint: "written-fingerprint")],
                fingerprints: [path: "written-fingerprint"]
            ),
            candidateProvider: StubCandidateProvider(candidates: [
                AppliedIconCandidate(
                    path: path,
                    bundleIdentifier: metadata.bundleIdentifier,
                    signedMetadata: metadata
                )
            ]),
            dockRefresher: dockRefresher
        )

        await recovered.reconcileAtStartupIfNeeded()

        let record = try #require(try await store.records().first)
        #expect(record.customIconFingerprint == "written-fingerprint")
        #expect(try await store.iconData(for: record) == png)
        #expect(await dockRefresher.refreshCount() == 1)
        await availability.refresh()
        #expect(availability.hasDurableRecords)
    }

    @Test func restoreConsumesFirstApplyIntentWithoutASeparateStartupPass() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppliedIconStore(rootURL: root)
        let path = "/Applications/Fixture.app"
        let metadata = Self.metadata(revision: "v1")
        let png = try #require(Self.pngData())
        let writer = RecordingAppliedIconWriter(
            applyResults: [true],
            removeResults: [true]
        )
        let interrupted = AppliedIconPersistence(
            store: store,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: writer,
            customIconInspector: StubAppliedIconInspector(
                states: [path: .absent],
                fingerprints: [path: nil]
            ),
            faultInjection: .afterExternalIconWrite
        )

        #expect(await interrupted.applyPNGData(png, toAppAt: path) == false)
        #expect(try await store.records().isEmpty)
        #expect(try await store.hasRestorableState())

        let dockRefresher = RecordingDockRefresher()
        let restorer = AppliedIconPersistence(
            store: store,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: writer,
            customIconInspector: SequencedAppliedIconInspector(
                fingerprints: [.value("written-fingerprint"), .value(nil)],
                state: .macBuddyOwned(fingerprint: "written-fingerprint")
            ),
            candidateProvider: StubCandidateProvider(candidates: [
                AppliedIconCandidate(
                    path: path,
                    bundleIdentifier: metadata.bundleIdentifier,
                    signedMetadata: metadata
                )
            ]),
            dockRefresher: dockRefresher,
            pathChecker: StubPathChecker(existingPaths: [path])
        )

        let result = await restorer.restoreOriginals(legacyPaths: [])

        #expect(result.restoredCount == 1)
        #expect(result.failedPaths.isEmpty)
        #expect(try await store.records().isEmpty)
        #expect(try await store.recoverableApplicationIntents().isEmpty)
        #expect(await writer.removeCount() == 1)
        #expect(await dockRefresher.refreshCount() == 1)
    }

    @Test func fingerprintFailureRetainsPriorPNGAndRequiresRestore() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppliedIconStore(rootURL: root)
        let path = "/Applications/Fixture.app"
        let metadata = Self.metadata(revision: "v1")
        let priorPNG = try #require(Self.pngData())
        let priorRecord = try await Self.commit(
            png: priorPNG,
            path: path,
            metadata: metadata,
            store: store
        )
        let writer = RecordingAppliedIconWriter(applyResults: [true], removeResults: [true])
        let inspector = StubAppliedIconInspector(
            states: [path: .absent],
            fingerprints: [path: nil]
        )
        let persistence = AppliedIconPersistence(
            store: store,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: writer,
            customIconInspector: inspector
        )

        #expect(await persistence.applyPNGData(Data("replacement-png".utf8), toAppAt: path) == false)

        let retained = try #require(try await store.records().first)
        #expect(retained.id == priorRecord.id)
        #expect(retained.signedRevision == priorRecord.signedRevision)
        #expect(retained.appliedPNG_SHA256 == priorRecord.appliedPNG_SHA256)
        #expect(retained.retryState.kind == .restoreNeeded)
        #expect(try await store.iconData(for: retained) == priorPNG)
        #expect(await writer.appliedPayloads() == [Data("replacement-png".utf8), priorPNG])
        #expect(await writer.removeCount() == 0)
        #expect(AppliedIconReconciliationStateMachine.decide(
            record: retained,
            path: path,
            metadata: metadata,
            customIcon: .absent
        ) == .restoreAppliedIcon)

        let dockRefresher = RecordingDockRefresher()
        let restorer = AppliedIconPersistence(
            store: store,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: writer,
            customIconInspector: StubAppliedIconInspector(
                states: [path: .absent],
                fingerprints: [path: "restored-fingerprint"]
            ),
            candidateProvider: StubCandidateProvider(candidates: [
                AppliedIconCandidate(
                    path: path,
                    bundleIdentifier: metadata.bundleIdentifier,
                    signedMetadata: metadata
                )
            ]),
            dockRefresher: dockRefresher
        )

        await restorer.reconcileAtStartupIfNeeded()

        let restored = try #require(try await store.records().first)
        #expect(await writer.appliedPayloads() == [
            Data("replacement-png".utf8),
            priorPNG,
            priorPNG,
        ])
        #expect(restored.retryState == .ready)
        #expect(restored.customIconFingerprint == "restored-fingerprint")
        #expect(restored.signedRevision == priorRecord.signedRevision)
        #expect(try await store.iconData(for: restored) == priorPNG)
        #expect(await dockRefresher.refreshCount() == 1)
    }

    @Test func verifiedPriorPNGRollbackPersistsItsActualFingerprint() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppliedIconStore(rootURL: root)
        let path = "/Applications/Fixture.app"
        let metadata = Self.metadata(revision: "v1")
        let priorPNG = try #require(Self.pngData())
        let priorRecord = try await Self.commit(
            png: priorPNG,
            path: path,
            metadata: metadata,
            store: store
        )
        let replacementPNG = Data("replacement-png".utf8)
        let writer = RecordingAppliedIconWriter(
            applyResults: [true, true],
            removeResults: []
        )
        let inspector = SequencedAppliedIconInspector(
            fingerprints: [
                .value("prior-fingerprint"),
                .value(nil),
                .value("rollback-fingerprint"),
            ]
        )
        let persistence = AppliedIconPersistence(
            store: store,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: writer,
            customIconInspector: inspector
        )

        #expect(await persistence.applyPNGData(replacementPNG, toAppAt: path) == false)

        let retained = try #require(try await store.records().first)
        #expect(retained.id == priorRecord.id)
        #expect(retained.appliedPNG_SHA256 == priorRecord.appliedPNG_SHA256)
        #expect(retained.customIconFingerprint == "rollback-fingerprint")
        #expect(retained.retryState == .ready)
        #expect(try await store.iconData(for: retained) == priorPNG)
        #expect(await writer.appliedPayloads() == [replacementPNG, priorPNG])
        #expect(try await store.recoverableApplicationIntents().isEmpty)
    }

    @Test func markerAndPriorPNGRollbackFailureRetainDurableRestoreIntent() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "/Applications/Fixture.app"
        let metadata = Self.metadata(revision: "v1")
        let priorPNG = try #require(Self.pngData())
        let initialStore = AppliedIconStore(rootURL: root)
        let priorRecord = try await Self.commit(
            png: priorPNG,
            path: path,
            metadata: metadata,
            store: initialStore
        )
        let faultingStore = AppliedIconStore(
            rootURL: root,
            faultInjection: .beforeRetryStateWrite
        )
        let writer = RecordingAppliedIconWriter(
            applyResults: [true, false],
            removeResults: [false]
        )
        let persistence = AppliedIconPersistence(
            store: faultingStore,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: writer,
            customIconInspector: SequencedAppliedIconInspector(
                fingerprints: [.value("prior-fingerprint"), .value(nil)]
            )
        )

        #expect(await persistence.applyPNGData(Data("replacement".utf8), toAppAt: path) == false)

        let retained = try #require(try await initialStore.records().first)
        #expect(retained.id == priorRecord.id)
        #expect(retained.retryState == .ready)
        let intent = try #require(
            try await faultingStore.recoverableApplicationIntents().first
        )
        #expect(intent.requiresPreviousIconRestore)
        #expect(try await faultingStore.hasRestorableState())
        #expect(await writer.appliedPayloads() == [Data("replacement".utf8), priorPNG])
    }

    @Test func applicationEvidenceFailurePersistsObservedReplacementFingerprint() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "/Applications/Fixture.app"
        let metadata = Self.metadata(revision: "v1")
        let priorPNG = try #require(Self.pngData())
        let initialStore = AppliedIconStore(rootURL: root)
        _ = try await Self.commit(
            png: priorPNG,
            path: path,
            metadata: metadata,
            store: initialStore
        )
        let faultingStore = AppliedIconStore(
            rootURL: root,
            faultInjection: .beforeApplicationEvidenceWrite
        )
        let replacementPNG = Data("replacement".utf8)
        let writer = RecordingAppliedIconWriter(
            applyResults: [true, false],
            removeResults: []
        )
        let persistence = AppliedIconPersistence(
            store: faultingStore,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: writer,
            customIconInspector: SequencedAppliedIconInspector(fingerprints: [
                .value("prior-fingerprint"),
                .value("replacement-fingerprint"),
            ])
        )

        #expect(await persistence.applyPNGData(replacementPNG, toAppAt: path) == false)

        let intent = try #require(
            try await faultingStore.recoverableApplicationIntents().first
        )
        #expect(intent.requiresPreviousIconRestore)
        #expect(intent.observedAppliedFingerprint == "replacement-fingerprint")
        #expect(await writer.appliedPayloads() == [replacementPNG, priorPNG])
    }

    @Test func failureAfterIndexCommitReturnsDurableSuccessWithoutRollback() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "/Applications/Fixture.app"
        let metadata = Self.metadata(revision: "v1")
        let priorPNG = try #require(Self.pngData())
        let initialStore = AppliedIconStore(rootURL: root)
        _ = try await Self.commit(
            png: priorPNG,
            path: path,
            metadata: metadata,
            store: initialStore
        )
        let replacementPNG = Data("replacement".utf8)
        let faultingStore = AppliedIconStore(
            rootURL: root,
            faultInjection: .afterIndexCommitBeforeCleanup
        )
        let writer = RecordingAppliedIconWriter(applyResults: [true], removeResults: [])
        let persistence = AppliedIconPersistence(
            store: faultingStore,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: writer,
            customIconInspector: StubAppliedIconInspector(
                states: [:],
                fingerprints: [path: "replacement-fingerprint"]
            )
        )

        #expect(await persistence.applyPNGData(replacementPNG, toAppAt: path))

        let committed = try #require(try await initialStore.records().first)
        #expect(committed.customIconFingerprint == "replacement-fingerprint")
        #expect(try await initialStore.iconData(for: committed) == replacementPNG)
        #expect(await writer.appliedPayloads() == [replacementPNG])
        #expect(await writer.removeCount() == 0)
    }

    @Test func restoreInterruptedAfterRemovalRetainsPNGAndStartupNeverRestoresIt() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppliedIconStore(rootURL: root)
        let path = "/Applications/Fixture.app"
        let metadata = Self.metadata(revision: "v1")
        let png = try #require(Self.pngData())
        let record = try await Self.commit(
            png: png,
            path: path,
            metadata: metadata,
            store: store
        )
        let writer = RecordingAppliedIconWriter(applyResults: [], removeResults: [true])
        let interrupted = AppliedIconPersistence(
            store: store,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: writer,
            customIconInspector: StubAppliedIconInspector(
                states: [path: .macBuddyOwned(fingerprint: "prior-fingerprint")],
                fingerprints: [path: nil]
            ),
            pathChecker: StubPathChecker(existingPaths: [path]),
            faultInjection: .afterExternalIconRemoval
        )

        _ = await interrupted.restoreOriginals(legacyPaths: [])

        #expect(try #require(try await store.records().first).id == record.id)
        #expect(try await store.iconData(for: record) == png)
        #expect(try await store.pendingRestoreTransactions().count == 1)

        let dockRefresher = RecordingDockRefresher()
        let recovered = AppliedIconPersistence(
            store: store,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: writer,
            customIconInspector: StubAppliedIconInspector(
                states: [path: .absent],
                fingerprints: [path: nil]
            ),
            candidateProvider: StubCandidateProvider(candidates: [
                AppliedIconCandidate(
                    path: path,
                    bundleIdentifier: metadata.bundleIdentifier,
                    signedMetadata: metadata
                )
            ]),
            dockRefresher: dockRefresher,
            pathChecker: StubPathChecker(existingPaths: [path])
        )

        await recovered.reconcileAtStartupIfNeeded()

        #expect(try await store.records().isEmpty)
        #expect(try await store.pendingRestoreTransactions().isEmpty)
        #expect(await writer.applyCount() == 0)
        #expect(await writer.removeCount() == 1)
        #expect(await dockRefresher.refreshCount() == 1)

        let nextLaunch = AppliedIconPersistence(
            store: store,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: writer,
            customIconInspector: StubAppliedIconInspector(states: [:], fingerprints: [:]),
            candidateProvider: StubCandidateProvider(candidates: []),
            dockRefresher: dockRefresher,
            pathChecker: StubPathChecker(existingPaths: [path])
        )
        await nextLaunch.reconcileAtStartupIfNeeded()
        #expect(await writer.applyCount() == 0)
        #expect(await dockRefresher.refreshCount() == 1)
    }

    @Test func restoreIndexCommitCrashLeavesCleanupTombstoneAndCannotReapply() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "/Applications/Fixture.app"
        let metadata = Self.metadata(revision: "v1")
        let png = try #require(Self.pngData())
        let initialStore = AppliedIconStore(rootURL: root)
        _ = try await Self.commit(
            png: png,
            path: path,
            metadata: metadata,
            store: initialStore
        )
        let faultingStore = AppliedIconStore(
            rootURL: root,
            faultInjection: .afterRestoreIndexCommitBeforeCleanup
        )
        let writer = RecordingAppliedIconWriter(applyResults: [], removeResults: [true])
        let interruptedDockRefresher = RecordingDockRefresher()
        let persistence = AppliedIconPersistence(
            store: faultingStore,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: writer,
            customIconInspector: StubAppliedIconInspector(
                states: [path: .macBuddyOwned(fingerprint: "prior-fingerprint")],
                fingerprints: [path: nil]
            ),
            dockRefresher: interruptedDockRefresher,
            pathChecker: StubPathChecker(existingPaths: [path])
        )

        _ = await persistence.restoreOriginals(legacyPaths: [])

        #expect(try await initialStore.records().isEmpty)
        let tombstone = try #require(
            try await initialStore.pendingRestoreTransactions().first
        )
        #expect(tombstone.phase == .removalVerified)
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: root.appending(path: "records"),
                includingPropertiesForKeys: nil
            ).count == 1
        )

        let dockRefresher = RecordingDockRefresher()
        let recoveredStore = AppliedIconStore(rootURL: root)
        let recovered = AppliedIconPersistence(
            store: recoveredStore,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: writer,
            customIconInspector: StubAppliedIconInspector(states: [:], fingerprints: [:]),
            candidateProvider: StubCandidateProvider(candidates: []),
            dockRefresher: dockRefresher,
            pathChecker: StubPathChecker(existingPaths: [path])
        )

        await recovered.reconcileAtStartupIfNeeded()

        #expect(try await recoveredStore.pendingRestoreTransactions().isEmpty)
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: root.appending(path: "records"),
                includingPropertiesForKeys: nil
            ).isEmpty
        )
        #expect(await writer.applyCount() == 0)
        #expect(await writer.removeCount() == 1)
        #expect(await interruptedDockRefresher.refreshCount() == 1)
        #expect(await dockRefresher.refreshCount() == 1)
    }

    @Test func explicitRestoreCannotInterleaveWithSuspendedStartupReconciliation() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppliedIconStore(rootURL: root)
        let path = "/Applications/Fixture.app"
        let v1 = Self.metadata(revision: "v1")
        let v2 = Self.metadata(revision: "v2")
        let png = try #require(Self.pngData())
        _ = try await Self.commit(png: png, path: path, metadata: v1, store: store)
        let iconWorld = SimulatedCustomIconWorld(fingerprint: nil)
        let writer = SuspendedAppliedIconWriter(world: iconWorld)
        let inspector = SimulatedAppliedIconInspector(world: iconWorld)
        let dockRefresher = RecordingDockRefresher()
        let persistence = AppliedIconPersistence(
            store: store,
            metadataReader: StubSignedMetadataReader(values: [path: v2]),
            iconWriter: writer,
            customIconInspector: inspector,
            candidateProvider: StubCandidateProvider(candidates: [
                AppliedIconCandidate(
                    path: path,
                    bundleIdentifier: v2.bundleIdentifier,
                    signedMetadata: v2
                )
            ]),
            dockRefresher: dockRefresher,
            pathChecker: StubPathChecker(existingPaths: [path])
        )

        let startup = Task {
            await persistence.reconcileAtStartupIfNeeded()
        }
        await writer.waitUntilApplyStarts()
        let explicitRestore = Task {
            await persistence.restoreOriginals(legacyPaths: [])
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        await writer.resumeApply()
        await startup.value
        _ = await explicitRestore.value

        #expect(try await store.records().isEmpty)
        #expect(try await store.pendingRestoreTransactions().isEmpty)
        #expect(await iconWorld.currentFingerprint() == nil)
        #expect(await writer.applyCount() == 1)
        #expect(await writer.removeCount() == 1)
        #expect(await dockRefresher.refreshCount() == 2)
    }

    @Test func startupRecoveryCanRetryInTheSameProcessAfterTransientStoreFailure() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppliedIconStore(rootURL: root)
        let path = "/Applications/Fixture.app"
        let metadata = Self.metadata(revision: "v1")
        let png = try #require(Self.pngData())
        let stage = try await store.stageNewApplication(
            pngData: png,
            path: path,
            metadata: metadata
        )
        try await store.markApplicationSucceeded(
            stage,
            customIconFingerprint: "applied-fingerprint"
        )

        let indexURL = root.appending(path: "index.json")
        let validIndex = Data(#"{"schemaVersion":1,"generations":{}}"#.utf8)
        try Data("temporarily-corrupt-index".utf8).write(to: indexURL, options: .atomic)
        let dockRefresher = RecordingDockRefresher()
        let persistence = AppliedIconPersistence(
            store: store,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: RecordingAppliedIconWriter(applyResults: [], removeResults: []),
            customIconInspector: StubAppliedIconInspector(states: [:], fingerprints: [:]),
            candidateProvider: StubCandidateProvider(candidates: []),
            dockRefresher: dockRefresher
        )

        await persistence.reconcileAtStartupIfNeeded()
        try validIndex.write(to: indexURL, options: .atomic)
        await persistence.reconcileAtStartupIfNeeded()

        let record = try #require(try await store.records().first)
        #expect(record.customIconFingerprint == "applied-fingerprint")
        #expect(try await store.iconData(for: record) == png)
        #expect(await dockRefresher.refreshCount() == 1)
    }

    @Test func startupRecoveryRetriesAStageThatFaultedAfterJournalWrite() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "/Applications/Fixture.app"
        let metadata = Self.metadata(revision: "v1")
        let png = try #require(Self.pngData())
        let stagingStore = AppliedIconStore(rootURL: root)
        let stage = try await stagingStore.stageNewApplication(
            pngData: png,
            path: path,
            metadata: metadata
        )
        try await stagingStore.markApplicationSucceeded(
            stage,
            customIconFingerprint: "applied-fingerprint"
        )
        let faultingStore = AppliedIconStore(
            rootURL: root,
            faultInjection: .afterCommitJournalWriteBeforeMove
        )
        let dockRefresher = RecordingDockRefresher()
        let persistence = AppliedIconPersistence(
            store: faultingStore,
            metadataReader: StubSignedMetadataReader(values: [path: metadata]),
            iconWriter: RecordingAppliedIconWriter(applyResults: [], removeResults: []),
            customIconInspector: StubAppliedIconInspector(states: [:], fingerprints: [:]),
            candidateProvider: StubCandidateProvider(candidates: []),
            dockRefresher: dockRefresher
        )

        await persistence.reconcileAtStartupIfNeeded()
        #expect(try await faultingStore.records().isEmpty)
        await persistence.reconcileAtStartupIfNeeded()

        #expect(try await faultingStore.records().count == 1)
        #expect(try await faultingStore.finalizeSucceededStages() == 0)
        #expect(await dockRefresher.refreshCount() == 1)
    }

    @Test func failedBatchIncludesRollbackWritesAndRemovalsInOneDockRefresh() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppliedIconStore(rootURL: root)
        let metadata = Self.metadata(revision: "v1")
        let reapplyPath = "/Applications/Reapply.app"
        let firstApplyPath = "/Applications/First.app"
        let priorPNG = try #require(Self.pngData())
        _ = try await Self.commit(
            png: priorPNG,
            path: reapplyPath,
            metadata: metadata,
            store: store
        )
        let writer = RecordingAppliedIconWriter(
            applyResults: [true, true, true],
            removeResults: [true]
        )
        let inspector = SequencedAppliedIconInspector(fingerprints: [
            .value("prior-fingerprint"),
            .failure,
            .value("rolled-back-fingerprint"),
            .value(nil),
            .failure,
            .value(nil)
        ])
        let dockRefresher = RecordingDockRefresher()
        let persistence = AppliedIconPersistence(
            store: store,
            metadataReader: StubSignedMetadataReader(values: [
                reapplyPath: metadata,
                firstApplyPath: metadata
            ]),
            iconWriter: writer,
            customIconInspector: inspector,
            dockRefresher: dockRefresher
        )

        let outcomes = await persistence.applyPNGBatch([
            .init(pngData: Data("replacement".utf8), path: reapplyPath),
            .init(pngData: Data("first".utf8), path: firstApplyPath)
        ])

        #expect(outcomes.map(\.succeeded) == [false, false])
        #expect(outcomes.allSatisfy { $0.didMutateIcon })
        #expect(await writer.applyCount() == 3)
        #expect(await writer.removeCount() == 1)
        #expect(await dockRefresher.refreshCount() == 1)
    }

    @Test func finalizeFailureKeepsVerifiedIconForJournalRecovery() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "/Applications/Fixture.app"
        let priorPNG = try #require(Self.pngData())
        let initialStore = AppliedIconStore(rootURL: root)
        let v1 = try await Self.commit(
            png: priorPNG,
            path: path,
            metadata: Self.metadata(revision: "v1"),
            store: initialStore
        )
        let v2Metadata = Self.metadata(revision: "v2")
        let replacementPNG = Data("verified-replacement-png".utf8)
        let crashingStore = AppliedIconStore(
            rootURL: root,
            faultInjection: .afterGenerationMoveBeforeIndexCommit
        )
        let writer = RecordingAppliedIconWriter(applyResults: [true], removeResults: [true])
        let persistence = AppliedIconPersistence(
            store: crashingStore,
            metadataReader: StubSignedMetadataReader(values: [path: v2Metadata]),
            iconWriter: writer,
            customIconInspector: StubAppliedIconInspector(
                states: [path: .macBuddyOwned(fingerprint: "replacement-fingerprint")],
                fingerprints: [path: "replacement-fingerprint"]
            )
        )

        #expect(await persistence.applyPNGData(replacementPNG, toAppAt: path) == false)
        #expect(await writer.removeCount() == 0)
        #expect(try #require(try await initialStore.records().first).id == v1.id)
        #expect(try #require(try await initialStore.records().first).signedRevision.cdHash == "v1")

        let recoveredStore = AppliedIconStore(rootURL: root)
        #expect(try await recoveredStore.finalizeSucceededStages() == 1)
        let recovered = try #require(try await recoveredStore.records().first)
        #expect(recovered.id == v1.id)
        #expect(recovered.signedRevision.cdHash == "v2")
        #expect(recovered.customIconFingerprint == "replacement-fingerprint")
        #expect(try await recoveredStore.iconData(for: recovered) == replacementPNG)
    }

    @Test func startupRestoresMultipleRecordsWithOneDockRefresh() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppliedIconStore(rootURL: root)
        let png = try #require(Self.pngData())
        let paths = ["/Applications/One.app", "/Applications/Two.app"]
        let v1 = Self.metadata(revision: "v1")
        let v2 = Self.metadata(revision: "v2")
        for path in paths {
            _ = try await Self.commit(png: png, path: path, metadata: v1, store: store)
        }
        let writer = RecordingAppliedIconWriter(
            applyResults: [true, true],
            removeResults: []
        )
        let inspector = StubAppliedIconInspector(
            states: Dictionary(uniqueKeysWithValues: paths.map { ($0, .absent) }),
            fingerprints: Dictionary(uniqueKeysWithValues: paths.map {
                ($0, "restored-\($0)")
            })
        )
        let candidates = paths.map {
            AppliedIconCandidate(
                path: $0,
                bundleIdentifier: v2.bundleIdentifier,
                signedMetadata: v2
            )
        }
        let dockRefresher = RecordingDockRefresher()
        let persistence = AppliedIconPersistence(
            store: store,
            metadataReader: StubSignedMetadataReader(
                values: Dictionary(uniqueKeysWithValues: paths.map { ($0, v2) })
            ),
            iconWriter: writer,
            customIconInspector: inspector,
            candidateProvider: StubCandidateProvider(candidates: candidates),
            dockRefresher: dockRefresher
        )

        await persistence.reconcileAtStartupIfNeeded()

        #expect(await writer.applyCount() == 2)
        #expect(await dockRefresher.refreshCount() == 1)
        let records = try await store.records()
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.signedRevision.cdHash == "v2" })
        #expect(records.allSatisfy { $0.retryState == .ready })
    }

    private static func commit(
        png: Data,
        path: String,
        metadata: SignedAppMetadata,
        store: AppliedIconStore
    ) async throws -> AppliedIconRecord {
        let stage = try await store.stageNewApplication(
            pngData: png,
            path: path,
            metadata: metadata
        )
        try await store.markApplicationSucceeded(stage, customIconFingerprint: "prior-fingerprint")
        return try await store.finalize(stage)
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

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "applied-icon-persistence-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private static func pngData() -> Data? {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=")
    }
}

private nonisolated struct StubSignedMetadataReader: SignedAppMetadataReading {
    let values: [String: SignedAppMetadata]

    func metadata(forAppAt path: String) throws -> SignedAppMetadata {
        guard let value = values[path] else { throw CocoaError(.fileNoSuchFile) }
        return value
    }
}

private actor RecordingAppliedIconWriter: AppliedIconWriting {
    private var applyResults: [Bool]
    private var removeResults: [Bool]
    private var appliedData: [Data] = []
    private var removedPaths: [String] = []

    init(applyResults: [Bool], removeResults: [Bool]) {
        self.applyResults = applyResults
        self.removeResults = removeResults
    }

    func apply(pngData: Data, toAppAt path: String) -> Bool {
        appliedData.append(pngData)
        return applyResults.isEmpty ? true : applyResults.removeFirst()
    }

    func removeCustomIcon(atAppPath path: String) -> Bool {
        removedPaths.append(path)
        return removeResults.isEmpty ? true : removeResults.removeFirst()
    }

    func applyCount() -> Int { appliedData.count }
    func appliedPayloads() -> [Data] { appliedData }
    func removeCount() -> Int { removedPaths.count }
}

private actor StubAppliedIconInspector: AppliedIconInspecting {
    private let states: [String: ObservedCustomIconState]
    private var fingerprints: [String: String?]

    init(states: [String: ObservedCustomIconState], fingerprints: [String: String?]) {
        self.states = states
        self.fingerprints = fingerprints
    }

    func state(atAppPath path: String, expectedFingerprint: String) -> ObservedCustomIconState {
        states[path] ?? .absent
    }

    func fingerprintIfPresent(atAppPath path: String) throws -> String? {
        fingerprints[path] ?? nil
    }
}

private nonisolated enum StubFingerprintResult: Sendable {
    case value(String?)
    case failure
}

private actor SequencedAppliedIconInspector: AppliedIconInspecting {
    private var fingerprints: [StubFingerprintResult]
    private let observedState: ObservedCustomIconState

    init(
        fingerprints: [StubFingerprintResult],
        state: ObservedCustomIconState = .absent
    ) {
        self.fingerprints = fingerprints
        observedState = state
    }

    func state(atAppPath path: String, expectedFingerprint: String) -> ObservedCustomIconState {
        observedState
    }

    func fingerprintIfPresent(atAppPath path: String) throws -> String? {
        guard !fingerprints.isEmpty else { return nil }
        switch fingerprints.removeFirst() {
        case let .value(value):
            return value
        case .failure:
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

private nonisolated struct StubCandidateProvider: AppliedIconCandidateProviding {
    let candidates: [AppliedIconCandidate]

    func candidate(at path: String) -> AppliedIconCandidate? {
        candidates.first { $0.path == path }
    }

    func dockCandidates() -> [AppliedIconCandidate] {
        candidates
    }
}

private nonisolated struct StubPathChecker: AppliedIconPathChecking {
    let existingPaths: Set<String>

    init(existingPaths: Set<String>) {
        self.existingPaths = existingPaths
    }

    func fileExists(atPath path: String) -> Bool {
        existingPaths.contains(path)
    }
}

private actor RecordingDockRefresher: AppliedIconDockRefreshing {
    private var count = 0

    func refreshDock() {
        count += 1
    }

    func refreshCount() -> Int { count }
}

private actor SimulatedCustomIconWorld {
    private var fingerprint: String?

    init(fingerprint: String?) {
        self.fingerprint = fingerprint
    }

    func setFingerprint(_ fingerprint: String?) {
        self.fingerprint = fingerprint
    }

    func currentFingerprint() -> String? {
        fingerprint
    }
}

private nonisolated struct SimulatedAppliedIconInspector: AppliedIconInspecting {
    let world: SimulatedCustomIconWorld

    func state(
        atAppPath path: String,
        expectedFingerprint: String
    ) async -> ObservedCustomIconState {
        guard let fingerprint = await world.currentFingerprint() else {
            return .absent
        }
        return fingerprint == expectedFingerprint
            ? .macBuddyOwned(fingerprint: fingerprint)
            : .unknown
    }

    func fingerprintIfPresent(atAppPath path: String) async throws -> String? {
        await world.currentFingerprint()
    }
}

private actor SuspendedAppliedIconWriter: AppliedIconWriting {
    private let world: SimulatedCustomIconWorld
    private var applyStarted = false
    private var applyStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var applyContinuation: CheckedContinuation<Void, Never>?
    private var appliedPayloads: [Data] = []
    private var removedPaths: [String] = []

    init(world: SimulatedCustomIconWorld) {
        self.world = world
    }

    func apply(pngData: Data, toAppAt path: String) async -> Bool {
        applyStarted = true
        let waiters = applyStartWaiters
        applyStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            applyContinuation = continuation
        }
        appliedPayloads.append(pngData)
        await world.setFingerprint("restored-fingerprint")
        return true
    }

    func removeCustomIcon(atAppPath path: String) async -> Bool {
        removedPaths.append(path)
        await world.setFingerprint(nil)
        return true
    }

    func waitUntilApplyStarts() async {
        guard !applyStarted else { return }
        await withCheckedContinuation { continuation in
            applyStartWaiters.append(continuation)
        }
    }

    func resumeApply() {
        applyContinuation?.resume()
        applyContinuation = nil
    }

    func applyCount() -> Int { appliedPayloads.count }
    func removeCount() -> Int { removedPaths.count }
}
