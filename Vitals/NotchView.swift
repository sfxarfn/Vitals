import SwiftUI

enum NotchMode: Equatable {
    case idle
    case event(Event)
    case accessory(Accessory)
    case audioLost
    /// Xcode is building or archiving. Not an event — it holds for the whole
    /// build and replaces idle as the resting state until it ends.
    case building(BuildProgress)
    /// Plain hover: the notch acknowledges the pointer and nothing more.
    case peek
    case expanded
}

struct NotchMetrics {
    /// Physical notch, measured from the screen's auxiliary areas.
    var notch: CGSize
    /// Q5: symmetric pill, capped so it only reaches the tail of the menus.
    var pillWidth: CGFloat = 440
    var panelWidth: CGFloat = 540
    var panelBodyHeight: CGFloat = 94
    /// The accessory pill only carries a glyph and a ring, so it stops well
    /// short of the event pill's width.
    var accessoryFlank: CGFloat = 62

    func size(for mode: NotchMode) -> CGSize {
        switch mode {
        case .idle:      notch
        case .event(let event):
            event.signal.isCompact
                ? CGSize(width: notch.width + accessoryFlank * 2, height: notch.height)
                : CGSize(width: pillWidth, height: notch.height)
        case .accessory,
             .audioLost: CGSize(width: notch.width + accessoryFlank * 2, height: notch.height)
        // Same flare as the accessory pill, twice as tall — enough to read as
        // "it noticed you" without claiming the screen the way the panel does.
        case .peek,
             .building:  CGSize(width: notch.width + accessoryFlank * 2, height: notch.height * 2)
        case .expanded:  CGSize(width: panelWidth, height: notch.height + panelBodyHeight)
        }
    }

    /// The window is sized once to the largest state; everything else insets into
    /// it. The slack has to cover the shape's top flare on both sides *and* the
    /// ambient shadow past it — radius 24 blurs ~36pt out, plus its 12pt drop.
    var windowSize: CGSize {
        CGSize(width: max(pillWidth, panelWidth) + 160, height: notch.height + panelBodyHeight + 72)
    }
}

/// The Bluetooth rune, drawn rather than looked up: SF Symbols has no glyph for
/// it. One continuous stroke, exactly as the mark is constructed.
struct BluetoothMark: Shape {
    func path(in rect: CGRect) -> Path {
        let x = { (t: CGFloat) in rect.minX + rect.width * t }
        let y = { (t: CGFloat) in rect.minY + rect.height * t }
        var path = Path()
        path.move(to: CGPoint(x: x(0), y: y(0.3)))
        path.addLine(to: CGPoint(x: x(1), y: y(0.7)))
        path.addLine(to: CGPoint(x: x(0.5), y: y(1)))
        path.addLine(to: CGPoint(x: x(0.5), y: y(0)))
        path.addLine(to: CGPoint(x: x(1), y: y(0.3)))
        path.addLine(to: CGPoint(x: x(0), y: y(0.7)))
        return path
    }
}

/// Sound just fell off a headset onto the built-in speakers, told in two beats
/// inside the notch's two flanks.
///
/// Nothing travels between them on purpose: the notch's own width in the middle
/// is the camera housing, so an icon sliding across it is invisible for most of
/// the trip and the swap reads as a glitch. The left glyph turns over in place
/// and the right one fades up instead, which lands as a handoff without either
/// icon entering dead space. The resting frame it settles into has to carry the
/// whole message on its own — the pill lives 2.6s and you look up late.
private struct AudioLostPill: View {
    let metrics: NotchMetrics
    @State private var lost = false

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: lost ? "headphones.slash" : "headphones")
                .foregroundStyle(lost ? Color.red : .white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: metrics.accessoryFlank)
            Spacer(minLength: 0).frame(width: metrics.notch.width)
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.white)
                .opacity(lost ? 1 : 0)
                .frame(width: metrics.accessoryFlank)
        }
        .font(.system(size: 17, weight: .medium))
        .frame(height: metrics.notch.height)
        .task {
            // Beat one is the pill arriving with the headset still on it; the
            // turnover only lands once the shape has finished growing, or the
            // two animations fight and neither reads.
            try? await Task.sleep(for: .seconds(0.35))
            withAnimation(.easeOut(duration: 0.3)) { lost = true }
        }
    }
}

