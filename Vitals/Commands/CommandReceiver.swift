import Foundation
import SwiftUI

/// One command sent by `vitals-notify`. Distributed notifications are local to
/// this login session and carry the whole command as JSON in `object`, which is
/// the one payload type the distributed centre guarantees it can transport.
enum ExternalCommand {
    case event(ExternalEvent)
    case activityStart(ExternalActivity)
    case activityStop(id: String)
    case extensionStart(NotchExtension)
    case extensionStop(id: String)
}

/// Work whose lifecycle is known by the process doing it instead of inferred
/// from CPU load or another app's UI.
struct ExternalActivity: Equatable {
    var id: String
    var name: String
    var startedAt: Date

    var title: String { Self.words(name).joined(separator: " ") }

    var symbol: String { Self.symbol(for: name) }

    fileprivate static func symbol(for value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("build") || lower.contains("archive") { return "hammer.fill" }
        if lower.contains("test") { return "checkmark.diamond.fill" }
        if lower.contains("deploy") || lower.contains("upload") { return "arrow.up.circle.fill" }
        return "terminal.fill"
    }

    fileprivate static func words(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == "-" || $0 == "_" || $0.isWhitespace })
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
    }
}

/// A named one-shot from a process. Kebab-case naturally becomes the notch's
/// two flanks: `build-failed` reads as “Build · Failed”. The last word is the
/// outcome; a one-word Event falls back to “Task · Done”.
struct ExternalEvent: Equatable {
    var name: String

    private var words: [String] { ExternalActivity.words(name) }
    var subject: String {
        guard words.count > 1 else { return "Task" }
        return words.dropLast().joined(separator: " ")
    }
    var outcome: String { words.count > 1 ? (words.last ?? "Done") : (words.first ?? "Done") }
    var subjectSymbol: String { ExternalActivity.symbol(for: subject) }

    /// Read by the controller too, to file Xcode's failed builds as a verdict.
    var isFailure: Bool {
        ["failed", "failure", "error", "cancelled", "canceled"].contains(outcome.lowercased())
    }
    private var isWarning: Bool {
        ["warning", "warned", "blocked"].contains(outcome.lowercased())
    }

    var symbol: String {
        if isFailure { return "xmark.circle.fill" }
        if isWarning { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }
    var tint: Color { isFailure ? .red : (isWarning ? .orange : .green) }
}

/// Receives commands from the shell without opening a port or granting another
/// process access to the app. This is intentionally a tiny, versioned protocol:
/// malformed or future payloads disappear instead of becoming notch content.
@MainActor
final class CommandReceiver: NSObject {
    static let notification = Notification.Name("com.polkka.Vitals.command")

    private struct Payload: Decodable {
        var version: Int
        var command: String
        var name: String?
        var id: String?
    }

    private var handler: ((ExternalCommand) -> Void)?

    func start(_ handler: @escaping (ExternalCommand) -> Void) {
        self.handler = handler
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receive(_:)),
            name: Self.notification,
            object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    @objc private func receive(_ notification: Notification) {
        guard let json = notification.object as? String,
              json.utf8.count <= 1_024,
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1 else { return }

        switch payload.command {
        case "event":
            guard let name = valid(payload.name, limit: 64) else { return }
            handler?(.event(ExternalEvent(name: name)))
        case "activity-start":
            guard let name = valid(payload.name, limit: 48),
                  let id = valid(payload.id, limit: 128) else { return }
            handler?(.activityStart(ExternalActivity(id: id, name: name, startedAt: .now)))
        case "activity-stop":
            guard let id = valid(payload.id, limit: 128) else { return }
            handler?(.activityStop(id: id))
        case "extension-start":
            guard let name = valid(payload.name, limit: 24),
                  let id = valid(payload.id, limit: 128) else { return }
            handler?(.extensionStart(NotchExtension(id: id, name: name, startedAt: .now)))
        case "extension-stop":
            guard let id = valid(payload.id, limit: 128) else { return }
            handler?(.extensionStop(id: id))
        default:
            return
        }
    }

    /// Control characters have no place in a one-line pill. Trimming here also
    /// prevents an argument made only of spaces from buying an empty Activity.
    private func valid(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= limit,
              clean.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return clean
    }
}
