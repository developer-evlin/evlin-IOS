import SwiftUI

// Small stand-in catalog since there's no real installed-app inventory to
// query — bundle IDs are shown because that's specifically what was asked
// for, matching how Evlin-iOS's own disambiguation cards (AppControlCard's
// app_store_disambiguation) label each candidate. Shared (not private to
// one screen) because both ScreenChat's one-off "Block an app" card and
// ScreenProfile's standing "Blocked Apps" rule pick from the same catalog —
// the same app list should look identical wherever a parent picks from it.
struct MockApp: Identifiable {
    let id = UUID()
    var name: String
    var bundleID: String
    var icon: String
    var color: Color
}

let mockAppCatalog: [MockApp] = [
    MockApp(name: "TikTok", bundleID: "com.zhiliaoapp.musically", icon: "music.note", color: .black),
    MockApp(name: "Instagram", bundleID: "com.burbn.instagram", icon: "camera.fill", color: Color(hex: "E1306C")),
    MockApp(name: "YouTube", bundleID: "com.google.ios.youtube", icon: "play.rectangle.fill", color: .red),
    MockApp(name: "Roblox", bundleID: "com.roblox.robloxmobile", icon: "gamecontroller.fill", color: Color(hex: "00A2FF")),
    MockApp(name: "Snapchat", bundleID: "com.toyopagroup.picaboo", icon: "camera.fill", color: Color(hex: "FFFC00")),
    MockApp(name: "Discord", bundleID: "com.hammerandchisel.discord", icon: "bubble.left.and.bubble.right.fill", color: Color(hex: "5865F2")),
    MockApp(name: "Messages", bundleID: "com.apple.MobileSMS", icon: "message.fill", color: .green),
    MockApp(name: "Safari", bundleID: "com.apple.mobilesafari", icon: "safari.fill", color: .blue),
]

// Mirrors LockListManagerView's real Apps/Categories split (Views/Settings/
// LockListManagerView.swift) — blocking a whole category, not just named
// apps, is a real option there.
struct MockCategory: Identifiable {
    let id = UUID()
    var name: String
    var icon: String
    var color: Color
}

let mockCategoryCatalog: [MockCategory] = [
    MockCategory(name: "Social Media", icon: "person.2.fill", color: Color(hex: "E1306C")),
    MockCategory(name: "Games", icon: "gamecontroller.fill", color: Color(hex: "00A2FF")),
    MockCategory(name: "Entertainment", icon: "play.rectangle.fill", color: .red),
    MockCategory(name: "Messaging", icon: "message.fill", color: .green),
]
