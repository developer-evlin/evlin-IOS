import XCTest
@testable import Evlin

/// A typed habit's ring fills with the drawing its words suggest, else the
/// leaf (HabitArt.suggest).
final class HabitPictureSuggestTests: XCTestCase {
    func testWordsFindTheirDrawing() {
        XCTAssertEqual(HabitArt.suggest(for: "Swim club"), "Swimming")
        XCTAssertEqual(HabitArt.suggest(for: "Brush teeth before bed"), "Brush your teeth")
        XCTAssertEqual(HabitArt.suggest(for: "Read a story"), "Read for 20 minutes")
        XCTAssertEqual(HabitArt.suggest(for: "Practice violin"), nil)
        XCTAssertEqual(HabitArt.suggest(for: "Walk Max the dog"), "Walk the dog")
        XCTAssertEqual(HabitArt.suggest(for: "Tidy up toys"), "Clean your room")
        XCTAssertEqual(HabitArt.suggest(for: "Help cook dinner"), "Help with dinner")
    }

    func testOnlyWordStartsMatch() {
        XCTAssertNil(HabitArt.suggest(for: "Start early"))   // not "art"
        XCTAssertNil(HabitArt.suggest(for: ""))
    }

    func testEveryChoiceHasADrawing() {
        for c in HabitArt.choices { XCTAssertTrue(HabitArt.has(c), c) }
    }

    func testThePickedLeafIsTheLeaf() {
        var g = Goal(id: "g", childId: "c", title: "Piano", target: 7, unit: "days", prize: "")
        g.picture = Goal.leafPicture
        XCTAssertEqual(g.symbol, Goal.leafSymbol)
    }
}
