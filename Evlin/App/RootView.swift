import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case parent, tablet
    var id: String { rawValue }
    var label: String { self == .parent ? "Parent" : "Child" }
}

struct RootView: View {
    @State private var mode: AppMode? = nil
    // Separate per role — a parent and a kid go through entirely different
    // onboarding chains (accounts/PIN/pairing vs. consent/permissions), so
    // finishing one must never skip the other. (A single shared flag used to
    // gate both; that made switching to Child mode after parent onboarding
    // skip OnboardingV2Coordinator(role: .child) entirely.) Reset by nothing
    // (no persistence): a fresh app launch always re-onboards both.
    @State private var parentOnboarded = false
    @State private var childOnboarded = false
    // Tracks whether a role has entered onboarding at least once this
    // session — the very first step's "back to mode picker" button only
    // shows the first time through (see OnboardingV2Coordinator). Once a
    // parent/kid has started (even if they later bail back to the picker
    // and re-enter), that escape hatch stops being offered — backing out
    // no longer reads as "I haven't started yet."
    @State private var parentOnboardingStarted = false
    @State private var childOnboardingStarted = false
    // Gates the first-task spotlight tutorial (see ScreenProfile) — starts
    // false so the very first entry into parent mode after onboarding walks
    // the parent through adding a task before anything else is reachable.
    // Like `onboarded`, this is session-only and never persists.
    @State private var taskTutorialDone = false
    // Brief brand splash before the mode picker, matching the reference
    // flow's full-bleed logo screen ahead of onboarding.
    @State private var showSplash = true

    var body: some View {
        Group {
            if showSplash {
                SplashScreenView()
                    .transition(.opacity)
            } else {
                switch mode {
                case .none:
                    ModePickerView(mode: $mode)
                case .parent:
                    if parentOnboarded {
                        ParentRootView(onSwitchMode: { mode = nil }, taskTutorialDone: $taskTutorialDone)
                    } else {
                        OnboardingV2Coordinator(
                            role: .parent,
                            onExitToModePicker: parentOnboardingStarted ? nil : { mode = nil },
                            onComplete: { parentOnboarded = true }
                        )
                        .onAppear { parentOnboardingStarted = true }
                    }
                case .tablet:
                    if childOnboarded {
                        TabletRootView(onSwitchMode: { mode = nil })
                    } else {
                        OnboardingV2Coordinator(
                            role: .child,
                            onExitToModePicker: childOnboardingStarted ? nil : { mode = nil },
                            onComplete: { childOnboarded = true }
                        )
                        .onAppear { childOnboardingStarted = true }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: mode)
        // Used to be a blanket dismissKeyboardOnTap() here covering the
        // whole app (mode picker, every onboarding step, both tab roots) —
        // sat on top of screens with no text fields at all too, including
        // Settings' root list, where its simultaneousGesture measurably
        // delayed plain NavigationLink row taps (a short tap stopped
        // registering; only a longer press did). Removed in favor of
        // wiring it onto the specific screens/containers that actually
        // have fields (OnboardingV2ScreenContainer, FormShell, chat, etc.)
        // — see dismissKeyboardOnTap()'s own doc comment for why
        // simultaneousGesture alone doesn't fully prevent this at the
        // scale of "every screen in the app."
        .task {
            // Was a 1.1s hold + 0.3s fade (~1.4s total) — a real wait to
            // sit through on every single launch, not just the first one.
            // Still a beat long enough to register the brand, just not a
            // stall.
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.easeInOut(duration: 0.2)) { showSplash = false }
        }
    }
}

// Full-bleed brand splash — dark forest-green background, centered mascot
// mark, thin pulsing loading bar pinned near the bottom (mirrors the
// Robinhood-style reference: solid brand color, single centered logo mark,
// minimal loading affordance, no other chrome).
struct SplashScreenView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            EColor.primary.ignoresSafeArea()

            Image(systemName: "flame.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color(hex: "8CE6A8"))

            VStack {
                Spacer()
                Capsule()
                    .fill(Color.white.opacity(pulse ? 1 : 0.3))
                    .frame(width: 120, height: 4)
                    .padding(.bottom, 48)
            }
        }
        .task {
            // A `repeatForever` animation kicked off directly in .onAppear
            // races with SwiftUI's own transaction for the view's initial
            // appearance — most of the time it wins and the pulse starts
            // fine, but sometimes it loses that race and the animation
            // never actually begins, leaving the bar stuck at its static
            // starting opacity. A one-tick defer (this .task always runs
            // in its own transaction, after appear) sidesteps the race
            // instead of just narrowing the window.
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// Mirrors the web build's separate Evlin_Parent_view / Evlin_Tablet_view apps:
// one native binary, choose which experience to enter.
struct ModePickerView: View {
    @Binding var mode: AppMode?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(EColor.primary)
                .frame(width: 96, height: 96)
                .overlay(
                    Image(systemName: "flame.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color(hex: "8CE6A8"))
                )
                .shadow(color: EColor.primary.opacity(0.35), radius: 24, y: 10)

            Text("Evlin")
                .font(Typography.font(34, weight: .heavy))

            Spacer()

            VStack(spacing: 12) {
                ForEach(AppMode.allCases) { m in
                    Button {
                        mode = m
                    } label: {
                        HStack {
                            Text(m.label)
                                .font(Typography.font(16, weight: .bold))
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .foregroundStyle(m == .parent ? .white : EColor.onSurface)
                        .padding(.horizontal, 22)
                        .frame(height: 58)
                        .background(m == .parent ? EColor.primary : EColor.surfaceContainerLowest)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(EColor.outlineVariant, lineWidth: m == .parent ? 0 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EColor.surface)
    }
}
