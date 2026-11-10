import Darwin
import Foundation
import XCTest
@testable import LidSwitch

final class AppInstanceLockTests: XCTestCase {
    func testSecondIndependentOpenContendsAndReleaseKeepsTheSameInode() throws {
        try withDirectory { parent in
            var owner: AppInstanceLock? = try XCTUnwrap(AppInstanceLock.acquire(in: parent))
            let before = try lockStatus(parent)
            try withExtendedLifetime(owner) {
                XCTAssertNil(try AppInstanceLock.acquire(in: parent))
            }
            owner = nil
            let replacement = try XCTUnwrap(AppInstanceLock.acquire(in: parent))
            try withExtendedLifetime(replacement) {
                let after = try lockStatus(parent)
                XCTAssertEqual(after.st_ino, before.st_ino)
                XCTAssertEqual(after.st_dev, before.st_dev)
            }
        }
    }

    func testKernelReleasesLockWhenItsLastOwningProcessExits() throws {
        try withDirectory { parent in
            // Establish exactly the production file, then transfer a separate
            // open-file description to a harmless child. Its stdout holds the
            // lock; a pipe controls its lifetime without sleeps or PID polling.
            var initial: AppInstanceLock? = try XCTUnwrap(AppInstanceLock.acquire(in: parent))
            XCTAssertNotNil(initial)
            initial = nil
            var file = openat(parent, relativeLockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(file, 0)
            guard file >= 0 else { return }
            defer { if file >= 0 { close(file) } }
            XCTAssertEqual(flock(file, LOCK_EX | LOCK_NB), 0)

            let process = Process()
            let input = Pipe()
            let ready = Pipe()
            let fixtureRoot = try TestSandbox.configuredFixtureRoot()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // XCTest's inherited cwd may be unreadable to a sandboxed shell;
            // its environment also contains loader/testing configuration.
            process.currentDirectoryURL = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
            process.environment = ["HOME": fixtureRoot, "PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
            process.arguments = ["-c", "printf '\\nlidswitch-instance-ready\\n' >&2; read -r release"]
            process.standardInput = input
            process.standardError = ready
            process.standardOutput = FileHandle(fileDescriptor: file, closeOnDealloc: false)
            try process.run()
            defer {
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.waitUntilExit() }
            }
            // Startup diagnostics share stderr. Require our complete marker,
            // while bounding both diagnostic bytes and time spent waiting.
            let marker = Data("\nlidswitch-instance-ready\n".utf8)
            var readiness = Data()
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !readiness.suffix(marker.count).elementsEqual(marker),
                  readiness.count < 4096, ProcessInfo.processInfo.systemUptime < deadline {
                var event = pollfd(fd: ready.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let result = Darwin.poll(&event, 1, 100)
                if result == 0 || (result < 0 && errno == EINTR) { continue }
                guard result > 0,
                      let byte = try ready.fileHandleForReading.read(upToCount: 1), !byte.isEmpty
                else { break }
                readiness.append(byte)
            }
            XCTAssertTrue(readiness.suffix(marker.count).elementsEqual(marker),
                          "Child readiness missing; stderr: \(String(decoding: readiness, as: UTF8.self))")
            XCTAssertEqual(close(file), 0)
            file = -1
            XCTAssertNil(try AppInstanceLock.acquire(in: parent))
            try input.fileHandleForWriting.write(contentsOf: Data("release\n".utf8))
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertNotNil(try AppInstanceLock.acquire(in: parent))
        }
    }

    func testExistingContentDoesNotBehaveAsAStalePIDLock() throws {
        try withDirectory { parent in
            var owner: AppInstanceLock? = try XCTUnwrap(AppInstanceLock.acquire(in: parent))
            let file = openat(parent, relativeLockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(file, 0)
            guard file >= 0 else { return }
            defer { close(file) }
            let stalePID = Data("999999\n".utf8)
            XCTAssertEqual(stalePID.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }, stalePID.count)
            try withExtendedLifetime(owner) {
                XCTAssertNil(try AppInstanceLock.acquire(in: parent))
            }
            owner = nil
            XCTAssertNotNil(try AppInstanceLock.acquire(in: parent))
            var bytes = [UInt8](repeating: 0, count: stalePID.count)
            XCTAssertEqual(bytes.withUnsafeMutableBytes { pread(file, $0.baseAddress, $0.count, 0) }, stalePID.count)
            XCTAssertEqual(Data(bytes), stalePID)
        }
    }

    func testRejectsSymlinkedDirectoryWithoutTouchingItsTarget() throws {
        let target = try TestSandbox.makeDirectory(label: "instance-link-target")
        try withDirectory { parent in
            XCTAssertEqual(symlinkat(target.url.path, parent, AppInstanceLock.directoryName), 0)
            XCTAssertThrowsError(try AppInstanceLock.acquire(in: parent))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.url.path), [])
        }
    }

