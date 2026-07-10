import Foundation
import Testing

struct CustomIconInspectorTests {
    @Test func resourceForkParticipatesInFingerprint() throws {
        let first = try CustomIconInspector.fingerprint(for: .init(
            finderInfo: Self.finderInfoWithCustomIconFlag,
            iconFileExists: true,
            dataFork: Data("data".utf8),
            resourceFork: Self.usableResourceFork(prefix: 0x01)
        ))
        let second = try CustomIconInspector.fingerprint(for: .init(
            finderInfo: Self.finderInfoWithCustomIconFlag,
            iconFileExists: true,
            dataFork: Data("data".utf8),
            resourceFork: Self.usableResourceFork(prefix: 0x02)
        ))

        #expect(first != nil)
        #expect(first != second)
    }

    @Test func nonemptyGarbageResourceForkIsNotAUsableCustomIcon() {
        #expect(throws: CocoaError.self) {
            _ = try CustomIconInspector.fingerprint(for: .init(
                finderInfo: Self.finderInfoWithCustomIconFlag,
                iconFileExists: true,
                dataFork: Data("nonempty-data-fork".utf8),
                resourceFork: Data("not-an-icns-resource".utf8)
            ))
        }
    }

    @Test func truncatedICNSResourceIsNotAUsableCustomIcon() {
        var truncated = Self.usableResourceFork(prefix: 0x01)
        truncated.removeLast()
        #expect(throws: CocoaError.self) {
            _ = try CustomIconInspector.fingerprint(for: .init(
                finderInfo: Self.finderInfoWithCustomIconFlag,
                iconFileExists: true,
                dataFork: Data(),
                resourceFork: truncated
            ))
        }
    }

    @Test func cleanAbsenceAndInconsistentFinderArtifactsStayDistinct() throws {
        #expect(try CustomIconInspector.fingerprint(for: .init(
            finderInfo: nil,
            iconFileExists: false,
            dataFork: Data(),
            resourceFork: Data()
        )) == nil)

        #expect(throws: CocoaError.self) {
            _ = try CustomIconInspector.fingerprint(for: .init(
                finderInfo: Self.finderInfoWithCustomIconFlag,
                iconFileExists: false,
                dataFork: Data(),
                resourceFork: Data()
            ))
        }
    }

    private static var finderInfoWithCustomIconFlag: Data {
        var data = Data(repeating: 0, count: 32)
        data[8] = 0x04
        return data
    }

    /// Finder stores an ICNS container inside Icon\r's resource fork. This
    /// compact fixture uses a decodable PNG element and a variable outer-fork
    /// prefix so fingerprint changes remain observable.
    private static func usableResourceFork(prefix: UInt8) -> Data {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=")!
        var icns = Data("icns".utf8)
        appendBigEndian(UInt32(16 + png.count), to: &icns)
        icns.append(Data("icp4".utf8))
        appendBigEndian(UInt32(8 + png.count), to: &icns)
        icns.append(png)

        var resourceFork = Data([prefix, 0, 0, 0])
        resourceFork.append(icns)
        return resourceFork
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
