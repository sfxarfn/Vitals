//
//  Shelf.swift
//  Vitals
//

import AppKit
import Observation
import SwiftUI

/// A temporary box: files live here until you drag them out, clear it, or quit.
/// ponytail: plain URLs, no security-scoped bookmarks. The sandbox hands us
/// access when the file is dropped and we never persist across launches. If
/// items go stale mid-session, store `URL.bookmarkData()` instead.
@Observable
@MainActor
final class Shelf {
    private(set) var urls: [URL] = []

    /// The URLs that were not already in the box. Callers spring only those —
    /// a second drop of the same file is not a new arrival.
    @discardableResult
    func add(_ dropped: [URL]) -> [URL] {
        let fresh = dropped.filter { !urls.contains($0) }
        urls.append(contentsOf: fresh)
        return fresh
    }

    func remove(_ url: URL) { urls.removeAll { $0 == url } }
    func clear() { urls.removeAll() }
}

/// AppKit has no supported direct handle on AirDrop left — both
/// `NSSharingService(named:)` and `sharingServices(forItems:)` are deprecated.
/// What still works: show a picker on a detached view, take the services it
/// proposes via the delegate, and keep the one AirDrop. Discovery runs once.
@MainActor
final class AirDropper: NSObject, NSSharingServicePickerDelegate {
    static let shared = AirDropper()

    private var service: NSSharingService?
    private var capture: (([NSSharingService]) -> Void)?

    /// `view` anchors the fallback picker, and is only used if AirDrop itself
    /// could not be found.
    func send(_ urls: [URL], from view: NSView?) {
        guard !urls.isEmpty else { return }
        Task {
            if service == nil { service = await discover(with: urls) }
            if let service, service.canPerform(withItems: urls) {
                service.perform(withItems: urls)
            } else if let view {
                NSSharingServicePicker(items: urls).show(relativeTo: .zero, of: view, preferredEdge: .minY)
            }
        }
    }

    private func discover(with items: [Any]) async -> NSSharingService? {
        // Not in a window, so nothing of this picker is ever drawn — the
        // delegate fires on show and that is all we want from it.
        let host = NSView()
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self

        return await withCheckedContinuation { continuation in
            var resumed = false
            capture = { services in
                guard !resumed else { return }
                resumed = true
                // ponytail: title match, so this misses on a non-English system
                // and falls back to the share sheet. Compare bundle ids if that
                // turns out to matter.
                continuation.resume(returning: services.first { $0.title == "AirDrop" })
            }
            picker.show(relativeTo: .zero, of: host, preferredEdge: .minY)

            // The delegate is not guaranteed to fire; without this the task
            // would hang forever and the tile would go dead.
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: nil)
            }
        }
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker,
                              sharingServicesForItems items: [Any],
                              proposedSharingServices proposed: [NSSharingService]) -> [NSSharingService] {
        capture?(proposed)
        return proposed
    }
}
