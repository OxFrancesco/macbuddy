import Foundation
import Testing

struct AppliedIconResolverTests {
    @Test func validLastPathWinsEvenWhenDockContainsDuplicates() {
        let record = Self.record()
        let metadata = Self.metadata(revision: "v2")
        let resolution = AppliedIconResolver.resolve(
            record: record,
            lastPathCandidate: Self.candidate(path: record.lastPath, metadata: metadata),
            dockCandidates: [
                Self.candidate(path: "/Applications/Copy One.app", metadata: metadata),
                Self.candidate(path: "/Applications/Copy Two.app", metadata: metadata),
            ]
        )

        #expect(resolution == .resolved(path: record.lastPath, metadata: metadata, moved: false))
    }

    @Test func movedAppRequiresExactlyOneSignedDockMatch() {
        let record = Self.record()
        let metadata = Self.metadata(revision: "v2")

        #expect(AppliedIconResolver.resolve(
            record: record,
            lastPathCandidate: nil,
            dockCandidates: [Self.candidate(path: "/Moved/Fixture.app", metadata: metadata)]
        ) == .resolved(path: "/Moved/Fixture.app", metadata: metadata, moved: true))
    }

    @Test func duplicateSignedMatchesAreAmbiguous() {
        let record = Self.record()
        let metadata = Self.metadata(revision: "v2")

        #expect(AppliedIconResolver.resolve(
            record: record,
            lastPathCandidate: nil,
            dockCandidates: [
                Self.candidate(path: "/A/Fixture.app", metadata: metadata),
                Self.candidate(path: "/B/Fixture.app", metadata: metadata),
            ]
        ) == .ambiguous)
    }

    @Test func unverifiableSameBundleCandidatePreventsGuessing() {
        let record = Self.record()
        let metadata = Self.metadata(revision: "v2")
        let unresolved = AppliedIconCandidate(
            path: "/B/Fixture.app",
            bundleIdentifier: metadata.bundleIdentifier,
            signedMetadata: nil
        )

        #expect(AppliedIconResolver.resolve(
            record: record,
            lastPathCandidate: nil,
            dockCandidates: [
                Self.candidate(path: "/A/Fixture.app", metadata: metadata),
                unresolved,
            ]
        ) == .signingMetadataUnavailable)
    }

    @Test func unverifiableLastPathIsRetainedForRetry() {
        let record = Self.record()
        let candidate = AppliedIconCandidate(
            path: record.lastPath,
            bundleIdentifier: record.bundleIdentifier,
            signedMetadata: nil
        )

        #expect(AppliedIconResolver.resolve(
            record: record,
            lastPathCandidate: candidate,
            dockCandidates: []
        ) == .signingMetadataUnavailable)
    }

    @Test func sameBundleFromDifferentTeamDoesNotMatch() {
        let record = Self.record()
        let impostor = Self.metadata(revision: "v2", team: "OTHERTEAM")

        #expect(AppliedIconResolver.resolve(
            record: record,
            lastPathCandidate: nil,
            dockCandidates: [Self.candidate(path: "/Moved/Fixture.app", metadata: impostor)]
        ) == .missing)
    }

    @Test func teamlessIdentityRequiresExactDesignatedRequirement() {
        let stored = SignedAppIdentity(
            teamIdentifier: nil,
            signingIdentifier: "com.example.fixture",
            designatedRequirement: "identifier com.example.fixture and anchor apple"
        )
        let same = SignedAppIdentity(
            teamIdentifier: nil,
            signingIdentifier: "com.example.fixture",
            designatedRequirement: "identifier com.example.fixture and anchor apple"
        )
        let changed = SignedAppIdentity(
            teamIdentifier: nil,
            signingIdentifier: "com.example.fixture",
            designatedRequirement: "cdhash H\"different\""
        )

        #expect(stored.matches(same))
        #expect(!stored.matches(changed))
    }

    private static func candidate(path: String, metadata: SignedAppMetadata) -> AppliedIconCandidate {
        AppliedIconCandidate(
            path: path,
            bundleIdentifier: metadata.bundleIdentifier,
            signedMetadata: metadata
        )
    }

    private static func record() -> AppliedIconRecord {
        AppliedIconRecord(
            schemaVersion: AppliedIconRecord.schemaVersion,
            id: "fixture",
            lastPath: "/Applications/Fixture.app",
            bundleIdentifier: "com.example.fixture",
            signingIdentity: metadata(revision: "v1").identity,
            signedRevision: metadata(revision: "v1").revision,
            appliedPNG_SHA256: "png-sha",
            customIconFingerprint: "finder-sha",
            retryState: .ready,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private static func metadata(revision: String, team: String = "TEAM123") -> SignedAppMetadata {
        SignedAppMetadata(
            bundleIdentifier: "com.example.fixture",
            identity: SignedAppIdentity(
                teamIdentifier: team,
                signingIdentifier: "com.example.fixture",
                designatedRequirement: "designated \(revision)"
            ),
            revision: SignedAppRevision(
                cdHash: revision,
                bundleVersion: revision,
                shortVersion: nil
            )
        )
    }
}
