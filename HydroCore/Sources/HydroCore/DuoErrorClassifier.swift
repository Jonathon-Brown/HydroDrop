import Foundation

// The one place a failed Duo response becomes an error (final design §6.0's last bullet, §6.7,
// decision D63; vector KV15). The API client hands every non-2xx answer here and nothing above
// it ever looks at a status code or a body again, so the Android port and this one can be held
// to the same table by the KV15 vectors.
//
// The rule is to believe the server's own envelope and nothing else. A JSON body that carries
// `error.code` is the server speaking: its code decides, with the status, `Retry-After`, the
// request id and `details` kept as context. Anything else (an HTML page from Cloudflare's WAF, a
// captive portal, a proxy, an empty body) did not come from the Worker, so it is classified by
// its status alone and never as anything that changes who this phone is. That is why `banned`
// and `blocked` are only ever read from a JSON code: an HTML 403 is a WAF page, and reading it
// as `banned` would lock a person out for a firewall rule. A 401 is the same (D63, 2026-10-07):
// the design first read a bare 401 as `unauthenticated`, which forgets the identity and ends
// every live duo on the phone, an outcome nothing undoes, for what is in practice a hotel Wi-Fi
// page. The real server answers every 401 with its envelope, so a 401 without one is
// `maintenance`: wait and try again, losing nothing.
//
// Even the envelope is believed only where the server could have sent it, for the five codes
// that change who this phone is or end a duo: `unauthenticated` and `device_revoked` only at
// 401, `banned` only at 403, `duo_unknown` only at 404 and `duo_ended` only at 409, the one
// status contract-v1 gives each. The envelope is easy to copy, and a proxy or a misbehaving
// edge that wraps some other failure in it must not be able to forget the identity, bar the
// person or end a duo; at any other status the answer is read by its status alone. Every other
// code, which costs nothing irreversible, is taken at its word.

public enum DuoErrorClassifier {
    /// The largest delay believed, in whole seconds. The contract declares `retry_after_s` as a
    /// non-negative int32 and says `Retry-After` is the same number, so anything larger is not
    /// the server's and is read as no delay at all, which the retry rule then fills with its own
    /// fallback. (How long a believed delay is honoured is `DuoRetry`'s to cap, at two days; the
    /// ceiling here only says which numbers could have come from the server.)
    public static let maximumRetryAfter = Int(Int32.max)

