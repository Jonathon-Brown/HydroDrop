#if DUO_V2
import Foundation

/// A deliberately narrow development-only mapping for the one staging identity observed
/// in the November 3 recovery drill. The launch receipt is an explicit operator approval,
/// not evidence by itself: the existing cached member, Support ID and this-device row must
/// all agree with the strictly decoded legacy credential before migration can write anything.
/// This is an isolated staging overlay; it is not a general legacy migration policy.
enum DuoLegacyStagingProvenance {
    static let approvalArgument = "-DuoVerifiedLegacyStaging"
    static let approvalReceipt = "nov3-staging-build34-qcxz"
    static let approvedSupportID = "QCXZKZJCAYW7"

    static func approvedEnvironment(baseURL: URL, arguments: [String], bundleIdentifier: String?,
                                    cachedMember: DuoMemberInfo?, credential: DuoCredential) -> DuoRecoveryEnvironment? {
        #if DEBUG
        let flags = arguments.indices.filter { arguments[$0] == approvalArgument }
        guard flags.count == 1, let flag = flags.first, arguments.indices.contains(flag + 1),
              arguments[flag + 1] == approvalReceipt,
              DuoConfig.isCanonicalStagingBase(baseURL),
              bundleIdentifier == "com.jonathonbrown.HydroDrop",
              let member = cachedMember, member.supportID == approvedSupportID,
              member.memberID == credential.memberID,
              (try? DuoJournalCredential(credential, protocolVersion: "1.0").validate()) != nil else { return nil }
        let thisDevice = member.devices.filter(\.thisDevice)
        guard thisDevice.count == 1, let device = thisDevice.first,
              device.id == credential.deviceID, device.platform == "ios", !device.superseded else { return nil }
        return .staging
        #else
        return nil
        #endif
    }
}
#endif
