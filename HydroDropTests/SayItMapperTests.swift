import XCTest
@testable import HydroDrop

/// Every number Say it logs is worked out by `SayItMapper`, never by the language
/// model, so this is where "two glasses of water" has to be right.
final class SayItMapperTests: XCTestCase {
    private let defaultML = 237

    private func drafts(_ drinks: SpokenDrink...) -> [SayItDraft] {
        SayItMapper.drafts(from: drinks, defaultML: defaultML)
    }

    // MARK: - Size words

    func testEverySizeWordMeansWhatTheTableSays() {
        let expected: [String: Int] = [
            "small": 200, "medium": 350, "large": 500, "glass": 250, "cup": 240, "mug": 350,
            "bottle": 500, "can": 355, "pint": 473, "shot": 45, "sip": 30,
        ]
        XCTAssertEqual(Set(expected.keys), Set(SayItMapper.SizeWord.allCases.map(\.rawValue)))
        for (word, mL) in expected {
            XCTAssertEqual(SayItMapper.volumeML(forSizeWord: word), mL, word)
        }
    }

    func testSizeWordsAreReadWhateverTheirCasingOrSpacing() {
        XCTAssertEqual(SayItMapper.volumeML(forSizeWord: " Large "), 500)
        XCTAssertEqual(SayItMapper.volumeML(forSizeWord: "MUG"), 350)
    }

    func testNoneAndNonsenseAreNotSizes() {
        XCTAssertNil(SayItMapper.volumeML(forSizeWord: "none"))
        XCTAssertNil(SayItMapper.volumeML(forSizeWord: "bucket"))
        XCTAssertNil(SayItMapper.volumeML(forSizeWord: ""))
    }

    // MARK: - Units

    func testFluidOunces() {
        XCTAssertEqual(SayItMapper.milliliters(amount: 12, unit: "oz"), 355)
        XCTAssertEqual(SayItMapper.milliliters(amount: 16, unit: "ounces"), 473)
        XCTAssertEqual(SayItMapper.milliliters(amount: 8, unit: "fl oz"), 237)
    }

    func testMillilitres() {
        XCTAssertEqual(SayItMapper.milliliters(amount: 330, unit: "mL"), 330)
        XCTAssertEqual(SayItMapper.milliliters(amount: 330, unit: "ml"), 330)
        XCTAssertEqual(SayItMapper.milliliters(amount: 250.4, unit: "millilitres"), 250)
    }

    func testLitres() {
        XCTAssertEqual(SayItMapper.milliliters(amount: 1, unit: "L"), 1_000)
        XCTAssertEqual(SayItMapper.milliliters(amount: 1.5, unit: "liters"), 1_500)
        XCTAssertEqual(SayItMapper.milliliters(amount: 0.5, unit: "litre"), 500)
    }

    func testCups() {
        XCTAssertEqual(SayItMapper.milliliters(amount: 1, unit: "cup"), 240)
        XCTAssertEqual(SayItMapper.milliliters(amount: 2, unit: "cups"), 480)
        XCTAssertEqual(SayItMapper.milliliters(amount: 0.5, unit: "cups"), 120)
    }

    func testAnAmountWithNoUsableUnitOrNumberIsNotConverted() {
        XCTAssertNil(SayItMapper.milliliters(amount: 12, unit: "none"))
        XCTAssertNil(SayItMapper.milliliters(amount: 12, unit: "gallons"))
        XCTAssertNil(SayItMapper.milliliters(amount: 0, unit: "oz"))
        XCTAssertNil(SayItMapper.milliliters(amount: -3, unit: "oz"))
        XCTAssertNil(SayItMapper.milliliters(amount: .nan, unit: "oz"))
        XCTAssertNil(SayItMapper.milliliters(amount: .infinity, unit: "mL"))
    }

    // MARK: - The sentence in the brief

