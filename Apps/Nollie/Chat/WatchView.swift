import SwiftUI
#if os(iOS)
import UIKit
#endif
import NollieCore

/// The header's Watch pill: shown while the helper is busy on a computer, or while you hold it.
struct WatchPill: View {
    var chat: ChatSession
    var action: () -> Void
    @Environment(AppModel.self) private var model

    private var held: Bool { ComputerHandoff.shared.isHeld(chat.runtime, chat.profileName) }
    private var shown: Bool {
        WatchPolicy.showsWatch(active: BotComputerActivity.isActive(runtime: chat.runtime, profile: chat.profileName), held: held,
                               isPrivate: PrivateBots.isPrivate(chat.profileName, connection: chat.runtime.connection.id))
    }

    var body: some View {
        if shown {
            Button(action: action) {
                Label("Watch", systemImage: held ? "hand.raised.fill" : "eye.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(held ? Color.orange : Color.blue)
                    .inset(h: 12, v: 6)
                    .nollieGlass(.regular.interactive(), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help("Watch the computer")
            .accessibilityLabel("Watch")
            .accessibilityValue(held ? "You have the computer" : "Using a computer")
            .accessibilityHint("Shows the computer live.")
            .accessibilityIdentifier("chat.watch")
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }
}

/// Lets you watch a helper use its computer, take over, hand back, or stop it. Watching alters
/// nothing. Taking over asks for biometrics or the passcode first.
struct WatchView: View {
    let chat: ChatSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var model
    @State private var preview = ComputerPreviewModel()
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var settledPan: CGSize = .zero
    @State private var note: String?
    @State private var work: Task<Void, Never>?
    private let handoff = ComputerHandoff.shared
    private let authenticator = RememberedSignInCoordinator.defaultAuthenticator()

    private var profile: String { chat.profileName }
    private var name: String { chat.runtime.profiles.first { $0.name == profile }?.shownName ?? profile.capitalized }
    private var updating: Bool { scenePhase == .active }
    private var watchKey: String { "\(chat.runtime.connection.id)/\(profile)/\(chat.storedID)/\(updating)" }
    private var held: Bool { handoff.isHeld(chat.runtime, profile) }
    private var busy: Bool { handoff.isBusy(chat.runtime, profile) }
    private var active: Bool { BotComputerActivity.isActive(runtime: chat.runtime, profile: profile) }

    var body: some View {
        ZStack {
            Self.backdrop.ignoresSafeArea()
            screen
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                bottomBar
            }
            .inset(h: 16, v: 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watch.view")
        #if os(macOS)
        .frame(minWidth: 760, idealWidth: 960, minHeight: 560, idealHeight: 680)
        #endif
        .task(id: watchKey) { if updating { await preview.watch(chat, live: true) } }
        .onChange(of: preview.holder) { _, holder in handoff.note(holder, runtime: chat.runtime, profile: profile) }
        .onChange(of: model.lock.isLocked) { _, locked in if locked { work?.cancel(); dismiss() } }
        // If a take over or hand back was already requested it still completes after this closes,
        // and its result keeps the chat's Watch pill correct.
    }

    // MARK: Top: the helper, centred, and how fresh the picture is

    private var topBar: some View {
        ZStack(alignment: .top) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.title3.weight(.semibold))
                        .frame(square: 44).nollieGlass(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("watch.close")
                Spacer()
            }
            VStack(spacing: -BotAvatarStore.seat(for: profile, size: 44, overlap: 8)) {
                BotAvatar(profile: profile, size: 44, state: held ? .idle : (active ? .usingTool : .idle))
                    .zIndex(1)
                    .accessibilityHidden(true)
                VStack(spacing: 1) {
                    Text(name).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(held ? "Waiting for you" : (preview.computerName ?? "Computer"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .inset(h: 14).padding(.top, 10).padding(.bottom, 6)
                .nollieGlass(.regular, in: .capsule)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("watch.helper")
            .frame(maxWidth: 220)
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 6) {
                badge
                if let line = statusLine {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 170, alignment: .trailing)
                        .accessibilityIdentifier("watch.link")
                }
                #if DEBUG
                if DemoMode.isOn { stats }
                #endif
            }
        }
    }

    private var badge: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let badge = currentBadge(at: context.date) {
                HStack(spacing: 5) {
                    switch badge {
                    case .live: Circle().fill(Color.red).frame(square: 7)
                    case .paused: Image(systemName: "pause.fill").font(.caption2)
                    case .stopped: Image(systemName: "stop.fill").font(.caption2)
                    case .signIn: Image(systemName: "key.fill").font(.caption2)
                    case .lastSeen: Image(systemName: "clock").font(.caption2)
                    }
                    Text(badge.text).font(.caption.weight(.semibold)).lineLimit(1)
                }
                .inset(h: 10, v: 7)
                .nollieGlass(.regular, in: .capsule)
                .padding(.top, 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(badge.text)
                .accessibilityIdentifier("watch.badge")
            }
        }
    }

    /// The badge as it stands at `now`; the picture's spoken value follows the same rule.
    private func currentBadge(at now: Date) -> WatchPolicy.Badge? {
        WatchPolicy.badge(frame: preview.frame, hasImage: preview.image != nil, interrupted: preview.interrupted,
                          updating: updating, receivedAt: preview.receivedAt, now: now, live: preview.liveBadge,
                          signInPaused: preview.signInPaused)
    }

    /// Words under the badge: a slow connection, or video set aside to keep the device cool.
    private var statusLine: String? {
        guard updating else { return nil }
        if preview.live.running, preview.live.greeted { return WatchPolicy.linkLine(preview.live.link) }
        return preview.cooling ? WatchPolicy.coolingLine(Self.deviceName) : nil
    }

    private static var deviceName: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        "Mac"
        #endif
    }

    #if DEBUG
    /// For UI tests in the demo copy: how late the live picture is, never shown.
    private var stats: some View {
        Color.clear
            .frame(square: 1)
            .accessibilityElement()
            .accessibilityLabel("Live stats")
            .accessibilityValue(preview.live.stats)
            .accessibilityIdentifier("watch.stats")
    }
    #endif

    // MARK: The screen, with the helper's character where it last acted

    private var screen: some View {
        // Once a second, so what the picture is said to be keeps up with the badge.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            screen(at: context.date)
        }
    }

    private func screen(at now: Date) -> some View {
        GeometryReader { geometry in
            let box = geometry.size
            if let size = displaySize {
                let fitted = Self.fit(size, in: box)
                ZStack(alignment: .topLeading) {
                    picture
                        .frame(width: fitted.width, height: fitted.height)
                        .scaleEffect(zoom)
                        .offset(pan)
                        .position(x: box.width / 2, y: box.height / 2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(name)’s computer screen")
                        .accessibilityAddTraits(.isImage)
                        .accessibilityValue(pictureValue(at: now))
                        .accessibilityIdentifier("watch.frame")
                    if let spot = WatchPolicy.pointerSpot(preview.pointer, pixelSize: preview.pixelSize) {
                        pointer
                            .position(x: box.width / 2 + ((spot.x - 0.5) * fitted.width) * zoom + pan.width,
                                      y: box.height / 2 + ((spot.y - 0.5) * fitted.height) * zoom + pan.height)
                            .animation(.snappy(duration: 0.35), value: spot)
                    }
                }
                .contentShape(.rect)
                .gesture(magnify.simultaneously(with: drag))
                .onTapGesture(count: 2) {
                    withAnimation(.snappy) {
                        zoom = zoom > 1.05 ? 1 : 2.5; settledZoom = zoom
                        pan = .zero; settledPan = .zero
                    }
                }
            } else {
                VStack(spacing: 12) {
                    if preview.loading { ProgressView() }
                    else { Image(systemName: "desktopcomputer").font(.largeTitle) }
                    Text(preview.loading ? "Connecting to the screen…" : emptyLine)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("watch.empty")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .inset(v: 110)
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    /// The live picture's own size once it plays, else the still's.
    private var displaySize: CGSize? {
        if preview.showsVideo || (preview.placesVideo && preview.image == nil) { return preview.live.sourceSize }
        return preview.image.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// The live picture, with the last still over it until its first frame arrives.
    private var picture: some View {
        ZStack {
            if preview.placesVideo { LiveVideoSurface(watch: preview.live) }
            if !preview.showsVideo, let image = preview.image {
                Image(image, scale: 1, label: Text("\(name)’s computer screen"))
                    .resizable()
                    .interpolation(.high)
            }
        }
    }

    private func pictureValue(at now: Date) -> String {
        WatchPolicy.pictureValue(showsVideo: preview.showsVideo, badge: currentBadge(at: now), capturedAt: preview.frame?.capturedAt)
    }

    private var emptyLine: String {
        if preview.signInPaused { return WatchPolicy.signInPausedLine + "." }
        if preview.needsCompanion { return "Watching isn’t set up on this gateway yet." }
        if preview.kind == "mac" { return "Watching this Mac isn’t available yet." }
        return "No screen to show yet."
    }

    /// The helper's look, and its coat colour for the pointer.
    private var look: CharacterLookID { BotAvatarStore.look(for: profile) }
    private var coat: Color { Color(botHex: CharacterCatalog.shared.look(look).colour) ?? .accentColor }

    /// The helper's own glyph, in its coat colour, standing just above the spot with a dot on it.
    private var pointer: some View {
        ZStack {
            Circle().fill(coat).frame(square: 9)
                .overlay(Circle().stroke(.white, lineWidth: 2))
            CharacterGlyph(look: look)
                .foregroundStyle(coat)
                .frame(square: 26)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                .background(Circle().fill(.white.opacity(0.85)).frame(square: 30))
                .offset(x: 16, y: -18)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Where \(name) last acted")
        .accessibilityIdentifier("watch.pointer")
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in zoom = min(5, max(1, settledZoom * value.magnification)) }
            .onEnded { _ in
                settledZoom = zoom
                if zoom <= 1.01 { withAnimation(.snappy) { pan = .zero; settledPan = .zero } }
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard zoom > 1.01 else { return }
                pan = CGSize(width: settledPan.width + value.translation.width, height: settledPan.height + value.translation.height)
            }
            .onEnded { _ in settledPan = pan }
    }

    /// Behind the screen: a soft grey in light, near black in dark, so the picture stands out.
    static let backdrop = Ink.dyn(0xE9E9EE, 0x0B0B0C)

    static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    // MARK: Bottom: take over or hand back, and Stop

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if held {
                Label(WatchPolicy.heldLine(name), systemImage: "hand.raised.fill")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .inset(h: 16, v: 10)
                    .nollieGlass(.regular.tint(.orange.opacity(0.35)), in: .capsule)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("watch.held")
            } else if preview.holder == .someone {
                Text(WatchPolicy.someoneLine).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch.someone")
            }
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .accessibilityIdentifier("watch.note")
            }
            HStack(spacing: 12) {
                if held {
                    Button("Hand back", systemImage: "hand.wave.fill") { handBack() }
                        .buttonStyle(InkPillStyle())
                        .accessibilityHint("\(name) can use the computer again.")
                        .accessibilityIdentifier("watch.handBack")
                } else if preview.holder == .helper {
                    Button("Take over", systemImage: "hand.raised.fill") { takeOver() }
                        .buttonStyle(InkPillStyle())
                        .accessibilityHint("\(name) waits until you hand it back.")
                        .accessibilityIdentifier("watch.takeOver")
                }
                if chat.isRunning {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { if !blockedAway() { Task { await chat.stop() } } }
                        .buttonStyle(OutlinePillStyle())
                        .accessibilityHint("Stops what \(name) is doing in this chat.")
                        .accessibilityIdentifier("watch.stop")
                }
            }
            .disabled(busy || model.lock.isLocked)
        }
        .frame(maxWidth: 560)
        .animation(.snappy, value: held)
    }

    /// Watch covers the window, so the away card can't show over it: the same words go in its note.
    private func blockedAway() -> Bool {
        guard model.linkReach == .away else { return false }
        note = "You're away from home. This needs Tailscale to reach your Mac."
        return true
    }

    private func takeOver() {
        note = nil
        guard !blockedAway() else { return }
        let runtime = chat.runtime
        work = Task {
            let outcome = await handoff.takeOver(profile: profile, runtime: runtime, name: name, authenticator: authenticator)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .done(.someone): note = WatchPolicy.someoneLine
            case .done, .cancelled: break
            case .refused, .failed: note = WatchPolicy.takeOverFailed
            }
        }
    }

    private func handBack() {
        note = nil
        guard !blockedAway() else { return }
        let runtime = chat.runtime
        work = Task {
            let outcome = await handoff.handBack(profile: profile, runtime: runtime)
            guard !Task.isCancelled else { return }
            if outcome == .refused || outcome == .failed { note = WatchPolicy.handBackFailed }
        }
    }
}
