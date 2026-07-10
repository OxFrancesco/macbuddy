import CryptoKit
import Foundation

nonisolated struct SignedAppIdentity: Codable, Equatable, Sendable {
    let teamIdentifier: String?
    let signingIdentifier: String
    let designatedRequirement: String?

    /// Team plus signing identifier survives ordinary signed updates. When a
    /// signer has no team identifier, an exact designated requirement is the
    /// only identity we accept; a CDHash-only ad-hoc requirement intentionally
    /// will not reconcile across builds.
    func matches(_ other: SignedAppIdentity) -> Bool {
        guard signingIdentifier == other.signingIdentifier else { return false }
        switch (teamIdentifier, other.teamIdentifier) {
        case let (left?, right?):
            return left == right
        case (nil, nil):
            guard let left = designatedRequirement,
                  let right = other.designatedRequirement else { return false }
            return left == right
        default:
            return false
        }
    }
}

nonisolated struct SignedAppRevision: Codable, Equatable, Sendable {
    /// Security.framework's kSecCodeInfoUnique CDHash, encoded as lowercase
    /// hexadecimal. Unlike the signing identifier, this changes with code.
    let cdHash: String
    let bundleVersion: String?
    let shortVersion: String?
}

nonisolated struct SignedAppMetadata: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let identity: SignedAppIdentity
    let revision: SignedAppRevision
}

nonisolated protocol SignedAppMetadataReading: Sendable {
    func metadata(forAppAt path: String) throws -> SignedAppMetadata
}

nonisolated enum AppliedIconRetryKind: String, Codable, Equatable, Sendable {
    case ready
    case appMissing
    case ambiguousCandidates
    case signingMetadataUnavailable
    case storedIconCorrupt
    case unknownCustomIcon
    case customIconUnreadable
    case applicationFailed
    case persistenceFailed
    case restoreNeeded
}

nonisolated struct AppliedIconRetryState: Codable, Equatable, Sendable {
    var kind: AppliedIconRetryKind
    var detail: String?
    var lastAttemptAt: Date?

    static let ready = AppliedIconRetryState(kind: .ready, detail: nil, lastAttemptAt: nil)
}

nonisolated struct AppliedIconRecord: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let id: String
    var lastPath: String
    let bundleIdentifier: String
    let signingIdentity: SignedAppIdentity
    var signedRevision: SignedAppRevision
    let appliedPNG_SHA256: String
    var customIconFingerprint: String
    var retryState: AppliedIconRetryState
    let createdAt: Date
    var updatedAt: Date
}

nonisolated struct AppliedIconCandidate: Equatable, Sendable {
    let path: String
    let bundleIdentifier: String?
    let signedMetadata: SignedAppMetadata?
}

nonisolated enum AppliedIconResolution: Equatable, Sendable {
    case resolved(path: String, metadata: SignedAppMetadata, moved: Bool)
    case missing
    case ambiguous
    case signingMetadataUnavailable
}

/// Pure candidate selection. A valid last path always wins. For moved apps we
/// require one unambiguous Dock candidate and refuse to guess when another
/// same-bundle candidate could not be signature-checked.
nonisolated enum AppliedIconResolver {
    static func resolve(
        record: AppliedIconRecord,
        lastPathCandidate: AppliedIconCandidate?,
        dockCandidates: [AppliedIconCandidate]
    ) -> AppliedIconResolution {
        if let lastPathCandidate, lastPathCandidate.path == record.lastPath {
            if let metadata = lastPathCandidate.signedMetadata,
               metadataMatches(metadata, record: record) {
                return .resolved(
                    path: lastPathCandidate.path,
                    metadata: metadata,
                    moved: false
                )
            }
            if lastPathCandidate.signedMetadata == nil {
                return .signingMetadataUnavailable
            }
        }

        var seenPaths: Set<String> = []
        let sameBundleCandidates = dockCandidates.filter { candidate in
            seenPaths.insert(candidate.path).inserted
                && candidate.bundleIdentifier == record.bundleIdentifier
        }
        let matches = sameBundleCandidates.filter {
            metadataMatches($0.signedMetadata, record: record)
        }
        let unresolved = sameBundleCandidates.contains { $0.signedMetadata == nil }

        if matches.count > 1 {
            return .ambiguous
        }
        if matches.count == 1, !unresolved, let metadata = matches[0].signedMetadata {
            return .resolved(path: matches[0].path, metadata: metadata, moved: true)
        }
        if unresolved {
            return .signingMetadataUnavailable
        }
        return .missing
    }

    private static func metadataMatches(
        _ metadata: SignedAppMetadata?,
        record: AppliedIconRecord
    ) -> Bool {
        guard let metadata else { return false }
        return metadata.bundleIdentifier == record.bundleIdentifier
            && record.signingIdentity.matches(metadata.identity)
    }
}

nonisolated enum ObservedCustomIconState: Equatable, Sendable {
    case absent
    case macBuddyOwned(fingerprint: String)
    case unknown
    case unreadable
}

nonisolated enum AppliedIconReconciliationDecision: Equatable, Sendable {
    case noAction
    case updateLocation
    case acceptObservedRevision
    case restoreAppliedIcon
    case retry(AppliedIconRetryKind)
}

/// Pure policy for one resolved app. It never schedules a write over an
/// unknown custom icon and only schedules restoration after a signed revision
/// transition when the custom icon is absent.
nonisolated enum AppliedIconReconciliationStateMachine {
    static func decide(
        record: AppliedIconRecord,
        path: String,
        metadata: SignedAppMetadata,
        customIcon: ObservedCustomIconState
    ) -> AppliedIconReconciliationDecision {
        let revisionChanged = metadata.revision != record.signedRevision
        let pathChanged = path != record.lastPath

        switch customIcon {
        case .unknown:
            return .retry(.unknownCustomIcon)
        case .unreadable:
            return .retry(.customIconUnreadable)
        case .absent:
            if record.retryState.kind == .restoreNeeded {
                return .restoreAppliedIcon
            }
            if revisionChanged {
                return .restoreAppliedIcon
            }
            return pathChanged ? .updateLocation : .noAction
        case let .macBuddyOwned(fingerprint):
            guard fingerprint == record.customIconFingerprint else {
                return .retry(.unknownCustomIcon)
            }
            if revisionChanged {
                return .acceptObservedRevision
            }
            return pathChanged ? .updateLocation : .noAction
        }
    }
}

nonisolated enum AppliedIconSHA256 {
    static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
