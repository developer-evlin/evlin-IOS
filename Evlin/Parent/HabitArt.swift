import SwiftUI

/// Hand-drawn pictures for a few habit ideas, in the style of the plant on the
/// empty Goals lane: flat shapes, two tones each, a soft shadow on the ground.
/// Drawn in code, so they stay sharp at any size. Still, not animated.
struct HabitArt: View {
    var title: String

    /// Whether there's a picture for this idea.
    static func has(_ title: String) -> Bool { drawings[title] != nil }

    private typealias Drawing = (inout GraphicsContext) -> Void

    private static let drawings: [String: Drawing] = [
        "Ready for school": backpack,
        "Prepare for school on their own": backpack,   // saved before it was shortened
        // The chore list's pictures (New task's Library, Let Mia choose).
        "Clean your room": bed,
        "Water the plants": pottedPlant,
        "Help with laundry": laundry,
        "Set or clear the table": table,
        "Take care of the pet": petBowl,
        "Take out the trash": trashBin,
        "Do your homework": homework,
        // Every habit idea on New habit (2026-11-05).
        "Play outside": tree,
        "Skip rope": ropeJumper,
        "Play football": football,
        "Karate": karateKick,
        "Jiu-jitsu": gi,
        "Ride a bike": bike,
        "Swimming": swimmer,
        "Play basketball": basketball,
        "Yoga": stretcher,
        "Brush your teeth": toothbrush,
        "Floss daily": floss,
        "Take a shower or bath": bathtub,
        "Take daily vitamins": vitamins,
        "Read for 20 minutes": openBook,
        "Play chess": chessPawn,
        "Practice Spanish": spanishBubble,
        "Practice Mandarin": chineseBubble,
        // No longer an idea; kept so habits saved from it keep their picture.
        "Practice your family's language": speechBubbles,
        "Drawing": crayonDrawing,
        "Practice guitar": guitar,
        "Practice piano": pianoKeys,
        "Writing": writingPage,
        "Feed the pet": petBowl,
        "Walk the dog": dogOnLead,
        "Clean the house": sprayBottle,
        "Help with dinner": cookingPot,
        "Set the table": table,
        "Help with the laundry": laundry,
        // New habit's kinds, across the top.
        "kind.active": dumbbell,
        "kind.wellness": heart,
        "kind.creative": paintPalette,
        "kind.household": house,
    ]