    func testRejectsSymlinkHardLinkFIFOAndBroadFilePermissions() throws {
        for kind in ["symlink", "fifo", "permissions"] {
            try withDirectory { parent in
                XCTAssertEqual(mkdirat(parent, AppInstanceLock.directoryName, 0o700), 0)
                let directory = openat(parent, AppInstanceLock.directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                XCTAssertGreaterThanOrEqual(directory, 0)
                guard directory >= 0 else { return }
                defer { close(directory) }
                switch kind {
                case "symlink":
                    XCTAssertEqual(symlinkat("missing-target", directory, AppInstanceLock.fileName), 0)
                case "fifo":
                    XCTAssertEqual(mkfifoat(directory, AppInstanceLock.fileName, 0o600), 0)
                default:
                    let file = openat(directory, AppInstanceLock.fileName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    XCTAssertGreaterThanOrEqual(file, 0)
                    guard file >= 0 else { return }
                    XCTAssertEqual(fchmod(file, 0o644), 0)
                    XCTAssertEqual(close(file), 0)
                }
                XCTAssertThrowsError(try AppInstanceLock.acquire(in: parent), kind)
                if kind == "symlink" {
                    var target = stat()
                    XCTAssertEqual(fstatat(directory, "missing-target", &target, AT_SYMLINK_NOFOLLOW), -1)
                    XCTAssertEqual(errno, ENOENT)
                }
            }
        }
        // The held test sandbox deliberately denies file-link. Exercise the
        // exact production metadata predicate without weakening that boundary.
        try withDirectory { parent in
            let owner = try XCTUnwrap(AppInstanceLock.acquire(in: parent))
            try withExtendedLifetime(owner) {
                var status = try lockStatus(parent)
                XCTAssertTrue(AppInstanceLock.isPrivateLockFile(status))
                status.st_nlink = 2
                XCTAssertFalse(AppInstanceLock.isPrivateLockFile(status))
            }
        }
    }

    func testRejectsBroadDirectoryAndParentPermissions() throws {
        try withDirectory { parent in
            XCTAssertEqual(mkdirat(parent, AppInstanceLock.directoryName, 0o700), 0)
            // The protected launcher uses umask 077; set the unsafe mode
            // explicitly so this fixture actually exercises that rejection.
            XCTAssertEqual(fchmodat(parent, AppInstanceLock.directoryName, 0o755, 0), 0)
            XCTAssertThrowsError(try AppInstanceLock.acquire(in: parent))
        }
        try withDirectory { parent in
            XCTAssertEqual(fchmod(parent, 0o777), 0)
            defer { XCTAssertEqual(fchmod(parent, 0o700), 0) }
            XCTAssertThrowsError(try AppInstanceLock.acquire(in: parent))
        }
    }

    func testDiagnosticsPrecedeLockAndLockPrecedesProductionEffects() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/LidSwitch/App/LidSwitchApp.swift"), encoding: .utf8)
        let diagnostic = try XCTUnwrap(source.range(of: "DebugCommands.handleIfNeeded()"))
        let lock = try XCTUnwrap(source.range(of: "AppInstanceLock.acquireForCurrentUser()"))
        let client = try XCTUnwrap(source.range(of: "RawHelperControlClient.production()"))
        let controller = try XCTUnwrap(source.range(of: "PowerController(sideEffects:"))
        XCTAssertLessThan(diagnostic.lowerBound, lock.lowerBound)
        XCTAssertLessThan(lock.lowerBound, client.lowerBound)
        XCTAssertLessThan(lock.lowerBound, controller.lowerBound)
    }

    private var relativeLockPath: String {
        AppInstanceLock.directoryName + "/" + AppInstanceLock.fileName
    }

    private func lockStatus(_ parent: Int32) throws -> stat {
        var status = stat()
        guard fstatat(parent, relativeLockPath, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(.EIO)
        }
        return status
    }

    private func withDirectory(_ body: (Int32) throws -> Void) throws {
        let fixture = try TestSandbox.makeDirectory(label: "instance-lock")
        let descriptor = try TestSandbox.openManagedDirectory(at: fixture.url)
        defer { close(descriptor) }
        try body(descriptor)
    }
}
