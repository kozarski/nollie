import SwiftUI
import NollieCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The look of the "Nollie, cleaner" mockup in one place: its colours (each with a dark twin),
/// its type sizes and its spacing. On the Mac the sizes are the mockup's own points; on the
/// phone they follow the text-size setting, from the same starting points. The bot list, the
/// chat's header, bubbles, cards and composer all read from here, so the two stay one design.
enum Ink {
    // MARK: Colours (light, dark)

    /// Words: names, messages.
    static let text = dyn(0x1D1D1F, 0xF5F5F7)
    /// Second-rank words: a row's last message, a card's description, the steps line.
    static let text2 = dyn(0x6E6E73, 0xA1A1A6)
    /// Quiet words: times, placeholders, what a working bot is doing.
    static let text3 = dyn(0xA1A1A6, 0x7C7C82)
    /// Borders: the composer, the outline buttons, the scheduled-run pill.
    static let line = dyn(0xE5E5EA, 0x3A3A3E)
    /// The rule under the chat's header.
    static let hairline = dyn(0xF0F0F2, 0x2C2C2F)
    /// The window behind the chat.
    static let canvas = dyn(0xFFFFFF, 0x1C1C1E)
    /// The bot list's column.
    static let sidebar = dyn(0xF6F6F8, 0x242427)
    /// The search field.
    static let field = dyn(0xEBEBEF, 0x323236)
    /// The open bot's row.
    static let selected = dyn(0xE9E9EE, 0x37373C)
    /// A row or an icon under the pointer.
    static let hover = dyn(0xF0F0F3, 0x2E2E32)
    /// The bot's bubbles.
    static let bubble = dyn(0xF0F0F2, 0x2C2C2F)
    /// Ink: your bubbles and the answer most people give (black on light, white on dark).
    static let ink = dyn(0x161618, 0xF5F5F7)
    /// Words on ink.
    static let onInk = dyn(0xFFFFFF, 0x161618)
    /// Cards in the thread (an approval).
    static let card = dyn(0xF6F6F8, 0x262629)
    /// A command on a card.
    static let code = dyn(0xECECF0, 0x333337)
    static let codeText = dyn(0x55555A, 0xC7C7CC)
    /// A card's description.
    static let cardText = dyn(0x3A3A3C, 0xD1D1D6)
    /// "Action needed".
    static let warnText = dyn(0xB5661B, 0xF2A65A)
    static let warnFill = dyn(0xFBEEDD, 0x3B2C1A)
    /// The round + in the composer.
    static let plusFill = dyn(0xF2F2F4, 0x333337)
    /// Colour for your own initials at the bottom of the list.
    static let me = dyn(0xDCDCE2, 0x3A3A3E)
    static let meText = dyn(0x55555A, 0xD1D1D6)
    /// A gateway that is up.
    static let online = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)

    // MARK: Type

    #if os(macOS)
    /// A message, a card's title, the composer's words.
    static var message: Font { .system(size: 15) }
    /// A row's name.
    static var rowName: Font { .system(size: 15, weight: .semibold) }
    /// A row's last message.
    static var rowPreview: Font { .system(size: 13.5) }
    /// A row's time.
    static var rowTime: Font { .system(size: 12.5) }
    /// The bot's name over its chat.
    static var headerName: Font { .system(size: 16, weight: .semibold) }
    /// "Today 8:45" between messages.
    static var stamp: Font { .system(size: 12, weight: .medium) }
    /// "6 steps · 41s".
    static var steps: Font { .system(size: 13) }
    /// A small pill ("Scheduled run · Board triage"), a chip ("Action needed").
    static var pill: Font { .system(size: 12) }
    static var chip: Font { .system(size: 12, weight: .medium) }
    /// A card's title and its description.
    static var cardTitle: Font { .system(size: 15, weight: .semibold) }
    static var cardBody: Font { .system(size: 14) }
    /// A command on a card.
    static var code11: Font { .system(size: 11.5, design: .monospaced) }
    /// Pill buttons ("Allow once").
    static var button: Font { .system(size: 14, weight: .semibold) }
    /// What a working bot is doing, under the thread.
    static var working: Font { .system(size: 14) }
    /// The search field.
    static var search: Font { .system(size: 14) }
    /// The list's foot.
    static var footName: Font { .system(size: 14, weight: .medium) }
    static var footDetail: Font { .system(size: 12) }
    static var initials: Font { .system(size: 12, weight: .semibold) }
    /// Code in a reply.
    static var codeBlock: Font { .system(size: 12.5, design: .monospaced) }
    #else
    static var message: Font { .body }
    static var rowName: Font { .body.weight(.semibold) }
    static var rowPreview: Font { .subheadline }
    static var rowTime: Font { .subheadline }
    static var headerName: Font { .headline }
    static var stamp: Font { .caption.weight(.medium) }
    static var steps: Font { .footnote }
    static var pill: Font { .caption }
    static var chip: Font { .caption.weight(.medium) }
    static var cardTitle: Font { .body.weight(.semibold) }
    static var cardBody: Font { .subheadline }
    static var code11: Font { .system(.caption, design: .monospaced) }
    static var button: Font { .subheadline.weight(.semibold) }
    static var working: Font { .subheadline }
    static var search: Font { .body }
    static var footName: Font { .subheadline.weight(.medium) }
    static var footDetail: Font { .caption }
    static var initials: Font { .caption.weight(.semibold) }
    static var codeBlock: Font { .system(.footnote, design: .monospaced) }
    #endif

    /// A heading in a reply, sized against `message`: on the Mac the system's heading styles
    /// are smaller than the mockup's 15 pt text, so they get sizes of their own.
    static func heading(_ level: Int) -> Font {
        #if os(macOS)
        switch level {
        case ...1: return .system(size: 20, weight: .bold)
        case 2: return .system(size: 17, weight: .semibold)
        case 3: return .system(size: 15, weight: .semibold)
        case 4: return .system(size: 14, weight: .semibold)
        case 5: return .system(size: 13.5, weight: .medium)
        default: return .system(size: 13, weight: .semibold)
        }
        #else
        switch level {
        case ...1: return .title2.weight(.bold)
        case 2: return .title3.weight(.semibold)
        case 3: return .headline
        case 4: return .subheadline.weight(.semibold)
        case 5: return .subheadline.weight(.medium)
        default: return .footnote.weight(.semibold)
        }
        #endif
    }

    // MARK: Spacing

    #if os(macOS)
    /// Width of the reading column. Thread and composer use it, centred in the window.
    static let column: CGFloat = 720
    static let composerWidth: CGFloat = 740
    /// The widest a bot's bubble and one of yours may be.
    static let botBubble: CGFloat = 560
    static let myBubble: CGFloat = 480
    static let rowAvatar: CGFloat = 46
    static let composerHeight: CGFloat = 56
    static let composerButton: CGFloat = 40
    /// Between the capsule's edge and its round buttons, and above and below one line of words.
    static let composerInset: CGFloat = 8
    static let composerTextInset: CGFloat = 11
    #else
    static let column: CGFloat = .infinity
    static let composerWidth: CGFloat = .infinity
    static let botBubble: CGFloat = .infinity
    static let myBubble: CGFloat = .infinity
    static let rowAvatar: CGFloat = 52
    static let composerHeight: CGFloat = 50
    static let composerButton: CGFloat = 36
    static let composerInset: CGFloat = 7
    static let composerTextInset: CGFloat = 7
    #endif
    /// Cards in the thread (an approval, a crew note): soft, round corners like a sheet's.
    static let cardRadius: CGFloat = 26
    /// Pill buttons: chunky capsules.
    #if os(macOS)
    static let pillPadH: CGFloat = 18
    static let pillPadV: CGFloat = 8
    #else
    static let pillPadH: CGFloat = 20
    static let pillPadV: CGFloat = 12
    #endif
    /// Bubbles: one radius, no tails, the mockup's padding, and its 1.42 line height.
    static let bubbleRadius: CGFloat = 20
    #if os(macOS)
    static let bubblePadH: CGFloat = 16
    static let bubblePadV: CGFloat = 12
    static let lineSpacing: CGFloat = 3.3
    #else
    static let bubblePadH: CGFloat = 14
    static let bubblePadV: CGFloat = 10
    static let lineSpacing: CGFloat = 1.5
    #endif

    // MARK: Helpers

    /// A colour with a light and a dark value, resolved by the view's appearance.
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return native(isDark ? dark : light)
        })
        #else
        Color(uiColor: UIColor { traits in native(traits.userInterfaceStyle == .dark ? dark : light) })
        #endif
    }

    /// Red, green and blue of a 0xRRGGBB number, each from 0 to 1.
    private static func channels(_ hex: UInt32) -> [CGFloat] {
        [16, 8, 0].map { CGFloat((hex >> $0) & 0xFF) / 255 }
    }

    #if os(macOS)
    private static func native(_ hex: UInt32) -> NSColor {
        let c = channels(hex)
        return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
    }
    #else
    private static func native(_ hex: UInt32) -> UIColor {
        let c = channels(hex)
        return UIColor(red: c[0], green: c[1], blue: c[2], alpha: 1)
    }
    #endif
}

