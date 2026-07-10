import Foundation
import Security

nonisolated enum SignedAppMetadataError: Error, LocalizedError, Sendable {
    case security(operation: String, status: OSStatus)
    case missingSigningField(String)

    var errorDescription: String? {
        switch self {
        case let .security(operation, status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "\(operation) failed: \(message)."
        case let .missingSigningField(field):
            return "The signed app metadata is missing \(field)."
        }
    }
}

/// Reads identity and revision from the validated static code object. Resource
/// validation is skipped because a Finder custom icon intentionally modifies
/// app-bundle resources; executable signatures and all architectures are still
/// checked before any signing information is trusted.
nonisolated struct SecuritySignedAppMetadataReader: SignedAppMetadataReading {
    func metadata(forAppAt path: String) throws -> SignedAppMetadata {
        var code: SecStaticCode?
        try check(
            SecStaticCodeCreateWithPath(URL(filePath: path) as CFURL, [], &code),
            operation: "SecStaticCodeCreateWithPath"
        )
        guard let code else {
            throw SignedAppMetadataError.missingSigningField("static code")
        }

        let validationFlags = SecCSFlags(rawValue:
            kSecCSCheckAllArchitectures | kSecCSDoNotValidateResources
        )
        try check(
            SecStaticCodeCheckValidity(code, validationFlags, nil),
            operation: "SecStaticCodeCheckValidity"
        )

        var information: CFDictionary?
        let informationFlags = SecCSFlags(rawValue:
            kSecCSSigningInformation | kSecCSRequirementInformation
        )
        try check(
            SecCodeCopySigningInformation(code, informationFlags, &information),
            operation: "SecCodeCopySigningInformation"
        )
        guard let values = information as? [CFString: Any] else {
            throw SignedAppMetadataError.missingSigningField("signing information")
        }
        guard let signingIdentifier = values[kSecCodeInfoIdentifier] as? String,
              !signingIdentifier.isEmpty else {
            throw SignedAppMetadataError.missingSigningField("signing identifier")
        }
        guard let cdHashData = values[kSecCodeInfoUnique] as? Data,
              !cdHashData.isEmpty else {
            throw SignedAppMetadataError.missingSigningField("CDHash")
        }
        guard let signedInfo = values[kSecCodeInfoPList] as? [String: Any],
              let bundleIdentifier = signedInfo["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty else {
            throw SignedAppMetadataError.missingSigningField("bundle identifier")
        }

        let teamIdentifier = (values[kSecCodeInfoTeamIdentifier] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        let requirement = try designatedRequirement(for: code)
        guard teamIdentifier != nil || requirement != nil else {
            throw SignedAppMetadataError.missingSigningField("stable signing identity")
        }

        return SignedAppMetadata(
            bundleIdentifier: bundleIdentifier,
            identity: SignedAppIdentity(
                teamIdentifier: teamIdentifier,
                signingIdentifier: signingIdentifier,
                designatedRequirement: requirement
            ),
            revision: SignedAppRevision(
                cdHash: cdHashData.map { String(format: "%02x", $0) }.joined(),
                bundleVersion: signedInfo["CFBundleVersion"] as? String,
                shortVersion: signedInfo["CFBundleShortVersionString"] as? String
            )
        )
    }

    private func designatedRequirement(for code: SecStaticCode) throws -> String? {
        var requirement: SecRequirement?
        let copyStatus = SecCodeCopyDesignatedRequirement(code, [], &requirement)
        if copyStatus == errSecCSReqFailed || copyStatus == errSecCSUnsigned {
            return nil
        }
        try check(copyStatus, operation: "SecCodeCopyDesignatedRequirement")
        guard let requirement else { return nil }

        var text: CFString?
        try check(
            SecRequirementCopyString(requirement, [], &text),
            operation: "SecRequirementCopyString"
        )
        return (text as String?).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else {
            throw SignedAppMetadataError.security(operation: operation, status: status)
        }
    }
}

/// Startup-only Dock discovery without preview rendering or palette state.
nonisolated enum AppliedIconDockCandidates {
    static func paths() -> [String] {
        guard let dockDefaults = UserDefaults(suiteName: "com.apple.dock"),
              let items = dockDefaults.array(forKey: "persistent-apps") as? [[String: Any]] else {
            return []
        }

        var seen: Set<String> = []
        return items.compactMap { item -> String? in
            guard let tileData = item["tile-data"] as? [String: Any],
                  let fileData = tileData["file-data"] as? [String: Any],
                  let urlString = fileData["_CFURLString"] as? String else { return nil }
            let urlType = fileData["_CFURLStringType"] as? Int ?? 15
            let url = urlType == 15 ? URL(string: urlString) : URL(filePath: urlString)
            guard let url else { return nil }
            let path = url.path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: path),
                  seen.insert(path).inserted else { return nil }
            return path
        }
    }
}

nonisolated struct AppliedIconCandidateScanner: Sendable {
    let metadataReader: any SignedAppMetadataReading

    func candidate(at path: String) -> AppliedIconCandidate? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let metadata = try? metadataReader.metadata(forAppAt: path)
        let unsignedBundleIdentifier = Bundle(url: URL(filePath: path))?.bundleIdentifier
        return AppliedIconCandidate(
            path: path,
            bundleIdentifier: metadata?.bundleIdentifier ?? unsignedBundleIdentifier,
            signedMetadata: metadata
        )
    }

    func dockCandidates() -> [AppliedIconCandidate] {
        AppliedIconDockCandidates.paths().compactMap(candidate(at:))
    }
}