    /// "Large iced coffee and two glasses of water."
    func testALargeCoffeeAndTwoGlassesOfWater() {
        let result = drafts(
            SpokenDrink(kind: "coffee", quantity: 1, sizeWord: "large"),
            SpokenDrink(kind: "water", quantity: 2, sizeWord: "glass")
        )
        XCTAssertEqual(result.map(\.drinkType), [.coffee, .water, .water])
        XCTAssertEqual(result.map(\.amountML), [500, 250, 250])
        XCTAssertTrue(result.allSatisfy { !$0.needsReview })
    }

    // MARK: - Quantity

    func testTwoGlassesBecomeTwoEntries() {
        let result = drafts(SpokenDrink(kind: "water", quantity: 2, sizeWord: "glass"))
        XCTAssertEqual(result.count, 2)
        XCTAssertNotEqual(result[0].id, result[1].id, "each row has to be its own row")
    }

    /// A stated amount is for one drink: "two 12 oz cans" is two cans of 12 oz, not 12 oz
    /// shared between them, and not 24 oz each.
    func testAStatedAmountAppliesToEachDrink() {
        let result = drafts(SpokenDrink(kind: "sparkling", quantity: 2, sizeWord: "can", amount: 12, unit: "oz"))
        XCTAssertEqual(result.map(\.amountML), [355, 355])
    }

    func testAQuantityBelowOneIsStillOneDrink() {
        XCTAssertEqual(drafts(SpokenDrink(kind: "water", quantity: 0, sizeWord: "glass")).count, 1)
        XCTAssertEqual(drafts(SpokenDrink(kind: "water", quantity: -4, sizeWord: "glass")).count, 1)
    }

    func testAnAbsurdQuantityIsCappedAndFlagged() {
        let result = drafts(SpokenDrink(kind: "water", quantity: 100, sizeWord: "glass"))
        XCTAssertEqual(result.count, SayItMapper.maximumQuantity)
        XCTAssertTrue(result.allSatisfy(\.needsReview))
    }

    func testOneSentenceNeverProducesMoreThanTheMaximumRows() {
        let many = (0..<5).map { _ in SpokenDrink(kind: "water", quantity: 12, sizeWord: "glass") }
        XCTAssertEqual(SayItMapper.drafts(from: many, defaultML: defaultML).count, SayItMapper.maximumDrafts)
    }

    // MARK: - Amounts

    func testAStatedAmountBeatsTheSizeWord() {
        let result = drafts(SpokenDrink(kind: "coffee", quantity: 1, sizeWord: "large", amount: 8, unit: "oz"))
        XCTAssertEqual(result.first?.amountML, 237)
        XCTAssertEqual(result.first?.needsReview, false)
    }

    /// "A water" with no size means the person's own usual glass, and is not a guess
    /// worth flagging.
    func testNoSizeAtAllMeansTheirFirstQuickAdd() {
        let result = drafts(SpokenDrink(kind: "water", quantity: 1, sizeWord: "none"))
        XCTAssertEqual(result.first?.amountML, defaultML)
        XCTAssertEqual(result.first?.needsReview, false)
    }

    func testAnUnrecognisedSizeWordFallsBackAndAsks() {
        let result = drafts(SpokenDrink(kind: "water", quantity: 1, sizeWord: "bucket"))
        XCTAssertEqual(result.first?.amountML, defaultML)
        XCTAssertEqual(result.first?.needsReview, true)
    }

    func testANumberWithNoUnitFallsBackToTheSizeWordAndAsks() {
        let result = drafts(SpokenDrink(kind: "water", quantity: 1, sizeWord: "bottle", amount: 16, unit: "none"))
        XCTAssertEqual(result.first?.amountML, 500)
        XCTAssertEqual(result.first?.needsReview, true)
    }

    /// Seen from the real model: "a pint of beer" came back as size word pint plus an
    /// amount of 1 mL, the "a" read as a number. The size word is what was said.
    func testAnAmountTooSmallToBeRealFallsBackToTheSizeWordAndAsks() {
        let result = drafts(SpokenDrink(kind: "other", quantity: 1, sizeWord: "pint", amount: 1, unit: "mL"))
        XCTAssertEqual(result.first?.amountML, 473)
        XCTAssertEqual(result.first?.needsReview, true)
    }

