import Foundation

/// Runs `/usr/bin/security`. Keychain items created through it trust the tool itself, not
/// Claudometer's ad-hoc signature, so reading them never prompts again after a rebuild or update.
struct SecurityTool {
    static let itemNotFound: Int32 = 44

    struct Output {
        let status: Int32
        let data: Data
    }

    /// `input` is fed to stdin (used with `-i`), so secrets never appear in the process list.
    static func run(_ arguments: [String], input: String? = nil) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let stdin = input.map { _ in Pipe() }
        if let stdin { process.standardInput = stdin }
        do {
            try process.run()
        } catch {
            return nil
        }
        if let stdin, let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, data: data.trimmingTrailingNewlines())
    }
}

private extension Data {
    func trimmingTrailingNewlines() -> Data {
        var copy = self
        while let last = copy.last, last == 0x0A || last == 0x0D { copy.removeLast() }
        return copy
    }
}
