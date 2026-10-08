#if DUO_V2
import Foundation

/// Builds the real services, in the order they need each other, and gives them to the store.
/// The one file that names every concrete service; nothing else does.
enum DuoComposition {
    /// The parameters are what a test of the whole wiring replaces: the session, so every
    /// request can be counted; the secret store and the cache, so it touches nothing real; and
    /// the attester and DeviceCheck, which talk to Apple outside the session, so a test that
    /// counts only HTTP could not see an attestation made before a tap. Nil builds the real one
    /// (it needs the secrets built here, so it cannot be a default argument).
    @MainActor
    static func makeLiveStore(session: DuoHTTPSession = URLSessionHTTP(), secretStore: DuoSecretStore = KeychainDuoSecretStore(),
                              cache: DuoCache = .live, baseURL: URL = DuoConfig.baseURL,
                              attester: DuoAttesting? = nil, deviceCheck: DuoDeviceCheckProviding? = nil) -> DuoStore {
        #if DEBUG
        // `-DuoPreview` draws sample duos and talks to nobody. Compiled out of Release.
        // The name after it picks a scenario (`DuoStore.previewScenarioNames`); alone it is `sample`.
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-DuoPreview") {
            let next = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
            return DuoStore.makePreview(scenario: next.hasPrefix("-") ? "sample" : next)
        }
        #endif
        let store = DuoStore(cache: cache)
        let secrets = DuoSecrets(store: secretStore)
        let dependencies = DuoDependencies(
            host: store, cache: store.cache, secrets: secrets, client: DuoConfig.client,
            attester: attester ?? DuoAppAttest(secrets: secrets), deviceCheck: deviceCheck ?? DuoDeviceCheck()
        )
        dependencies.isSubscribed = { StoreManager.shared.isSubscribed }
        dependencies.activeSkin = { AppSettings.shared.activeMascotSkin.rawValue }
        dependencies.wakingWindow = { (AppSettings.shared.quietStartMinutes, AppSettings.shared.quietEndMinutes) }
        dependencies.knownSkins = Set(MascotSkin.allCases.map(\.rawValue))

        // The identity is the API client's credential and the API client is the identity's
        // transport, so the first is built before and the second is handed over after.
        let identity = DuoIdentity(dependencies: dependencies)
        dependencies.identity = identity
        // Every response leaves its request id in Diagnostics (the observer hops to the main
        // actor, where the store lives, and holds the store weakly).
        let clock = dependencies.clock
        let observed = DuoObservedSession(base: session) { [weak store] status, requestID in
            let at = clock.now
            Task { @MainActor in store?.diagnostics.recordRequest(status: status, requestID: requestID, at: at) }
        }
        dependencies.transport = DuoAPIClient(baseURL: baseURL, client: DuoConfig.client, credentials: identity,
                                              attester: dependencies.attester, session: observed)
        dependencies.ops = DuoOpQueueService(dependencies: dependencies)
        dependencies.announcer = DuoNotifier(dependencies: dependencies)
        dependencies.push = DuoPushService(dependencies: dependencies)
        dependencies.sync = DuoSyncEngine(dependencies: dependencies)
        dependencies.joining = DuoJoiningService(dependencies: dependencies)
        dependencies.exiting = DuoExitService(dependencies: dependencies)
        dependencies.background = DuoBackground(dependencies: dependencies)
        store.install(dependencies)
        return store
    }
}
#endif
