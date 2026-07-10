import Foundation
import Testing

struct AppliedIconAvailabilityTests {
    @Test func refreshTracksDurableRecordsWithoutLegacyPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "applied-icon-availability-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppliedIconStore(rootURL: root)
        let availability = AppliedIconAvailability(store: store)

        await availability.refresh()
        #expect(availability.hasDurableRecords == false)

        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII="))
        let stage = try await store.stageNewApplication(
            pngData: png,
            path: "/Applications/Fixture.app",
            metadata: Self.metadata
        )
        try await store.markApplicationSucceeded(stage, customIconFingerprint: "finder-v1")
        let record = try await store.finalize(stage)

        await availability.refresh()
        #expect(availability.hasDurableRecords)

        try await store.retire(recordID: record.id)
        await availability.refresh()
        #expect(availability.hasDurableRecords == false)
    }

    private static let metadata = SignedAppMetadata(
        bundleIdentifier: "com.example.fixture",
        identity: SignedAppIdentity(
            teamIdentifier: "TEAM123",
            signingIdentifier: "com.example.fixture",
            designatedRequirement: "anchor apple generic and identifier com.example.fixture"
        ),
        revision: SignedAppRevision(
            cdHash: "v1",
            bundleVersion: "1",
            shortVersion: "1.0"
        )
    )
}
