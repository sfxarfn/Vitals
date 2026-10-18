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

/// Reads the drag pasteboard the same way the controller decides a drag is a
/// file at all. Synchronous, so the shelf can spring the new rows in the drop
/// that just landed instead of waiting on a provider callback.
enum DragboardFiles {
    static func read() -> [URL] {
        let board = NSPasteboard(name: .drag)
        guard let objects = board.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [NSURL] else {
            return []
        }
        return objects.map { $0 as URL }
    }

    static func load(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await one(provider) { urls.append(url) }
        }
        return urls
    }

    private static func one(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: URL.self) { object, _ in
                continuation.resume(returning: object as? URL)
            }
        }
    }
}

/// Location plus the drop. `dropDestination` only reports the point once the
/// file has landed, which is too late for the silhouette to follow the pointer.
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
        let urls = DragboardFiles.read()
        if !urls.isEmpty { return onPerform(urls, point) }
        // The pasteboard can come back empty once SwiftUI has claimed the
        // items. The providers are the same files; they just arrive late.
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            let loaded = await DragboardFiles.load(providers)
            guard !loaded.isEmpty else { return }
            _ = onPerform(loaded, point)
        }
        return true
    }
}

func shelfDropHaptic() {
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
}

// MARK: Landing

extension NotchView {
    func followDrag(_ point: CGPoint) {
        guard !reduceMotion else { return }
        let width = max(metrics.baseSize(for: .panel).width, 1)
        let raw = max(-1, min(1, (point.x / width - 0.5) * 2))
        let stepped = (raw * 32).rounded() / 32
        if stepped != dragLean { dragLean = stepped }
    }

    func releaseDragAim() {
        shelfTargeted = false
        dragLean = 0
        endFileDrag()
    }

    /// Files aimed anywhere on the open panel land in the shelf. Duplicates
    /// are not a landing — the box already held them, so it does not squash.
    @discardableResult
    func catchOnShelf(_ urls: [URL], at point: CGPoint) -> Bool {
        let fresh = shelf.add(urls)
        panelBody = .shelf
        endFileDrag()
        NotchController.shared?.setDraggingFile(false)
        guard !urls.isEmpty else { return false }
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
        endFileDrag()
        NotchController.shared?.setDraggingFile(false)
        shelfDropHaptic()
        playLanding()
        airDrop(urls)
        return true
    }

    /// Squash in, then spring back. One shot — the completion is what lets go,
    /// so a drop cannot leave the silhouette pinched.
    func playLanding() {
        landFlash = true
        withAnimation(.easeOut(duration: 0.4)) { landFlash = false }
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.14, dampingFraction: 0.46)) {
            landSquash = true
        } completion: {
            withAnimation(.spring(response: 0.44, dampingFraction: 0.56)) {
                landSquash = false
            }
        }
    }

    func noteDrag(_ url: URL, _ session: DragSession) {
        if case .ended(let operation) = session.phase {
            // Cancel and a refused drop put the file back. Anything else took
            // it, and the gap closes with the removal.
            NotchController.shared?.setDraggingFile(false)
            switch operation {
            case .cancel, .forbidden:
                withAnimation(shelfPop) {
                    liftingURL = nil
                    liftTilt = 0
                    liftSample = nil
                }
            default:
                withAnimation(shelfPop) { shelf.remove(url) }
                liftingURL = nil
                liftTilt = 0
                liftSample = nil
            }
            return
        }
        let previous = liftSample ?? session.location
        liftSample = session.location
        if liftingURL != url { liftingURL = url }
        NotchController.shared?.setDraggingFile(true)
        guard !reduceMotion else { return }
        let dx = session.location.x - previous.x
        let stepped = (max(-9, min(9, Double(dx) * 0.55)) * 2).rounded() / 2
        if stepped != liftTilt { liftTilt = stepped }
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
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.5),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
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
    let tilt: Double
    let delay: Double
    let onSession: (DragSession) -> Void
    let onSettled: () -> Void
    let onRemove: () -> Void
    let onReveal: () -> Void

    @State private var settled: Bool
    @State private var didArrive: Bool

    init(url: URL, fresh: Bool, reduceMotion: Bool, lifted: Bool, tilt: Double,
         delay: Double, onSession: @escaping (DragSession) -> Void,
         onSettled: @escaping () -> Void, onRemove: @escaping () -> Void,
         onReveal: @escaping () -> Void) {
        self.url = url
        self.fresh = fresh
        self.reduceMotion = reduceMotion
        self.lifted = lifted
        self.tilt = tilt
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
        .rotationEffect(.degrees(reduceMotion ? 0 : tilt))
        .offset(y: lifted && !reduceMotion ? -5 : 0)
        .shadow(color: .black.opacity(lifted && !reduceMotion ? 0.4 : 0),
                radius: lifted ? 7 : 0, y: lifted ? 4 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.7),
                   value: lifted)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.22, dampingFraction: 0.7),
                   value: tilt)
        // Hover and the pointing hand, but not a press-drag: that gesture
        // would take the horizontal scroll and the drag-out of the file.
        .vitalsPressable(tracksPress: false)
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
