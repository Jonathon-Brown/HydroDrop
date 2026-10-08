@testable import HydroCore

// Owned by one stage of plan P2 and replaced whole by it; the foundation commits this empty
// provider so every stage compiles before any other lands. Add cases to `apiCases()`
// only: `Vectors.clientCases()` already includes it, and the file stays out of
// `duo-vectors-v1.json` until the integration pass flips `Vectors.includesClientVectors`.
extension Vectors {
    static func apiCases() -> [Vector] { [] }
}
