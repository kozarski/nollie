import AppKit
import NollieCore
import SwiftUI

/// The last step of a payment, on this Mac: what will be paid, where, with which card, and the card's
/// security code, typed here each time and never kept. Pay asks for Touch ID or the Mac's password,
/// then Nollie checks the total is on the helper's screen and fills the card in.
struct PaySheet: View {
    var ask: PayAsk
    var pay: (String) async -> String?
    var cancel: () async -> Void
    @State private var code = ""
    @State private var working = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: "creditcard.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 56))
                    .foregroundStyle(Ink.text)
                    .accessibilityHidden(true)
                Text("Pay \(ask.amount)")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Ink.text)
                    .accessibilityAddTraits(.isHeader)
                    .testID("pay.title")
                Text("to \(ask.site)")
                    .font(.title3)
                    .foregroundStyle(Ink.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                fact("creditcard", ask.cardLabel)
                fact("person.fill", "\(ask.bot) asked")
            }
            SecureField("Security code", text: $code, prompt: Text("Security code"))
                .textContentType(.creditCardSecurityCode)
                .font(.title3.monospacedDigit())
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.vertical, 14)
                .padding(.horizontal, 22)
                .frame(maxWidth: 260)
                .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
                .onSubmit(submit)
                .accessibilityHint("The \(ask.codeLength) digits on your card. Never kept.")
                .testID("pay.code")
            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(Ink.warnText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .testID("pay.problem")
            }
            HStack(spacing: 10) {
                Button("Cancel") { Task { await cancel() } }
                    .buttonStyle(OutlinePillStyle(fill: false))
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                    .testID("pay.cancel")
                Button(action: submit) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "lock.fill").imageScale(.small).accessibilityHidden(true)
                        Text(working ? "Checking…" : "Pay")
                    }
                }
                .buttonStyle(InkPillStyle(fill: false))
                .keyboardShortcut(.defaultAction)
                .disabled(working || code.count != ask.codeLength)
                .accessibilityHint("Asks for Touch ID, then fills in the card.")
                .testID("pay.pay")
            }
            Text("Nollie checks the total is on screen first. \(ask.bot) never sees the card number.")
                .font(.footnote)
                .foregroundStyle(Ink.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 30, leading: 32, bottom: 26, trailing: 32))
        .frame(width: 420)
        .background(Ink.canvas)
        .onAppear { focused = true }
        .onDisappear { code = "" }
        .testID("pay.sheet")
    }

    private func fact(_ symbol: String, _ word: String) -> some View {
        Label(word, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Ink.text)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
    }

    private func submit() {
        guard !working, code.count == ask.codeLength else { return }
        working = true
        problem = nil
        Task {
            let said = await pay(code)
            working = false
            problem = said
            if said == nil { code = "" }
        }
    }
}

/// A small window of its own for the pay sheet, in front, so the person sees it wherever they are.
@MainActor
enum PaySheetWindow {
    private static var window: NSWindow?

    static func show(_ ask: PayAsk?) {
        guard let ask else {
            window?.close()
            window = nil
            return
        }
        let center = CardCenter.shared
        let sheet = PaySheet(ask: ask, pay: { await center.pay(code: $0) }, cancel: { await center.cancel() })
            .withAppModel()
        let host = NSHostingController(rootView: sheet)
        let panel = window ?? NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        panel.contentViewController = host
        panel.title = "Pay"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        // A payment waits on this: it stays in sight while the person is in another app.
        (panel as? NSPanel)?.hidesOnDeactivate = false
        panel.setContentSize(host.view.fittingSize)
        panel.center()
        window = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }
}