    var body: some View {
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width / 100, y: size.height / 100)
            Self.drawings[title]?(&ctx)
        }
        .accessibilityHidden(true)
    }

    // The plant's colours, and a few to go with them.
    private static let leaf = Color(light: "4CC764", dark: "3FA457")
    private static let shade = Color(light: "2E9E4F", dark: "2A7F41")
    private static let earth = Color(light: "9A6238", dark: "A47552")
    private static let earthDark = Color(light: "7A4A28", dark: "85593A")
    private static let cream = Color(light: "F7EFE2", dark: "CFC6B6")
    // The shade on white things: a deeper tan since the page went Alabaster
    // (#E6D8C2 before, 2026-11-14: it all but matched the page).
    private static let creamDark = Color(light: "D9C7A8", dark: "B5A994")
    private static let amber = Color(light: "F5B83D", dark: "D9A23C")
    private static let amberDark = Color(light: "D9932A", dark: "B97E26")
    private static let sky = Color(light: "6EC1E4", dark: "5AA6C7")
    private static let skyDark = Color(light: "3B93C8", dark: "357FAD")
    private static let skyPale = Color(light: "DDF0F8", dark: "A9C2CE")
    // The near-black parts lighten in Dark, so they don't vanish on it.
    private static let slate = Color(light: "33404F", dark: "B4BBC4")
    private static let red = Color(light: "E0483C", dark: "C9554B")

    private static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .continuous)
    }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    private static func shadow(_ ctx: inout GraphicsContext, x: CGFloat, y: CGFloat, width: CGFloat) {
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 1.8))
            layer.fill(Path(ellipseIn: CGRect(x: x - width / 2, y: y - 2.5, width: width, height: 5)),
                       with: .color(.black.opacity(0.2)))
        }
    }

    // A made bed, side on: headboard, green blanket with its fold, a pillow.
    private static let bed: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 83, width: 76)
        ctx.fill(box(17, 72, 6, 10, 2), with: .color(earthDark))
        ctx.fill(box(78, 72, 6, 10, 2), with: .color(earthDark))
        ctx.fill(box(10, 30, 10, 46, 4), with: .color(earthDark))
        ctx.fill(box(84, 50, 8, 26, 3), with: .color(earthDark))
        ctx.fill(box(14, 62, 74, 12, 3), with: .color(earth))
        ctx.fill(box(20, 48, 66, 16, 6), with: .color(creamDark))
        let blanket = box(40, 44, 46, 24, 7)
        ctx.fill(blanket, with: .color(leaf))
        ctx.fill(blanket.intersection(Path(CGRect(x: 40, y: 58, width: 46, height: 10))), with: .color(shade))
        ctx.fill(box(38, 43, 10, 25, 5), with: .color(shade))
        let pillow = box(21, 37, 21, 14, 7)
        ctx.fill(pillow, with: .color(cream))
        ctx.fill(pillow.intersection(Path(CGRect(x: 21, y: 46, width: 21, height: 5))), with: .color(creamDark))
    }

    // A green school bag: handle, straps, a darker pocket with its zip.
    private static let backpack: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 88, width: 54)
        var handle = Path()
        handle.addArc(center: CGPoint(x: 50, y: 24), radius: 9, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        ctx.stroke(handle, with: .color(shade), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
        ctx.fill(box(18, 44, 9, 28, 4), with: .color(earthDark))
        ctx.fill(box(73, 44, 9, 28, 4), with: .color(earthDark))
        let body = box(25, 22, 50, 64, 17)
        ctx.fill(body, with: .color(leaf))
        ctx.fill(body.intersection(Path(CGRect(x: 58, y: 22, width: 17, height: 64))), with: .color(shade))
        ctx.fill(box(33, 56, 34, 23, 8), with: .color(shade))
        var zip = Path()
        zip.move(to: CGPoint(x: 39, y: 64))
        zip.addLine(to: CGPoint(x: 61, y: 64))
        ctx.stroke(zip, with: .color(cream), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        ctx.fill(box(44, 37, 12, 8, 3), with: .color(amber))
    }

    // MARK: The chores

    private static let redDark = Color(light: "B8372E", dark: "9E3A33")
    private static let bin = Color(light: "8A96A3", dark: "7C8794")
    private static let binDark = Color(light: "6B7785", dark: "5E6976")

    // A plant in a pot, two leaves, and a drop of water by it.
    private static let pottedPlant: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 89, width: 44)
        var stem = Path()
        stem.move(to: CGPoint(x: 50, y: 56))
        stem.addLine(to: CGPoint(x: 50, y: 38))
        ctx.stroke(stem, with: .color(shade), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        var left = Path()
        left.move(to: CGPoint(x: 50, y: 48))
        left.addQuadCurve(to: CGPoint(x: 22, y: 32), control: CGPoint(x: 28, y: 50))
        left.addQuadCurve(to: CGPoint(x: 50, y: 48), control: CGPoint(x: 42, y: 26))
        ctx.fill(left, with: .color(leaf))
        var right = Path()
        right.move(to: CGPoint(x: 50, y: 40))
        right.addQuadCurve(to: CGPoint(x: 76, y: 20), control: CGPoint(x: 72, y: 42))
        right.addQuadCurve(to: CGPoint(x: 50, y: 40), control: CGPoint(x: 56, y: 16))
        ctx.fill(right, with: .color(shade))
        var pot = Path()
        pot.move(to: CGPoint(x: 32, y: 60))
        pot.addLine(to: CGPoint(x: 68, y: 60))
        pot.addLine(to: CGPoint(x: 63, y: 88))
        pot.addLine(to: CGPoint(x: 37, y: 88))
        pot.closeSubpath()
        ctx.fill(pot, with: .color(earth))
        ctx.fill(box(28, 54, 44, 9, 3), with: .color(earthDark))
        var drop = Path()
        drop.move(to: CGPoint(x: 82, y: 42))
        drop.addQuadCurve(to: CGPoint(x: 87, y: 54), control: CGPoint(x: 87, y: 48))
        drop.addArc(center: CGPoint(x: 82, y: 54), radius: 5, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        drop.addQuadCurve(to: CGPoint(x: 82, y: 42), control: CGPoint(x: 77, y: 48))
        ctx.fill(drop, with: .color(sky))
    }

    // A woven basket with a shirt and a sock in it.
    private static let laundry: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 88, width: 62)
        ctx.fill(Path(ellipseIn: CGRect(x: 24, y: 30, width: 32, height: 22)), with: .color(sky))
        ctx.fill(Path(ellipseIn: CGRect(x: 48, y: 28, width: 26, height: 20)), with: .color(red))
        var body = Path()
        body.move(to: CGPoint(x: 22, y: 50))
        body.addLine(to: CGPoint(x: 78, y: 50))
        body.addLine(to: CGPoint(x: 72, y: 86))
        body.addLine(to: CGPoint(x: 28, y: 86))
        body.closeSubpath()
        ctx.fill(body, with: .color(amber))
        for y in [62.0, 73.0] {
            let inset = (y - 50) / 36 * 6
            ctx.fill(box(22 + inset + 2, y, 56 - inset * 2 - 4, 3, 1.5), with: .color(amberDark))
        }
        ctx.fill(box(18, 45, 64, 9, 4.5), with: .color(amberDark))
    }

    // A plate between a fork and a knife.
    private static let table: Drawing = { ctx in
        ctx.fill(circle(50, 54, 27), with: .color(creamDark))
        ctx.stroke(circle(50, 54, 27), with: .color(giEdge), lineWidth: 1.5)
        ctx.fill(circle(50, 54, 19), with: .color(cream))
        // Fork: three tines on a neck, then the handle.
        for x in [10.0, 14.5, 19.0] { ctx.fill(box(x, 28, 2.6, 14, 1.3), with: .color(slate)) }
        ctx.fill(box(10, 38, 11.6, 7, 3), with: .color(slate))
        ctx.fill(box(13.8, 42, 4, 38, 2), with: .color(slate))
        // Knife: a rounded blade, then the handle.
        ctx.fill(box(79, 28, 7, 28, 3.5), with: .color(slate))
        ctx.fill(box(80.5, 52, 4, 28, 2), with: .color(slate))
    }

    // A full food bowl, and a paw print over it.
    private static let petBowl: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 87, width: 66)
        var bowl = Path()
        bowl.move(to: CGPoint(x: 16, y: 60))
        bowl.addLine(to: CGPoint(x: 84, y: 60))
        bowl.addQuadCurve(to: CGPoint(x: 70, y: 85), control: CGPoint(x: 82, y: 83))
        bowl.addLine(to: CGPoint(x: 30, y: 85))
        bowl.addQuadCurve(to: CGPoint(x: 16, y: 60), control: CGPoint(x: 18, y: 83))
        ctx.fill(bowl, with: .color(red))
        ctx.fill(Path(ellipseIn: CGRect(x: 16, y: 54, width: 68, height: 12)), with: .color(redDark))
        for (x, y, r) in [(36.0, 56.0, 5.5), (47.0, 53.0, 5.5), (58.0, 55.0, 5.5), (66.0, 57.0, 4.5), (52.0, 58.0, 4.5)] {
            ctx.fill(circle(x, y, r), with: .color(earth))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: 42, y: 25, width: 16, height: 12)), with: .color(earthDark))
        for (x, y) in [(39.0, 21.0), (45.5, 16.0), (54.5, 16.0), (61.0, 21.0)] {
            ctx.fill(circle(x, y, 3.4), with: .color(earthDark))
        }
    }

    // A bin with its lid on.
    private static let trashBin: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 89, width: 48)
        var body = Path()
        body.move(to: CGPoint(x: 30, y: 36))
        body.addLine(to: CGPoint(x: 70, y: 36))
        body.addLine(to: CGPoint(x: 66, y: 87))
        body.addLine(to: CGPoint(x: 34, y: 87))
        body.closeSubpath()
        ctx.fill(body, with: .color(bin))
        for x in [41.0, 48.5, 56.0] { ctx.fill(box(x, 44, 3, 36, 1.5), with: .color(binDark)) }
        ctx.fill(box(25, 27, 50, 10, 4), with: .color(binDark))
        ctx.fill(box(42, 20, 16, 9, 3.5), with: .color(binDark))
        ctx.fill(box(46, 24, 8, 5, 2), with: .color(bin))
    }

    // A notebook with a pencil across it.
    private static let homework: Drawing = { ctx in
        shadow(&ctx, x: 52, y: 89, width: 56)
        ctx.fill(box(24, 18, 46, 64, 6), with: .color(sky))
        ctx.fill(box(24, 18, 9, 64, 4), with: .color(skyDark))
        ctx.fill(box(41, 30, 22, 10, 2.5), with: .color(skyPale))
        var pencil = Path()
        pencil.move(to: CGPoint(x: 52, y: 86))
        pencil.addLine(to: CGPoint(x: 84, y: 54))
        pencil.addLine(to: CGPoint(x: 78, y: 48))
        pencil.addLine(to: CGPoint(x: 46, y: 80))
        pencil.closeSubpath()
        ctx.fill(pencil, with: .color(amber))
        var eraser = Path()
        eraser.move(to: CGPoint(x: 84, y: 54))
        eraser.addLine(to: CGPoint(x: 89, y: 49))
        eraser.addLine(to: CGPoint(x: 83, y: 43))
        eraser.addLine(to: CGPoint(x: 78, y: 48))
        eraser.closeSubpath()
        ctx.fill(eraser, with: .color(red))
        var tip = Path()
        tip.move(to: CGPoint(x: 46, y: 80))
        tip.addLine(to: CGPoint(x: 52, y: 86))
        tip.addLine(to: CGPoint(x: 41, y: 91))
        tip.closeSubpath()
        ctx.fill(tip, with: .color(cream))
        var lead = Path()
        lead.move(to: CGPoint(x: 43.5, y: 87.5))
        lead.addLine(to: CGPoint(x: 45.5, y: 89.2))
        lead.addLine(to: CGPoint(x: 41, y: 91))
        lead.closeSubpath()
        ctx.fill(lead, with: .color(slate))
    }

    // MARK: The habit ideas

    private static let orange = Color(light: "F28C28", dark: "D17D2C")
    private static let orangeDark = Color(light: "D9731A", dark: "B4651E")
    private static let ink = Color(light: "1F2933", dark: "CDD2D9")
    private static let slateLight = Color(light: "4A5868", dark: "8E97A3")

    private static func poly(_ points: [(CGFloat, CGFloat)]) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: points[0].0, y: points[0].1))
        for pt in points.dropFirst() { p.addLine(to: CGPoint(x: pt.0, y: pt.1)) }
        p.closeSubpath()
        return p
    }

    private static func stroke(_ ctx: inout GraphicsContext, _ points: [(CGFloat, CGFloat)], _ color: Color, _ width: CGFloat) {
        var p = Path()
        p.move(to: CGPoint(x: points[0].0, y: points[0].1))
        for pt in points.dropFirst() { p.addLine(to: CGPoint(x: pt.0, y: pt.1)) }
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private static func sparkle(_ ctx: inout GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: Color) {
        var p = Path()
        p.move(to: CGPoint(x: x, y: y - r))
        p.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x, y: y))
        p.addQuadCurve(to: CGPoint(x: x, y: y + r), control: CGPoint(x: x, y: y))
        p.addQuadCurve(to: CGPoint(x: x - r, y: y), control: CGPoint(x: x, y: y))
        p.addQuadCurve(to: CGPoint(x: x, y: y - r), control: CGPoint(x: x, y: y))
        ctx.fill(p, with: .color(color))
    }

    /// Fills the part of a shape right of `x`, for its shaded side. By
    /// clipping: cutting a shape joined from circles came out as a block.
    private static func fillRight(_ ctx: inout GraphicsContext, _ p: Path, from x: CGFloat, _ color: Color) {
        ctx.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: x, y: 0, width: 100 - x, height: 100)))
            layer.fill(p, with: .color(color))
        }
    }

    // A round tree.
    private static let tree: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 89, width: 50)
        ctx.fill(box(45, 54, 10, 34, 3), with: .color(earth))
        let canopy = circle(50, 36, 24).union(circle(31, 48, 15)).union(circle(69, 48, 15))
        ctx.fill(canopy, with: .color(leaf))
        fillRight(&ctx, canopy, from: 50, shade)
    }

    // A skipping rope, its two handles up.
    private static let skipRope: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 90, width: 50)
        var rope = Path()
        rope.move(to: CGPoint(x: 26, y: 42))
        rope.addCurve(to: CGPoint(x: 74, y: 42), control1: CGPoint(x: 22, y: 100), control2: CGPoint(x: 78, y: 100))
        ctx.stroke(rope, with: .color(red), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        for x in [21.0, 69.0] {
            ctx.fill(box(x, 18, 10, 24, 5), with: .color(amber))
            ctx.fill(box(x + 1, 36, 8, 7, 2.5), with: .color(amberDark))
        }
    }

    // Ink that stays dark in Dark too, for black things on a light object (a
    // ball's patches, black keys, a guitar's sound hole): the usual ink
    // lightens there and left them grey on grey. Then the football's own colours.
    private static let ballWhite = Color(light: "F7EFE2", dark: "ECE7DD")
    private static let ballShade = Color(light: "E6D8C2", dark: "C2B8A6")
    private static let patchInk = Color(light: "1F2933", dark: "262C33")

    // A football.
    private static let football: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 88, width: 50)
        let ball = circle(50, 50, 30)
        ctx.fill(ball, with: .color(ballWhite))
        ctx.fill(ball.subtracting(circle(44, 44, 30)), with: .color(ballShade))
        func pentagon(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ turn: Double) -> Path {
            poly((0..<5).map { i in
                let a = (Double(i) * 72 + turn - 90) * .pi / 180
                return (cx + r * CGFloat(cos(a)), cy + r * CGFloat(sin(a)))
            })
        }
        ctx.fill(pentagon(50, 50, 10, 0), with: .color(patchInk))
        for k in 0..<5 {
            let a = (Double(k) * 72 - 90) * .pi / 180
            let patch = pentagon(50 + 28 * CGFloat(cos(a)), 50 + 28 * CGFloat(sin(a)), 9, 36)
            ctx.fill(patch.intersection(ball), with: .color(patchInk))
        }
    }

    private static let giEdge = Color(light: "B5A68C", dark: "7D7262")

    // Someone in a white gi and black belt, mid front kick, fist out.
    private static let karateKick: Drawing = { ctx in
        shadow(&ctx, x: 42, y: 90, width: 36)
        // The gi, part by part: every part's warm edge first, then the fills,
        // so the white gi stays clear on the cream page.
        let gi: [([(CGFloat, CGFloat)], Color, CGFloat)] = [
            ([(42, 58), (36, 86)], creamDark, 9),
            ([(46, 58), (62, 52), (82, 46)], cream, 9),
            ([(42, 34), (44, 58)], cream, 16),
            ([(40, 40), (30, 50), (34, 56)], creamDark, 7),
            ([(46, 38), (60, 38), (70, 34)], cream, 7),
        ]
        for (points, _, width) in gi { limb(&ctx, points, giEdge, width + 4) }
        for (points, color, width) in gi { limb(&ctx, points, color, width) }
        ctx.fill(circle(73, 33, 4.5), with: .color(skin))
        ctx.fill(circle(85, 45, 3.5), with: .color(skin))
        ctx.fill(box(34, 50, 19, 5, 2.5), with: .color(patchInk))
        limb(&ctx, [(38, 54), (34, 64)], patchInk, 3.5)
        head(&ctx, 41, 22)
    }

    // A word in a speech bubble, for a language to practise: the bubble in
    // `color`, the letter or character over it in `text`.
    private static func languageBubble(_ ctx: inout GraphicsContext, _ word: String, size: CGFloat,
                                       _ color: Color, _ shade: Color, _ text: Color) {
        shadow(&ctx, x: 50, y: 90, width: 50)
        let bubble = box(12, 14, 76, 60, 20).union(poly([(26, 66), (42, 66), (24, 84)]))
        ctx.fill(bubble, with: .color(color))
        fillRight(&ctx, bubble, from: 66, shade)
        ctx.draw(Text(word).font(.system(size: size, weight: .heavy, design: .rounded)).foregroundColor(text),
                 at: CGPoint(x: 50, y: 44))
    }

    // Spanish: ¡Hola! in a warm bubble.
    private static let spanishBubble: Drawing = { ctx in
        languageBubble(&ctx, "¡Hola!", size: 20, amber, amberDark, patchInk)
    }

    // Mandarin: 你好 (hello) in a red bubble.
    private static let chineseBubble: Drawing = { ctx in
        languageBubble(&ctx, "你好", size: 26, red, redDark, ballWhite)
    }

    // A black belt, knotted.
    private static let karateBelt: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 90, width: 56)
        ctx.fill(box(10, 42, 80, 14, 4), with: .color(ink))
        ctx.fill(poly([(44, 54), (52, 54), (40, 86), (31, 83)]), with: .color(ink))
        ctx.fill(poly([(49, 54), (57, 54), (69, 83), (60, 86)]), with: .color(ink))
        ctx.fill(box(41, 38, 18, 22, 6), with: .color(slateLight))
        ctx.fill(box(32, 74, 9, 3, 1.5).applying(.identity), with: .color(amber))
    }

    // A martial-arts jacket, its belt tied.
    private static let gi: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 90, width: 58)
        ctx.fill(poly([(28, 28), (12, 56), (21, 62), (33, 44)]), with: .color(creamDark))
        ctx.fill(poly([(72, 28), (88, 56), (79, 62), (67, 44)]), with: .color(creamDark))
        // A warm edge round the white gi, so it holds on the page.
        ctx.stroke(poly([(28, 28), (12, 56), (21, 62), (33, 44)]), with: .color(giEdge), lineWidth: 2.4)
        ctx.stroke(poly([(72, 28), (88, 56), (79, 62), (67, 44)]), with: .color(giEdge), lineWidth: 2.4)
        ctx.stroke(poly([(28, 26), (72, 26), (78, 84), (22, 84)]), with: .color(giEdge), lineWidth: 2.4)
        ctx.fill(poly([(28, 28), (12, 56), (21, 62), (33, 44)]), with: .color(creamDark))
        ctx.fill(poly([(72, 28), (88, 56), (79, 62), (67, 44)]), with: .color(creamDark))
        ctx.fill(poly([(28, 26), (72, 26), (78, 84), (22, 84)]), with: .color(cream))
        stroke(&ctx, [(39, 25), (50, 54), (61, 25)], creamDark, 6)
        ctx.fill(box(22, 60, 56, 8, 3), with: .color(skyDark))
        ctx.fill(poly([(46, 66), (52, 66), (47, 80), (42, 79)]), with: .color(skyDark))
    }

    // A bike, side on.
    private static let bike: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 82, width: 72)
        for x in [26.0, 74.0] {
            ctx.stroke(circle(x, 64, 15), with: .color(ink), lineWidth: 4)
            ctx.fill(circle(x, 64, 2.5), with: .color(ink))
        }
        stroke(&ctx, [(26, 64), (48, 64), (40, 40), (26, 64)], red, 4)
        stroke(&ctx, [(40, 40), (66, 40), (48, 64)], red, 4)
        stroke(&ctx, [(66, 40), (74, 64)], red, 4)
        stroke(&ctx, [(66, 40), (64, 31)], ink, 3.5)
        stroke(&ctx, [(59, 31), (70, 31)], ink, 4)
        ctx.fill(box(33, 34, 14, 5, 2.5), with: .color(ink))
    }

    // Someone swimming front crawl: head and one arm out of the water, the
    // rest under the waves.
    private static let swimmer: Drawing = { ctx in
        limb(&ctx, [(40, 60), (76, 64)], red, 13)
        limb(&ctx, [(74, 64), (90, 62)], skin, 6)
        limb(&ctx, [(36, 58), (14, 62)], skin, 5)
        limb(&ctx, [(44, 56), (54, 34), (70, 40)], skin, 5)
        head(&ctx, 32, 50)
        // The water: a wavy top and a soft rounded bottom, not a box.
        var water = Path()
        water.move(to: CGPoint(x: 8, y: 64))
        for i in 0..<4 {
            let x0 = 8 + Double(i) * 21
            water.addQuadCurve(to: CGPoint(x: x0 + 21, y: 64), control: CGPoint(x: x0 + 10.5, y: 57))
        }
        water.addQuadCurve(to: CGPoint(x: 78, y: 84), control: CGPoint(x: 94, y: 84))
        water.addLine(to: CGPoint(x: 22, y: 84))
        water.addQuadCurve(to: CGPoint(x: 8, y: 64), control: CGPoint(x: 6, y: 84))
        water.closeSubpath()
        ctx.fill(water, with: .color(sky))
        var wave = Path()
        wave.move(to: CGPoint(x: 22, y: 75))
        for i in 0..<3 {
            let x0 = 22 + Double(i) * 19
            wave.addQuadCurve(to: CGPoint(x: x0 + 19, y: 75), control: CGPoint(x: x0 + 9.5, y: 69))
        }
        ctx.stroke(wave, with: .color(skyDark), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
    }

    // A swim ring on the water.
    private static let swimRing: Drawing = { ctx in
        let ring = circle(50, 44, 25).subtracting(circle(50, 44, 11))
        ctx.fill(ring, with: .color(red))
        ctx.drawLayer { layer in
            layer.clip(to: ring)
            layer.fill(Path(CGRect(x: 45, y: 0, width: 10, height: 100)), with: .color(cream))
            layer.fill(Path(CGRect(x: 0, y: 39, width: 100, height: 10)), with: .color(cream))
        }
        for (y, color) in [(70.0, sky), (84.0, skyDark)] {
            var wave = Path()
            wave.move(to: CGPoint(x: 8, y: y))
            for i in 0..<4 {
                let x0 = 8 + Double(i) * 21
                wave.addQuadCurve(to: CGPoint(x: x0 + 21, y: y), control: CGPoint(x: x0 + 10.5, y: y - 8))
            }
            ctx.stroke(wave, with: .color(color), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }
    }

    // A basketball.
    private static let basketball: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 88, width: 50)
        let ball = circle(50, 50, 30)
        ctx.fill(ball, with: .color(orange))
        ctx.fill(ball.subtracting(circle(44, 44, 30)), with: .color(orangeDark))
        ctx.drawLayer { layer in
            layer.clip(to: ball)
            var seams = Path()
            seams.move(to: CGPoint(x: 50, y: 18)); seams.addLine(to: CGPoint(x: 50, y: 82))
            seams.move(to: CGPoint(x: 18, y: 50)); seams.addLine(to: CGPoint(x: 82, y: 50))
            seams.move(to: CGPoint(x: 29, y: 26)); seams.addQuadCurve(to: CGPoint(x: 29, y: 74), control: CGPoint(x: 46, y: 50))
            seams.move(to: CGPoint(x: 71, y: 26)); seams.addQuadCurve(to: CGPoint(x: 71, y: 74), control: CGPoint(x: 54, y: 50))
            layer.stroke(seams, with: .color(Color(light: "5A3210", dark: "6E4630")), lineWidth: 2.5)
        }
    }

    // A yoga mat, half rolled.
    private static let yogaMat: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 88, width: 74)
        ctx.fill(poly([(10, 72), (62, 72), (72, 84), (20, 84)]), with: .color(leaf))
        ctx.fill(poly([(10, 72), (62, 72), (63, 74), (12, 74)]), with: .color(shade))
        ctx.fill(circle(70, 60, 18), with: .color(leaf))
        ctx.fill(circle(70, 60, 12), with: .color(shade))
        ctx.fill(circle(70, 60, 6.5), with: .color(leaf))
        ctx.fill(circle(70, 60, 2.5), with: .color(shade))
    }

    // A toothbrush with paste on it, big and on a slant (2026-11-14, the
    // user's call: the slim upright one, pale bristles up top, was hard to
    // see): a two-tone blue handle with a pale grip, the head, white
    // bristles in a warm edge, and a blue swirl of paste.
    private static let toothbrush: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 90, width: 46)
        var brush = ctx
        brush.translateBy(x: 50, y: 50)
        brush.rotate(by: .degrees(35))
        brush.translateBy(x: -50, y: -50)
        let handle = box(42, 36, 16, 58, 8).union(box(45, 20, 10, 20, 5))
        brush.fill(handle, with: .color(sky))
        fillRight(&brush, handle, from: 50, skyDark)
        brush.fill(box(46.5, 54, 7, 30, 3.5), with: .color(skyPale))
        brush.fill(box(42, 2, 16, 24, 6), with: .color(skyDark))
        // The bristles, three tufts, on the head's side.
        let bristles = box(26, 4, 17, 20, 3)
        brush.fill(bristles, with: .color(cream))
        for y in [10.0, 15.5] { brush.fill(box(26, y, 17, 1.8, 0.9), with: .color(creamDark)) }
        brush.stroke(bristles, with: .color(giEdge), lineWidth: 1.6)
        // Paste along the top of the bristles.
        let paste = circle(29, 3, 5).union(circle(36, 1.5, 5.5)).union(circle(42, 3, 4.5))
        brush.fill(paste, with: .color(skyPale))
        brush.stroke(paste, with: .color(sky), lineWidth: 1.6)
    }

    // A tooth, and floss across it.
    private static let floss: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 90, width: 40)
        var tooth = Path()
        tooth.move(to: CGPoint(x: 28, y: 34))
        tooth.addCurve(to: CGPoint(x: 50, y: 26), control1: CGPoint(x: 28, y: 18), control2: CGPoint(x: 42, y: 20))
        tooth.addCurve(to: CGPoint(x: 72, y: 34), control1: CGPoint(x: 58, y: 20), control2: CGPoint(x: 72, y: 18))
        tooth.addCurve(to: CGPoint(x: 63, y: 82), control1: CGPoint(x: 72, y: 54), control2: CGPoint(x: 68, y: 74))
        tooth.addQuadCurve(to: CGPoint(x: 55, y: 62), control: CGPoint(x: 57, y: 82))
        tooth.addQuadCurve(to: CGPoint(x: 45, y: 62), control: CGPoint(x: 50, y: 57))
        tooth.addQuadCurve(to: CGPoint(x: 37, y: 82), control: CGPoint(x: 43, y: 82))
        tooth.addCurve(to: CGPoint(x: 28, y: 34), control1: CGPoint(x: 32, y: 74), control2: CGPoint(x: 28, y: 54))
        tooth.closeSubpath()
        ctx.fill(tooth, with: .color(Color(light: "FBFAF6", dark: "D6D3CC")))
        fillRight(&ctx, tooth, from: 56, creamDark)
        ctx.stroke(tooth, with: .color(giEdge), lineWidth: 2)
        var thread = Path()
        thread.move(to: CGPoint(x: 10, y: 52))
        thread.addLine(to: CGPoint(x: 84, y: 40))
        thread.addQuadCurve(to: CGPoint(x: 86, y: 58), control: CGPoint(x: 96, y: 46))
        ctx.stroke(thread, with: .color(sky), style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }

    // A bath, with bubbles.
    private static let bathtub: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 90, width: 72)
        stroke(&ctx, [(17, 48), (17, 28), (27, 28)], ink, 4)
        for (x, y, r) in [(32.0, 44.0, 8.0), (45.0, 40.0, 10.0), (59.0, 43.0, 8.0), (71.0, 41.0, 7.0)] {
            ctx.fill(circle(x, y, r), with: .color(skyPale))
            ctx.stroke(circle(x, y, r), with: .color(sky), lineWidth: 1.5)
        }
        var tub = Path()
        tub.move(to: CGPoint(x: 14, y: 52))
        tub.addLine(to: CGPoint(x: 86, y: 52))
        tub.addLine(to: CGPoint(x: 81, y: 72))
        tub.addQuadCurve(to: CGPoint(x: 69, y: 80), control: CGPoint(x: 79, y: 80))
        tub.addLine(to: CGPoint(x: 31, y: 80))
        tub.addQuadCurve(to: CGPoint(x: 19, y: 72), control: CGPoint(x: 21, y: 80))
        tub.closeSubpath()
        ctx.fill(tub, with: .color(cream))
        fillRight(&ctx, tub, from: 62, creamDark)
        ctx.stroke(tub, with: .color(giEdge), lineWidth: 1.8)
        ctx.fill(box(10, 47, 80, 8, 4), with: .color(creamDark))
        ctx.stroke(box(10, 47, 80, 8, 4), with: .color(giEdge), lineWidth: 1.4)
        ctx.fill(box(26, 78, 6, 9, 2), with: .color(ink))
        ctx.fill(box(68, 78, 6, 9, 2), with: .color(ink))
    }

    // A vitamin bottle and a capsule.
    private static let vitamins: Drawing = { ctx in
        shadow(&ctx, x: 52, y: 90, width: 60)
        ctx.fill(box(24, 32, 32, 54, 6), with: .color(amber))
        fillRight(&ctx, box(24, 32, 32, 54, 6), from: 44, amberDark)
        ctx.fill(box(22, 22, 36, 13, 4), with: .color(ink))
        ctx.fill(box(26, 48, 28, 20, 2), with: .color(cream))
        ctx.fill(box(37, 51, 6, 14, 1.5), with: .color(leaf))
        ctx.fill(box(33, 55, 14, 6, 1.5), with: .color(leaf))
        let turn = CGAffineTransform(rotationAngle: -.pi / 5).concatenating(CGAffineTransform(translationX: 74, y: 76))
        let pill = Path(roundedRect: CGRect(x: -15, y: -6.5, width: 30, height: 13), cornerRadius: 6.5)
        ctx.fill(pill.applying(turn), with: .color(cream))
        ctx.stroke(pill.applying(turn), with: .color(giEdge), lineWidth: 1.2)
        ctx.fill(pill.intersection(Path(CGRect(x: -15, y: -7, width: 15, height: 14))).applying(turn), with: .color(red))
    }

    // An open book.
    private static let openBook: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 86, width: 74)
        ctx.fill(poly([(10, 30), (50, 36), (50, 80), (10, 74)]), with: .color(sky))
        ctx.fill(poly([(90, 30), (50, 36), (50, 80), (90, 74)]), with: .color(skyDark))
        ctx.fill(poly([(15, 27), (50, 33), (50, 75), (15, 69)]), with: .color(cream))
        ctx.fill(poly([(85, 27), (50, 33), (50, 75), (85, 69)]), with: .color(creamDark))
        for i in 0..<4 {
            let y = 40 + Double(i) * 8
            stroke(&ctx, [(22, y), (43, y + 3.5)], Color(light: "C9B79C", dark: "9C8D76"), 2)
            stroke(&ctx, [(57, y + 3.5), (78, y)], Color(light: "BCA98D", dark: "8E806B"), 2)
        }
    }

    // A chess pawn on a board.
    private static let chessPawn: Drawing = { ctx in
        for i in 0..<4 {
            ctx.fill(box(18 + Double(i) * 16, 76, 16, 10, i == 0 ? 3 : (i == 3 ? 3 : 0)),
                     with: .color(i.isMultiple(of: 2) ? creamDark : cream))
        }
        ctx.stroke(box(18, 76, 64, 10, 3), with: .color(giEdge), lineWidth: 1.4)
        let pawn = circle(50, 28, 10)
            .union(box(39, 38, 22, 6, 3))
            .union(poly([(44, 43), (56, 43), (63, 70), (37, 70)]))
            .union(box(31, 67, 38, 10, 4))
        ctx.fill(pawn, with: .color(slateLight))
        fillRight(&ctx, pawn, from: 50, ink)
    }

    // Two speech bubbles: talking at home.
    private static let speechBubbles: Drawing = { ctx in
        let first = box(12, 18, 50, 34, 13).union(poly([(22, 48), (34, 48), (20, 62)]))
        ctx.fill(first, with: .color(leaf))
        for (y, w) in [(29.0, 30.0), (38.0, 22.0)] { ctx.fill(box(22, y, w, 4, 2), with: .color(cream)) }
        let second = box(38, 46, 50, 32, 13).union(poly([(66, 74), (78, 74), (80, 88)]))
        ctx.fill(second, with: .color(amber))
        for (y, w) in [(56.0, 30.0), (65.0, 20.0)] { ctx.fill(box(48, y, w, 4, 2), with: .color(cream)) }
    }

    // A picture on paper, and a crayon.
    private static let crayonDrawing: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 92, width: 60)
        ctx.fill(box(16, 16, 56, 66, 5), with: .color(Color(light: "FBFAF6", dark: "D6D3CC")))
        ctx.stroke(box(16, 16, 56, 66, 5), with: .color(creamDark), lineWidth: 1.5)
        ctx.fill(circle(34, 34, 7), with: .color(amber))
        var hills = Path()
        hills.move(to: CGPoint(x: 22, y: 66))
        hills.addQuadCurve(to: CGPoint(x: 44, y: 60), control: CGPoint(x: 32, y: 50))
        hills.addQuadCurve(to: CGPoint(x: 66, y: 62), control: CGPoint(x: 56, y: 48))
        ctx.stroke(hills, with: .color(leaf), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        ctx.fill(poly([(56, 86), (86, 56), (78, 48), (48, 78)]), with: .color(red))
        ctx.fill(poly([(48, 78), (56, 86), (43, 91)]), with: .color(redDark))
        ctx.fill(poly([(62, 80), (65, 77), (57, 69), (54, 72)]), with: .color(cream))
    }

    // A guitar.
    private static let guitar: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 93, width: 46)
        let body = circle(50, 72, 20).union(circle(50, 50, 14))
        ctx.fill(body, with: .color(amber))
        fillRight(&ctx, body, from: 50, amberDark)
        ctx.fill(circle(50, 62, 6.5), with: .color(patchInk))
        ctx.fill(box(47, 10, 6, 46, 2), with: .color(earthDark))
        ctx.fill(box(44, 4, 12, 11, 3), with: .color(patchInk))
        ctx.fill(box(41, 78, 18, 4.5, 2), with: .color(patchInk))
        stroke(&ctx, [(49, 12), (49, 79)], cream, 0.9)
        stroke(&ctx, [(51, 12), (51, 79)], cream, 0.9)
    }

    // Piano keys.
    private static let pianoKeys: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 82, width: 82)
        // In Dark the case is a mid slate, so the keys and their black
        // keys stay apart from it and from each other.
        ctx.fill(box(8, 30, 84, 48, 7), with: .color(Color(light: "1F2933", dark: "5A6573")))
        for i in 0..<7 { ctx.fill(box(13 + Double(i) * 10.8, 38, 9.6, 34, 2), with: .color(Color(light: "FBFAF6", dark: "E4E0D8"))) }
        for i in [0, 1, 3, 4, 5] { ctx.fill(box(19.5 + Double(i) * 10.8, 38, 6.4, 20, 1.5), with: .color(patchInk)) }
    }

    // A written page, and a pen.
    private static let writingPage: Drawing = { ctx in
        shadow(&ctx, x: 48, y: 92, width: 54)
        ctx.fill(box(18, 14, 52, 68, 5), with: .color(Color(light: "FBFAF6", dark: "D6D3CC")))
        ctx.stroke(box(18, 14, 52, 68, 5), with: .color(creamDark), lineWidth: 1.5)
        for (y, w) in [(28.0, 36.0), (38.0, 36.0), (48.0, 28.0), (58.0, 32.0)] {
            ctx.fill(box(26, y, w, 3.5, 1.75), with: .color(Color(light: "C9B79C", dark: "9C8D76")))
        }
        ctx.fill(poly([(56, 86), (86, 56), (80, 50), (50, 80)]), with: .color(sky))
        ctx.fill(poly([(80, 50), (86, 56), (90, 52), (84, 46)]), with: .color(skyDark))
        ctx.fill(poly([(50, 80), (56, 86), (45, 91)]), with: .color(ink))
    }

    // A spray bottle, and sparkles.
    private static let sprayBottle: Drawing = { ctx in
        shadow(&ctx, x: 54, y: 90, width: 44)
        ctx.fill(box(36, 44, 34, 44, 9), with: .color(sky))
        fillRight(&ctx, box(36, 44, 34, 44, 9), from: 56, skyDark)
        ctx.fill(box(45, 34, 16, 12, 3), with: .color(skyDark))
        ctx.fill(box(38, 22, 32, 13, 4), with: .color(ink))
        ctx.fill(box(24, 24, 17, 7, 3), with: .color(ink))
        ctx.fill(poly([(47, 35), (53, 35), (49, 47), (44, 45)]), with: .color(ink))
        ctx.fill(box(41, 58, 24, 16, 3), with: .color(skyPale))
        sparkle(&ctx, 16, 44, 7, amber)
        sparkle(&ctx, 22, 60, 4.5, amber)
        sparkle(&ctx, 12, 30, 3.5, amberDark)
    }

    // A cooking pot with its lid on and steam rising: dinner on the way.
    private static let cookingPot: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 89, width: 64)
        for x in [36.0, 50.0, 64.0] {
            var steam = Path()
            steam.move(to: CGPoint(x: x, y: 34))
            steam.addCurve(to: CGPoint(x: x, y: 12), control1: CGPoint(x: x - 6, y: 27), control2: CGPoint(x: x + 6, y: 19))
            ctx.stroke(steam, with: .color(creamDark), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        ctx.fill(box(10, 50, 12, 7, 3.5), with: .color(redDark))
        ctx.fill(box(78, 50, 12, 7, 3.5), with: .color(redDark))
        ctx.fill(box(18, 46, 64, 40, 10), with: .color(red))
        fillRight(&ctx, box(18, 46, 64, 40, 10), from: 60, redDark)
        ctx.fill(box(15, 40, 70, 9, 4.5), with: .color(slateLight))
        ctx.fill(box(43, 33, 14, 8, 4), with: .color(ink))
        ctx.fill(box(18, 60, 64, 4, 0), with: .color(Color.white.opacity(0.25)))
    }

    // MARK: People and the dog

    private static let skin = Color(light: "E8B48A", dark: "CC9C77")
    private static let hair = Color(light: "5A3A22", dark: "7A5638")

    private static func limb(_ ctx: inout GraphicsContext, _ points: [(CGFloat, CGFloat)], _ color: Color, _ width: CGFloat) {
        var p = Path()
        p.move(to: CGPoint(x: points[0].0, y: points[0].1))
        if points.count == 3 {
            p.addQuadCurve(to: CGPoint(x: points[2].0, y: points[2].1), control: CGPoint(x: points[1].0, y: points[1].1))
        } else {
            for pt in points.dropFirst() { p.addLine(to: CGPoint(x: pt.0, y: pt.1)) }
        }
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private static func head(_ ctx: inout GraphicsContext, _ x: CGFloat, _ y: CGFloat) {
        ctx.fill(circle(x, y, 8), with: .color(skin))
        ctx.fill(circle(x, y, 8).intersection(Path(CGRect(x: x - 9, y: y - 9, width: 18, height: 7))), with: .color(hair))
    }

    // Someone in a side stretch on a mat, arms over their head.
    private static let stretcher: Drawing = { ctx in
        ctx.fill(box(14, 82, 72, 7, 3.5), with: .color(leaf))
        ctx.fill(box(14, 86, 72, 3, 1.5), with: .color(shade))
        limb(&ctx, [(48, 58), (40, 82)], slate, 7)
        limb(&ctx, [(52, 58), (60, 82)], slate, 7)
        limb(&ctx, [(50, 60), (54, 38)], sky, 13)
        limb(&ctx, [(53, 40), (46, 16), (70, 14)], skin, 5)
        limb(&ctx, [(56, 40), (56, 22), (72, 18)], skin, 5)
        head(&ctx, 60, 30)
    }

    // Someone mid-jump with a skipping rope going under their feet.
    private static let ropeJumper: Drawing = { ctx in
        ctx.fill(Path(ellipseIn: CGRect(x: 34, y: 88, width: 32, height: 5)), with: .color(.black.opacity(0.15)))
        var rope = Path()
        rope.move(to: CGPoint(x: 26, y: 54))
        rope.addCurve(to: CGPoint(x: 74, y: 54), control1: CGPoint(x: 22, y: 100), control2: CGPoint(x: 78, y: 100))
        ctx.stroke(rope, with: .color(red), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        limb(&ctx, [(47, 58), (40, 66), (44, 76)], slate, 7)
        limb(&ctx, [(53, 58), (60, 66), (56, 76)], slate, 7)
        limb(&ctx, [(50, 34), (50, 58)], red, 13)
        limb(&ctx, [(46, 38), (34, 46), (28, 54)], skin, 5)
        limb(&ctx, [(54, 38), (66, 46), (72, 54)], skin, 5)
        ctx.fill(box(23, 50, 7, 11, 3), with: .color(amber))
        ctx.fill(box(70, 50, 7, 11, 3), with: .color(amber))
        head(&ctx, 50, 24)
    }

    // The dog's own colours: a warm tan that stays clear in Dark (the soil's
    // brown went muddy there), and a nose and eye that stay dark.
    private static let fur = Color(light: "9A6238", dark: "C08A5E")
    private static let furDark = Color(light: "7A4A28", dark: "9A6A44")
    private static let nose = Color(light: "1F2933", dark: "1A1D21")

    // A dog out for a walk, its lead going up to a hand out of sight.
    private static let dogOnLead: Drawing = { ctx in
        shadow(&ctx, x: 54, y: 86, width: 60)
        var lead = Path()
        lead.move(to: CGPoint(x: 70, y: 46))
        lead.addQuadCurve(to: CGPoint(x: 92, y: 10), control: CGPoint(x: 90, y: 34))
        ctx.stroke(lead, with: .color(red), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        limb(&ctx, [(26, 50), (16, 38)], fur, 5)
        for x in [30.0, 38.0, 58.0, 66.0] { ctx.fill(box(x, 60, 7, 24, 3.5), with: .color(x == 38 || x == 66 ? furDark : fur)) }
        ctx.fill(box(24, 44, 50, 22, 11), with: .color(fur))
        ctx.fill(circle(74, 38, 12), with: .color(fur))
        ctx.fill(Path(ellipseIn: CGRect(x: 80, y: 38, width: 14, height: 9)), with: .color(fur))
        ctx.fill(circle(92, 41, 2.8), with: .color(nose))
        ctx.fill(circle(76, 34, 2), with: .color(nose))
        ctx.fill(Path(ellipseIn: CGRect(x: 63, y: 30, width: 9, height: 18)), with: .color(furDark))
        ctx.fill(box(63, 44, 14, 4, 2), with: .color(red))
    }

    // MARK: The kinds of habit

    // A dumbbell: lifting weights at the gym.
    private static let dumbbell: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 82, width: 76)
        ctx.fill(box(30, 46, 40, 8, 4), with: .color(slateLight))
        for x in [10.0, 76.0] {
            ctx.fill(box(x, 30, 14, 40, 5), with: .color(ink))
        }
        for x in [22.0, 68.0] {
            ctx.fill(box(x, 36, 10, 28, 4), with: .color(slate))
        }
        ctx.fill(box(12, 33, 4, 12, 2), with: .color(Color.white.opacity(0.25)))
        ctx.fill(box(78, 33, 4, 12, 2), with: .color(Color.white.opacity(0.25)))
    }

    // A running shoe.
    private static let sneaker: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 84, width: 76)
        var shoe = Path()
        shoe.move(to: CGPoint(x: 12, y: 72))
        shoe.addLine(to: CGPoint(x: 14, y: 40))
        shoe.addQuadCurve(to: CGPoint(x: 34, y: 38), control: CGPoint(x: 24, y: 32))
        shoe.addQuadCurve(to: CGPoint(x: 58, y: 54), control: CGPoint(x: 42, y: 54))
        shoe.addQuadCurve(to: CGPoint(x: 88, y: 64), control: CGPoint(x: 84, y: 54))
        shoe.addLine(to: CGPoint(x: 88, y: 72))
        shoe.closeSubpath()
        ctx.fill(shoe, with: .color(sky))
        fillRight(&ctx, shoe, from: 62, skyDark)
        ctx.fill(box(10, 70, 80, 9, 4.5), with: .color(cream))
        for (x, y) in [(30.0, 46.0), (37.0, 50.0), (44.0, 53.0)] {
            ctx.fill(box(x, y, 6, 2.5, 1.25), with: .color(cream))
        }
    }

    // A heart.
    private static let heart: Drawing = { ctx in
        var h = Path()
        h.move(to: CGPoint(x: 50, y: 84))
        h.addCurve(to: CGPoint(x: 12, y: 38), control1: CGPoint(x: 30, y: 70), control2: CGPoint(x: 12, y: 56))
        h.addCurve(to: CGPoint(x: 50, y: 26), control1: CGPoint(x: 12, y: 18), control2: CGPoint(x: 42, y: 14))
        h.addCurve(to: CGPoint(x: 88, y: 38), control1: CGPoint(x: 58, y: 14), control2: CGPoint(x: 88, y: 18))
        h.addCurve(to: CGPoint(x: 50, y: 84), control1: CGPoint(x: 88, y: 56), control2: CGPoint(x: 70, y: 70))
        h.closeSubpath()
        ctx.fill(h, with: .color(red))
        fillRight(&ctx, h, from: 50, redDark)
        ctx.fill(Path(ellipseIn: CGRect(x: 22, y: 30, width: 12, height: 8)), with: .color(Color.white.opacity(0.35)))
    }

    // A paint palette with its colours.
    private static let paintPalette: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 86, width: 66)
        let board = Path(ellipseIn: CGRect(x: 10, y: 22, width: 80, height: 60)).subtracting(circle(66, 66, 8))
        ctx.fill(board, with: .color(earth))
        fillRight(&ctx, board, from: 58, earthDark)
        for (x, y, c) in [(30.0, 40.0, red), (46.0, 33.0, amber), (63.0, 37.0, sky), (26.0, 58.0, leaf)] {
            ctx.fill(circle(x, y, 6.5), with: .color(c))
        }
    }

    // A house.
    private static let house: Drawing = { ctx in
        shadow(&ctx, x: 50, y: 88, width: 72)
        ctx.fill(box(22, 44, 56, 42, 3), with: .color(cream))
        fillRight(&ctx, box(22, 44, 56, 42, 3), from: 54, creamDark)
        ctx.stroke(box(22, 44, 56, 42, 3), with: .color(giEdge), lineWidth: 1.6)
        ctx.fill(poly([(12, 48), (50, 16), (88, 48), (82, 52), (50, 26), (18, 52)]), with: .color(red))
        ctx.fill(poly([(50, 16), (88, 48), (82, 52), (50, 26)]), with: .color(redDark))
        ctx.fill(box(43, 62, 14, 24, 3), with: .color(earth))
        ctx.fill(box(28, 54, 11, 11, 2), with: .color(sky))
        ctx.fill(box(62, 54, 11, 11, 2), with: .color(skyDark))
    }
}


