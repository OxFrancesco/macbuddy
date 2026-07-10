import Darwin
import Foundation
import ImageIO

/// Identifies the exact Finder custom-icon artifact produced by a successful
/// setIcon call. The resource fork matters: Icon\r's data fork is commonly
/// empty even though the icon itself is present.
nonisolated enum CustomIconInspector {
    struct Artifact: Equatable, Sendable {
        let finderInfo: Data?
        let iconFileExists: Bool
        let dataFork: Data
        let resourceFork: Data
    }

    private static let finderInfoName = "com.apple.FinderInfo"
    private static let customIconMask: UInt8 = 0x04

    static func state(
        atAppPath path: String,
        expectedFingerprint: String
    ) -> ObservedCustomIconState {
        do {
            guard let fingerprint = try fingerprintIfPresent(atAppPath: path) else {
                return .absent
            }
            return fingerprint == expectedFingerprint
                ? .macBuddyOwned(fingerprint: fingerprint)
                : .unknown
        } catch {
            return .unreadable
        }
    }

    /// Returns nil only for the clean, internally consistent "no custom icon"
    /// state. Inconsistent Finder metadata is treated as unknown via an error.
    static func fingerprintIfPresent(atAppPath path: String) throws -> String? {
        let finderInfo = try extendedAttribute(named: finderInfoName, atPath: path)
        let hasCustomIconFlag = hasCustomIconFlag(in: finderInfo)

        let iconURL = URL(filePath: path).appending(path: "Icon\r")
        let iconPath = iconURL.path(percentEncoded: false)
        let hasIconFile = FileManager.default.fileExists(atPath: iconPath)

        if !hasCustomIconFlag, !hasIconFile {
            return try fingerprint(for: Artifact(
                finderInfo: finderInfo,
                iconFileExists: false,
                dataFork: Data(),
                resourceFork: Data()
            ))
        }
        guard hasCustomIconFlag, hasIconFile else {
            return try fingerprint(for: Artifact(
                finderInfo: finderInfo,
                iconFileExists: hasIconFile,
                dataFork: Data(),
                resourceFork: Data()
            ))
        }

        let dataFork = try Data(contentsOf: iconURL)
        let resourceForkURL = URL(filePath: iconPath + "/..namedfork/rsrc")
        let resourceFork = try Data(contentsOf: resourceForkURL)
        return try fingerprint(for: Artifact(
            finderInfo: finderInfo,
            iconFileExists: true,
            dataFork: dataFork,
            resourceFork: resourceFork
        ))
    }

    /// Pure classification and hashing seam used by tests. It mirrors the
    /// Finder flag plus Icon\r consistency rule without creating xattrs or
    /// mutating an application bundle.
    static func fingerprint(for artifact: Artifact) throws -> String? {
        let hasCustomIconFlag = hasCustomIconFlag(in: artifact.finderInfo)
        if !hasCustomIconFlag, !artifact.iconFileExists {
            return nil
        }
        guard hasCustomIconFlag, artifact.iconFileExists,
              containsUsableICNSResource(artifact.resourceFork) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var fingerprintInput = Data()
        append(artifact.dataFork, to: &fingerprintInput)
        append(artifact.resourceFork, to: &fingerprintInput)
        return AppliedIconSHA256.hexDigest(fingerprintInput)
    }

    /// NSWorkspace embeds an ICNS container in Icon\r's resource fork. The
    /// bundled fileicon reference locates the `icns` magic and trusts its
    /// big-endian length; additionally decoding it keeps corrupt or merely
    /// nonempty forks from being treated as a custom icon we own.
    private static func containsUsableICNSResource(_ resourceFork: Data) -> Bool {
        let magic = Data("icns".utf8)
        var searchStart = resourceFork.startIndex
        while searchStart < resourceFork.endIndex,
              let magicRange = resourceFork.range(
                of: magic,
                in: searchStart..<resourceFork.endIndex
              ) {
            let lengthStart = magicRange.upperBound
            let lengthEnd = resourceFork.index(
                lengthStart,
                offsetBy: 4,
                limitedBy: resourceFork.endIndex
            )
            guard let lengthEnd else { return false }
            let declaredLength = resourceFork[lengthStart..<lengthEnd].reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            if declaredLength >= 8,
               let icnsEnd = resourceFork.index(
                   magicRange.lowerBound,
                   offsetBy: Int(declaredLength),
                   limitedBy: resourceFork.endIndex
               ) {
                let icnsData = resourceFork[magicRange.lowerBound..<icnsEnd]
                if let source = CGImageSourceCreateWithData(icnsData as CFData, nil),
                   CGImageSourceGetCount(source) > 0,
                   CGImageSourceCreateImageAtIndex(source, 0, nil) != nil {
                    return true
                }
            }
            searchStart = magicRange.upperBound
        }
        return false
    }

    private static func hasCustomIconFlag(in finderInfo: Data?) -> Bool {
        finderInfo.map {
            $0.count > 8 && ($0[$0.startIndex + 8] & customIconMask) != 0
        } ?? false
    }

    private static func append(_ data: Data, to target: inout Data) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { target.append(contentsOf: $0) }
        target.append(data)
    }

    private static func extendedAttribute(named name: String, atPath path: String) throws -> Data? {
        let size = path.withCString { pathPointer in
            name.withCString { namePointer in
                getxattr(pathPointer, namePointer, nil, 0, 0, 0)
            }
        }
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var data = Data(count: size)
        let bytesRead = data.withUnsafeMutableBytes { buffer in
            path.withCString { pathPointer in
                name.withCString { namePointer in
                    getxattr(pathPointer, namePointer, buffer.baseAddress, size, 0, 0)
                }
            }
        }
        guard bytesRead == size else {
            throw POSIXError(.EIO)
        }
        return data
    }
}