/// A bot's name as the list and the header show it: its own display name, else the profile's
/// name with a capital ("career" reads "Career").
extension ProfileInfo {
    var shownName: String {
        if let d = displayName, !d.isEmpty { return d }
        guard let first = name.first else { return name }
        return first.uppercased() + name.dropFirst()
    }

    /// A bot marked Private in Bot settings, or one that runs only on this Mac (a local model):
    /// its rows say so instead of showing what it last said.
    var isPrivateBot: Bool { isPrivateBot(on: nil) }

    /// The same, on one gateway. Without one, a bot private on any gateway counts.
    func isPrivateBot(on connection: UUID?) -> Bool {
        let local: Set<String> = ["ollama", "llamacpp", "llama.cpp", "llama-cpp", "lmstudio", "lm-studio", "mlx", "local"]
        if let p = provider?.lowercased(), local.contains(p) { return true }
        return PrivateBots.isPrivate(name, connection: connection)
    }
}

// MARK: - Buttons

/// The ink pill: the answer most people give ("Allow once", "Create"). Tinted glass on a capsule,
/// chunky enough to hit without looking.
struct InkPillStyle: ButtonStyle {
    var fill = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Ink.button)
            .lineLimit(1)
            .foregroundStyle(Ink.onInk)
            .padding(.horizontal, Ink.pillPadH).padding(.vertical, Ink.pillPadV)
            .frame(maxWidth: fill ? .infinity : nil)
            .nollieGlass(.regular.tint(Ink.ink), in: Capsule(), solid: Ink.ink)
            .opacity(!enabled ? 0.35 : (configuration.isPressed ? 0.8 : 1))
            .contentShape(.capsule)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// The glass pill beside it ("Deny", "Not now"). A destructive role turns its words red.
