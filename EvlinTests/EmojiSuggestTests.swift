import XCTest
@testable import Evlin

/// A typed task's emoji, guessed on the phone from Unicode's own emoji names
/// and keywords (EmojiSuggest). Common chores have to land on the obvious
/// one; anything unrecognisable gets the star.
final class EmojiSuggestTests: XCTestCase {

    private func best(_ title: String) -> String {
        // Compare without the variation selector some emoji need to show.
        EmojiSuggest.best(for: title).replacingOccurrences(of: "\u{FE0F}", with: "")
    }

    func testCommonChores() {
        XCTAssertEqual(best("Make the bed"), "🛏")
        XCTAssertEqual(best("Brush teeth"), "🪥")
        XCTAssertEqual(best("Unload the dishwasher"), "🍽")
        XCTAssertEqual(best("Do the laundry"), "🧺")
        XCTAssertEqual(best("Take out the trash"), "🗑")
        XCTAssertEqual(best("Violin practice"), "🎻")
        XCTAssertEqual(best("Water the plants"), "🪴")
        XCTAssertTrue(["🐟", "🐠"].contains(best("Feed the fish")))
    }

    func testNothingRecognisableGetsTheStar() {
        XCTAssertEqual(best("Xyzzy qwerty"), EmojiSuggest.fallback)
    }

    func testAlternativesAreDistinct() {
        let options = EmojiSuggest.suggestions(for: "Walk the dog")
        XCTAssertEqual(Set(options).count, options.count)
        XCTAssertGreaterThan(options.count, 1)
    }
}
