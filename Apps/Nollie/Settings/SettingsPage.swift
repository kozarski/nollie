import SwiftUI

// The pieces of every Settings page, after Away from home: what is true right now at the top in
// one large symbol and a few words, a handful of facts as symbols, one clear switch on glass,
// and anything technical behind one Advanced row. No lists of grey rows, no small grey text.
//
// Words: a literal passed to these pieces is looked up in the string catalog (the
// `LocalizedStringResource` inits); a `String` is shown as it is, so build it with
// `String(localized:)` when it holds the app's own words.

/// A settings page: a centred column on the canvas that scrolls, with air between its parts.
struct SettingsPage<Content: View>: View {
    var id: String
    private let content: Content

    init(_ id: String, @ViewBuilder content: () -> Content) {
        self.id = id
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 36) { content }
                .frame(maxWidth: 560)
                .padding(EdgeInsets(top: 28, leading: 24, bottom: 40, trailing: 24))
                .frame(maxWidth: .infinity)
        }
        .background(Ink.canvas.ignoresSafeArea())
        // The back button floats over the page on the phone: words scrolled under it fade out
        // instead of showing through.
        #if os(iOS)
        .scrollEdgeEffectStyle(.hard, for: .top)
        #endif
        .testID(id)
    }
}

/// The top of a page: one large symbol and what is true now, in its own colour, with one short
/// line at most.
struct PageHero: View {
    var symbol: String
    var title: String
    var line: String? = nil
    var tint: Color
    /// The title's identifier; the line's is the same with `.lead` in place of `.hero`.
    var id: String
    @Environment(\.self) private var environment

    init(symbol: String, title: LocalizedStringResource, line: LocalizedStringResource? = nil, tint: Color, id: String) {
        self.init(verbatim: symbol, title: String(localized: title), line: line.map { String(localized: $0) }, tint: tint, id: id)
    }

    fileprivate init(verbatim symbol: String, title: String, line: String? = nil, tint: Color, id: String) {
        self.symbol = symbol
        self.title = title
        self.line = line
        self.tint = tint
        self.id = id
    }