#if EVLIN_DEMO
extension HabitArt {
    static var allTitles: [String] { drawings.keys.sorted() }
}

/// Demo only (`-EvlinParentOpen artgallery`): every drawing in its ring on
/// the page, for checking them against the page colour.
struct HabitArtGallery: View {
    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 10) {
                // `-EvlinGalleryFrom n` starts at the nth drawing.
                ForEach(Array(HabitArt.allTitles.dropFirst(UserDefaults.standard.integer(forKey: "EvlinGalleryFrom"))), id: \.self) { t in
                    VStack(spacing: 2) {
                        ZStack {
                            Circle().stroke(GoalRingStyle.track, lineWidth: 6).padding(3)
                            HabitArt(title: t).frame(width: 52, height: 52)
                        }
                        .frame(width: 84, height: 84)
                        Text(t).font(.system(size: 9)).lineLimit(1).foregroundStyle(EColor.onSurface)
                    }
                }
            }
            .padding(10)
        }
        .background(EColor.surface.ignoresSafeArea())
    }
}
#endif

// MARK: - Picking a picture

extension HabitArt {
    /// Every drawing a parent can give a habit, one of each (the names kept
    /// for saved habits draw the same as these), in New habit's kinds'
    /// order. The leaf (`Goal.leafPicture`) goes before them in the picker.
    static let choices: [String] = [
        // Household
        "Clean the house", "Clean your room", "Walk the dog", "Feed the pet", "Help with dinner",
        "Set the table", "Help with the laundry", "Water the plants", "Take out the trash", "Ready for school",
        // Hygiene & wellness
        "Floss daily", "Take a shower or bath", "Take daily vitamins", "Brush your teeth", "kind.wellness",
        // Fitness & activity
        "Play outside", "Skip rope", "Play football", "Karate", "Jiu-jitsu", "Ride a bike", "Swimming",
        "Play basketball", "Yoga", "kind.active",
        // Learning
        "Read for 20 minutes", "Do your homework", "Writing", "Play chess", "Practice Spanish",
        "Practice Mandarin", "Practice your family's language",
        // Creativity & arts
        "Drawing", "Practice guitar", "Practice piano", "kind.creative", "kind.household",
    ]

