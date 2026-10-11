import AppKit
import ClaudometerCore
import Foundation
import os

/// Installs a release from inside the app: downloads its DMG, checks it against the checksum
/// GitHub publishes, copies the new app next to this one, and swaps the two after quitting.
///
/// Downloaded this way the app carries no quarantine flag (Claudometer doesn't opt into
/// `LSFileQuarantineEnabled`), so Gatekeeper's "Open Anyway" step doesn't come back on
/// updates. Only the first install from a browser needs it.
enum UpdateInstaller {
    /// `log stream --predicate 'subsystem == "dev.claudometer.app"'` shows each step.
    static let log = Logger(subsystem: "dev.claudometer.app", category: "update")

    enum Failure: Error {
        /// The app's folder isn't writable (e.g. a standard user and /Applications), or it
        /// runs from the DMG itself.
        case cantReplace
        case download
        /// The file doesn't match GitHub's checksum, or isn't a Claudometer of that version.
        case verification
        case install

        var message: String {
            switch self {
            case .cantReplace: return tr("Claudometer can’t replace itself in this folder. Download the update instead.")
            case .download: return tr("The download failed. Check your connection and try again.")
            case .verification: return tr("The download didn’t match the release, so it wasn’t installed.")
            case .install: return tr("The update couldn’t be installed. Download it instead.")
            }
        }
    }

    /// The running app, if it can be replaced in place.
    static var replaceableApp: URL? {
        let app = Bundle.main.bundleURL
        let folder = app.deletingLastPathComponent()
        guard app.pathExtension == "app", !app.path.hasPrefix("/Volumes/"),
              FileManager.default.isWritableFile(atPath: folder.path) else { return nil }
        return app
    }

    /// Downloads, verifies and stages `release`, then quits; a helper swaps the apps once
    /// this process has exited and opens the new one. Returns only on failure.
    @MainActor
    static func install(_ release: AppRelease, progress: @escaping @MainActor (Double) -> Void) async throws {
        guard let download = release.download, let app = replaceableApp else { throw Failure.cantReplace }
        log.info("Installing \(release.version, privacy: .public) over \(app.path, privacy: .public)")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("claudometer-update-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let dmg = try await fetch(download.url, to: work.appendingPathComponent("update.dmg"), progress: progress)
        guard (try? UpdateChecker.sha256(of: dmg)) == download.sha256 else {
            log.error("Checksum mismatch")
            throw Failure.verification
        }

        // Staged beside the running app so the final swap is a rename on the same volume.
        let staged = app.deletingLastPathComponent().appendingPathComponent(".Claudometer-\(release.version).app")
        try await Task.detached { try extract(dmg, to: staged, mountPoint: work.appendingPathComponent("mount")) }.value
        guard isValid(staged, version: release.version) else {
            log.error("Staged app failed validation")
            try? FileManager.default.removeItem(at: staged)
            throw Failure.verification
        }
        try relaunch(replacing: app, with: staged)
    }

    // MARK: - Steps

    private static func fetch(_ url: URL, to destination: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let delegate = ProgressDelegate { fraction in Task { @MainActor in progress(fraction) } }
        do {
            let (file, response) = try await URLSession.shared.download(from: url, delegate: delegate)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                log.error("Download HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                throw Failure.download
            }
            try FileManager.default.moveItem(at: file, to: destination)
            return destination
        } catch let failure as Failure {
            throw failure
        } catch {
            log.error("Download failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.download
        }
    }

    /// Copies `Claudometer.app` out of the DMG.
    private static func extract(_ dmg: URL, to staged: URL, mountPoint: URL) throws {
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path]) else {
            log.error("hdiutil attach failed")
            throw Failure.install
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }
        try? FileManager.default.removeItem(at: staged)
        // Without extended attributes: macOS tags files with `com.apple.provenance`, which a
        // strict signature check rejects, and no quarantine flag comes along either.
        guard run("/usr/bin/ditto", ["--norsrc", "--noextattr", "--noqtn",
                                     mountPoint.appendingPathComponent("Claudometer.app").path, staged.path]) else {
            log.error("Copying the app out of the DMG failed")
            throw Failure.install
        }
    }

    /// Same bundle identifier, the promised version, and an intact code signature.
    private static func isValid(_ app: URL, version: String) -> Bool {
        guard let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else { return false }
        return run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    /// Hands the swap to a shell script that outlives this process: it waits for Claudometer
    /// to quit, moves the old app aside, puts the new one in its place (restoring the old one
    /// if that fails), and opens it.
    @MainActor
    private static func relaunch(replacing app: URL, with staged: URL) throws {
        let backup = app.deletingLastPathComponent().appendingPathComponent(".Claudometer-previous.app")
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$4"
        if mv "$2" "$4"; then
            if mv "$3" "$2"; then rm -rf "$4"; else mv "$4" "$2"; fi
        fi
        xattr -dr com.apple.quarantine "$2" 2>/dev/null
        open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "claudometer-update",
                             String(ProcessInfo.processInfo.processIdentifier), app.path, staged.path, backup.path]
        do { try process.run() } catch { throw Failure.install }
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// Reports a download task's progress, 0...1.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [onProgress] progress, _ in
            onProgress(progress.fractionCompleted)
        }
    }
}
