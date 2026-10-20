//
//  ShelfMotion.swift
//  Vitals
//
//  Drag feedback for the shelf. Everything in here is driven by a drop session
//  or a drag phase — nothing ticks while the notch is idle.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Drop

/// File URLs from a drop. `performDrop` reads the drag pasteboard before it
/// returns; providers are only for a promise that is not on the board yet.
/// `URL` does not conform to `NSItemProviderReading`; `NSURL` does, and a file
/// promise that will not bridge that way comes back as `UTType.fileURL` data.
enum DragboardFiles {
    static func read() -> [URL] {
        let board = NSPasteboard(name: .drag)
        guard let objects = board.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [NSURL] else {
            return []
        }
        return unique(objects.map { $0 as URL })
    }

    /// Nonisolated so the provider callbacks — which are `@Sendable` and may
    /// run off the main actor — are not main-actor closures. The caller hops
    /// back to the main actor before touching the shelf.
    nonisolated static func load(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadOne(provider) { urls.append(url) }
        }
        return unique(urls)
    }

    private nonisolated static func loadOne(_ provider: NSItemProvider) async -> URL? {
        if let url = await loadNSURL(provider) { return url }
        return await loadFileURL(provider)
    }

    private nonisolated static func loadNSURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: object as? URL)
            }
        }
    }

    private nonisolated static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                continuation.resume(returning: url(from: item))
            }
        }
    }

    private nonisolated static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        guard let data = item as? Data else { return nil }
        return URL(dataRepresentation: data, relativeTo: nil)
    }

    private nonisolated static func unique(_ urls: [URL]) -> [URL] {
        var seen: [URL] = []
        for url in urls where !seen.contains(url) {
            seen.append(url)
        }
        return seen
    }
}

/// Targeting plus the drop and where it landed, for the ripple. The location
/// on move is not used — nothing follows the pointer while it is in the panel.
struct ShelfFileDrop: DropDelegate {
    var onMove: (CGPoint) -> Void
    var onExit: () -> Void
    var onPerform: ([URL], CGPoint) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) { onMove(info.location) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onMove(info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { onExit() }

    func performDrop(info: DropInfo) -> Bool {
        let point = info.location
        let providers = info.itemProviders(for: [.fileURL])
        // Synchronous, before this returns. A pasteboard that already has the
        // files is the whole drop — no landing can arrive after the panel has
        // closed, because nothing is waiting on a provider callback.
        let pasted = DragboardFiles.read()
        if !pasted.isEmpty {
            // Same live-state gate as the promise path. `onPerform` closes over
            // the view from this render; the landing functions read the controller.
            return onPerform(pasted, point)
        }
        // Empty board and no providers: the drop is empty. Do not report success.
        guard !providers.isEmpty else { return false }
        // A file promise is not on the board yet, so emptiness is not knowable
        // here. Returning true keeps the providers alive. An empty load adds
        // nothing. A load that finishes after the notch has left does not call
        // `onPerform` — that closure's `state` is still `.panel`.
        let finish = onPerform
        Task { @MainActor in
            let loaded = await DragboardFiles.load(providers)
            guard !loaded.isEmpty else {
                NotchController.shared?.fileDragEnded()
                return
            }
            guard NotchController.shared?.state == .panel else {
                NotchController.shared?.shelf.add(loaded)
                return
            }
            _ = finish(loaded, point)
        }
        return true
    }
}

func shelfDropHaptic() {
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
}

// MARK: Landing

extension NotchView {
    func releaseDragAim() {
        shelfTargeted = false
        // Button still down: the drag moved to another target or off the panel,
        // and the drag cursor has to stay. Button up: it was cancelled over the
        // panel, and the global monitor will not see that mouse-up.
        if NSEvent.pressedMouseButtons & 1 == 0 {
            NotchController.shared?.fileDragEnded()
        } else {
            endFileDrag()
        }
    }

    /// `state` on this value is whatever render built the drop closure. A promise
    /// finishes on that copy, so the let stays `.panel` after the notch has left.
    /// The controller is the notch that is actually up.
    private var panelIsLive: Bool {
        NotchController.shared?.state == .panel
    }

    /// Files aimed anywhere on the open panel land in the shelf. Duplicates
    /// are not a landing — the box already held them, so it does not squash.
    @discardableResult
    func catchOnShelf(_ urls: [URL], at point: CGPoint) -> Bool {
        guard !urls.isEmpty else { return false }
        let fresh = shelf.add(urls)
        // Off the live panel the URLs still belong in the box. The squash,
        // ripple, and fresh-chip arrival do not — writing them here is what
        // replays the landing the next time the shelf opens.
        guard panelIsLive else { return true }
        showShelf()
        NotchController.shared?.fileDragEnded()
        // A duplicate still caught the file; it just has nothing new to settle.
        shelfDropHaptic()
        guard !fresh.isEmpty else { return true }
        freshURLs.formUnion(fresh)
        ripplePoint = point
        rippleToken &+= 1
        playLanding()
        return true
    }

    @discardableResult
    func catchAirDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        // Sending after the panel is gone raises a share sheet over whatever
        // is now in front. Keep the files; do not AirDrop.
        guard panelIsLive else {
            shelf.add(urls)
            return true
        }
        NotchController.shared?.fileDragEnded()
        shelfDropHaptic()
        playLanding()
        airDrop(urls)
        return true
    }

    /// Squash in, then spring back. One shot — the completion is what lets go,
    /// so a drop cannot leave the silhouette pinched. No-op once the live panel
    /// is gone: `landSquash` is what `reach` pins on, and a pill must not inherit it.
    func playLanding() {
        guard panelIsLive else { return }
        landFlash = true
        withAnimation(.easeOut(duration: 0.4)) { landFlash = false }
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.14, dampingFraction: 0.46)) {
            landSquash = true
        } completion: {
            guard panelIsLive else {
                landSquash = false
                return
            }
            withAnimation(.spring(response: 0.44, dampingFraction: 0.56)) {
                landSquash = false
            }
        }
    }

    func noteDrag(_ url: URL, _ session: DragSession) {
        if case .ended(let operation) = session.phase {
            // Cancel and a refused drop put the file back. Anything else took
            // it, and the gap closes with the removal.
            NotchController.shared?.fileDragEnded()
            switch operation {
            case .cancel, .forbidden:
                withAnimation(shelfPop) { liftingURL = nil }
            default:
                withAnimation(shelfPop) { shelf.remove(url) }
                liftingURL = nil
            }
            return
        }
        if liftingURL != url { liftingURL = url }
        NotchController.shared?.setDraggingFile(true)
    }
}

