# Simulator demo and onboarding previews

This guide explains the demo modes and simulator launch settings used to
preview Evlin's parent and child experiences. They exist only in the
**Evlin Demo** app: build the `Evlin Demo` scheme (Demo configuration,
bundle id `com.evlin.ios.demo`). The real app (`Evlin` scheme, Debug and
Release, `com.evlin.ios.demo`) contains none of it, and these flags do nothing
there. See "Builds: real vs Demo" in CLAUDE.md. There are no checked-in
demo shell scripts: the app reads launch arguments and simulator
`UserDefaults`.

## What the modes do

[DemoMode.swift](../Evlin/App/DemoMode.swift) owns the switches.
[EvlinApp.swift](../Evlin/App/EvlinApp.swift) calls `DemoMode.seedIfOn()`
during app startup, before [RootView.swift](../Evlin/App/RootView.swift) is
created. All demo behavior is behind `#if EVLIN_DEMO`, set only by the Demo
configuration.

| Preview | How to start | Result |
|---|---|---|
| Parent app | `-EvlinDemo` | Opens Parent Home with a local sample family and tasks. |
| Child app | `-EvlinKidDemo` | Opens the paired-child experience with local sample data. |
| Onboarding | `-EvlinOnboardingPreview` | Opens onboarding without a real sign-in or pairing flow. Choose a role from the mode picker unless a step override selects one. |
| Offline pill | `-EvlinDemo -EvlinOffline` or `-EvlinKidDemo -EvlinOffline` | Starts the corresponding seeded app in the offline-preview state. |
| Kid tab | `-EvlinKidDemo -EvlinKidTab 0`, `1`, or `2` | Opens Task, Calendar, or Library. |
| Kid task detail | `-EvlinKidDemo -EvlinKidOpenTask` | Opens the first available task. |
| Kid video | `-EvlinKidDemo -EvlinKidPlay` | Opens the first sample Library video. |

Demo data is written to the simulator's local store. The sample parent has
two children; the child demo contains only the kid's sample child. Demo mode
does not represent a real paired account. Some sample task photos use remote
`picsum.photos` URLs, so those images need network access.

## Onboarding previews

The onboarding routes are implemented by
[OnboardingV2Coordinator.swift](../Evlin/Onboarding/OnboardingV2Coordinator.swift).
`-EvlinOnboardingPreview` starts the parent at `parentProfile` and bypasses
QR pairing in the preview flow. For the child flow it starts at
`childProfile`; continuing bypasses QR pairing and goes to the connected
step. The Screen Time permission is a simulator preview only and does not
grant real FamilyControls access.

To open one flow at a specific step, set its per-simulator default before
launching:

```sh
# Child onboarding, starting at a chosen step:
xcrun simctl spawn "$IPAD_UDID" defaults write com.evlin.ios.demo \
  EvlinKidOnboarding childProfile

# Parent onboarding, starting at the agreement:
xcrun simctl spawn "$IPHONE_UDID" defaults write com.evlin.ios.demo \
  EvlinParentOnboarding parentBetaAgreement
```

Valid step values are the case names in `OnboardingV2Step`:

- Parent: `parentSignIn`, `parentProfile`, `parentBetaAgreement`,
  `parentPairScan`, `parentConnected`, `parentNotificationsAsk`,
  `parentWaitingForKid`, `parentDone`.
- Child: `childProfile`, `childShowCode`, `childConnected`,
  `childScreenTime`, `childNotifications`, `childLockableHub`,
  `childFamilySharingAsk`, `childLockChoice`, `childFamilySharingSetup`,
  `childSafetyLock`, `childReady`.

The child override also selects Child mode. The parent override selects Parent
mode. If testing the parent terms screen directly, mark the parent as not
onboarded as shown below; otherwise a saved completed session may enter the
app instead of onboarding.

## Build and open simulator windows

Find the simulator identifiers available on the current Mac:

