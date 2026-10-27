import SwiftUI
import NollieCore
#if os(macOS)
import AppKit
#endif

/// Settings › About › Remove. On the Direct Mac edition: everything Nollie set up on this Mac, then
/// Nollie goes to the Trash and quits. Elsewhere: Nollie's data in this app's container. One sheet
/// that says in plain words what goes and what stays, then does it line by line.
struct RemoveNollieSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// A reinstalled Nollie removing what an earlier copy left: the app stays open afterwards.
    var keepApp = false
    /// For pictures and the demo copy: start already removing (`working`) or done (`finished`).
    var demoStart: String? = nil
    /// Pictures in tests: the made-up Mac and a pretend run, as in the demo copy.
    var preview = false
    @State private var includeCloud = false
    @State private var plan: RemovalPlan?
    @State private var runner: RemovalRunner?
    /// How tall the content is: the sheet fits it once there is less to show than the review.
    @State private var contentHeight: CGFloat = 660
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(keepApp: Bool = false, demoStart: String? = nil, preview: Bool = false, previewRunner: RemovalRunner? = nil) {
        self.keepApp = keepApp
        self.demoStart = demoStart
        self.preview = preview
        _runner = State(initialValue: previewRunner)
    }

    private var pretend: Bool { DemoMode.isOn || preview }
    private var places: RemovalPlaces { pretend ? RemovalPlan.demoPlaces : RemovalPlaces.thisDevice() }
    private var direct: Bool { places.edition == .macDirect }
    private var title: String {
        if keepApp { return String(localized: "Remove Nollie's earlier setup", comment: "Safety: the remove sheet's title; keep exact meaning") }
        return direct ? String(localized: "Remove Nollie from this Mac", comment: "Safety: the remove sheet's title; keep exact meaning")
            : String(localized: "Remove Nollie's data", comment: "Safety: the remove sheet's title; keep exact meaning")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                if let runner, runner.phase == .finished { finished(runner) }
                else if let runner { working(runner) }
                else { reviewing }
            }
            .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 24)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        // On the list alone: the buttons below keep their own identifiers.
        .accessibilityIdentifier("remove.sheet")
        .safeAreaInset(edge: .bottom, spacing: 0) { if runner == nil { reviewButtons } }
        .background(Ink.canvas.ignoresSafeArea())
        #if os(macOS)
        .frame(width: 540, height: isDone ? min(contentHeight, 660) : 660)
        #else
        .presentationDetents(isDone ? [.height(contentHeight + 24)] : [.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .interactiveDismissDisabled(runner != nil)
        .task { rebuild(); await startDemoIfAsked() }
        .onChange(of: includeCloud) { _, _ in rebuild() }
    }

    /// Done: a few lines and a button, in a sheet no taller than they are.
    private var isDone: Bool { runner?.phase == .finished }

    private func rebuild() {
        let options = RemovalPlan.Options(includeCloud: includeCloud, keepApp: keepApp)
        plan = pretend ? RemovalPlan.demo(places, options: options) : RemovalPlan.build(places, options: options)
    }

    // MARK: Before

    @ViewBuilder private var reviewing: some View {
        RemoveHero(symbol: "trash.circle.fill", title: title,
                   line: String(localized: "This can't be undone.", comment: "Safety: Remove Nollie, the warning before it starts; keep exact meaning"),
                   tint: .red, id: "remove.title")
        if let plan {
            group(LocalizedStringResource("What goes", comment: "Safety: heading over what Remove Nollie deletes; keep exact meaning")) {
                ForEach(plan.parts) { part in line(part.symbol, part.title, part.detail, state: nil) }
            }
            group(LocalizedStringResource("What stays", comment: "Safety: heading over what Remove Nollie leaves; keep exact meaning")) {
                ForEach(stays(plan), id: \.self) { text in kept(text) }
            }
        }
        GlassSwitch(LocalizedStringResource("Also delete Nollie's data in iCloud", comment: "Safety: Remove Nollie, a switch that deletes more; keep exact meaning"),
                    isOn: $includeCloud, id: "remove.icloud")
    }

    /// Cancel and Remove, held at the foot of the sheet so they show however long the list is.
    private var reviewButtons: some View {
        buttons {
            Button(role: .cancel) { dismiss() } label: { capsuleText("Cancel") }
                .buttonStyle(.nollieGlass)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("remove.cancel")
            Button(role: .destructive) { start() } label: {
                capsuleText(direct && !keepApp
                            ? LocalizedStringResource("Remove Nollie", comment: "Safety: button that starts removing Nollie; keep exact meaning")
                            : LocalizedStringResource("Remove", comment: "Safety: button that starts removing Nollie's data; keep exact meaning"))
            }
                .buttonStyle(.nollieGlassProminent)
                .tint(.red)
                .accessibilityIdentifier("remove.confirm")
                .disabled(plan == nil)
        }
        .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 16)
        .background(Ink.canvas)
    }

    /// The plan's own notes, then what never goes, in the person's words.
    private func stays(_ plan: RemovalPlan) -> [String] {
        var lines = plan.kept
        if direct {
            if !keepApp {
                lines.append(String(localized: "Nollie's rows in Privacy & Security. macOS keeps those; you can remove them there afterwards.",
                                    comment: "Safety: Remove Nollie, what stays; keep exact meaning"))
            }
            lines.append(String(localized: "Backups you saved yourself.", comment: "Safety: Remove Nollie, what stays; keep exact meaning"))
        } else {
            lines.append(String(localized: "Your bots and chats on your Hermes.", comment: "Safety: Remove Nollie, what stays; keep exact meaning"))
        }
        return lines
    }

    // MARK: During

    @ViewBuilder private func working(_ runner: RemovalRunner) -> some View {
        let total = runner.lines.count
        let finished = runner.lines.filter { $0.state != .waiting && $0.state != .working }.count
        RemoveHero(symbol: "trash.circle.fill",
                   title: keepApp ? String(localized: "Removing the earlier setup", comment: "Safety: Remove Nollie, while it works; keep exact meaning")
                       : String(localized: "Removing Nollie", comment: "Safety: Remove Nollie, while it works; keep exact meaning"),
                   line: String(localized: "Step \(min(finished + 1, total)) of \(total)", comment: "Remove Nollie: how far along it is"),
                   tint: Ink.text2, id: "remove.working")
        group(nil) {
            ForEach(runner.lines) { item in line(item.part.symbol, item.part.title, troubleText(item.state), state: item.state) }
        }
    }

    // MARK: After

    @ViewBuilder private func finished(_ runner: RemovalRunner) -> some View {
        let finishedTitle = runner.movedAppToTheTrash
            ? String(localized: "Nollie is in the Trash", comment: "Safety: Remove Nollie, the result; keep exact meaning")
            : keepApp ? String(localized: "The earlier setup is gone", comment: "Safety: Remove Nollie, the result; keep exact meaning")
            : direct ? String(localized: "Nollie is almost gone", comment: "Safety: Remove Nollie, the result; keep exact meaning")
            : String(localized: "Nollie's data is gone", comment: "Safety: Remove Nollie, the result; keep exact meaning")
        let leftInApplications = direct && !keepApp && !runner.movedAppToTheTrash
        if !runner.troubles.isEmpty {
            RemoveHero(symbol: "exclamationmark.triangle.fill", title: finishedTitle,
                       line: String(localized: "A few things need you.", comment: "Remove Nollie, the result when some steps failed"), tint: .orange,
                       id: "remove.finished")
        } else if leftInApplications {
            RemoveHero(symbol: "trash.slash.fill", title: finishedTitle,
                       line: String(localized: "Drag Nollie to the Trash from Applications.", comment: "Safety: Remove Nollie, what is left to do; keep exact meaning"),
                       tint: .orange,
                       id: "remove.finished")
        } else {
            RemoveHero(symbol: "checkmark.circle.fill", title: finishedTitle,
                       line: keepApp || !direct
                           ? String(localized: "Everything on the list is done.", comment: "Safety: Remove Nollie, the result; keep exact meaning")
                           : String(localized: "Everything Nollie set up on this Mac is gone.", comment: "Safety: Remove Nollie, the result; keep exact meaning"),
                       tint: .green, id: "remove.finished")
        }
        if !runner.troubles.isEmpty {
            group(LocalizedStringResource("A few things couldn't be done", comment: "Safety: heading over the Remove Nollie steps that failed; keep exact meaning")) {
                ForEach(runner.lines.filter { if case .trouble = $0.state { true } else { false } }) { item in
                    line(item.part.symbol, item.part.title, troubleText(item.state), state: item.state)
                }
                if leftInApplications {
                    line("trash.slash", String(localized: "Nollie couldn't move itself to the Trash. Drag Nollie there from Applications.",
                                               comment: "Safety: Remove Nollie, what stayed; keep exact meaning"),
                         nil, state: nil, tint: .orange)
                }
            }
        }
        if direct && !keepApp {
            line("lock.shield", String(localized: "macOS keeps a few rows for Nollie in Privacy & Security. You can remove them there.",
                                       comment: "Safety: Remove Nollie, what stays; keep exact meaning"),
                 nil, state: nil, tint: .blue)
            #if os(macOS)
            buttons {
                Button { openPrivacy() } label: { capsuleText("Open Privacy & Security") }
                    .buttonStyle(.nollieGlass)
                    .accessibilityIdentifier("remove.privacy")
                Button { quit() } label: { capsuleText("Quit Nollie") }
                    .buttonStyle(.nollieGlassProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("remove.quit")
            }
            #endif
        } else {
            Button { Task { dismiss(); await model.resetApp() } } label: { capsuleText(LocalizedStringResource("Done", comment: "A button that closes the remove sheet")) }
                .buttonStyle(.nollieGlassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("remove.done")
        }
    }

    // MARK: Pieces

    /// A heading and its rows, each a large symbol and plain words.
    @ViewBuilder private func group(_ header: LocalizedStringResource?, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let header {
                Text(header).font(.title3.weight(.semibold)).foregroundStyle(Ink.text)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row: its symbol (red for what goes, unless told otherwise) or how far along it is, and its words.
    private func line(_ symbol: String, _ title: String, _ detail: String?, state: RemovalRunner.State?,
                      tint: Color = .red) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                switch state {
                case .working?: ProgressView().controlSize(.small)
                case .done?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .trouble?: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .waiting?: Image(systemName: "circle.dotted").foregroundStyle(Ink.text3)
                case nil: Image(systemName: symbol).foregroundStyle(tint)
                }
            }
            .font(.title3.weight(.semibold))
            .frame(width: 32)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.body).foregroundStyle(Ink.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// Something that stays: a green check and the words.
    private func kept(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 32)
                .accessibilityHidden(true)
            Text(text).font(.body).foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// Two capsules side by side, one above the other at the largest text sizes.
    @ViewBuilder private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout { content() }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
    }

    private func capsuleText(_ text: LocalizedStringResource) -> some View {
        Text(text).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
    }

    private func troubleText(_ state: RemovalRunner.State) -> String? {
        if case .trouble(let text) = state { text } else { nil }
    }

    // MARK: Doing

    private func start(holdAt: Int? = nil) {
        guard let plan, runner == nil else { return }
        let places = places
        let services: any RemovalServices = pretend ? PretendRemovalServices() : LiveRemovalServices(places: places)
        let made = RemovalRunner(plan: plan, places: places, services: services, pretend: pretend)
        made.pretendHold = holdAt
        runner = made
        Task {
            // The gateway stops sending here and the open connection closes first.
            if !pretend { await model.prepareForRemoval() }
            await made.run()
        }
    }

    private func startDemoIfAsked() async {
        guard pretend, let demoStart, runner == nil else { return }
        try? await Task.sleep(for: .milliseconds(300))
        // `working` holds part way through, for its picture.
        start(holdAt: demoStart == "working" ? 3 : nil)
    }

    #if os(macOS)
    private func openPrivacy() {
        // Opens the pane only; Nollie never changes a setting there.
        if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(pane)
        }
    }

    private func quit() {
        if pretend { dismiss(); return }
        // The open windows may have saved a thing or two since: clear once more, then leave at once.
        LiveRemovalServices(places: places).clearSettings()
        exit(0)
    }
    #endif
}