struct OutlinePillStyle: ButtonStyle {
    var fill = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Ink.button)
            .lineLimit(1)
            .foregroundStyle(configuration.role == .destructive ? Color.red : Ink.text)
            .padding(.horizontal, Ink.pillPadH).padding(.vertical, Ink.pillPadV)
            .frame(maxWidth: fill ? .infinity : nil)
            .nollieGlass(.regular, in: Capsule(), solid: Ink.canvas)
            .opacity(!enabled ? 0.4 : (configuration.isPressed ? 0.75 : 1))
            .contentShape(.capsule)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// An icon in a header (the Board, ⋯): 32 pt, a soft circle behind it under the pointer
/// or while its menu is open.
struct HeaderIconStyle: ButtonStyle {
    var on = false

    func makeBody(configuration: Configuration) -> some View {
        HeaderIconFace(label: configuration.label, pressed: configuration.isPressed, on: on)
    }
}

/// The icon's square, with its own hover state (a style cannot keep one).
private struct HeaderIconFace<Label: View>: View {
    var label: Label
    var pressed: Bool
    var on: Bool
    @State private var hovering = false

    var body: some View {
        label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Ink.text.opacity(0.85))
            .frame(width: 32, height: 32)
            .background((on || hovering || pressed) ? Ink.hover : Color.clear, in: .circle)
            .contentShape(.circle)
            .onHover { hovering = $0 }
    }
}