    func testAOneOunceShotIsStillBelieved() {
        let result = drafts(SpokenDrink(kind: "coffee", quantity: 1, sizeWord: "shot", amount: 1, unit: "oz"))
        XCTAssertEqual(result.first?.amountML, 30)
        XCTAssertEqual(result.first?.needsReview, false)
    }

    func testAnImplausibleAmountIsPulledIntoRangeAndFlagged() {
        let result = drafts(SpokenDrink(kind: "water", quantity: 1, sizeWord: "none", amount: 40, unit: "L"))
        XCTAssertEqual(result.first?.amountML, MeasurementSystem.plausibleDrinkRangeML.upperBound)
        XCTAssertEqual(result.first?.needsReview, true)
    }

    // MARK: - Unknown drinks

    func testAnUnknownDrinkIsWaterAndIsFlagged() {
        let result = drafts(SpokenDrink(kind: "unknown", quantity: 1, sizeWord: "glass"))
        XCTAssertEqual(result.first?.drinkType, .water)
        XCTAssertEqual(result.first?.needsReview, true)
        XCTAssertEqual(result.first?.amountML, 250, "the size is still believed")
    }

    /// The model is constrained to the vocabulary, but its output is still input.
    func testADrinkThatIsNotEvenInTheVocabularyIsTreatedAsUnknown() {
        let result = drafts(SpokenDrink(kind: "kombucha", quantity: 1, sizeWord: "bottle"))
        XCTAssertEqual(result.first?.drinkType, .water)
        XCTAssertEqual(result.first?.needsReview, true)
    }

    func testEveryDrinkTypeTheAppHasIsUnderstood() {
        for type in DrinkType.allCases {
            let result = drafts(SpokenDrink(kind: type.rawValue, quantity: 1, sizeWord: "cup"))
            XCTAssertEqual(result.first?.drinkType, type)
            if type != .other {
                XCTAssertEqual(result.first?.needsReview, false, type.rawValue)
            }
        }
    }

    /// With "other" on its list the model never says "unknown": a pint of beer comes
    /// back as other. That is the same admission, so it has to be flagged the same way.
    func testOtherIsKeptButFlagged() {
        let result = drafts(SpokenDrink(kind: "other", quantity: 1, sizeWord: "pint"))
        XCTAssertEqual(result.first?.drinkType, .other)
        XCTAssertEqual(result.first?.amountML, 473)
        XCTAssertEqual(result.first?.needsReview, true)
    }

    func testTheVocabularyFollowsTheDrinkTypes() {
        XCTAssertEqual(SayItMapper.kindVocabulary, DrinkType.allCases.map(\.rawValue) + ["unknown"])
        XCTAssertEqual(SayItMapper.sizeVocabulary.last, "none")
        XCTAssertTrue(SayItMapper.unitVocabulary.contains("none"))
    }

    func testNothingHeardMeansNothingToConfirm() {
        XCTAssertTrue(SayItMapper.drafts(from: [], defaultML: defaultML).isEmpty)
    }

    // MARK: - Timestamps

    /// The store's launch dedupe pass collapses rows that match on timestamp, amount and
    /// type. Two identical glasses logged together must not look like that.
    func testDrinksLoggedTogetherNeverShareAnInstant() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stamps = SayItMapper.timestamps(count: 5, endingAt: now)

        XCTAssertEqual(stamps.count, 5)
        XCTAssertEqual(Set(stamps).count, 5, "no two drinks may share a timestamp")
        XCTAssertEqual(stamps.first, now)
        XCTAssertTrue(stamps.allSatisfy { $0 <= now }, "nothing is logged in the future")
        XCTAssertTrue(stamps.allSatisfy { now.timeIntervalSince($0) < 60 }, "all within the same minute or so")

        // The same key the dedupe pass builds, for two identical glasses of water.
        let keys = stamps.map { "\($0.timeIntervalSinceReferenceDate)|250|water" }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testNoDrinksNeedNoTimestamps() {
        XCTAssertTrue(SayItMapper.timestamps(count: 0, endingAt: Date()).isEmpty)
    }
}
