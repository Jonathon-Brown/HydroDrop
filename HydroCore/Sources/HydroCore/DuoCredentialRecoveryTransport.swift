import Foundation

/// The versioned credential-safety seam is deliberately separate from frozen v1. A rejected
/// pending candidate must never reach v1's reidentify handler, which would erase the only
/// material that can recover an answer the server committed before the connection was lost.
public protocol DuoCredentialRecoveryTransport: Sendable {
    func recoveryCapabilities() async throws -> DuoRecoveryCapabilities
    func prepareDeviceIssuance(_ request: DuoRecoveryPrepareRequest) async throws -> DuoRecoveryIssuance
    func commitDevice(_ request: DuoRecoveryCommitRequest, as credential: DuoRecoveryCredential) async throws -> DuoRecoveryCredentialState
    func credentialState(as credential: DuoRecoveryCredential) async throws -> DuoRecoveryCredentialState
    func rotateCredential(_ request: DuoRecoveryRotateRequest, as credential: DuoRecoveryCredential) async throws -> DuoRecoveryCredentialState
    func cancelDeviceIssuance(deviceID: String, as credential: DuoRecoveryCredential) async throws -> DuoRecoveryCancelResponse
    func deleteMe(as credential: DuoRecoveryCredential, _ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws
}

public struct DuoRecoveryCredential: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var deviceID: String
    public var deviceSecret: String
    public init(deviceID: String, deviceSecret: String) {
        self.deviceID = deviceID
        self.deviceSecret = deviceSecret
    }
    public init(_ credential: DuoCredential) { self.init(deviceID: credential.deviceID, deviceSecret: credential.deviceSecret) }
    public var description: String { "DuoRecoveryCredential(<redacted>)" }
    public var debugDescription: String { description }
    public var isValid: Bool { DuoRecoveryWire.isUUID(deviceID) && DuoRecoveryWire.isSecret(deviceSecret) }
}

public enum DuoRecoveryErrorCode: String, Codable, Sendable, CaseIterable {
    case credentialRejected = "credential_rejected", credentialConflict = "credential_conflict"
    case issuanceUnavailable = "issuance_unavailable", banned
    case attestRequired = "attest_required", attestInvalid = "attest_invalid", schema
    case payloadTooLarge = "payload_too_large", upgradeRequired = "upgrade_required"
    case termsRequired = "terms_required", rateLimited = "rate_limited", maintenance
    public func permits(status: Int) -> Bool {
        switch self {
        case .credentialRejected: return status == 401
        case .credentialConflict: return status == 409
        case .issuanceUnavailable: return status == 410
        case .banned, .attestRequired, .attestInvalid: return status == 403
        case .schema: return status == 400 || status == 422
        case .payloadTooLarge: return status == 413
        case .upgradeRequired: return status == 426
        case .termsRequired: return status == 428
        case .rateLimited: return status == 429
        case .maintenance: return status == 503
        }
    }
}

public enum DuoRecoveryError: Error, Equatable, Sendable {
    case refused(DuoRecoveryErrorCode, DuoErrorContext)
    case unavailable(DuoErrorContext)
    case offline
    public var context: DuoErrorContext? {
        switch self {
        case .refused(_, let c), .unavailable(let c): return c
        case .offline: return nil
        }
    }
    public var code: DuoRecoveryErrorCode? {
        if case .refused(let code, _) = self { return code }
        return nil
    }
}

public enum DuoRecoveryWireError: Error { case invalid }
public protocol DuoRecoveryResponse: Decodable, Sendable { func validate() throws }

private struct RecoveryKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func closed(_ decoder: Decoder, keys: Set<String>) throws {
    let c = try decoder.container(keyedBy: RecoveryKey.self)
    guard Set(c.allKeys.map(\.stringValue)) == keys else { throw DuoRecoveryWireError.invalid }
}

