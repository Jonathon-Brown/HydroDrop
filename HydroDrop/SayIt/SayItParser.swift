import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Reads a sentence and reports the drinks in it, as words.
///
/// A protocol so the sheet does not care where the answer comes from, and so the
/// on-device model, which needs iOS 26 and Apple Intelligence, is not the only way to
/// see the sheet work.
@MainActor
protocol SayItParsing: AnyObject {
    /// Called once when the sheet opens, so the first answer is not the slow one.
    func prewarm()
    func parse(_ text: String) async throws -> [SpokenDrink]
}

/// Why a sentence produced no drinks. Every case ends as one friendly line on the
/// sheet, never as an alert and never as a crash.
enum SayItError: Error {
    /// The model declined to answer, which its safety guardrails can do for any text.
    case declined
    /// The model could not be reached or did not produce anything usable.
    case failed
}

/// Whether Say it exists on this device, and the thing that does the reading if so.
@MainActor
enum SayIt {
    /// Longer than anyone's description of a day's drinks, and short enough that the
    /// model's context window is never the thing that fails.
    static let maximumInputLength = 400

    /// True only when the on-device model can answer right now.
    ///
    /// An old OS, an unsupported device, Apple Intelligence switched off and a model
    /// that is still downloading all read the same way here: false. The feature then
    /// simply is not there, which is kinder than a button that explains why it cannot
    /// work.
    static var isAvailable: Bool {
        #if DEBUG
        if usesStubParser { return true }
        #endif
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// A fresh parser for one presentation of the sheet, or nil when there is no model.
    static func makeParser() -> (any SayItParsing)? {
        #if DEBUG
        if usesStubParser { return StubSayItParser() }
        #endif
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available {
            return OnDeviceSayItParser()
        }
        #endif
        return nil
    }

    #if DEBUG
    /// Lets the sheet be seen and screenshotted on a simulator with no language model.
    /// Compiled out of Release, like the other launch-argument hooks.
    private static var usesStubParser: Bool {
        ProcessInfo.processInfo.arguments.contains("-SayItStubParser")
    }
    #endif
}

#if canImport(FoundationModels)

/// What the model is asked to fill in. Words and numbers as said, nothing derived.
@available(iOS 26.0, *)
@Generable(description: "The drinks a person says they had")
struct GeneratedDrinkList {
    @Guide(description: "One item for each kind of drink mentioned, in the order mentioned", .maximumCount(10))
    var drinks: [GeneratedDrink]
}

@available(iOS 26.0, *)
@Generable(description: "One kind of drink the person mentioned")
struct GeneratedDrink {
    @Guide(description: "Which drink it is. Use unknown if it is not on the list.", .anyOf(SayItMapper.kindVocabulary))
    var kind: String

    @Guide(description: "How many of this drink the person had", .range(1...12))
    var quantity: Int

    @Guide(description: "The size word the person used for one drink, or none if they used no size word", .anyOf(SayItMapper.sizeVocabulary))
    var sizeWord: String

    @Guide(description: "The number in an amount stated for one drink, such as 12 in 12 oz. Leave it out if no amount was stated.")
    var amount: Double?

    @Guide(description: "The unit of that stated amount, or none if no amount was stated", .anyOf(SayItMapper.unitVocabulary))
    var unit: String
}

/// The real thing: Apple's on-device model, with guided generation.
@available(iOS 26.0, *)
@MainActor
final class OnDeviceSayItParser: SayItParsing {
    /// Short on purpose. Every word here is paid for again on every request.
    private static let instructions = """
        List the drinks in what the person says they drank. If they state an amount, \
        like 12 oz or 500 mL, put the number in amount and its unit in unit. Copy size \
        words and amounts exactly as said. Never convert units and never do arithmetic.
        """

    private var session = LanguageModelSession(instructions: OnDeviceSayItParser.instructions)

    func prewarm() {
        session.prewarm()
    }

    func parse(_ text: String) async throws -> [SpokenDrink] {
        let prompt = String(text.prefix(SayIt.maximumInputLength))
        do {
            return try await respond(to: prompt)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // A session remembers every exchange, so enough retries in one sheet can
            // fill it. Start a clean one and ask once more rather than giving up.
            session = LanguageModelSession(instructions: Self.instructions)
            do {
                return try await respond(to: prompt)
            } catch {
                throw SayItError.failed
            }
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            throw SayItError.declined
        } catch {
            Diagnostics.log("Say it could not read a sentence: \(error)")
            throw SayItError.failed
        }
    }

    private func respond(to prompt: String) async throws -> [SpokenDrink] {
        let response = try await session.respond(to: prompt, generating: GeneratedDrinkList.self)
        return response.content.drinks.map { drink in
            SpokenDrink(
                kind: drink.kind,
                quantity: drink.quantity,
                sizeWord: drink.sizeWord,
                amount: drink.amount,
                unit: drink.unit
            )
        }
    }
}

#endif

#if DEBUG
/// Stands in for the model where there is none. Knows one sentence's worth of answer,
/// plus the two edge cases the sheet has to handle, so each can be looked at.
@MainActor
final class StubSayItParser: SayItParsing {
    func prewarm() {}

    func parse(_ text: String) async throws -> [SpokenDrink] {
        try? await Task.sleep(for: .milliseconds(400))
        let lowered = text.lowercased()
        if lowered.contains("nothing") { return [] }
        var drinks = [
            SpokenDrink(kind: "coffee", quantity: 1, sizeWord: "large"),
            SpokenDrink(kind: "water", quantity: 2, sizeWord: "glass"),
        ]
        if lowered.contains("kombucha") {
            drinks.append(SpokenDrink(kind: "unknown", quantity: 1, sizeWord: "none", amount: 12, unit: "oz"))
        }
        return drinks
    }
}
#endif
