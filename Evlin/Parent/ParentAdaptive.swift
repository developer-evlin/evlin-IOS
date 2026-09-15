import SwiftUI

// Parent-side counterpart to Tablet/KidAdaptive.swift — same shape, kept as
// its own type rather than reused directly since the parent tabs (Home,
// Profile, Calendar, Chat, Library, Settings) hadn't picked up any iPad
// adaptation yet and needed their own drop-in rather than borrowing a
// kid-themed helper by name. Driven by horizontalSizeClass, not device
// idiom, so iPad Split View/Slide Over (compact) and iPhone landscape
// (regular) both fall out correctly.
struct ParentAdaptive {
    var isRegular: Bool

    init(_ hSizeClass: UserInterfaceSizeClass?) {
        isRegular = hSizeClass == .regular
    }

    // Reading/list-shaped content (profile header, task rows, rules list)
    // centers in a column this wide on iPad instead of stretching edge to
    // edge into rows with a chevron floating 1200pt away from its label.
    var contentMaxWidth: CGFloat? { isRegular ? 760 : nil }

    func of<T>(_ compact: T, _ regular: T) -> T { isRegular ? regular : compact }
}

extension View {
    func parentContentColumn(_ maxWidth: CGFloat?) -> some View {
        self.frame(maxWidth: maxWidth ?? .infinity).frame(maxWidth: .infinity)
    }
}
