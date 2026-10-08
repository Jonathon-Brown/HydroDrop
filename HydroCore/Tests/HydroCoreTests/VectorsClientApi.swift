import Foundation
@testable import HydroCore

// Stage A's client vectors: KV15, error mapping (final design §6.0's last bullet, §6.7, D63).
// The fixture's KV15 has had no Swift function behind it until now, so these cases are what the
// Android classifier and this one are held to once the integration pass carries them into
// `duo-vectors-v1.json`. Each case's `in` is the whole response the classifier reads (status,
// `Content-Type`, `Retry-After` and the body as text; no request id, which decides nothing),
// and `expect` is the code it maps to (null for an answer with no code), the delay it carries
// and what `DuoRetry.verdict` then does. `spec` is the answer the design states: the four cases
// of AND §15's KV15 row (a JSON `banned` is the banned copy, an HTML 403 maintenance, an HTML
// 429 with `Retry-After: 30` a 30-second rate limit, a JSON `duo_unknown` on a cached duo ends
// it locally), §6.0's status table for the rest, D63 for a 401 that is not the envelope, and
// the review's rule that the five codes which change standing or end a duo are believed only at
// their own status (2026-10-07).
extension Vectors {
    static func apiCases() -> [Vector] {
        let html = "text/html; charset=UTF-8"
        let json = "application/json"
        let waf = "<!DOCTYPE html><html><head><title>Attention Required! | Cloudflare</title></head><body>Sorry, you have been blocked</body></html>"
        func envelope(_ code: String, retryAfterS: Int? = nil) -> String {
            let delay = retryAfterS.map { #","retry_after_s":\#($0)"# } ?? ""
            return #"{"error":{"code":"\#(code)","message":"m"\#(delay),"request_id":"9b1c2d3e4f5a6b7c-LHR"}}"#
        }
        // (id, status, Content-Type, Retry-After, body, stated code, stated delay, stated verdict)
        let rows: [(String, Int, String?, String?, String, String?, Int?, String)] = [
            ("jsonBanned", 403, json, nil, envelope("banned"), "banned", nil, "banned"),
            ("htmlForbidden", 403, html, nil, waf, "maintenance", nil, "retry:60"),
            ("html429", 429, html, "30", waf, "rate_limited", 30, "retry:30"),
            ("html429NoRetryAfter", 429, html, nil, waf, "rate_limited", 60, "retry:60"),
            ("jsonDuoUnknown", 404, json, nil, envelope("duo_unknown"), "duo_unknown", nil, "ended"),
            // D63: a 401 that is not the envelope is a captive portal or a proxy, never a gone
            // identity, so nothing is forgotten and nothing ends.
            ("html401", 401, html, nil, "<html><body>Please log in to the Wi-Fi</body></html>", "maintenance", nil, "retry:60"),
            // And the other half of D63: the server's own 401 still means the identity is gone (§3.4).
            ("json401", 401, json, nil, envelope("unauthenticated"), "unauthenticated", nil, "reidentify"),
            ("html413", 413, html, nil, "<html><body>413 Request Entity Too Large</body></html>", "schema", nil, "fail"),
            ("html502", 502, html, nil, "<html><body>502 Bad Gateway</body></html>", "maintenance", nil, "retry:60"),
            // A code from a newer server, on a status that is not a 5xx: unreadable, not acted on.
            ("jsonUnknownCode409", 409, json, nil, envelope("duo_frozen"), nil, nil, "fail"),
            // But a 429 is a rate limit whatever its code, a minute when it says nothing.
            ("jsonUnknownCode429", 429, json, nil, envelope("slow_down"), "rate_limited", 60, "retry:60"),
            // The header beats the body's `retry_after_s`, and the delay is honoured as given.
            ("jsonRateLimited", 429, json, "120", envelope("rate_limited", retryAfterS: 90), "rate_limited", 120, "retry:120"),
            // The five codes that change standing or end a duo are believed only at the one status
            // the contract gives each; elsewhere the status alone decides.
            ("jsonBannedAt500", 500, json, nil, envelope("banned"), "maintenance", nil, "retry:60"),
            ("jsonUnauthenticatedAt403", 403, json, nil, envelope("unauthenticated"), "maintenance", nil, "retry:60"),
            ("jsonDeviceRevokedAt503", 503, json, nil, envelope("device_revoked"), "maintenance", nil, "retry:60"),
            ("jsonDuoUnknownAt409", 409, json, nil, envelope("duo_unknown"), nil, nil, "fail"),
            ("jsonDuoEndedAt404", 404, json, nil, envelope("duo_ended"), nil, nil, "fail"),
        ]
        return rows.map { name, status, contentType, retryAfter, body, code, delay, verdict in
            let error = DuoErrorClassifier.classify(status: status, contentType: contentType, retryAfter: retryAfter, requestID: nil,
                                                   body: Data(body.utf8))
            let input: JSON = ["status": .int(status), "contentType": contentType.map { JSON.string($0) } ?? .null,
                               "retryAfter": retryAfter.map { JSON.string($0) } ?? .null, "body": .string(body)]
            return Vector(id: "KV15.\(name)", fn: "DuoErrorClassifier.classify", input: input,
                          expect: ["code": error.code.map { JSON.string($0.rawValue) } ?? .null,
                                   "retryAfter": error.context?.retryAfter.map { JSON.int($0) } ?? .null,
                                   "verdict": .string(apiVerdictName(DuoRetry.verdict(for: error)))],
                          spec: ["code": code.map { JSON.string($0) } ?? .null, "retryAfter": delay.map { JSON.int($0) } ?? .null,
                                 "verdict": .string(verdict)])
        }
    }

    /// A verdict as a port can spell it: its case name, and a retry's delay in whole seconds.
    /// Named for this stage, since `Vectors` is shared by every stage's provider.
    static func apiVerdictName(_ verdict: DuoRetry.Verdict) -> String {
        switch verdict {
        case .ended: return "ended"
        case .retry(let after): return "retry:\(Int(after))"
        case .cancelled: return "cancelled"
        case .reidentify: return "reidentify"
        case .disconnected: return "disconnected"
        case .upgradeRequired: return "upgradeRequired"
        case .termsRequired: return "termsRequired"
        case .banned: return "banned"
        case .fail: return "fail"
        }
    }
}