struct NotchView: View {
    let mode: NotchMode
    let metrics: NotchMetrics
    let telemetry: Telemetry
    /// One per notch edge. Nil is no glow on that side.
    let cpuGlow: Signal?
    let thermalGlow: Signal?
    let shelf: Shelf
    /// Sends via AirDrop, anchored on the panel's own NSView for the fallback
    /// share sheet — the controller owns the window, so it owns that call.
    let airDrop: ([URL]) -> Void

    @State private var shelfTargeted = false
    @State private var airDropTargeted = false
    @State private var settingsHovered = false
    @State private var showBattery = false
    @State private var batteryHovered = false

    private var size: CGSize { metrics.size(for: mode) }
    private var lifted: Bool { mode != .idle }
    private let topRadius: CGFloat = 22
    private let bottomRadius: CGFloat = 28

    private var shape: NotchShape {
        NotchShape(topCornerRadius: topRadius,
                   bottomCornerRadius: mode == .idle ? 10 : bottomRadius)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The sized box is its own stable view — a Color, not the mode
            // switch. Hanging the frame off `content` instead makes the whole
            // thing change identity on every mode change, and SwiftUI hard-cuts
            // to the new size and only cross-fades. This way the frame
            // interpolates and the box actually grows and shrinks.
            Color.clear
                // The shape flares outward by topRadius per side, so the
                // body lines up with the notch only if the frame is wider.
                .frame(width: size.width + topRadius * 2, height: size.height)
                // Opaque black in every mode so the panel reads as an
                // extension of the bezel instead of showing the desktop
                // through it.
                .background(shape.fill(.black))
                .overlay(alignment: .top) { content.frame(width: size.width) }
                // Content is laid out at its final size the instant the mode
                // flips; the clip is what makes it get revealed by the growing
                // shape rather than spilling outside it mid-morph.
                .clipShape(shape)
                // Grown states lift off the bezel; idle is flush with it, so no
                // shadow there. Two layers, the way glass casts: a tight contact
                // shadow at the edge plus a wide diffuse ambient one. Radii and
                // opacities interpolate with the morph.
                .shadow(color: .black.opacity(lifted ? 0.55 : 0),
                        radius: lifted ? 6 : 0, y: lifted ? 3 : 0)
                .shadow(color: .black.opacity(lifted ? 0.35 : 0),
                        radius: lifted ? 24 : 0, y: lifted ? 12 : 0)
                // Behind the black shape and outside its clip, so only the half
                // that escapes past each edge is ever seen — that overlap is
                // what reads as light leaking out rather than a colored border.
                .background {
                    ZStack {
                        glowBar(thermalGlow).offset(x: -glowInset)
                        glowBar(cpuGlow).offset(x: glowInset)
                    }
                }
                // States that last twenty minutes must not announce themselves;
                // fading is the whole difference between a glow and a pill.
                .animation(.easeInOut(duration: 0.5), value: [thermalGlow, cpuGlow])
            Spacer(minLength: 0)
        }
        .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
        .animation(.bouncy(duration: 0.45, extraBounce: 0.12), value: mode)
        // The shelf is what expanded is for; a battery panel left up from the
        // last hover would greet the next drag with the wrong row.
        .onChange(of: mode) { if mode == .idle { showBattery = false } }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .idle:
            EmptyView()
        case .peek:
            // Two rows: the camera housing row carrying a stat in each flank,
            // and the gear centred below. Peek is exactly the accessory pill's
            // width, so the flanks divide the same way the pills' do.
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    readout("thermometer.medium", tempValue, tint: tempTint)
                        .frame(width: metrics.accessoryFlank)
                    Spacer(minLength: 0).frame(width: metrics.notch.width)
                    readout("cpu", "\(Int(telemetry.stall.cpuPercent.rounded()))%", tint: .white)
                        .frame(width: metrics.accessoryFlank)
                }
                .frame(height: metrics.notch.height)
                settingsButton(size: 17).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: size.height)
            .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.06)))
        case .event(let event) where event.signal.isCompact:
            compactPill(event).transition(.opacity)
        case .event(let event):
            // Anything behind the camera housing is invisible, so the pill puts
            // its glyph and label in the two flanks and leaves the middle empty.
            HStack(spacing: 0) {
                Image(systemName: event.symbol)
                    .foregroundStyle(event.tint)
                    .frame(width: flank)
                Spacer(minLength: 0).frame(width: metrics.notch.width)
                Text(event.title)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(.white)
                    .frame(width: flank)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .frame(height: metrics.notch.height)
            .transition(.opacity)
        case .accessory(let accessory):
            // Same two-flank trick as the event pill: the camera housing owns
            // the middle, so the glyph and the ring take a side each.
            HStack(spacing: 0) {
                Image(systemName: accessory.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: metrics.accessoryFlank)
                Spacer(minLength: 0).frame(width: metrics.notch.width)
                batteryRing(accessory).frame(width: metrics.accessoryFlank)
            }
            .frame(height: metrics.notch.height)
            .transition(.opacity)
        case .audioLost:
            AudioLostPill(metrics: metrics).transition(.opacity)
        case .building(let build):
            // Peek's two-row shape: flanks either side of the camera housing,
            // stats on the row below where there is real width to read them.
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    buildIcon(build).frame(width: metrics.accessoryFlank)
                    Spacer(minLength: 0).frame(width: metrics.notch.width)
                    ring(build.fraction, tint: .blue).frame(width: metrics.accessoryFlank)
                }
                .frame(height: metrics.notch.height)
                Text(build.text)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: size.height)
            .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.06)))
        case .expanded:
            VStack(spacing: 0) {
                // Camera housing row — anything under it is invisible, so the
                // gear sits in the right flank beside it.
                Color.clear.frame(height: metrics.notch.height)
                    .overlay(alignment: .trailing) { settingsButton().padding(.trailing, 14) }
                // One slot, two contents — the badge swaps what is in the row,
                // never the panel's geometry.
                Group {
                    if showBattery {
                        batteryPanel
                    } else {
                        HStack(spacing: 12) {
                            airDropTile
                            shelfBox
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .animation(.snappy(duration: 0.2), value: showBattery)
            }
            // Content fades in behind the shape rather than appearing at full
            // opacity the instant the geometry starts moving.
            .transition(.opacity.animation(.easeOut(duration: 0.28).delay(0.06)))
        }
    }

    private var flank: CGFloat { (metrics.pillWidth - metrics.notch.width) / 2 }

    /// Same two-flank shape as the accessory pill: tinted glyph on the left, a
    /// live number on the right, camera housing in between.
    private func compactPill(_ event: Event) -> some View {
        HStack(spacing: 0) {
            Image(systemName: event.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(event.tint)
                .frame(width: metrics.accessoryFlank)
            Spacer(minLength: 0).frame(width: metrics.notch.width)
            Text(compactValue(event))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(.white)
                .frame(width: metrics.accessoryFlank)
        }
        .frame(height: metrics.notch.height)
    }

    /// Falls back to the word when the sensor tree gave us nothing — a thermal
    /// pill with an empty flank would look broken rather than quiet.
    private func compactValue(_ event: Event) -> String {
        switch event.signal {
        case .thermalSerious:
            telemetry.stall.tempC.map { "\(Int($0.rounded()))°" } ?? event.title
        default:
            "\(telemetry.power.percent)%"
        }
    }

    // MARK: Glow

    /// Where each bar's centre sits — *inside* the straight edge, so the black
    /// shape covers the bar itself and only the blur's tail clears the flare.
    /// A source you can see is a smudge sitting next to the notch; a source you
    /// can't is light coming from behind it.
    ///
    /// Calibration knob, and it moves against `glowBlur`: further in or a
    /// tighter blur and nothing escapes at all, further out and the bright core
    /// crosses the edge and detaches again.
    private var glowInset: CGFloat { size.width / 2 - 6 }
    private let glowBlur: CGFloat = 20

    private func glowBar(_ signal: Signal?) -> some View {
        Capsule()
            .fill(signal?.tint ?? .clear)
            // Exactly the shape's height, never more: the blur already carries
            // the spill past the bottom corner, whereas an overhanging bar puts
            // its unmasked core down there and the blob comes back.
            .frame(width: 26, height: size.height)
            .blur(radius: glowBlur)
    }

    /// Glyph plus one short value. Same 17/12 pair the compact pill uses, so a
    /// stat reads at the same weight whether you hovered for it or it came to
    /// you — the glyph is the only thing that says which stat this is.
    private func readout(_ symbol: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                // SF Symbols do not share a bounding box — `cpu` is near-square
                // and `thermometer.medium` narrow and tall — so at one point
                // size the two flanks take different room and their values stop
                // lining up. A fixed box is what makes the pair symmetric.
                .frame(width: 20)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(.white)
        }
    }

    /// Throttling state, not the thermometer. A die at 78° is fine on one
    /// machine and clamped on another, so a degree threshold could only ever
    /// approximate what `thermalState` reports outright — green is nothing cut,
    /// orange is the governor starting to clamp, red is it clamping hard. The
    /// number beside the glyph stays the raw reading.
    private var tempTint: Color {
        guard telemetry.stall.tempC != nil else { return .white.opacity(0.4) }
        switch telemetry.stall.thermal {
        case .serious:  return .orange
        case .critical: return .red
        // `fair` is fans spinning up, which costs no performance and is not
        // news — it stays green alongside `nominal`.
        default:        return .green
        }
    }

    /// A machine whose sensor tree we cannot read gets a dash, not a zero — 0°
    /// is a plausible-looking temperature and reads as a working sensor.
    private var tempValue: String {
        telemetry.stall.tempC.map { "\(Int($0.rounded()))°" } ?? "—"
    }

    /// Shared by the accessory pill and the build pill. The floor keeps 1% a
    /// ring rather than a dot; the ease is what makes a build's arc creep
    /// instead of jumping a step per poll.
    private func ring(_ fraction: Double, tint: Color) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
        .animation(.easeOut(duration: 0.5), value: fraction)
    }

    /// The real Xcode icon when the watcher caught it, a hammer when the
    /// Accessibility grant is missing and there is nothing to copy it from.
    @ViewBuilder private func buildIcon(_ build: BuildProgress) -> some View {
        if let icon = build.icon {
            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "hammer.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    /// A device that never reported a level gets the Bluetooth mark instead —
    /// an empty ring would read as a flat battery.
    @ViewBuilder private func batteryRing(_ accessory: Accessory) -> some View {
        if let level = accessory.battery {
            ring(Double(level) / 100, tint: accessory.batteryTint)
        } else {
            BluetoothMark()
                .stroke(Color(red: 0, green: 0.51, blue: 1),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 11, height: 18)
        }
    }

    private func settingsButton(size: CGFloat = 12) -> some View {
        HStack(spacing: size * 0.4) {
            // Charge reads off how full the glyph is, not a number — the pill
            // already carries the percentage when it is worth interrupting for.
            // Pressing it swaps the expanded row over to the numbers.
            Button { showBattery.toggle() } label: {
                Image(systemName: telemetry.power.isCharging
                      ? "battery.100percent.bolt"
                      : "battery.\(batteryStep)percent")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(.white.opacity(showBattery || batteryHovered ? 0.9 : 0.45))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { batteryHovered = $0 }
            .animation(.snappy(duration: 0.15), value: batteryHovered)
            SettingsLink {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(.white.opacity(settingsHovered ? 0.9 : 0.45))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { settingsHovered = $0 }
            .animation(.snappy(duration: 0.15), value: settingsHovered)
        }
    }

    /// SF Symbols only ships five fill levels, so the reading snaps to the
    /// nearest one rather than rounding down — 60% on a `50percent` glyph reads
    /// emptier than the battery is.
    private var batteryStep: Int {
        switch telemetry.power.percent {
        case ..<13:  0
        case ..<38:  25
        case ..<63:  50
        case ..<88:  75
        default:     100
        }
    }

    // MARK: Battery panel

    /// Takes the shelf row's slot, and its 104pt tile width, so the swap reads
    /// as the row changing its mind rather than the panel resizing.
    private var batteryPanel: some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                Text("\(telemetry.power.percent)%")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(chargeState)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 104).frame(maxHeight: .infinity)
            .background { RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)) }

            VStack(spacing: 5) {
                statLine("Battery", String(format: "%+.1f W", telemetry.power.batteryWatts))
                statLine("System", telemetry.power.systemWatts.map { String(format: "%.1f W", $0) } ?? "—")
                statLine("Adapter", adapterValue)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12)
            .background { RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)) }
        }
    }

    private func statLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 0)
            Text(value).monospacedDigit().foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
    }

    /// `isCharging` reads false through adapter negotiation and at a hold near
    /// full, so it cannot be the only thing that decides the wording — on AC
    /// with no estimate the honest line is that it is plugged in.
    private var chargeState: String {
        let p = telemetry.power
        if let m = p.minutesToFull, p.isCharging { return "\(duration(m)) to full" }
        if p.onAC { return p.isCharging ? "Charging" : (p.percent >= 95 ? "Charged" : "Plugged in") }
        return p.minutesToEmpty.map { "\(duration($0)) left" } ?? "On battery"
    }

    /// The estimate is nil until macOS has watched the draw settle, which is why
    /// every caller here treats it as optional rather than showing a 0:00.
    private func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private var adapterValue: String {
        let p = telemetry.power
        guard p.onAC else { return "—" }
        if let w = p.adapterWatts { return "\(Int(w.rounded()))W" }
        return p.adapterName ?? "AC"
    }

    // MARK: Shelf

    /// Drop straight on the tile to send those files; click it to send whatever
    /// is already sitting in the box.
    private var airDropTile: some View {
        VStack(spacing: 4) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: 17, weight: .medium))
            Text("AirDrop").font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white)
        .frame(width: 104).frame(maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [.blue, .purple],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .brightness(airDropTargeted ? 0.12 : 0)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { airDrop(shelf.urls) }
        .dropDestination(for: URL.self) { urls, _ in
            airDrop(urls)
            return true
        } isTargeted: { airDropTargeted = $0 }
        .scaleEffect(airDropTargeted ? 1.04 : 1)
        .animation(.snappy(duration: 0.18), value: airDropTargeted)
    }

    private var shelfBox: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                if shelf.urls.isEmpty {
                    Text("Drop files here")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(shelf.urls, id: \.self, content: item)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(shelfTargeted ? 0.55 : 0.2),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .dropDestination(for: URL.self) { urls, _ in
            shelf.add(urls)
            return true
        } isTargeted: { shelfTargeted = $0 }
        .animation(.snappy(duration: 0.18), value: shelfTargeted)
        .contextMenu {
            Button("Clear shelf") { shelf.clear() }.disabled(shelf.urls.isEmpty)
        }
    }

    private func item(_ url: URL) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 30, height: 30)
            Text(url.lastPathComponent)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 68)
        }
        // Dragging an item out is the way files leave the box; the copy stays
        // put until it is removed by hand or the app quits.
        .draggable(url)
        .contextMenu {
            Button("Remove") { shelf.remove(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
