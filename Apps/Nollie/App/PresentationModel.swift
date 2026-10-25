import SwiftUI

extension View {
    /// Hands the app model directly to the content of a sheet, full-screen cover or popover, rather
    /// than trusting the presentation to inherit it from whichever view raised it.
    ///
    /// A presentation normally inherits its presenter's environment, and on iPhone it does. On a Mac,
    /// the iPhone build crashed as a sheet opened (1.3 (5); SwiftUI reported no Observable of type
    /// AppModel inside the sheet's hosting controller): the sheet read the model but its environment
    /// had none. Injecting at the presentation removes any reliance on what the presenter held then.
    /// All presentations in app views use this, and a unit test scans the sources to enforce it.
    func withAppModel() -> some View {
        environment(AppModel.shared)
    }
}
