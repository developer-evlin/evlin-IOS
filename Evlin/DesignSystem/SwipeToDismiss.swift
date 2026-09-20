import SwiftUI

/// `.fullScreenCover` never gets swipe-to-dismiss for free (unlike `.sheet`,
/// which does) — this adds a drag-down gesture with the same feel, shared so
/// every kid-side full-screen flow exits the same way instead of "find the
/// one small X/back button."
///
/// `interactive: true` (the photo viewer, which has no scrollable content of
/// its own) tracks the finger and offsets the view as it drags — a `.gesture`
/// claims the touch outright, which is fine here since nothing else wants it.
/// `interactive: false` (a screen with its own ScrollView, e.g. the task
/// detail form) uses `.simultaneousGesture` instead and skips the visual
/// offset, so normal scrolling is never contested — it only ever fires on a
/// clearly deliberate big/fast downward swipe, layered on top of scrolling
/// rather than competing with it.
struct SwipeToDismiss: ViewModifier {
    var interactive: Bool
    var onDismiss: () -> Void
    @State private var dragOffset: CGFloat = 0

    private var drag: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard interactive, value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let mostlyVertical = abs(value.translation.height) > abs(value.translation.width)
                let passedDistance = value.translation.height > 120
                let passedVelocity = value.predictedEndTranslation.height > 400
                if mostlyVertical && value.translation.height > 0 && (passedDistance || passedVelocity) {
                    onDismiss()
                }
                dragOffset = 0
            }
    }

    func body(content: Content) -> some View {
        let offsetView = content.offset(y: interactive ? max(0, dragOffset) : 0)
            .animation(interactive ? .interactiveSpring(response: 0.35, dampingFraction: 0.86) : nil, value: dragOffset)
        if interactive {
            offsetView.gesture(drag)
        } else {
            offsetView.simultaneousGesture(drag)
        }
    }
}

extension View {
    /// Drag down to dismiss. See `SwipeToDismiss` for what `interactive`
    /// controls and why a scrollable screen needs the non-interactive mode.
    func swipeToDismiss(interactive: Bool = true, _ onDismiss: @escaping () -> Void) -> some View {
        modifier(SwipeToDismiss(interactive: interactive, onDismiss: onDismiss))
    }
}
