import Foundation
import Testing

struct AppliedIconStateMachineTests {
    @Test func injectedSignedV1ToV2FixtureTriggersRestoreOnlyWhenIconIsAbsent() throws {
        let fixture = InjectedSignatureMetadataFixture.v1ToV2
        let v1 = try fixture.metadata(forAppAt: "/Fixtures/V1.app")
        let v2 = try fixture.metadata(forAppAt: "/Fixtures/V2.app")
        let record = Self.record(metadata: v1)

        #expect(record.signingIdentity.matches(v2.identity))
        #expect(record.signedRevision != v2.revision)
        #expect(AppliedIconReconciliationStateMachine.decide(
            record: record,
            path: record.lastPath,
            metadata: v2,
            customIcon: .absent
        ) == .restoreAppliedIcon)
        #expect(record.signedRevision == v1.revision)
    }

    @Test func unchangedRevisionNeverRestoresMissingIcon() throws {
        let metadata = try InjectedSignatureMetadataFixture.v1ToV2
            .metadata(forAppAt: "/Fixtures/V1.app")
        let record = Self.record(metadata: metadata)

        #expect(AppliedIconReconciliationStateMachine.decide(
            record: record,
            path: record.lastPath,
            metadata: metadata,
            customIcon: .absent
        ) == .noAction)
    }

    @Test func durableRestoreNeededStateRestoresEvenWhenRevisionIsUnchanged() throws {
        let metadata = try InjectedSignatureMetadataFixture.v1ToV2
            .metadata(forAppAt: "/Fixtures/V1.app")
        var record = Self.record(metadata: metadata)
        record.retryState = AppliedIconRetryState(
            kind: .restoreNeeded,
            detail: "A replacement icon could not be fingerprinted.",
            lastAttemptAt: Date(timeIntervalSince1970: 2)
        )

        #expect(AppliedIconReconciliationStateMachine.decide(
            record: record,
            path: record.lastPath,
            metadata: metadata,
            customIcon: .absent
        ) == .restoreAppliedIcon)
    }

    @Test func unknownCustomIconIsNeverOverwritten() throws {
        let fixture = InjectedSignatureMetadataFixture.v1ToV2
        let record = Self.record(metadata: try fixture.metadata(forAppAt: "/Fixtures/V1.app"))
        let v2 = try fixture.metadata(forAppAt: "/Fixtures/V2.app")

        #expect(AppliedIconReconciliationStateMachine.decide(
            record: record,
            path: record.lastPath,
            metadata: v2,
            customIcon: .unknown
        ) == .retry(.unknownCustomIcon))
    }

    @Test func ownedIconSurvivingUpdateAdvancesRevisionWithoutRewrite() throws {
        let fixture = InjectedSignatureMetadataFixture.v1ToV2
        let record = Self.record(metadata: try fixture.metadata(forAppAt: "/Fixtures/V1.app"))
        let v2 = try fixture.metadata(forAppAt: "/Fixtures/V2.app")

        #expect(AppliedIconReconciliationStateMachine.decide(
            record: record,
            path: record.lastPath,
            metadata: v2,
            customIcon: .macBuddyOwned(fingerprint: record.customIconFingerprint)
        ) == .acceptObservedRevision)
    }

    @Test func mismatchedFingerprintIsTreatedAsUnknown() throws {
        let fixture = InjectedSignatureMetadataFixture.v1ToV2
        let record = Self.record(metadata: try fixture.metadata(forAppAt: "/Fixtures/V1.app"))
        let v2 = try fixture.metadata(forAppAt: "/Fixtures/V2.app")

        #expect(AppliedIconReconciliationStateMachine.decide(
            record: record,
            path: record.lastPath,
            metadata: v2,
            customIcon: .macBuddyOwned(fingerprint: "someone-else")
        ) == .retry(.unknownCustomIcon))
    }

    @Test func safeMoveUpdatesLocationWithoutInventingRevisionChange() throws {
        let metadata = try InjectedSignatureMetadataFixture.v1ToV2
            .metadata(forAppAt: "/Fixtures/V1.app")
        let record = Self.record(metadata: metadata)

        #expect(AppliedIconReconciliationStateMachine.decide(
            record: record,
            path: "/Moved/Fixture.app",
            metadata: metadata,
            customIcon: .absent
        ) == .updateLocation)
    }

    private static func record(metadata: SignedAppMetadata) -> AppliedIconRecord {
        AppliedIconRecord(
            schemaVersion: AppliedIconRecord.schemaVersion,
            id: "fixture",
            lastPath: "/Applications/Fixture.app",
            bundleIdentifier: metadata.bundleIdentifier,
            signingIdentity: metadata.identity,
            signedRevision: metadata.revision,
            appliedPNG_SHA256: "png-sha",
            customIconFingerprint: "finder-sha",
            retryState: .ready,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

/// Credential-free controlled signing fixture. Production metadata comes from
/// Security.framework; these injected values model a stable team/signing ID
/// with distinct revision CDHashes without pretending an ad-hoc build is a
/// stable signed update.
nonisolated struct InjectedSignatureMetadataFixture: SignedAppMetadataReading {
    nonisolated enum FixtureError: Error {
        case missingPath
    }

    let values: [String: SignedAppMetadata]

    func metadata(forAppAt path: String) throws -> SignedAppMetadata {
        guard let metadata = values[path] else { throw FixtureError.missingPath }
        return metadata
    }

    static let v1ToV2: InjectedSignatureMetadataFixture = {
        let identity = SignedAppIdentity(
            teamIdentifier: "TEAM123",
            signingIdentifier: "com.example.fixture",
            designatedRequirement: "anchor apple generic and identifier com.example.fixture"
        )
        return InjectedSignatureMetadataFixture(values: [
            "/Fixtures/V1.app": SignedAppMetadata(
                bundleIdentifier: "com.example.fixture",
                identity: identity,
                revision: SignedAppRevision(
                    cdHash: "1111111111111111111111111111111111111111",
                    bundleVersion: "1",
                    shortVersion: "1.0"
                )
            ),
            "/Fixtures/V2.app": SignedAppMetadata(
                bundleIdentifier: "com.example.fixture",
                identity: identity,
                revision: SignedAppRevision(
                    cdHash: "2222222222222222222222222222222222222222",
                    bundleVersion: "2",
                    shortVersion: "2.0"
                )
            ),
        ])
    }()
}