    /// Turns a non-2xx response into the error it means.
    ///
    /// - Parameters:
    ///   - status: The HTTP status.
    ///   - contentType: The `Content-Type` header, if any.
    ///   - retryAfter: The `Retry-After` header, if any. Only whole seconds are read (§6.0);
    ///     an HTTP date, a negative number or anything else is ignored.
    ///   - requestID: The id the response's headers carry: `X-Request-Id`, or `CF-Ray` when it has
    ///     none (`headerRequestID(xRequestID:cfRay:)` picks it). The body's `request_id` is the
    ///     fallback when the headers have nothing usable.
    ///   - body: The response body, possibly empty.
    public static func classify(status: Int, contentType: String?, retryAfter: String?, requestID: String?, body: Data) -> DuoTransportError {
        let headerDelay = seconds(fromHeader: retryAfter)
        var id = self.requestID(header: requestID, body: nil)
        var delay = headerDelay

        if isJSON(contentType), let envelope = DuoWireErrorEnvelope.decode(body) {
            id = self.requestID(header: requestID, body: envelope.error.requestId)
            // The header first, as §6.0 says the two are the same number and the header is what
            // every HTTP layer in between already honours.
            delay = headerDelay ?? envelope.error.retryAfterS.flatMap(believable)
            if let code = DuoErrorCode(rawValue: envelope.error.code) {
                if isBelieved(code, at: status) {
                    return DuoTransportError(code: code, context: DuoErrorContext(httpStatus: status, requestID: id, retryAfter: delay,
                                                                                  details: envelope.error.details))
                }
                // One of the five codes, at a status the server never sends it with: read by the
                // status alone, below, with the envelope's id and delay kept.
            } else {
                // A code this build has never heard of comes from a newer server. A 429 is still a
                // rate limit and a 5xx still the service being unwell, both to be waited out like
                // any other; anything else is an answer this build cannot act on, reported with
                // its status so the retry rule can still dispatch on it.
                if status == 429 {
                    return .rateLimited(DuoErrorContext(httpStatus: status, requestID: id, retryAfter: delay ?? Int(DuoRetry.fallbackDelay)))
                }
                if (500...599).contains(status) {
                    return .maintenance(DuoErrorContext(httpStatus: status, requestID: id, retryAfter: delay))
                }
                return .unreadable(httpStatus: status, requestID: id)
            }
        }

        // Not the server's envelope, or not a code it could have sent at this status: classified
        // by the status alone.
        switch status {
        case 401, 403, 503:
            return .maintenance(DuoErrorContext(httpStatus: status, requestID: id, retryAfter: delay))
        case 413:
            // The WAF's (or the platform's) body-size limit, before the Worker saw the request.
            return .schema(DuoErrorContext(httpStatus: status, requestID: id, retryAfter: delay))
        case 429:
            // A rate limit that says nothing about when reads as a minute (§6.0).
            return .rateLimited(DuoErrorContext(httpStatus: status, requestID: id, retryAfter: delay ?? Int(DuoRetry.fallbackDelay)))
        case 500...599:
            return .maintenance(DuoErrorContext(httpStatus: status, requestID: id, retryAfter: delay))
        default:
            return .unreadable(httpStatus: status, requestID: id)
        }
    }

    /// Whether a code is believed at this status. The five that change who this phone is, bar the
    /// person or end a duo are believed only at the one status contract-v1 gives each (see the
    /// header); every other code is believed wherever it comes.
    static func isBelieved(_ code: DuoErrorCode, at status: Int) -> Bool {
        switch code {
        case .unauthenticated, .deviceRevoked: return status == 401
        case .banned: return status == 403
        case .duoUnknown: return status == 404
        case .duoEnded: return status == 409
        default: return true
        }
    }

    /// The request id a response's headers carry: `X-Request-Id` when it is one Diagnostics would
    /// keep, else `CF-Ray` under the same rule (the Worker's id is the cf-ray, and a response that
    /// never reached the Worker, a WAF page say, still carries Cloudflare's), else none.
    public static func headerRequestID(xRequestID: String?, cfRay: String?) -> String? {
        DuoDiagnostics.usableRequestID(xRequestID) ?? DuoDiagnostics.usableRequestID(cfRay)
    }

    /// The request id to quote under an error: the headers' id when it is one Diagnostics would
    /// keep, else the error body's `request_id` under the same rule, else none. Both ways in are
    /// filtered here, so no error ever carries an id that is not safe to print, and a header
    /// mangled by something in between does not hide the good id the body still has.
    public static func requestID(header: String?, body: String?) -> String? {
        DuoDiagnostics.usableRequestID(header) ?? DuoDiagnostics.usableRequestID(body)
    }

    /// `application/json`, with or without parameters (`; charset=utf-8`), in any letter case.
    /// The server sends nothing else, so `text/html`, a missing header and every other type
    /// are someone else's page.
    static func isJSON(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        let mediaType = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return mediaType.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }

    /// `Retry-After` as whole seconds (`delay-seconds`, one or more ASCII digits), or nil. An
    /// HTTP date is never sent by the server (§6.0: integer seconds only), so it is ignored
    /// rather than read against a phone clock that may be wrong.
    static func seconds(fromHeader value: String?) -> Int? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let number = Int(trimmed) else { return nil }
        return believable(number)
    }

    private static func believable(_ seconds: Int) -> Int? {
        (0...maximumRetryAfter).contains(seconds) ? seconds : nil
    }
}