/// The bot list's search field: a glass capsule (a soft grey one on the Mac), with room for one
/// small button at its right edge (Papertrail in the chat list) that gives way to Clear while
/// there is text. A tap anywhere else in the capsule puts the cursor in the field.
struct InkSearchField<Trailing: View>: View {
    @Binding var text: String
    var prompt = "Search"
    var focused: FocusState<Bool>.Binding
    private let trailing: Trailing

    init(text: Binding<String>, prompt: String = "Search", focused: FocusState<Bool>.Binding,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        _text = text
        self.prompt = prompt
        self.focused = focused
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            glyph
            entry
            if text.isEmpty { trailing } else { clearButton }
        }
        .padding(.leading, 14)
        .padding(.trailing, text.isEmpty && Trailing.self != EmptyView.self ? 6 : 14)
        .contentShape(.capsule)
        .onTapGesture { focused.wrappedValue = true }
        .modifier(SearchCapsule())
        .testID("bots.search")
    }

    private var glyph: some View {
        Image(systemName: "magnifyingglass")
            .font(Font.system(size: 13).weight(.medium))
            .foregroundStyle(Ink.text3)
    }

    private var entry: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .font(Ink.search)
            .foregroundStyle(Ink.text)
            .focused(focused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #if os(macOS)
            .onExitCommand { text = ""; focused.wrappedValue = false }
            #endif
    }

    private var clearButton: some View {
        Button(action: { text = "" }) {
            Label("Clear search", systemImage: "xmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(Ink.text3)
        }
        .buttonStyle(.plain)
    }
}

/// The capsule behind the search field: soft grey on the Mac, glass on the phone.
private struct SearchCapsule: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(height: 34).background(Ink.field, in: .capsule)
        #else
        content.frame(height: 44).nollieGlass(.regular, in: Capsule(), solid: Ink.field)
        #endif
    }
}

extension View {
    /// The composer's capsule: on the Mac the mockup's white one with a hairline and a soft
    /// shadow, floating over the window; on the phone glass over the thread, which an approval or
    /// a question can morph out of.
    @ViewBuilder func composerSurface(namespace: Namespace.ID) -> some View {
        #if os(macOS)
        self
            .nollieGlass(.regular, in: .rect(cornerRadius: Ink.composerHeight / 2, style: .continuous), solid: Ink.canvas)
            .overlay(RoundedRectangle(cornerRadius: Ink.composerHeight / 2, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 6)
        #else
        // Non-interactive glass on purpose. An interactive capsule handles touches itself, and on iPhone
        // it intercepted the taps that belonged to the text field's Paste menu.
        self
            .nollieGlass(.regular, in: .rect(cornerRadius: Ink.composerHeight / 2))
            .glassEffectID("dock", in: namespace)
        #endif
    }
}

#if os(macOS)
/// Shown when the Mac's sidebar is hidden, as the button in the header that brings it back. It
/// lives here, not in the environment, because the chat toolbar did not see environment changes.
@MainActor @Observable final class MacSidebar {
    static let shared = MacSidebar()
    var hidden = false
}

/// Brings the hidden sidebar back (⌃⌘S does the same), from the header of whatever is beside it.
struct SidebarShowButton: View {
    var body: some View {
        Button { NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil) } label: {
            Label("Show Sidebar", systemImage: "sidebar.left")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(HeaderIconStyle())
        .help("Show the sidebar (⌃⌘S)")
        .testID("header.showSidebar")
    }
}
#endif