/// One ring and a short burst, played when a drop lands. Removed by the caller
/// when the animation finishes so a later open of the panel does not replay it.
struct ShelfRipple: View {
    var point: CGPoint
    var token: Int
    var onDone: (Int) -> Void
    @State private var expand = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(expand ? 0 : 0.55), lineWidth: 1.25)
                .frame(width: expand ? 116 : 12, height: expand ? 72 : 12)
            ForEach(0..<5, id: \.self) { i in
                let angle = (Double(i) / 5) * Double.pi * 2 - Double.pi / 2
                Circle()
                    .fill(Color.white.opacity(expand ? 0 : 0.8))
                    .frame(width: 3.5, height: 3.5)
                    .offset(x: (expand ? 42 : 3) * CGFloat(cos(angle)),
                            y: (expand ? 22 : 2) * CGFloat(sin(angle)))
            }
        }
        .position(point)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.46)) { expand = true } completion: {
                onDone(token)
            }
        }
    }
}

/// The empty slot a drop will fill. Shown only while a drag is over the shelf,
/// so the row makes room instead of jumping when the file arrives.
struct ShelfGhost: View {
    var body: some View {
        // Filled, no dashes: the box around it already says "drop here", a
        // second dashed outline inside it was one ring too many.
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .frame(width: 36, height: 48)
            .accessibilityHidden(true)
    }
}

// MARK: Chip

/// One file in the shelf. Owns the landing scale so a row of new files can
/// settle independently of the layout animation that opens their gap.
struct ShelfChip: View {
    let url: URL
    let fresh: Bool
    let reduceMotion: Bool
    let lifted: Bool
    let delay: Double
    let onSession: (DragSession) -> Void
    let onSettled: () -> Void
    let onRemove: () -> Void
    let onReveal: () -> Void

    @State private var settled: Bool
    @State private var didArrive: Bool

    init(url: URL, fresh: Bool, reduceMotion: Bool, lifted: Bool,
         delay: Double, onSession: @escaping (DragSession) -> Void,
         onSettled: @escaping () -> Void, onRemove: @escaping () -> Void,
         onReveal: @escaping () -> Void) {
        self.url = url
        self.fresh = fresh
        self.reduceMotion = reduceMotion
        self.lifted = lifted
        self.delay = delay
        self.onSession = onSession
        self.onSettled = onSettled
        self.onRemove = onRemove
        self.onReveal = onReveal
        let already = !fresh || reduceMotion
        _settled = State(initialValue: already)
        _didArrive = State(initialValue: already)
    }

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 30, height: 30)
            Text(url.lastPathComponent)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 68)
        }
        .opacity(lifted ? 0.5 : 1)
        .scaleEffect(scale, anchor: .bottom)
        .offset(y: lifted && !reduceMotion ? -5 : 0)
        .shadow(color: .black.opacity(lifted && !reduceMotion ? 0.4 : 0),
                radius: lifted ? 7 : 0, y: lifted ? 4 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.7),
                   value: lifted)
        // Hover and the pointing hand only. Press scale is a button style;
        // a drag gesture here would take the horizontal scroll and the drag-out.
        .vitalsPressable()
        // Insertion is the scale above, from small. Removal is this — the
        // slot closes and the icon leaves, instead of both fighting.
        .transition(.asymmetric(
            insertion: .identity,
            removal: reduceMotion
                ? .opacity
                : .scale(scale: 0.6, anchor: .bottom).combined(with: .opacity)
        ))
        .onAppear {
            guard fresh, !didArrive else { return }
            didArrive = true
            withAnimation(.spring(response: 0.44, dampingFraction: 0.56).delay(delay)) {
                settled = true
            } completion: {
                onSettled()
            }
        }
        // Dragging an item out is the way files leave the box, so the box lets
        // go of it once the drag lands somewhere. Only the shelf entry goes —
        // the drag itself is a copy, so the file stays wherever it came from.
        .draggable(url)
        .onDragSessionUpdated { session in
            // Not declared on the main actor, but AppKit only updates a drag
            // session there — same reason the controller's timers assume it.
            MainActor.assumeIsolated { onSession(session) }
        }
        .contextMenu {
            Button("Remove", action: onRemove)
            Button("Reveal in Finder", action: onReveal)
        }
        .accessibilityLabel(url.lastPathComponent)
    }

    private var scale: CGFloat {
        if lifted, !reduceMotion { return 1.06 }
        if reduceMotion || settled { return 1 }
        return 0.72
    }
}