    /// The large symbol, in a box tall enough that the page does not jump when it changes.
    private var mark: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: 72))
            .foregroundStyle(tint)
            .frame(height: 92)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }

    var body: some View {
        VStack(spacing: 12) {
            mark
            Text(title)
                .font(.largeTitle.weight(.bold))
                // Bright tints (teal, green, orange) sink just far enough to read on a white page.
                .foregroundStyle(tint.readable(against: Ink.canvas, ratio: 3, in: environment))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .testID(id)
            if let line { lead(line) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
    }

    private func lead(_ line: String) -> some View {
        Text(line)
            .font(.title3)
            .foregroundStyle(Ink.text2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .testID(id.replacingOccurrences(of: ".hero", with: ".lead"))
    }
}

/// One fact: a symbol and a word or two.
struct Fact: Identifiable, Hashable {
    var symbol: String
    var word: String
    var id: String { word }

    init(symbol: String, word: LocalizedStringResource) {
        self.init(verbatim: symbol, word: String(localized: word))
    }

    fileprivate init(verbatim symbol: String, word: String) {
        self.symbol = symbol
        self.word = word
    }
}

/// A few facts side by side, each a large symbol over its word or two.
struct FactStrip: View {
    var facts: [Fact]
    var tint: Color = Ink.text2
    var id: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            // At the largest text sizes, one fact to a line, its symbol beside its words.
            if typeSize.isAccessibilitySize { stacked } else { strip }
        }
        .accessibilityElement(children: .combine)
        .testID(id)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(facts) { fact in
                HStack(spacing: 14) {
                    Image(systemName: fact.symbol).font(.title3.weight(.semibold)).foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(fact.word).font(.body.weight(.medium)).foregroundStyle(Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var strip: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(facts) { fact in
                VStack(spacing: 10) {
                    Image(systemName: fact.symbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(height: 30)
                        .accessibilityHidden(true)
                    Text(fact.word)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Ink.text)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// A soft tile of facts, for two things side by side (without and with, here and there).
struct FactTile: View {
    var title: String
    var tint: Color
    var facts: [Fact]
    var id: String

    init(title: LocalizedStringResource, tint: Color, facts: [Fact], id: String) {
        self.init(verbatim: String(localized: title), tint: tint, facts: facts, id: id)
    }

    fileprivate init(verbatim title: String, tint: Color, facts: [Fact], id: String) {
        self.title = title
        self.tint = tint
        self.facts = facts
        self.id = id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).foregroundStyle(Ink.text2).font(.subheadline.weight(.semibold))
            ForEach(facts) { fact in
                Label {
                    Text(fact.word).font(.body.weight(.medium)).foregroundStyle(Ink.text)
                } icon: {
                    Image(systemName: fact.symbol)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                }
                .labelStyle(TileFactStyle())
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.card, in: .rect(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .combine)
        .testID(id)
    }
}

/// A tile's fact: its symbol in a narrow column, then its words.
private struct TileFactStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { TileFact(configuration: configuration) }
}

/// The column grows with the text size, so a large symbol never runs into the tile's edge.
private struct TileFact: View {
    var configuration: LabelStyleConfiguration
    @ScaledMetric(relativeTo: .body) private var column: CGFloat = 24

    var body: some View {
        HStack(spacing: 12) {
            configuration.icon.font(.body.weight(.semibold)).frame(width: column)
            configuration.title
        }
    }
}

/// Two tiles side by side, as tall as the taller one.
struct FactTiles: View {
    var leading: FactTile
    var trailing: FactTile
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // One above the other at the largest text sizes, where two side by side would squeeze.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        layout {
            leading
            trailing
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A page's one clear switch, on a glass capsule.
struct GlassSwitch: View {
    var title: String
    @Binding var isOn: Bool
    var id: String

    init(_ title: LocalizedStringResource, isOn: Binding<Bool>, id: String) {
        self.init(verbatim: String(localized: title), isOn: isOn, id: id)
    }

    fileprivate init(verbatim title: String, isOn: Binding<Bool>, id: String) {
        self.title = title
        _isOn = isOn
        self.id = id
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            // The words take the room, so the switch sits at the right on the Mac as on the phone.
            Text(title).font(.headline).foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .inset(h: 22, v: 14)
        .frame(maxWidth: .infinity)
        .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
        .testID(id)
    }
}

/// A few switches together: each on its own capsule, close to one another.
struct GlassStack<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 12, content: content)
    }
}

/// A choice of a few, on one glass capsule: the name, and the choice as a menu.
struct GlassChoice<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [(Value, String)]
    var id: String

    init(_ title: LocalizedStringResource, selection: Binding<Value>, options: [(Value, String)], id: String) {
        self.init(verbatim: String(localized: title), selection: selection, options: options, id: id)
    }

    fileprivate init(verbatim title: String, selection: Binding<Value>, options: [(Value, String)], id: String) {
        self.title = title
        _selection = selection
        self.options = options
        self.id = id
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // The name over the choice at the largest text sizes, where they would crowd side by side.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Text(title).font(.headline).foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { value, word in Text(word).tag(value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.leading, 22).padding(.trailing, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .nollieGlass(.regular, in: typeSize.isAccessibilitySize ? AnyShape(.rect(cornerRadius: 26, style: .continuous)) : AnyShape(Capsule()), solid: Ink.card)
        .accessibilityElement(children: .contain)
        .testID(id)
    }
}

/// The way to a page of its own, on a glass capsule: a symbol, a name, and, if it helps, a word
/// on the right.
struct GlassLink<Destination: View>: View {
    var title: String
    var symbol: String
    var value: String? = nil
    var badge: Int = 0
    var id: String
    private let destination: Destination

    /// `value` is worked out in code (a count, a bot's name), so it is shown as it is.
    init(_ title: LocalizedStringResource, symbol: String, value: String? = nil, badge: Int = 0, id: String,
         @ViewBuilder destination: () -> Destination) {
        self.init(verbatim: String(localized: title), symbol: symbol, value: value, badge: badge, id: id, destination: destination)
    }

    fileprivate init(verbatim title: String, symbol: String, value: String? = nil, badge: Int = 0, id: String,
         @ViewBuilder destination: () -> Destination) {
        self.title = title
        self.symbol = symbol
        self.value = value
        self.badge = badge
        self.id = id
        self.destination = destination()
    }

    var body: some View {
        NavigationLink { destination } label: {
            GlassRowLabel(title: title, symbol: symbol, value: value, badge: badge, chevron: true)
        }
        .buttonStyle(.plain)
        .testID(id)
    }
}

/// A row that does something, on a glass capsule (opens a sheet, a page elsewhere, a check).
struct GlassButton: View {
    var title: String
    var symbol: String
    var value: String? = nil
    var role: ButtonRole? = nil
    var id: String
    var action: () -> Void

    /// `value` is worked out in code, so it is shown as it is.
    init(_ title: LocalizedStringResource, symbol: String, value: String? = nil, role: ButtonRole? = nil, id: String,
         action: @escaping () -> Void) {
        self.init(verbatim: String(localized: title), symbol: symbol, value: value, role: role, id: id, action: action)
    }

    fileprivate init(verbatim title: String, symbol: String, value: String? = nil, role: ButtonRole? = nil, id: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.value = value
        self.role = role
        self.id = id
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            GlassRowLabel(title: title, symbol: symbol, value: value, tint: role == .destructive ? .red : nil, chevron: false)
        }
        .buttonStyle(.plain)
        .testID(id)
    }
}

/// What a glass row shows: its symbol, its name, a quiet word, and where it leads.
struct GlassRowLabel: View {
    var title: String
    var symbol: String
    var value: String? = nil
    var badge: Int = 0
    var tint: Color? = nil
    var chevron = true
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 14) {
            icon
            Text(title).font(.headline).foregroundStyle(tint ?? Ink.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if badge > 0 { CountBadge(badge) }
            if let value { Text(value).font(.body).foregroundStyle(Ink.text2).lineLimit(1) }
            if chevron { arrow }
        }
        .inset(h: 22, v: 14)
        .frame(minHeight: 54)
        .contentShape(shape)
        .nollieGlass(.regular, in: shape, solid: Ink.card)
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(tint ?? Ink.text2)
            .frame(width: 26)
            .accessibilityHidden(true)
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Ink.text3)
            .accessibilityHidden(true)
    }

    /// A capsule, or a softly rounded box once large text wraps the name onto more lines.
    private var shape: AnyShape {
        typeSize.isAccessibilitySize ? AnyShape(.rect(cornerRadius: 26, style: .continuous)) : AnyShape(Capsule())
    }
}