public struct DuoRecoveryCapabilities: Codable, Equatable, Sendable, DuoRecoveryResponse {
    public var contractVersion: String
    public var credentialRecovery: Bool
    public var issuanceTTLSeconds: Int
    public init(contractVersion: String = "1.1", credentialRecovery: Bool = true, issuanceTTLSeconds: Int = 86_400) {
        self.contractVersion = contractVersion
        self.credentialRecovery = credentialRecovery
        self.issuanceTTLSeconds = issuanceTTLSeconds
    }
    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version", credentialRecovery = "credential_recovery", issuanceTTLSeconds = "issuance_ttl_s"
    }
    public init(from decoder: Decoder) throws {
        try closed(decoder, keys: ["contract_version", "credential_recovery", "issuance_ttl_s"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try c.decode(String.self, forKey: .contractVersion)
        credentialRecovery = try c.decode(Bool.self, forKey: .credentialRecovery)
        issuanceTTLSeconds = try c.decode(Int.self, forKey: .issuanceTTLSeconds)
        try validate()
    }
    public func validate() throws {
        guard contractVersion == "1.1", credentialRecovery, issuanceTTLSeconds == 86_400 else { throw DuoRecoveryWireError.invalid }
    }
}

public struct DuoRecoveryPrepareRequest: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var platform: String
    public var appVersion: String
    public var termsVersion: Int
    public var deviceSecret: String
    public init(platform: String = "ios", appVersion: String, termsVersion: Int, deviceSecret: String) {
        self.platform = platform
        self.appVersion = appVersion
        self.termsVersion = termsVersion
        self.deviceSecret = deviceSecret
    }
    enum CodingKeys: String, CodingKey { case platform, appVersion = "app_version", termsVersion = "terms_version", deviceSecret = "device_secret" }
    public var description: String { "DuoRecoveryPrepareRequest(<redacted>)" }
    public var debugDescription: String { description }
    public func validate() throws {
        guard ["ios", "android"].contains(platform),
              (1...64).contains(appVersion.unicodeScalars.count),
              DuoRecoveryWire.isVersion(termsVersion),
              DuoRecoveryWire.isSecret(deviceSecret) else { throw DuoRecoveryWireError.invalid }
    }
}

public struct DuoRecoveryIssuance: Codable, Equatable, Sendable, DuoRecoveryResponse {
    public var contractVersion: String
    public var deviceID: String
    public var expiresAt: String
    public init(contractVersion: String = "1.1", deviceID: String, expiresAt: String) {
        self.contractVersion = contractVersion
        self.deviceID = deviceID
        self.expiresAt = expiresAt
    }
    enum CodingKeys: String, CodingKey { case contractVersion = "contract_version", deviceID = "device_id", expiresAt = "expires_at" }
    public init(from decoder: Decoder) throws {
        try closed(decoder, keys: ["contract_version", "device_id", "expires_at"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try c.decode(String.self, forKey: .contractVersion)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        expiresAt = try c.decode(String.self, forKey: .expiresAt)
        try validate()
    }
    public var expiresDate: Date? { DuoRecoveryWire.timestamp(expiresAt) }
    public func validate() throws {
        guard contractVersion == "1.1", DuoRecoveryWire.isUUID(deviceID), expiresDate != nil else { throw DuoRecoveryWireError.invalid }
    }
}

public struct DuoRecoveryCommitRequest: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var deviceID: String
    public var deviceCheckToken: String?
    public init(deviceID: String, deviceCheckToken: String? = nil) {
        self.deviceID = deviceID
        self.deviceCheckToken = deviceCheckToken
    }
    enum CodingKeys: String, CodingKey { case deviceID = "device_id", deviceCheckToken = "device_check_token" }
    public var description: String { "DuoRecoveryCommitRequest(<redacted>)" }
    public var debugDescription: String { description }
    public func validate() throws {
        guard DuoRecoveryWire.isUUID(deviceID),
              deviceCheckToken.map({ (1...8192).contains($0.unicodeScalars.count) }) ?? true else { throw DuoRecoveryWireError.invalid }
    }
}

public struct DuoRecoveryCredentialState: Codable, Equatable, Sendable, DuoRecoveryResponse {
    public var contractVersion: String
    public var deviceID: String
    public var memberID: String
    public var secretVersion: Int
    public var credentialProtocol: String
    public var deviceTier: String
    public var supportID: String
    public init(
        contractVersion: String = "1.1",
        deviceID: String,
        memberID: String,
        secretVersion: Int,
        credentialProtocol: String = "1.1",
        deviceTier: String,
        supportID: String
    ) {
        self.contractVersion = contractVersion
        self.deviceID = deviceID
        self.memberID = memberID
        self.secretVersion = secretVersion
        self.credentialProtocol = credentialProtocol
        self.deviceTier = deviceTier
        self.supportID = supportID
    }
    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version", deviceID = "device_id", memberID = "member_id", secretVersion = "secret_version"
        case credentialProtocol = "credential_protocol", deviceTier = "device_tier", supportID = "support_id"
    }
    public init(from decoder: Decoder) throws {
        try closed(decoder, keys: ["contract_version", "device_id", "member_id", "secret_version", "credential_protocol", "device_tier", "support_id"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try c.decode(String.self, forKey: .contractVersion)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        memberID = try c.decode(String.self, forKey: .memberID)
        secretVersion = try c.decode(Int.self, forKey: .secretVersion)
        credentialProtocol = try c.decode(String.self, forKey: .credentialProtocol)
        deviceTier = try c.decode(String.self, forKey: .deviceTier)
        supportID = try c.decode(String.self, forKey: .supportID)
        try validate()
    }
    public func validate() throws {
        guard contractVersion == "1.1",
              DuoRecoveryWire.isUUID(deviceID),
              DuoRecoveryWire.isUUID(memberID),
              DuoRecoveryWire.isVersion(secretVersion),
              ["1.0", "1.1"].contains(credentialProtocol),
              ["low", "attested"].contains(deviceTier),
              supportID.utf8.count == 12,
              supportID.utf8.allSatisfy({ Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8).contains($0) }) else { throw DuoRecoveryWireError.invalid }
    }
}

public struct DuoRecoveryRotateRequest: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var expectedSecretVersion: Int
    public var nextDeviceSecret: String
    public init(expectedSecretVersion: Int, nextDeviceSecret: String) {
        self.expectedSecretVersion = expectedSecretVersion
        self.nextDeviceSecret = nextDeviceSecret
    }
    enum CodingKeys: String, CodingKey { case expectedSecretVersion = "expected_secret_version", nextDeviceSecret = "next_device_secret" }
    public var description: String { "DuoRecoveryRotateRequest(<redacted>)" }
    public var debugDescription: String { description }
    public func validate() throws {
        guard DuoRecoveryWire.isVersion(expectedSecretVersion), DuoRecoveryWire.isSecret(nextDeviceSecret) else { throw DuoRecoveryWireError.invalid }
    }
}

