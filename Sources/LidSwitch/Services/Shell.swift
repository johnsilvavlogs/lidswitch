import Darwin
import Foundation

struct ProcessResult {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

enum Shell {
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval = 5
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(stdout: "", stderr: error.localizedDescription, exitCode: 127)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            usleep(100_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return ProcessResult(
            stdout: output,
            stderr: timedOut && errorOutput.isEmpty ? "Command timed out." : errorOutput,
            exitCode: timedOut ? 124 : process.terminationStatus
        )
    }
}
