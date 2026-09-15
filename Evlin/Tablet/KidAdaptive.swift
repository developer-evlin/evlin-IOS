import SwiftUI

// Shared "how big is this canvas" signal for kid-side tablet screens, plus
// the couple of scale primitives every one of them needs once they branch
// on it. Pulled out of ScreenTabletHome (the first kid screen to get a real
// iPad pass, before this existed) so Calendar/Library/Settings/TaskDetail/
// ComicViewer don't each hand-roll slightly different breakpoints and
// multipliers. Driven by horizontalSizeClass rather than the device idiom
// so iPad Split View/Slide Over (compact) and iPhone Plus/Max landscape
// (regular) both fall out correctly.
struct KidAdaptive {
    var isRegular: Bool

    init(_ hSizeClass: UserInterfaceSizeClass?) {
        isRegular = hSizeClass == .regular
    }

    // Reading/list-shaped content (a task list, a settings card, a form)
    // gets centered in a column this wide on iPad instead of stretching
    // edge to edge. Grids and canvases (the comic grid, the calendar
    // timeline) size themselves separately since they should use the
    // extra width rather than float a phone column in the middle of it.
    var contentMaxWidth: CGFloat? { isRegular ? 760 : nil }

    // Picks the iPad value on regular width, the iPhone value otherwise.
    func of<T>(_ compact: T, _ regular: T) -> T { isRegular ? regular : compact }
}

extension View {
    // Centers content under `contentMaxWidth` without changing its
    // alignment inside that column — the same double-frame this screen
    // family already used before there was a shared helper for it.
    func kidContentColumn(_ maxWidth: CGFloat?) -> some View {
        self.frame(maxWidth: maxWidth ?? .infinity).frame(maxWidth: .infinity)
    }
}