public struct DuoRecoveryCancelResponse: Codable, Equatable, Sendable, DuoRecoveryResponse {
    public enum Outcome: String, Codable, Sendable { case cancelled, committed }
    public var contractVersion: String
    public var deviceID: String
    public var outcome: Outcome
    public init(contractVersion: String = "1.1", deviceID: String, outcome: Outcome) {
        self.contractVersion = contractVersion
        self.deviceID = deviceID
        self.outcome = outcome
    }
    enum CodingKeys: String, CodingKey { case contractVersion = "contract_version", deviceID = "device_id", outcome }
    public init(from decoder: Decoder) throws {
        try closed(decoder, keys: ["contract_version", "device_id", "outcome"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try c.decode(String.self, forKey: .contractVersion)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
        try validate()
    }
    public func validate() throws {
        guard contractVersion == "1.1", DuoRecoveryWire.isUUID(deviceID) else { throw DuoRecoveryWireError.invalid }
    }
}

public enum DuoRecoveryWire {
    public static let maximumBodyBytes = 16_384
    public static func isVersion(_ value: Int) -> Bool { value > 0 && value <= Int(Int32.max) }
    public static func isUUID(_ value: String) -> Bool {
        let b = Array(value.utf8)
        guard b.count == 36, b[14] == 52, [56,57,97,98].contains(b[19]) else { return false }
        return b.indices.allSatisfy { [8,13,18,23].contains($0) ? b[$0] == 45 : (48...57).contains(b[$0]) || (97...102).contains(b[$0]) }
    }
    public static func isSecret(_ value: String) -> Bool {
        guard value.utf8.count == 43,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let raw = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
              raw.count == 32 else { return false }
        let canonical = raw.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return canonical == value
    }
    public static func timestamp(_ value: String) -> Date? {
        let b = Array(value.utf8)
        guard b.count == 24, b[19] == 46, b[23] == 90, b[10] == 84,
              b[17] <= 53, b[20...22].allSatisfy({ (48...57).contains($0) }) else { return nil }
        return DuoWireTime.parse(value)
    }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumBodyBytes else { throw DuoRecoveryWireError.invalid }
        return data
    }
    public static func decode<T: DuoRecoveryResponse>(_ type: T.Type, from data: Data) throws -> T {
        try validateJSON(data)
        let value = try JSONDecoder().decode(type, from: data)
        try value.validate()
        return value
    }
    public static func isJSON(_ contentType: String?) -> Bool {
        contentType?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "application/json"
    }
    public static func validateJSON(_ data: Data) throws {
        guard data.count <= maximumBodyBytes else { throw DuoRecoveryWireError.invalid }
        var scanner = RecoveryJSONScanner(bytes: Array(data))
        try scanner.scan()
    }

    /// A closed, correctly typed error is the only source of a definitive candidate rejection.
    /// Retrying an old credential based on an HTML401 or on a proxy's copied code would erase
    /// the distinction between an unknown commit and a server refusal.
    /// Privacy deletion still uses v1's frozen route. Translate its exact credential refusals
    /// into the recovery namespace without ever invoking the ordinary identity-gone path.
    public static func classifyDeletion(
        status: Int,
        contentType: String?,
        retryAfter: String?,
        requestID: String?,
        body: Data
    ) -> DuoRecoveryError {
        let context = DuoErrorContext(httpStatus: status, requestID: requestID)
        guard isJSON(contentType), (try? validateJSON(body)) != nil,
              let envelope = try? JSONDecoder().decode(RecoveryDeleteEnvelope.self, from: body) else { return .unavailable(context) }
        let e = envelope.error
        let id = DuoErrorClassifier.headerRequestID(xRequestID: e.requestID, cfRay: nil)
        guard id != nil else { return .unavailable(context) }
        if status == 401, ["unauthenticated", "device_revoked"].contains(e.code) {
            return .refused(.credentialRejected, DuoErrorContext(httpStatus: status, requestID: id))
        }
        guard let code = DuoRecoveryErrorCode(rawValue: e.code),
              code.permits(status: status),
              code != .credentialRejected else { return .unavailable(context) }
        if status == 429 {
            guard let delay = e.retryAfter, delay >= 0, delay <= Int(Int32.max), retryAfter == String(delay) else { return .unavailable(context) }
        }
        return .refused(code, DuoErrorContext(httpStatus: status, requestID: id, retryAfter: e.retryAfter))
    }

    public static func classify(
        status: Int,
        contentType: String?,
        retryAfter: String?,
        requestID: String?,
        body: Data
    ) -> DuoRecoveryError {
        let context = DuoErrorContext(httpStatus: status, requestID: requestID)
        guard isJSON(contentType), (try? validateJSON(body)) != nil,
              let parsed = try? JSONDecoder().decode(RecoveryErrorEnvelope.self, from: body),
              parsed.error.code.permits(status: status) else { return .unavailable(context) }
        let e = parsed.error
        if status == 429 {
            guard let delay = e.retryAfter, let retryAfter, retryAfter == String(delay) else { return .unavailable(context) }
        } else if e.retryAfter != nil {
            return .unavailable(context)
        }
        return .refused(e.code, DuoErrorContext(httpStatus: status, requestID: e.requestID, retryAfter: e.retryAfter))
    }
}

private struct RecoveryErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: DuoRecoveryErrorCode
        let requestID: String
        let retryAfter: Int?
        enum CodingKeys: String, CodingKey { case code, message, requestID = "request_id", retryAfter = "retry_after_s" }
        init(from decoder: Decoder) throws {
            let all = Set(try decoder.container(keyedBy: RecoveryKey.self).allKeys.map(\.stringValue))
            guard all == ["code", "message", "request_id"] || all == ["code", "message", "request_id", "retry_after_s"] else {
                throw DuoRecoveryWireError.invalid
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decode(DuoRecoveryErrorCode.self, forKey: .code)
            requestID = try c.decode(String.self, forKey: .requestID)
            let message = try c.decode(String.self, forKey: .message)
            retryAfter = all.contains("retry_after_s") ? try c.decode(Int.self, forKey: .retryAfter) : nil
            guard (1...256).contains(message.unicodeScalars.count), requestID.utf8.count == 16,
                  requestID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  retryAfter.map({ $0 >= 0 && $0 <= Int(Int32.max) }) ?? true else { throw DuoRecoveryWireError.invalid }
        }
    }
    let error: Body
    enum CodingKeys: String, CodingKey { case error }
    init(from decoder: Decoder) throws {
        try closed(decoder, keys: ["error"])
        error = try decoder.container(keyedBy: CodingKeys.self).decode(Body.self, forKey: .error)
    }
}

