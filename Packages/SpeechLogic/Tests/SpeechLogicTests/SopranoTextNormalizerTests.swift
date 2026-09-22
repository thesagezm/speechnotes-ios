import XCTest
@testable import SpeechLogic

/// Pins the number/ordinal/currency/abbreviation expansion the Soprano
/// engine needs before its tokenizer (it has no phonemizer — raw digits read
/// digit-by-digit). These cases mirror the reference implementation's
/// documented behaviour; the point is that a regression is caught here, not
/// on device by ear.
final class SopranoTextNormalizerTests: XCTestCase {

    func testPlainTextPassesThrough() {
        XCTAssertEqual(SopranoTextNormalizer.normalize("Hello there, friend."), "Hello there, friend.")
    }

    func testIntegers() {
        XCTAssertEqual(SopranoTextNormalizer.normalize("I have 42 apples"), "I have forty two apples")
        XCTAssertEqual(SopranoTextNormalizer.normalize("0 items"), "zero items")
        XCTAssertEqual(SopranoTextNormalizer.normalize("15 left"), "fifteen left")
        XCTAssertEqual(SopranoTextNormalizer.normalize("100 done"), "one hundred done")
        XCTAssertEqual(SopranoTextNormalizer.normalize("1,250 rows"), "one thousand two hundred fifty rows")
    }

    func testDecimalsReadDigitWise() {
        XCTAssertEqual(SopranoTextNormalizer.normalize("pi is 3.14"), "pi is three point one four")
    }

    func testLeadingZeroRunsReadDigitWise() {
        // A code, not a number.
        XCTAssertEqual(SopranoTextNormalizer.normalize("agent 007 reports"), "agent zero zero seven reports")
    }

    func testCurrency() {
        XCTAssertEqual(SopranoTextNormalizer.normalize("costs $5 today"), "costs five dollars today")
        XCTAssertEqual(SopranoTextNormalizer.normalize("just $1"), "just one dollar")
        XCTAssertEqual(SopranoTextNormalizer.normalize("£3.50 please"), "three pounds fifty pence please")
        XCTAssertEqual(SopranoTextNormalizer.normalize("€10 flat"), "ten euros flat")
        XCTAssertEqual(SopranoTextNormalizer.normalize("$0 but $10 later"), "zero dollars but ten dollars later")
    }

    func testOrdinals() {
        let first = SopranoTextNormalizer.normalize("on the 1st of May")
        XCTAssertEqual(first, "on the first of May")
        let second = SopranoTextNormalizer.normalize("the 2nd item")
        XCTAssertEqual(second, "the second item")
        let third = SopranoTextNormalizer.normalize("the 3rd try")
        XCTAssertEqual(third, "the third try")
        let twentyThird = SopranoTextNormalizer.normalize("the 23rd floor")
        XCTAssertEqual(twentyThird, "the twenty third floor")
    }

    func testAbbreviations() {
        XCTAssertEqual(SopranoTextNormalizer.normalize("Dr. Smith said"), "Doctor Smith said")
        XCTAssertEqual(SopranoTextNormalizer.normalize("e.g. this"), "for example this")
        XCTAssertEqual(SopranoTextNormalizer.normalize("cats, dogs, etc. here"), "cats, dogs, et cetera. here")
    }

    func testIdempotent() {
        let once = SopranoTextNormalizer.normalize("42 items at $5, or 3.14 for the 1st")
        let twice = SopranoTextNormalizer.normalize(once)
        XCTAssertEqual(once, twice, "normalising twice must not change the result")
    }

    func testNumbersInSentenceWithSurroundingText() {
        // Text around a number must survive untouched.
        let out = SopranoTextNormalizer.normalize("Room 42 is on floor 3 (see map).")
        XCTAssertTrue(out.hasPrefix("Room forty two is"))
        XCTAssertTrue(out.contains("floor three"))
        XCTAssertTrue(out.contains("(see map)."))
    }

    func testMultipleNumbersInOneString() {
        XCTAssertEqual(
            SopranoTextNormalizer.normalize("1 cat, 2 dogs, 11 birds"),
            "one cat, two dogs, eleven birds"
        )
    }
}
