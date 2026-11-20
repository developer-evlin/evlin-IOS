import Foundation
import UIKit

/// The Demo build only (the `Evlin Demo` scheme, Demo configuration, flag
/// `EVLIN_DEMO`). It's a separate app, "Evlin Demo" (`com.evlin.ios.demo`),
/// with its own database and Keychain, for agents to try screens on the
/// Simulator. It opens as a parent with a sample family on the phone and
/// never talks to Evlin's server (`APIClient.baseURL` points nowhere).
/// `-EvlinKidDemo` opens the kid side instead, as Mia's paired device;
/// `-EvlinDemo` goes back to the parent side.
///
/// The Evlin scheme's Debug (Run in Xcode) and Release (Archive and
/// TestFlight) builds compile all of it out: `isBuild` and `isOn` are false.
enum DemoMode {
    #if EVLIN_DEMO
    static let isBuild = true
    #else
    static let isBuild = false
    #endif

    /// `-EvlinOnboardingPreview`: walk through onboarding on the Simulator
    /// with no account and no second device. Skips the parent's sign-in and
    /// the QR pairing on both sides (the kid is "Mia"), and keeps the
    /// parent's name on the phone only.
    #if EVLIN_DEMO
    static let previewsOnboarding = ProcessInfo.processInfo.arguments.contains("-EvlinOnboardingPreview")
    #else
    static let previewsOnboarding = false
    #endif