/// Foundation's decoders accept duplicate keys. Scan before decoding so an escaped duplicate
/// cannot turn an unknown outcome into a definitive rejection. Foundation still judges scalar
/// grammar/UTF-8; this bounded scanner adds duplicate-key and nesting checks without retaining
/// a response body or a secret in an error message.
private struct RecoveryJSONScanner {
    let bytes: [UInt8]
    var index = 0
    mutating func scan() throws {
        try value(depth: 0)
        space()
        guard index == bytes.count else { throw DuoRecoveryWireError.invalid }
    }
    mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
    mutating func consume(_ byte: UInt8) throws {
        space()
        guard index < bytes.count, bytes[index] == byte else { throw DuoRecoveryWireError.invalid }
        index += 1
    }
    mutating func string() throws -> String {
        space()
        let start = index
        try consume(34)
        while index < bytes.count {
            let b = bytes[index]
            index += 1
            if b == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
            if b == 92 {
                guard index < bytes.count else { break }
                index += 1
            }
        }
        throw DuoRecoveryWireError.invalid
    }
    mutating func value(depth: Int) throws {
        guard depth < 16 else { throw DuoRecoveryWireError.invalid }
        space()
        guard index < bytes.count else { throw DuoRecoveryWireError.invalid }
        if bytes[index] == 123 {
            index += 1
            space()
            if index < bytes.count && bytes[index] == 125 {
                index += 1
                return
            }
            var keys = Set<String>()
            while true {
                let key = try string()
                guard keys.insert(key).inserted else { throw DuoRecoveryWireError.invalid }
                try consume(58)
                try value(depth: depth + 1)
                space()
                guard index < bytes.count else { throw DuoRecoveryWireError.invalid }
                if bytes[index] == 125 {
                    index += 1
                    return
                }
                try consume(44)
            }
        } else if bytes[index] == 91 {
            index += 1
            space()
            if index < bytes.count && bytes[index] == 93 {
                index += 1
                return
            }
            while true {
                try value(depth: depth + 1)
                space()
                guard index < bytes.count else { throw DuoRecoveryWireError.invalid }
                if bytes[index] == 93 {
                    index += 1
                    return
                }
                try consume(44)
            }
        } else if bytes[index] == 34 {
            _ = try string()
        } else {
            let start = index
            while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw DuoRecoveryWireError.invalid }
            _ = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])
        }
    }
}

private struct RecoveryDeleteEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
        let requestID: String
        let retryAfter: Int?
        enum CodingKeys: String, CodingKey { case code, message, requestID = "request_id", retryAfter = "retry_after_s", details }
        init(from decoder: Decoder) throws {
            let keys = Set(try decoder.container(keyedBy: RecoveryKey.self).allKeys.map(\.stringValue))
            guard keys.isSuperset(of: ["code", "message", "request_id"]),
                  keys.isSubset(of: ["code", "message", "request_id", "retry_after_s", "details"]) else { throw DuoRecoveryWireError.invalid }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decode(String.self, forKey: .code)
            requestID = try c.decode(String.self, forKey: .requestID)
            _ = try c.decode(String.self, forKey: .message)
            retryAfter = keys.contains("retry_after_s") ? try c.decode(Int.self, forKey: .retryAfter) : nil
            if keys.contains("details") { _ = try c.nestedContainer(keyedBy: RecoveryKey.self, forKey: .details) }
        }
    }
    let error: Body
    enum CodingKeys: String, CodingKey { case error }
    init(from decoder: Decoder) throws {
        try closed(decoder, keys: ["error"])
        error = try decoder.container(keyedBy: CodingKeys.self).decode(Body.self, forKey: .error)
    }
}