/// The top of the sheet: a large symbol and what is happening, in its own colour, with one short
/// line. Smaller than a page's, as a sheet is.
private struct RemoveHero: View {
    var symbol: String
    var title: String
    var line: String
    var tint: Color
    /// The title's identifier; the line's is the same with `.line` added.
    var id: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            Text(title)
                .font(.title.weight(.bold))
                .foregroundStyle(tint == Ink.text2 ? Ink.text : tint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(id)
            Text(line)
                .font(.title3)
                .foregroundStyle(Ink.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(id + ".line")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension RemovalPlan {
    /// The demo copy and pictures: a made-up Mac, never this one's disk.
    static var demoPlaces: RemovalPlaces {
        let home = URL(fileURLWithPath: "/Users/demo")
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        #if os(macOS) && NOLLIE_DIRECT
        let edition = RemovalPlaces.Edition.macDirect
        #else
        let edition = RemovalPlaces.Edition.contained
        #endif
        return RemovalPlaces(edition: edition, home: home, library: library,
                             nollie: NolliePaths.Layout(applicationSupport: support, systemCaches: library.appendingPathComponent("Caches"),
                                                        sandboxed: edition == .contained),
                             bundleID: AppIdentity.bundleID, app: edition == .macDirect ? URL(fileURLWithPath: "/Applications/Nollie.app") : nil)
    }

    /// What a typical Mac with a managed setup, helpers' computers and an older Hermes would show.
    static func demo(_ places: RemovalPlaces, options: Options) -> RemovalPlan {
        guard places.edition == .macDirect else {
            var parts = [RemovalPart(kind: .files, title: String(localized: "Delete Nollie's chats, pictures and settings here", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                                     detail: nil, steps: [.clearSettings]),
                         RemovalPart(kind: .keychain,
                                     title: String(localized: "Delete Nollie's connections and saved sign-ins from the keychain", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                                     detail: nil, steps: [.forgetKeychain(Keychain.baseBundleID + ".gateways")])]
            if options.includeCloud {
                parts.append(.init(kind: .cloud, title: String(localized: "Delete Nollie's alerts in iCloud", comment: "Safety: Remove Nollie, what goes; keep exact meaning"), detail: nil,
                                   steps: [.deleteCloudData]))
            }
            return RemovalPlan(parts: parts, kept: [])
        }
        let root = places.nollie.root
        var parts: [RemovalPart] = [
            .init(kind: .computers, title: String(localized: "Turn off your helpers' own computers and delete them", comment: "Safety: Remove Nollie, what goes; keep exact meaning"), detail: nil,
                  steps: [.releaseComputers(.init(home: root.appendingPathComponent("Setups/demo/user"), python: root, managed: true))]),
            .init(kind: .background, title: String(localized: "Stop Nollie Runtime and Nollie Notifications", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                  detail: String(localized: "Your assistant on this Mac stops first.", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                  steps: [.stopRuntime, .unregisterRuntime, .unregisterNotifications]),
            .init(kind: .hermes, title: String(localized: "Take Nollie's add-ons out of your Hermes", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                  detail: String(localized: "Your bots, chats and memory stay. The add-ons go to the Trash.", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                  steps: [.trash(places.hermes.appendingPathComponent("plugins/nollie-workflow"))]),
            .init(kind: .cua, title: String(localized: "Remove Cua, which Nollie set up", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                  detail: String(localized: "With your helpers' computers and Cua's settings.", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                  steps: [.delete(places.nollie.cua)]),
            .init(kind: .setup, title: String(localized: "Delete the assistant Nollie set up on this Mac", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                  detail: String(localized: "With its chats, memory and settings.", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                  steps: [.delete(root.appendingPathComponent("Setups/demo"))]),
            .init(kind: .files, title: String(localized: "Delete Nollie's folder and settings on this Mac", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                  detail: String(localized: "Its caches, logs and records, in ~/Library/Application Support/Nollie.", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                  steps: [.clearSettings]),
            .init(kind: .keychain, title: String(localized: "Delete Nollie's connections and saved sign-ins from the keychain", comment: "Safety: Remove Nollie, what goes; keep exact meaning"),
                  detail: nil,
                  steps: [.forgetKeychain(Keychain.baseBundleID + ".gateways")]),
        ]
        if options.includeCloud {
            parts.append(.init(kind: .cloud, title: String(localized: "Delete Nollie's alerts in iCloud", comment: "Safety: Remove Nollie, what goes; keep exact meaning"), detail: nil,
                               steps: [.deleteCloudData]))
        }
        if !options.keepApp, let app = places.app {
            parts.append(.init(kind: .app, title: String(localized: "Move Nollie to the Trash and quit", comment: "Safety: Remove Nollie, what goes; keep exact meaning"), detail: nil,
                               steps: [.trashApp(app)]))
        }
        return RemovalPlan(parts: parts, kept: [])
    }
}
