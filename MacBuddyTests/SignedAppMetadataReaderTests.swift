import Foundation
import Testing

struct SignedAppMetadataReaderTests {
    @Test func readsValidatedIdentityAndRevisionFromSignedSystemApp() throws {
        let path = "/System/Library/CoreServices/Finder.app"
        let metadata = try SecuritySignedAppMetadataReader().metadata(forAppAt: path)

        #expect(metadata.bundleIdentifier == "com.apple.finder")
        #expect(!metadata.identity.signingIdentifier.isEmpty)
        #expect(
            metadata.identity.teamIdentifier != nil
                || metadata.identity.designatedRequirement != nil
        )
        #expect(!metadata.revision.cdHash.isEmpty)
    }
}
