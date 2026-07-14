import Darwin
import Foundation
@testable import LidSwitch

/// Test-only filesystem boundary. It deliberately ignores TMPDIR and accepts
/// only the nonce-owned fixture root injected by the clean safe-wrapper
/// environment. Direct XCTest invocation therefore fails closed.
enum TestSandbox {
    static let literalRoot = "/private/tmp"

    static func configuredFixtureRoot() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["LIDSWITCH_TEST_FIXTURE_ROOT"],
              path.hasPrefix(literalRoot + "/"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path,
              URL(fileURLWithPath: path).lastPathComponent == "fixtures"
        else { throw Error.unsafeRoot }
        let scratch = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard scratch.deletingLastPathComponent().path == literalRoot,
              scratch.lastPathComponent.hasPrefix("lidswitch-swift."),
              (6...32).contains(scratch.lastPathComponent.dropFirst("lidswitch-swift.".count).count),
              scratch.lastPathComponent.dropFirst("lidswitch-swift.".count).allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")
              })
        else { throw Error.unsafeRoot }
        return path
    }

    struct Directory: Equatable {
        let url: URL
        let device: dev_t
        let inode: ino_t
    }

    enum Error: Swift.Error, LocalizedError {
        case unsafeRoot
        case invalidName
        case createFailed
        case unsafeDirectory
        case unsafeBenchmarkOutput(String)

        var errorDescription: String? {
            switch self {
            case .unsafeRoot: return "test sandbox root is not the sealed private execution directory"
            case .invalidName: return "test sandbox name is invalid"
            case .createFailed: return "could not create isolated test sandbox"
            case .unsafeDirectory: return "test sandbox directory failed ownership or identity checks"
            case let .unsafeBenchmarkOutput(reason): return "unsafe benchmark output: \(reason)"
            }
        }
    }

    static func makeDirectory(label: String) throws -> Directory {
        guard !label.isEmpty,
              label.utf8.count <= 64,
              label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else {
            throw Error.invalidName
        }
        let fixtureRoot = try configuredFixtureRoot()
        let rootDescriptor = try openFixtureRoot()
        defer { close(rootDescriptor) }

        let prefix = "lidswitch-\(label)-"
        var template = Array((fixtureRoot + "/" + prefix + "XXXXXX").utf8CString)
        let created: String? = template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }
        guard let path = created,
              directChildName(path: path, of: fixtureRoot)?.hasPrefix(prefix) == true,
              let name = directChildName(path: path, of: fixtureRoot)
        else { throw Error.createFailed }

        var pathStatus = stat()
        guard lstat(path, &pathStatus) == 0 else { throw Error.unsafeDirectory }
        let descriptor = openat(rootDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Error.unsafeDirectory }
        defer { close(descriptor) }
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              pathStatus.st_dev == descriptorStatus.st_dev,
              pathStatus.st_ino == descriptorStatus.st_ino,
              pathStatus.st_mode & S_IFMT == S_IFDIR,
              descriptorStatus.st_mode & S_IFMT == S_IFDIR,
              descriptorStatus.st_uid == getuid(),
              descriptorStatus.st_gid == getgid(),
              descriptorStatus.st_nlink >= 2,
              descriptorStatus.st_mode == (S_IFDIR | 0o700)
        else { throw Error.unsafeDirectory }
        return Directory(url: URL(fileURLWithPath: path, isDirectory: true), device: descriptorStatus.st_dev, inode: descriptorStatus.st_ino)
    }

    /// Reopens one fixture-owned direct child through the sealed execution-root
    /// descriptor. Callers receive a held directory capability, never authority
    /// derived from walking `/private/tmp` by pathname.
    static func openManagedDirectory(at url: URL) throws -> Int32 {
        let fixtureRoot = try configuredFixtureRoot()
        guard url.isFileURL,
              URL(fileURLWithPath: url.path).standardizedFileURL.path == url.path,
              let name = directChildName(path: url.path, of: fixtureRoot)
        else { throw Error.unsafeDirectory }

        let fixtureDescriptor = try openFixtureRoot()
        defer { close(fixtureDescriptor) }
        var before = stat()
        guard fstatat(fixtureDescriptor, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_mode & S_IFMT == S_IFDIR,
              before.st_uid == getuid(),
              before.st_gid == getgid(),
              before.st_nlink >= 2,
              before.st_mode & 0o022 == 0
        else { throw Error.unsafeDirectory }

        let descriptor = openat(fixtureDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Error.unsafeDirectory }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino,
              opened.st_uid == before.st_uid,
              opened.st_gid == before.st_gid,
              opened.st_mode == before.st_mode,
              opened.st_nlink == before.st_nlink
        else {
            close(descriptor)
            throw Error.unsafeDirectory
        }
        return descriptor
    }

    /// Creates a benchmark JSONL exactly once, without following a pathname
    /// after validation. Environment-driven benchmark output is always the
    /// fixed execution-root `benchmark/results.jsonl`; host publication occurs
    /// only after the wrapper proves postflight host preservation.
    static func createBenchmarkOutput(
        at output: URL,
        protectedRoots: [String] = defaultProtectedRoots()
    ) throws -> FileHandle {
        let rawPath = output.path
        guard output.isFileURL, rawPath.hasPrefix("/"), !rawPath.hasPrefix("/tmp/") else {
            throw Error.unsafeBenchmarkOutput("path must use literal /private/tmp")
        }
        guard !protectedRoots.contains(where: { TestPathPolicy.isEqualOrDescendant(rawPath, root: $0) }) else {
            throw Error.unsafeBenchmarkOutput("path is inside a protected root")
        }
        let parent = output.deletingLastPathComponent().path
        let fixtureRoot = try configuredFixtureRoot()
        let executionRoot = URL(fileURLWithPath: fixtureRoot).deletingLastPathComponent().path
        guard let name = directChildName(path: rawPath, of: parent), name == output.lastPathComponent else {
            throw Error.unsafeBenchmarkOutput("output must be one filename in a validated parent")
        }
        let rootDescriptor: Int32
        let parentName: String
        if let fixtureParent = directChildName(path: parent, of: fixtureRoot) {
            rootDescriptor = try openFixtureRoot()
            parentName = fixtureParent
        } else if ProcessInfo.processInfo.environment["LIDSWITCH_BENCHMARK_OUTPUT"] == rawPath,
                  rawPath == executionRoot + "/benchmark/results.jsonl" {
            rootDescriptor = try openExecutionRoot()
            parentName = "benchmark"
        } else {
            throw Error.unsafeBenchmarkOutput("output is outside this run's fixtures and explicit benchmark target")
        }
        defer { close(rootDescriptor) }
        let parentDescriptor = openat(rootDescriptor, parentName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else { throw Error.unsafeBenchmarkOutput("output parent is missing or symlinked") }
        defer { close(parentDescriptor) }
        var parentStatus = stat()
        guard fstat(parentDescriptor, &parentStatus) == 0,
              parentStatus.st_mode & S_IFMT == S_IFDIR,
              parentStatus.st_uid == getuid(),
              parentStatus.st_gid == getgid(),
              parentStatus.st_nlink >= 2,
              parentStatus.st_mode == (S_IFDIR | 0o700)
        else { throw Error.unsafeBenchmarkOutput("output parent must be current-user 0700 directory") }

        var existing = stat()
        if fstatat(parentDescriptor, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            throw Error.unsafeBenchmarkOutput("output target already exists")
        }
        guard errno == ENOENT else { throw Error.unsafeBenchmarkOutput("cannot safely inspect output target") }

        let descriptor = openat(
            parentDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { throw Error.unsafeBenchmarkOutput("could not create output exclusively") }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_gid == getgid(),
              status.st_mode & 0o777 == 0o600,
              status.st_nlink == 1
        else {
            close(descriptor)
            throw Error.unsafeBenchmarkOutput("created output failed ownership or mode checks")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func defaultProtectedRoots(repositoryRoot: String = FileManager.default.currentDirectoryPath) -> [String] {
        [repositoryRoot, AppPaths.userSupportDirectory.path, AppPaths.rootSupportDirectory]
    }

    private static func openFixtureRoot() throws -> Int32 {
        let scratchDescriptor = try openExecutionRoot()
        let fixtureDescriptor = openat(scratchDescriptor, "fixtures", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        close(scratchDescriptor)
        guard fixtureDescriptor >= 0 else { throw Error.unsafeRoot }
        var fixtureStatus = stat()
        guard fstat(fixtureDescriptor, &fixtureStatus) == 0,
              fixtureStatus.st_mode == (S_IFDIR | 0o700),
              fixtureStatus.st_uid == getuid(),
              fixtureStatus.st_gid == getgid(),
              fixtureStatus.st_nlink >= 2
        else {
            close(fixtureDescriptor)
            throw Error.unsafeRoot
        }
        return fixtureDescriptor
    }

    private static func openExecutionRoot() throws -> Int32 {
        let fixture = try configuredFixtureRoot()
        let scratch = URL(fileURLWithPath: fixture).deletingLastPathComponent().path
        guard directChildName(path: scratch, of: literalRoot) != nil,
              let expectedIdentity = ProcessInfo.processInfo.environment["LIDSWITCH_SWIFT_EXEC_ID"]
        else { throw Error.unsafeRoot }
        let identityFields = expectedIdentity.split(separator: ":", omittingEmptySubsequences: false)
        guard identityFields.count == 6,
              identityFields.allSatisfy({ field in
                  !field.isEmpty && field.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
              }),
              identityFields[4] == "700"
        else { throw Error.unsafeRoot }

        // The wrapper has already opened, identity-sealed, and sandbox-bound
        // this exact root. Opening it directly avoids granting XCTest read or
        // enumeration authority over the shared /private/tmp parent.
        let scratchDescriptor = open(scratch, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard scratchDescriptor >= 0 else { throw Error.unsafeRoot }
        var scratchStatus = stat()
        guard fstat(scratchDescriptor, &scratchStatus) == 0 else {
            close(scratchDescriptor)
            throw Error.unsafeRoot
        }
        let observedIdentity = "\(scratchStatus.st_dev):\(scratchStatus.st_ino):\(scratchStatus.st_uid):\(scratchStatus.st_gid):\(String(scratchStatus.st_mode & 0o7777, radix: 8)):\(scratchStatus.st_nlink)"
        guard observedIdentity == expectedIdentity,
              scratchStatus.st_mode == (S_IFDIR | 0o700),
              scratchStatus.st_uid == getuid(),
              scratchStatus.st_gid == getgid(),
              scratchStatus.st_nlink >= 2
        else {
            close(scratchDescriptor)
            throw Error.unsafeRoot
        }
        return scratchDescriptor
    }

    private static func directChildName(path: String, of parent: String) -> String? {
        guard path.hasPrefix(parent + "/") else { return nil }
        let suffix = String(path.dropFirst(parent.count + 1))
        guard !suffix.isEmpty, !suffix.contains("/"), suffix != ".", suffix != ".." else { return nil }
        return suffix
    }
}

enum TestPathPolicy {
    /// Lexical, boundary-aware containment for policy checks. It intentionally
    /// does not resolve symlinks; descriptor-anchored opens enforce that layer.
    static func isEqualOrDescendant(_ candidate: String, root: String) -> Bool {
        let normalizedCandidate = URL(fileURLWithPath: candidate).standardizedFileURL.path
        let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        return normalizedCandidate == normalizedRoot || normalizedCandidate.hasPrefix(normalizedRoot + "/")
    }
}
