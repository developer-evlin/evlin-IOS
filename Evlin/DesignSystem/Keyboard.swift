import SwiftUI
import UIKit

// The app had no way to dismiss the keyboard except hitting Save/Cancel on a
// form or (in chat only) dragging the scroll view — tapping anywhere else on
// screen just left it up.
//
// Two things make this reliable everywhere it's used, including forms nested
// two presentation contexts deep (a sheet like EditTaskReviewSheet stacked on
// top of TaskReviewDeckView's own fullScreenCover):
//  - `endEditing(true)` on the key window, not
//    `sendAction(#selector(resignFirstResponder))`. The latter searches the
//    responder chain for a target and can silently no-op once a view is a
//    couple of modal presentations deep; walking the window's view hierarchy
//    directly doesn't depend on where in that chain the call originates.
//  - `.contentShape(Rectangle())` before the gesture, so the *whole* frame —
//    including the transparent gaps between fields, not just their painted
//    backgrounds — counts as tappable. Without it, only actually-drawn
//    content triggers the gesture.
// `simultaneousGesture`, not `onTapGesture`/`gesture`, is what makes this
// safe to drop onto a screen that already has its own buttons/list
// rows/scrolling: it fires *alongside* whatever a tap already does there
// instead of intercepting it, so nothing underneath loses its own tap
// handling.
extension View {
    func dismissKeyboardOnTap() -> some View {
        contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    UIApplication.shared.connectedScenes
                        .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                        .first?
                        .endEditing(true)
                }
            )
    }
}
