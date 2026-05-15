import Foundation

struct ProcessResult {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

enum Shell {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String] = []) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessResult(stdout: "", stderr: error.localizedDescription, exitCode: 127)
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return ProcessResult(stdout: output, stderr: errorOutput, exitCode: process.terminationStatus)
    }
}