    /// The drawing that fits a typed habit's words, if one does ("Swim
    /// club" gets the swimmer): words are matched from their start, so
    /// "art" doesn't find "start". First match wins, so the more specific
    /// come first.
    static func suggest(for typed: String) -> String? {
        let words = typed.lowercased().split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty else { return nil }
        for (keys, picture) in suggestions where keys.contains(where: { key in
            key.contains(" ") ? typed.lowercased().contains(key) : words.contains { $0.hasPrefix(key) }
        }) { return picture }
        return nil
    }

    private static let suggestions: [(keys: [String], picture: String)] = [
        (["school", "backpack", "ready"], "Ready for school"),
        (["teeth", "tooth", "toothbrush"], "Brush your teeth"),
        (["floss"], "Floss daily"),
        (["shower", "bath", "wash"], "Take a shower or bath"),
        (["vitamin", "medicine", "pill"], "Take daily vitamins"),
        (["swim", "pool"], "Swimming"),
        (["bike", "bicycle", "cycling", "scooter"], "Ride a bike"),
        (["basketball", "hoop"], "Play basketball"),
        (["football", "soccer"], "Play football"),
        (["karate", "taekwondo", "kick", "martial"], "Karate"),
        (["jiu", "judo", "bjj", "wrestl"], "Jiu-jitsu"),
        (["yoga", "stretch"], "Yoga"),
        (["skip", "jump rope"], "Skip rope"),
        (["outside", "outdoor", "park", "climb"], "Play outside"),
        (["gym", "exercise", "workout", "run", "jog", "sport", "push", "sit up"], "kind.active"),
        (["chess"], "Play chess"),
        (["spanish"], "Practice Spanish"),
        (["mandarin", "chinese"], "Practice Mandarin"),
        (["language", "french", "german", "italian", "japanese", "korean", "arabic"], "Practice your family's language"),
        (["homework", "study", "math", "maths", "spelling"], "Do your homework"),
        (["read", "book", "library"], "Read for 20 minutes"),
        (["writ", "journal", "diary", "letter", "story"], "Writing"),
        (["guitar", "ukulele"], "Practice guitar"),
        (["piano", "keyboard"], "Practice piano"),
        (["draw", "sketch", "colour", "color"], "Drawing"),
        (["paint", "art", "craft", "music", "sing", "dance"], "kind.creative"),
        (["dog", "puppy"], "Walk the dog"),
        (["pet", "cat", "fish", "hamster", "rabbit", "feed"], "Feed the pet"),
        (["laundry", "clothes", "fold", "sock"], "Help with the laundry"),
        (["cook", "bake", "dinner", "lunch", "breakfast", "kitchen", "meal"], "Help with dinner"),
        (["table", "dishes", "dishwasher"], "Set the table"),
        (["plant", "garden", "flower"], "Water the plants"),
        (["trash", "rubbish", "garbage", "bin", "recycl"], "Take out the trash"),
        (["bed", "room", "toys"], "Clean your room"),
        (["clean", "tidy", "vacuum", "hoover", "dust", "sweep", "mop"], "Clean the house"),
        (["kind", "thank", "help", "share", "hug", "calm", "sleep", "breath"], "kind.wellness"),
    ]
}