/// The one Advanced row of an area: everything technical waits behind it.
struct AdvancedLink<Destination: View>: View {
    var id: String
    private let destination: Destination

    init(id: String, @ViewBuilder destination: () -> Destination) {
        self.id = id
        self.destination = destination()
    }

    var body: some View {
        GlassLink("Advanced", symbol: "slider.horizontal.3", id: id) { destination }
    }
}

/// A short plain line under a part of a page, when one is needed: never small, never grey on grey.
struct PageNote: View {
    var text: String
    var symbol: String? = nil
    var tint: Color = Ink.text2
    var id: String? = nil

    init(_ text: LocalizedStringResource, symbol: String? = nil, tint: Color = Ink.text2, id: String? = nil) {
        self.init(verbatim: String(localized: text), symbol: symbol, tint: tint, id: id)
    }

    fileprivate init(verbatim text: String, symbol: String? = nil, tint: Color = Ink.text2, id: String? = nil) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.id = id
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            }
            Text(text).font(.body).foregroundStyle(tint == Ink.text2 ? Ink.text2 : Ink.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .modifier(OptionalIdentifier(id: id))
    }
}

/// A heading over a group on a page: plain, in the page's words.
struct PageHeading: View {
    var text: String
    init(_ text: LocalizedStringResource) { self.text = String(localized: text) }
    fileprivate init(verbatim text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title3.weight(.semibold)).foregroundStyle(Ink.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct OptionalIdentifier: ViewModifier {
    var id: String?
    func body(content: Content) -> some View {
        if let id { content.testID(id) } else { content }
    }
}
