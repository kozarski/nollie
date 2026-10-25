import SwiftUI

// Phone-only SwiftUI names that the shared views still use. Here each one is a neighbour that
// does the same job or does nothing, so no shared file needs a platform check around a modifier.
// These are top-level types on purpose: SwiftUI's nested spellings are marked unavailable on the
// Mac, and writing them out again makes the compiler pick the unavailable one.

// MARK: Things a Mac window already has

/// On the Mac the window always uses the wide layout.
enum UserInterfaceSizeClass { case compact, regular }

extension EnvironmentValues {
    var horizontalSizeClass: UserInterfaceSizeClass? { .regular }
}

/// Where the phone puts its bars. Neither exists here.
enum NavigationBarItem {
    enum TitleDisplayMode { case automatic, inline, large }
}

enum NavigationBarToolbarPlacement { case navigationBar, tabBar }

extension View {
    /// The window title names the screen.
    func navigationBarTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View {
        self
    }

    /// Chats draw their own header on the phone. The Mac toolbar carries the sidebar button.
    func toolbar(_ visibility: Visibility, for placement: NavigationBarToolbarPlacement) -> some View {
        self
    }

    func listSectionSpacing(_ spacing: CGFloat) -> some View { self }

    /// The tab bar lives in a phone-only file. The sidebar does its work here.
    func hidesTabBar() -> some View { self }

    func tabRoot(_ tab: AppModel.AppTab) -> some View { return self }
}

// MARK: Neighbours

extension ToolbarItemPlacement {
    static var topBarLeading: ToolbarItemPlacement { Self.navigation }
    static var topBarTrailing: ToolbarItemPlacement { Self.primaryAction }
}

extension ListStyle where Self == InsetListStyle {
    static var insetGrouped: InsetListStyle { Self.inset }
}

enum SearchDrawerDisplayMode { case automatic, always }

extension SearchFieldPlacement {
    static func navigationBarDrawer(displayMode: SearchDrawerDisplayMode) -> SearchFieldPlacement {
        Self.toolbar
    }
}

// MARK: Typing

/// Capitalisation hints are for the soft keyboard, so each value is just a name.
struct TextInputAutocapitalization {
    private init() {}
    static var never: Self { Self() }
    static var words: Self { Self() }
    static var sentences: Self { Self() }
    static var characters: Self { Self() }
}

enum UIKeyboardType {
    case URL, emailAddress, webSearch, asciiCapable
    case numberPad, decimalPad, numbersAndPunctuation
    case `default`
}

extension View {
    func keyboardType(_ type: UIKeyboardType) -> some View { return self }
}

extension View {
    func textInputAutocapitalization(_ mode: TextInputAutocapitalization?) -> some View { return self }
}