/// New habit's picture picker (2026-11-17, the user's call): tapping the
/// ring shows every drawing, the leaf first; a tap picks one and closes.
struct HabitPicturePicker: View {
    /// The picture showing now (`Goal.leafPicture` for the leaf).
    var current: String?
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Pick a picture")
                    .font(Typography.font(22, weight: .heavy))
                    .foregroundStyle(Neutral.ink)
                    .padding(.top, 24)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 14) {
                    ForEach([Goal.leafPicture] + HabitArt.choices, id: \.self) { p in
                        let on = p == (current ?? Goal.leafPicture)
                        Button {
                            onPick(p)
                            dismiss()
                        } label: {
                            ZStack {
                                Circle().stroke(on ? StatusCardStyle.green : GoalRingStyle.track, lineWidth: on ? 4 : 3)
                                    .padding(2)
                                if p == Goal.leafPicture {
                                    HabitLeaf().frame(width: 40, height: 40)
                                } else {
                                    HabitArt(title: p).frame(width: 46, height: 46)
                                }
                            }
                            .frame(width: 72, height: 72)
                            .frame(maxWidth: .infinity)
                            .contentShape(Circle())
                        }
                        .buttonStyle(CardPressStyle())
                        .accessibilityLabel(p == Goal.leafPicture ? "Leaf" : p.hasPrefix("kind.") ? String(p.dropFirst(5)) : p)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .id(p)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        // Opens with the picture showing now in view.
        .onAppear { if let current, current != Goal.leafPicture { reader.scrollTo(current, anchor: .center) } }
        }
        .background(EColor.surface.ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: current)
    }
}