    #if EVLIN_DEMO
    /// A launch flag picks the side; with none, the side it last opened as.
    static var isKid: Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-EvlinKidDemo") || kidOnboardingStep != nil { return true }
        if args.contains("-EvlinDemo") { return false }
        return UserDefaults.standard.string(forKey: "evlin.demoRole") == "kid"
    }
    /// Always, except while walking through onboarding.
    static var isOn: Bool { !previewsOnboarding }
    /// `EvlinParentOnboarding parentBetaAgreement`: open the parent flow at
    /// a selected onboarding step for simulator previews.
    static let parentOnboardingStep: OnboardingV2Step? = UserDefaults.standard.string(forKey: "EvlinParentOnboarding")
        .flatMap { name in OnboardingV2Step.allCases.first { "\($0)" == name } }
    /// `-EvlinKidOnboarding childShowCode`: the kid's setup, opened at that
    /// step (an `OnboardingV2Step` case name), offline, with a made-up code.
    static let kidOnboardingStep: OnboardingV2Step? = UserDefaults.standard.string(forKey: "EvlinKidOnboarding")
        .flatMap { name in OnboardingV2Step.allCases.first { "\($0)" == name } }
    /// `-EvlinKidTab 0|1` (Task, Calendar): the tab the kid side
    /// opens on, skipping the "Your tasks for today" intro. For screenshots.
    static let kidTab = UserDefaults.standard.object(forKey: "EvlinKidTab").map { _ in UserDefaults.standard.integer(forKey: "EvlinKidTab") }
    /// `-EvlinKidOpenTask`: opens the first of today's tasks on launch.
    static let kidOpenTask = ProcessInfo.processInfo.arguments.contains("-EvlinKidOpenTask") || kidHandIn
    /// `-EvlinKidHandIn`: also taps "All done!" on it a moment later.
    static let kidHandIn = ProcessInfo.processInfo.arguments.contains("-EvlinKidHandIn")
    /// `-EvlinKidParentGate`: opens the gear's "Parents only" code entry.
    static let kidParentGate = ProcessInfo.processInfo.arguments.contains("-EvlinKidParentGate")
    /// `-EvlinKidParentSettings`: the settings behind it, as if the code was typed.
    static let kidParentSettings = ProcessInfo.processInfo.arguments.contains("-EvlinKidParentSettings")
    /// `-EvlinKidUnlock`: plays the "Unlocked!" moment a moment after launch.
    static let kidUnlock = ProcessInfo.processInfo.arguments.contains("-EvlinKidUnlock")
    /// `-EvlinKidOpenSent`: opens a task already sent in, still waiting.
    static let kidOpenSent = ProcessInfo.processInfo.arguments.contains("-EvlinKidOpenSent")
    /// `-EvlinKidOpenCompleted`: opens the Habits tab's Completed page.
    static let kidOpenCompleted = ProcessInfo.processInfo.arguments.contains("-EvlinKidOpenCompleted")
    /// `-EvlinKidGoalSend`: sends the first goal on the list, as a hold would.
    static let kidGoalSend = ProcessInfo.processInfo.arguments.contains("-EvlinKidGoalSend")
    /// `-EvlinKidGoalPhoto`: opens a photo goal's page with a sample photo in it
    /// (the Simulator has no camera).
    static let kidGoalPhoto: UIImage? = ProcessInfo.processInfo.arguments.contains("-EvlinKidGoalPhoto")
        ? UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).image { ctx in
            UIColor(red: 0.55, green: 0.72, blue: 0.86, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        }
        : nil
    /// With -EvlinOffline too: acts offline with two changes waiting, to
    /// see the connection pill.
    static var offline: Bool { isOn && ProcessInfo.processInfo.arguments.contains("-EvlinOffline") }
    /// `-EvlinChatSay "Block YouTube"`: Chat sends this once when it opens,
    /// so a reply's card can be seen without typing on the Simulator.
    static let chatSay: String? = UserDefaults.standard.string(forKey: "EvlinChatSay")
    /// `-EvlinParentTab 3`: the parent tab to open on (0 Home, 2 Chat,
    /// 3 Profile). `-EvlinParentOpen account|edit|child|story|newtask|lessons`:
    /// also opens Settings' Account sheet, its Edit account page, or the
    /// first child's page; `story` opens Home's first
    /// goal check-in waiting; `newtask` Home's New task form; `newgoal` New goal; `writetask` New task's form as Write my own opens it; `review` the review card of a task sent in without a photo; `-EvlinGoalKind n` opens New habit on kind n; `goalbuild` New goal's set-up; `goalprize` the same with its prize field being typed in; `artgallery` every habit and chore drawing in its ring on the page (`-EvlinGalleryFrom n` starts at the nth); `goalown` New goal's + (type a goal; `-EvlinHabitTyped "Swim club"` types it); `goalpictures` the same with the picture picker open; `settings` (on Profile) Settings; `childpaywall` (on Profile) Settings with the plan page Add a child opens on the free plan; `noahtrial` Noah picked, his 3-days-left trial card over his page; `noahplan` the plan page it leads to; `noahprofile` Noah picked, no card (with `-EvlinParentTab 3`, his Profile); `leopaywall` the plan page Leo's avatar opens (the free plan's example); `habittour` the first habit's tour on Mia's Walk the dog; `goalcard` a goal's half card with a check-in waiting; `goalidle` one with none; `goaledit` a goal's edit form; `goaltype` with its number being typed; `ava` shows Ava, with the habits that have pictures; `unlockguide` (on Profile) Instant unlock's guide; `milestone` (on Profile) the newest completed milestone's sheet; `celebrate` a reached goal's moment; `storyreach` the story viewer, then Looks good on the check-in that reaches the goal. For screenshots.
    static let parentTab = UserDefaults.standard.object(forKey: "EvlinParentTab").map { _ in UserDefaults.standard.integer(forKey: "EvlinParentTab") }
    static let parentOpen: String? = UserDefaults.standard.string(forKey: "EvlinParentOpen")
    /// `-EvlinHomeLane 2`: Home opens on a lane (0 Today, 1 Tomorrow, 2 This
    /// week, 3 Goals). For screenshots.
    /// `-EvlinAllSentIn`: Mia has sent in all of today's tasks.
    static let allSentIn = ProcessInfo.processInfo.arguments.contains("-EvlinAllSentIn")
    /// `-EvlinOneChild`: seed only Mia, for the single-child layouts.
    static let oneChild = ProcessInfo.processInfo.arguments.contains("-EvlinOneChild")
    /// `-EvlinNewFamily`: Mia has no tasks yet, as a family just set up
    /// (Today's first-task invitation).
    static let newFamily = ProcessInfo.processInfo.arguments.contains("-EvlinNewFamily")
    /// `-EvlinGoalCount n`: Mia's first n running goals only; with 0, none at all;
    /// above the four she has, more are added.
    static let goalCount = UserDefaults.standard.object(forKey: "EvlinGoalCount").map { _ in UserDefaults.standard.integer(forKey: "EvlinGoalCount") }
    static let homeLane = UserDefaults.standard.object(forKey: "EvlinHomeLane").map { _ in UserDefaults.standard.integer(forKey: "EvlinHomeLane") }
    /// The sample family's example of the free plan's limit: Leo, the
    /// second child, opens the plan page when picked (2026-11-16, the
    /// user's call). Mia and Ava open as before.
    static let proExampleChildId: String? = "55555555-5555-4555-8555-555555555555"
    /// The fourth child, Noah: the family's free trial with 3 days left,
    /// picking him says so before it moves to the free plan (2026-11-17).
    static let trialEndingChildId: String? = "44444444-4444-4444-8444-444444444444"
    /// `-EvlinKidTour`: the kid's first look round again, from the start.
    static let kidTour = UserDefaults.standard.bool(forKey: "EvlinKidTour")
    /// `-EvlinKidTourStep n` (with `-EvlinKidTour`): starts at its nth card.
    static let kidTourStep = UserDefaults.standard.integer(forKey: "EvlinKidTourStep")
    /// `-EvlinHabitTourStep n` (with `habittour`): the parent's habit tour from its nth card.
    static let habitTourStep = UserDefaults.standard.integer(forKey: "EvlinHabitTourStep")
    #else
    static let isKid = false
    static let isOn = false
    static let parentOnboardingStep: OnboardingV2Step? = nil
    static let kidOnboardingStep: OnboardingV2Step? = nil
    static let kidTab: Int? = nil
    static let kidOpenTask = false
    static let kidHandIn = false
    static let kidParentGate = false
    static let kidParentSettings = false
    static let kidOpenSent = false
    static let kidOpenCompleted = false
    static let kidGoalSend = false
    static let goalCount: Int? = nil
    static let kidGoalPhoto: UIImage? = nil
    static let kidUnlock = false
    static let offline = false
    static let chatSay: String? = nil
    static let parentTab: Int? = nil
    static let oneChild = false
    static let newFamily = false
    static let allSentIn = false
    static let parentOpen: String? = nil
    static let homeLane: Int? = nil
    static let proExampleChildId: String? = nil
    static let trialEndingChildId: String? = nil
    static let kidTour = false
    static let kidTourStep = 0
    static let habitTourStep = 0
    #endif

    /// The role the phone's database was last seeded for this launch.
    @MainActor private static var seededAsKid: Bool?

    /// Signs in as a stand-in parent and fills the phone's database: one
    /// child, six tasks today (three to do, one sent in, two done), and a
    /// real family's worth of other tasks and events.
    /// The end of the parent's onboarding walkthrough (`-EvlinOnboardingPreview`):
    /// Home opens as a family just set up, one child with no tasks, as it
    /// would on a new phone. The
    /// sample family a Demo launch left in the database is wiped; the next
    /// `-EvlinDemo` launch seeds it again.
    /// On the kid's side too (`asParent: false`): the iPad opens as the
    /// newly paired child, with none of the sample family's tasks or habits.
    /// With two simulators linked, each then keeps the child's tasks in
    /// step with the other (`DemoPairSync`).
    @MainActor static func startNewFamily(kidName: String, asParent: Bool = true) {
        #if EVLIN_DEMO
        LocalStore.shared.eraseAll()
        FamilyStore.clear()
        GoalStore.shared.replaceAll([])
        if asParent {
            // New task opens on the Library, as on a new phone.
            UserDefaults.standard.removeObject(forKey: NewTaskTab.key)
            // Habits pointed out again, as on a new phone.
            UserDefaults.standard.removeObject(forKey: HabitsTour.prizeTipKey)
        }
        SessionManager.shared.activeChildId = DemoPairBridge.childId
        FamilyStore.addOnboardedChild(name: kidName)
        TaskStore.shared.reload()
        SyncState.shared.publish()
        DemoPairSync.start(asParent: asParent)
        #endif
    }

    @MainActor static func seedIfOn() {
        #if EVLIN_DEMO
        // Once per launch for each role. RootView.init calls this too, and
        // SwiftUI runs that init on every redraw of the app's root: seeding
        // saves the store, the save redraws, and the next seed saves
        // again, a loop that held the main thread at full CPU and left
        // buttons dead. Launching as the other side seeds that one.
        guard isOn, seededAsKid != isKid else { return }
        seededAsKid = isKid
        // The app catalog the server would send (app_catalog.py), so
        // pickers that block apps have something to pick.
        AppCatalog.shared.useSample([
                "YouTube",
                "YouTube Kids",
                "Netflix",
                "Disney+",
                "TikTok",
                "Instagram",
                "Snapchat",
                "WhatsApp",
                "Messages",
                "Discord",
                "Roblox",
                "Minecraft",
                "Fortnite",
                "Brawl Stars",
                "Clash Royale",
                "Among Us",
                "Pokemon GO",
                "Subway Surfers",
                "Safari",
                "Google Chrome",
                "Spotify",
        ].enumerated().map { i, name in
            ApiApp(id: String(format: "aaaaaaaa-aaaa-4aaa-8aaa-%012d", i + 1), name: name, aliases: [], category: nil)
        })
        let defaults = UserDefaults.standard
        if isKid {
            // A paired kid's device: only a device token, no parent login.
            SessionManager.shared.parentAccessToken = nil
            SessionManager.shared.parentRefreshToken = nil
            SessionManager.shared.childDeviceToken = kidOnboardingStep == nil ? "demo" : nil
            defaults.set(false, forKey: "evlin.parentOnboarded")
            defaults.set(kidOnboardingStep == nil, forKey: "evlin.childOnboarded")
            defaults.set("tablet", forKey: "evlin.mode")
            defaults.set("kid", forKey: "evlin.demoRole")
        } else {
            SessionManager.shared.parentAccessToken = "demo"
            SessionManager.shared.parentRefreshToken = "demo"
            defaults.set(true, forKey: "evlin.parentOnboarded")
            defaults.set(false, forKey: "evlin.childOnboarded")
            defaults.set("parent", forKey: "evlin.mode")
            // A name for Account settings to show, as a signed-in parent has.
            defaults.set(["name": "Saraa", "email": "saraa@example.com"], forKey: "parentProfile.cache")
            defaults.set("parent", forKey: "evlin.demoRole")
        }

        let store = LocalStore.shared
        store.eraseAll()
        let childId = "11111111-1111-4111-8111-111111111111"
        SessionManager.shared.activeChildId = childId
        // Goals (kept on the phone, not the store).
        let day: TimeInterval = 86_400
        // Today's check-in (an hour or two ago) waits for the parent; the
        // days before are answered.
        func sent(_ n: Int, hoursAgo: Double) -> Date {
            n == 0 ? Date().addingTimeInterval(-hoursAgo * 3600) : Date().addingTimeInterval(-Double(n) * day)
        }
        var readingCheckIns: [GoalCheckIn] = []
        for n in 0...11 {
            let status: GoalCheckIn.Status = n == 0 ? .waiting : (n == 4 ? .notApproved : .approved)
            readingCheckIns.append(GoalCheckIn(at: sent(n, hoursAgo: 1), status: status,
                                           photo: "https://picsum.photos/seed/evlin-read-\(n)/600/800"))
        }
        var bedCheckIns: [GoalCheckIn] = []
        for n in 0...3 {
            let status: GoalCheckIn.Status = n == 0 ? .waiting : .approved
            bedCheckIns.append(GoalCheckIn(at: sent(n, hoursAgo: 2), status: status,
                                           photo: "https://picsum.photos/seed/evlin-bed-\(n)/600/800"))
        }
        // Instant unlock: Mia has 2 days to go; Ava has earned it (her work
        // is all sent in, so turning it on opens her phone at once).
        let trustDay = CalendarSync.isoDay(Date())
        UserDefaults.standard.removeObject(forKey: "evlin.unlockGuideSeen")
        UnlockTrustStore.shared.replaceAll([
            childId: UnlockTrust(streak: 1, day: trustDay),
            "99999999-9999-4999-8999-999999999999": UnlockTrust(streak: UnlockTrust.daysNeeded, earned: true, day: trustDay),
        ])
        let avaHabits = "99999999-9999-4999-8999-999999999999"
        GoalStore.shared.replaceAll([
            // Checked in each day: some approved, one not, two waiting. One
            // more that looks good reaches it.
            Goal(id: "goal-mia-read", childId: childId, title: "Read for 20 minutes", target: 14, unit: "days",
                 prize: "Trip to the zoo", done: 13, colorIndex: 4, createdAt: Date().addingTimeInterval(-12 * day),
                 needsPhoto: true,
                 entries: readingCheckIns),
            // A photo each morning.
            Goal(id: "goal-mia-bed", childId: childId, title: "Floss daily", target: 30, unit: "days",
                 prize: "A new toothbrush", done: 3, colorIndex: 3, createdAt: Date().addingTimeInterval(-5 * day),
                 needsPhoto: true,
                 entries: bedCheckIns),
            Goal(id: "goal-mia-piano", childId: childId, title: "Practice piano", target: 20, unit: "times",
                 prize: "Concert tickets", done: 6, colorIndex: 2, createdAt: Date().addingTimeInterval(-8 * day),
                 // No photo: the kid holds the ring. Waiting on the parent's side.
                 entries: isKid ? [] : [GoalCheckIn(at: Date().addingTimeInterval(-1800))]),
            // A photo goal not started: nothing done, so its ring is only grey.
            Goal(id: "goal-mia-dog", childId: childId, title: "Walk the dog", target: 20, unit: "days",
                 prize: "Dog park trip", done: 0, colorIndex: 0, createdAt: Date().addingTimeInterval(-1 * day),
                 needsPhoto: true),
            Goal(id: "goal-mia-bike", childId: childId, title: "Ride a bike", target: 8, unit: "times",
                 prize: "Bike bell and streamers", done: 8, colorIndex: 1, createdAt: Date().addingTimeInterval(-5 * day),
                 // Reached today: the kid sees the prize. `celebrate` plays it reaching.
                 finishedAt: parentOpen == "celebrate" ? nil : Date().addingTimeInterval(-3600)),
            // Reached and celebrated: Milestones.
            Goal(id: "goal-mia-outside", childId: childId, title: "Play outside", target: 14, unit: "days",
                 prize: "Trip to the park", done: 14, colorIndex: 1, createdAt: Date().addingTimeInterval(-40 * day),
                 finishedAt: Date().addingTimeInterval(-24 * day)),
            Goal(id: "goal-mia-draw", childId: childId, title: "Drawing", target: 15, unit: "times",
                 prize: "New art kit", done: 15, colorIndex: 5, createdAt: Date().addingTimeInterval(-60 * day),
                 finishedAt: Date().addingTimeInterval(-36 * day)),
            // Ava: four habits from New habit's ideas, a page full, part-way along.
            Goal(id: "goal-ava-school", childId: avaHabits, title: "Ready for school", target: 10, unit: "days",
                 prize: "Pick the weekend breakfast", done: 7, createdAt: Date().addingTimeInterval(-20 * day)),
            Goal(id: "goal-ava-teeth", childId: avaHabits, title: "Feed the pet", target: 14, unit: "days",
                 prize: "A toy the pet will love", done: 11, createdAt: Date().addingTimeInterval(-19 * day)),
            Goal(id: "goal-ava-yoga", childId: avaHabits, title: "Yoga", target: 14, unit: "days",
                 prize: "A new yoga mat", done: 3, createdAt: Date().addingTimeInterval(-18 * day)),
            Goal(id: "goal-ava-chess", childId: avaHabits, title: "Play chess", target: 10, unit: "times",
                 prize: "Board game night", done: 2, createdAt: Date().addingTimeInterval(-17 * day)),
            Goal(id: "goal-mia-piano10", childId: childId, title: "Practice piano", target: 10, unit: "times",
                 prize: "Concert tickets", done: 10, colorIndex: 2, createdAt: Date().addingTimeInterval(-80 * day),
                 finishedAt: Date().addingTimeInterval(-55 * day)),
            // Six in all, so Completed milestones folds after four.
            Goal(id: "goal-mia-swim", childId: childId, title: "Swimming", target: 10, unit: "times",
                 prize: "Pool day with a friend", done: 10, colorIndex: 3, createdAt: Date().addingTimeInterval(-90 * day),
                 finishedAt: Date().addingTimeInterval(-62 * day)),
            Goal(id: "goal-mia-teeth", childId: childId, title: "Take a shower or bath", target: 14, unit: "days",
                 prize: "Bath bombs", done: 14, colorIndex: 4, createdAt: Date().addingTimeInterval(-100 * day),
                 finishedAt: Date().addingTimeInterval(-70 * day)),
        ])
        if let goalCount {
            let kept = Array(GoalStore.shared.goals(for: childId).prefix(goalCount))
            let extras = ["Play chess", "Yoga", "Feed the pet", "Swimming", "Take daily vitamins"]
                .prefix(max(0, goalCount - kept.count))
                .enumerated().map { i, title in
                    Goal(id: "goal-mia-extra-\(i)", childId: childId, title: title, target: 14, unit: "days",
                         prize: "Movie night", done: i * 2, colorIndex: i)
                }
            GoalStore.shared.replaceAll(kept + extras)
        }
        let rules = ApiChildRule(dailyLimitMinutes: 90, downtimeEnabled: false, downtimeStart: nil, downtimeEnd: nil,
                                 dailyLimitEnabled: true, customRules: [], weeklySchedule: nil)
        let state = ApiChildState(manualLock: false, taskGateOverride: false)
        let today = CalendarSync.isoDay(Date())
        let titles = ["Make the bed", "Read for 20 minutes", "Feed the cat", "Math homework", "Tidy the desk", "Practice piano",
                      "Clean your room", "Water the plants", "Walk the dog"]
        // TEMPORARY: three more sent in with photos, waiting for review.
        let seeded = ["pending", "pending", "pending", "submitted", "approved", "approved",
                        "submitted", "submitted", "submitted"]
        // -EvlinAllSentIn: everything sent in, so Home shows slide to approve all.
        let statuses = allSentIn ? seeded.map { $0 == "pending" ? "submitted" : $0 } : seeded
        let photoTasks: [Int: [String]] = [
            6: ["https://picsum.photos/seed/evlin-room-1/900/1200", "https://picsum.photos/seed/evlin-room-2/900/1200"],
            7: ["https://picsum.photos/seed/evlin-plants/900/1200"],
            8: ["https://picsum.photos/seed/evlin-dog/900/1200"],
        ]
        var tasks: [ApiTask] = []
        var occurrences: [ApiOccurrence] = []
        for (i, title) in titles.enumerated() {
            let taskId = String(format: "22222222-2222-4222-8222-%012d", i)
            tasks.append(ApiTask(id: taskId, title: title, instructions: nil, recurrence: "daily", gatesApps: true,
                                 submissionKind: photoTasks[i] == nil ? "none" : "photo", bucket: "anytime", category: "Chore", dueDate: nil,
                                 dueTime: i == 2 ? "18:00:00" : nil,
                                 createdAt: CalendarSync.isoString(Date().addingTimeInterval(Double(-i) * 3600)),
                                 bonusMinutes: 0, createdBy: "parent"))
            occurrences.append(ApiOccurrence(id: String(format: "33333333-3333-4333-8333-%012d", i), taskId: taskId,
                                             childId: childId, dueDate: today, status: statuses[i],
                                             bypassRequested: false, bypassNote: nil, rejectionNote: nil))
        }
        // More tasks on other days and a month of events, so the demo is the
        // size of a real family's data: a small one hid a slow rebuild.
        for i in 9..<58 {
            let taskId = String(format: "22222222-2222-4222-8222-%012d", i)
            tasks.append(ApiTask(id: taskId, title: "Extra task \(i)", instructions: nil, recurrence: ["mon,wed,fri", "none", "tue,thu", "sat,sun"][i % 4], gatesApps: true,
                                 submissionKind: "none", bucket: "anytime", category: "Chore",
                                 dueDate: CalendarSync.isoDay(Date().addingTimeInterval(Double(i - 30) * 86400)),
                                 dueTime: nil, createdAt: CalendarSync.isoString(Date()), bonusMinutes: 0, createdBy: "parent"))
        }
        store.batch {
            store.saveChild(ApiChild(id: childId, name: "Mia", colorIndex: 0, isPaired: true, timezone: nil),
                            position: 0, rules: rules, state: state, availableMinutes: 90)
            store.saveTasks(newFamily ? [] : tasks, childId: childId)
            store.saveOccurrences(newFamily ? [] : occurrences,
                                  photos: Dictionary(uniqueKeysWithValues: photoTasks.map { (String(format: "33333333-3333-4333-8333-%012d", $0.key), $0.value) }),
                                  childId: childId, dueDate: today)
            // Blocked apps, so Screen time's list and detail pages have
            // something to show.
            let now = Date()
            func block(_ n: Int, _ app: String, _ type: String, ends: Date? = nil, task: String? = nil, why: String) -> ApiAppBlock {
                ApiAppBlock(id: String(format: "88888888-8888-4888-8888-%012d", n), childId: childId, appId: nil,
                            appName: app, blockType: type, durationMinutes: ends == nil ? nil : 60,
                            endsAt: ends.map(CalendarSync.isoString), untilTaskId: task, scheduleDays: nil,
                            scheduleStart: nil, scheduleEnd: nil, resolved: false, resolvedReason: nil,
                            createdBy: "parent", createdAt: CalendarSync.isoString(now), resolvedAt: nil,
                            state: "active", description: why)
            }
            store.saveAppBlocks([
                block(1, "YouTube", "indefinite", why: ""),
                block(2, "TikTok", "duration", ends: now.addingTimeInterval(3600), why: "for 1 hour"),
                block(3, "Roblox", "until_task", task: String(format: "22222222-2222-4222-8222-%012d", 3),
                      why: "until 'Math homework' is approved"),
            ], childId: childId)
            // A kid's device holds only its own child; -EvlinOneChild shows
            // a family of one.
            if isKid || oneChild { return }
            // A second child, so the multi-child layouts can be seen, and
            // out of time for today, so "Time's up" and the extra-time card
            // can be seen.
            let leoId = "55555555-5555-4555-8555-555555555555"
            store.saveChild(ApiChild(id: leoId, name: "Leo", colorIndex: 1, isPaired: true, timezone: nil),
                            position: 1, rules: rules, state: state, availableMinutes: 0)   // out of time
            store.saveTasks([ApiTask(id: "66666666-6666-4666-8666-000000000001", title: "Piano practice", instructions: nil,
                                     recurrence: "daily", gatesApps: true, submissionKind: "none", bucket: "anytime",
                                     category: "Chore", dueDate: nil, dueTime: nil, createdAt: CalendarSync.isoString(Date()),
                                     bonusMinutes: 0, createdBy: "parent")], childId: leoId)
            // Done for today, so all that's left is the time.
            store.saveOccurrences([ApiOccurrence(id: "66666666-6666-4666-8666-100000000001",
                                                 taskId: "66666666-6666-4666-8666-000000000001", childId: leoId,
                                                 dueDate: today, status: "approved", bypassRequested: false,
                                                 bypassNote: nil, rejectionNote: nil)],
                                  photos: [:], childId: leoId, dueDate: today)
            // A third child who has sent in every task and is waiting on
            // the parent, so Home's "waiting for you" and Approve all can
            // be seen with nothing yet approved.
            let avaId = "99999999-9999-4999-8999-999999999999"
            if parentOpen == "ava" { SessionManager.shared.activeChildId = avaId }
            store.saveChild(ApiChild(id: avaId, name: "Ava", colorIndex: 2, isPaired: true, timezone: nil),
                            position: 2, rules: rules, state: state, availableMinutes: 60)
            let avaTitles = ["Brush teeth", "Pack school bag", "Read a chapter", "Feed the fish"]
            store.saveTasks(avaTitles.enumerated().map { i, title in
                ApiTask(id: String(format: "99999999-0000-4000-8000-%012d", i), title: title, instructions: nil,
                        recurrence: "daily", gatesApps: true, submissionKind: "none", bucket: "anytime",
                        category: "Chore", dueDate: nil, dueTime: nil,
                        createdAt: CalendarSync.isoString(Date().addingTimeInterval(Double(-i) * 3600)),
                        bonusMinutes: 0, createdBy: "parent")
            }, childId: avaId)
            store.saveOccurrences(avaTitles.indices.map { i in
                ApiOccurrence(id: String(format: "99999999-1111-4111-8111-%012d", i),
                              taskId: String(format: "99999999-0000-4000-8000-%012d", i), childId: avaId,
                              dueDate: today, status: "submitted", bypassRequested: false,
                              bypassNote: nil, rejectionNote: nil)
            }, photos: [:], childId: avaId, dueDate: today)
            // A fourth child, Noah, the family's trial with 3 days left
            // (`trialEndingChildId`): two chores not started yet.
            let noahId = "44444444-4444-4444-8444-444444444444"
            store.saveChild(ApiChild(id: noahId, name: "Noah", colorIndex: 3, isPaired: true, timezone: nil),
                            position: 3, rules: rules, state: state, availableMinutes: 45)
            let noahTitles = ["Make your bed", "Water the plants"]
            store.saveTasks(noahTitles.enumerated().map { i, title in
                ApiTask(id: String(format: "44444444-0000-4000-8000-%012d", i), title: title, instructions: nil,
                        recurrence: "daily", gatesApps: true, submissionKind: "none", bucket: "anytime",
                        category: "Chore", dueDate: nil, dueTime: nil, createdAt: CalendarSync.isoString(Date()),
                        bonusMinutes: 0, createdBy: "parent")
            }, childId: noahId)
            store.saveOccurrences(noahTitles.indices.map { i in
                ApiOccurrence(id: String(format: "44444444-1111-4111-8111-%012d", i),
                              taskId: String(format: "44444444-0000-4000-8000-%012d", i), childId: noahId,
                              dueDate: today, status: "pending", bypassRequested: false,
                              bypassNote: nil, rejectionNote: nil)
            }, photos: [:], childId: noahId, dueDate: today)

        }
        #endif
    }

    #if EVLIN_DEMO
    /// A stand-in for the chat agent's block replies, so the Block card can be
    /// tried in the Demo app, which never reaches the server. Only what the
    /// real agent would send for these (tool_calls/draft_app_block.py); nil for
    /// anything else, which then fails offline as before.
    @MainActor static func chatReply(childId: String, text: String, shortcut: String?) -> ApiChatMessage? {
        let name = FamilyStore.child(childId).name
        func reply(_ text: String, _ tool: String?, _ args: [String: String]?) -> ApiChatMessage {
            ApiChatMessage(id: UUID().uuidString, childId: childId, conversationId: nil, role: "assistant",
                           text: text, toolCall: tool, toolArgs: args, agent: "chat",
                           createdAt: ISO8601DateFormatter().string(from: Date()))
        }
        if shortcut == "block_app" {
            let q = "Which app should I block for \(name), and for how long?"
            return reply(q, "ask_follow_up", ["question": q])
        }
        let said = text.lowercased()
        // Several tasks at once, the way the server sends them: the first
        // message carries the line, the rest are card-only.
        if said.contains("tasks") {
            let tasks: [[String: String]] = [
                ["title": "Tidy bedroom floor", "recurrence": "daily", "due_time": "18:00",
                 "instructions": "Nothing left on the floor."],
                ["title": "Pack school bag", "recurrence": "mon,tue,wed,thu,fri", "due_time": "19:30"],
                ["title": "Water the plants", "recurrence": "sat,sun"],
            ]
            var first = reply("Here are 3 things to add — check each one before you add it.", "draft_task", tasks[0])
            first.extraMessages = tasks.dropFirst().map { reply("", "draft_task", $0) }
            return first
        }
        guard let app = AppCatalog.shared.apps.first(where: { said.contains($0.name.lowercased()) })
                ?? (said.contains("yt") ? AppCatalog.shared.apps.first { $0.name == "YouTube" } : nil)
        else { return nil }
        let late = Calendar.current.component(.hour, from: Date()) >= 18
        let length = said.contains("hour") ? "1_hour" : late ? "rest_of_today" : "1_hour"
        let why = length == "rest_of_today" ? "for the rest of today, since it's already evening" : "for an hour"
        return reply("Blocking \(app.name) \(why). Change the app or the length below if you'd like.",
                     "draft_app_block",
                     ["app": app.name, "app_id": app.id, "app_name": app.name, "on_list": "True", "length": length])
    }
    #endif
}
