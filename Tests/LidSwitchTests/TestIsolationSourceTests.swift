import Foundation
import XCTest

final class TestIsolationSourceTests: XCTestCase {
    func testFixtureSourcesDoNotBypassTestSandboxForDiagnosticWrites() throws {
        let sourcesDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let excludedSources: Set<String> = ["TestIsolationSourceTests.swift", "TestSandbox.swift"]
        let sourceFiles = try FileManager.default.contentsOfDirectory(
            at: sourcesDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" && !excludedSources.contains($0.lastPathComponent) }

        let directTemporaryDirectory = ["FileManager.default", "temporaryDirectory"].joined(separator: ".")
        let legacyTemporaryDirectory = ["NSTemporary", "Directory("].joined()
        let temporaryEnvironment = ["TMP", "DIR"].joined()
        let unqualifiedTemporaryRoot = ["/", "tmp"].joined()
        let diagnosticStoreTemporaryPathPattern = [
            "SessionDiagnosticStore\\s*\\(\\s*file:\\s*URL\\s*\\(\\s*fileURLWithPath:\\s*[\\\"]",
            "\\/", "tmp", "(?:\\/|[\\\"])"
        ].joined()
        let diagnosticStoreTemporaryPath = try NSRegularExpression(pattern: diagnosticStoreTemporaryPathPattern)

        for sourceFile in sourceFiles {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            XCTAssertFalse(
                source.contains(directTemporaryDirectory),
                "\(sourceFile.lastPathComponent) bypasses TestSandbox with FileManager temporary directory"
            )
            XCTAssertFalse(
                source.contains(legacyTemporaryDirectory),
                "\(sourceFile.lastPathComponent) bypasses TestSandbox with legacy temporary directory"
            )
            XCTAssertFalse(
                source.contains("environment[\"\(temporaryEnvironment)\"]"),
                "\(sourceFile.lastPathComponent) derives a writable path from TMPDIR"
            )
            if sourceFile.lastPathComponent == "NativeUXStateFixtureTests.swift" {
                XCTAssertFalse(
                    source.contains(unqualifiedTemporaryRoot),
                    "Native UX fixtures must derive diagnostic paths from TestSandbox"
                )
            }
            let range = NSRange(source.startIndex..., in: source)
            XCTAssertEqual(
                diagnosticStoreTemporaryPath.numberOfMatches(in: source, range: range),
                0,
                "\(sourceFile.lastPathComponent) gives SessionDiagnosticStore an unqualified /tmp path"
            )
        }
    }
}