```sh
xcrun simctl list devices available
```

Set `IPAD_UDID` and `IPHONE_UDID` to the desired device identifiers, then
build the universal app. Boot each simulator if it is not already booted
(check its state in `simctl list devices`):

```sh
xcodebuild -quiet -project Evlin.xcodeproj -scheme Evlin \
  -destination "platform=iOS Simulator,id=$IPAD_UDID" \
  -derivedDataPath DerivedData -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO build

xcrun simctl boot "$IPAD_UDID"
xcrun simctl boot "$IPHONE_UDID"
xcrun simctl bootstatus "$IPAD_UDID" -b
xcrun simctl bootstatus "$IPHONE_UDID" -b

open -a Simulator --args -CurrentDeviceUDID "$IPAD_UDID"
open -a Simulator --args -CurrentDeviceUDID "$IPHONE_UDID"
```

Install the built app on each device. Launch the app with the desired preview
arguments. Terminating first ensures the new launch arguments take effect:

```sh
xcrun simctl install "$IPAD_UDID" \
  DerivedData/Build/Products/Demo-iphonesimulator/Evlin.app
xcrun simctl install "$IPHONE_UDID" \
  DerivedData/Build/Products/Demo-iphonesimulator/Evlin.app

xcrun simctl terminate "$IPAD_UDID" com.evlin.ios.demo 2>/dev/null || true
xcrun simctl launch "$IPAD_UDID" com.evlin.ios.demo \
  -EvlinKidDemo

xcrun simctl terminate "$IPHONE_UDID" com.evlin.ios.demo 2>/dev/null || true
xcrun simctl launch "$IPHONE_UDID" com.evlin.ios.demo \
  -EvlinDemo
```

Replace `-EvlinKidDemo` or `-EvlinDemo` with `-EvlinOnboardingPreview` for
the onboarding preview. For a specific onboarding step, set the matching
default above, set the corresponding `evlin.childOnboarded` or
`evlin.parentOnboarded` default to `false`, and launch with
`-EvlinOnboardingPreview`.

For example, to show the parent agreement directly:

```sh
xcrun simctl spawn "$IPHONE_UDID" defaults write com.evlin.ios.demo \
  EvlinParentOnboarding parentBetaAgreement
xcrun simctl spawn "$IPHONE_UDID" defaults write com.evlin.ios.demo \
  evlin.parentOnboarded -bool false
xcrun simctl terminate "$IPHONE_UDID" com.evlin.ios.demo 2>/dev/null || true
xcrun simctl launch "$IPHONE_UDID" com.evlin.ios.demo \
  -EvlinOnboardingPreview
```

## Clear step overrides

The step overrides live in each simulator's app defaults; clear them on the
same simulator where they were set:

```sh
xcrun simctl spawn "$IPAD_UDID" defaults delete com.evlin.ios.demo \
  EvlinKidOnboarding
xcrun simctl spawn "$IPHONE_UDID" defaults delete com.evlin.ios.demo \
  EvlinParentOnboarding
```

If a key is already absent, `defaults delete` can return an error; that simply
means there is no override to clear. The parent and child override keys are
independent. Remove both when returning to ordinary simulator testing.

## Important distinctions

- `-EvlinDemo` and `-EvlinKidDemo` seed the local store and mark their
  respective app experiences as onboarded. Do not combine either with
  `-EvlinOnboardingPreview` when you intend to see onboarding.
- Step overrides are persistent simulator defaults, not launch arguments.
  Changing a launch argument alone will not remove an old step override.
- Simulator `UserDefaults` and app data are separate for each simulator
  device. Set or clear defaults using the correct device identifier.
- The adult/parent UI is intended for iPhone and the child UI for iPad, but
  both are the same universal app. The demo one is `com.evlin.ios.demo`, a
  separate app from the real `com.evlin.ios`, with its own data.
- Simulator previews do not test real Screen Time authorization or haptics.
