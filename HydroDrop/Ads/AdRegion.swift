import Foundation

/// Where HydroDrop shows ads, decided on the device before Google's ad software starts.
///
/// Google's EU User Consent Policy asks for consent before even non-personalized ads are
/// served in the European Economic Area, the UK and Switzerland, because they still use
/// device identifiers for frequency capping and reporting, and it stops applying where
/// Google's ad services aren't used for those people at all. The ads there earn next to
/// nothing, so rather than a consent screen in front of the app, HydroDrop shows none in
/// those countries and never starts Google's ad software for them. The app used to start
/// it at launch for everyone, which is what left those users without the consent Google
/// asks for.
enum AdRegion {
    /// The EU's 27 members; Iceland, Liechtenstein and Norway, which make up the rest of
    /// the EEA; the UK; and Switzerland. Each appears twice, as the two-letter code the
    /// device's region setting reports and the three-letter code the App Store storefront
    /// reports. The EU territories that carry codes of their own (the French overseas
    /// regions, Saint Martin, Åland, the Canary Islands, and Ceuta and Melilla, the last two
    /// with no storefront of their own) are here too, as is "150", the code for Europe as a
    /// whole, which the region setting can report; including them costs nothing.
    static let adFreeCountries: Set<String> = [
        // European Union
        "AT", "AUT", "BE", "BEL", "BG", "BGR", "HR", "HRV", "CY", "CYP", "CZ", "CZE",
        "DK", "DNK", "EE", "EST", "FI", "FIN", "FR", "FRA", "DE", "DEU", "GR", "GRC",
        "HU", "HUN", "IE", "IRL", "IT", "ITA", "LV", "LVA", "LT", "LTU", "LU", "LUX",
        "MT", "MLT", "NL", "NLD", "PL", "POL", "PT", "PRT", "RO", "ROU", "SK", "SVK",
        "SI", "SVN", "ES", "ESP", "SE", "SWE",
        // The rest of the European Economic Area
        "IS", "ISL", "LI", "LIE", "NO", "NOR",
        // The United Kingdom and Switzerland
        "GB", "GBR", "CH", "CHE",
        // EU territories with codes of their own, and Europe as a whole
        "RE", "REU", "GP", "GLP", "MQ", "MTQ", "GF", "GUF", "YT", "MYT", "MF", "MAF", "AX", "ALA",
        "IC", "EA", "150",
    ]

    /// Whether ads may be shown, given the App Store storefront's country and the device's
    /// region setting. Either one in the list is enough to show none, and so is knowing
    /// neither: it fails closed rather than serve ads to someone it can't place. Neither
    /// is where the person actually is, so someone from elsewhere travelling in Europe can
    /// still be shown ads; Google limits those itself, as it did for everyone there before.
    static func servesAds(storefrontCountry: String?, deviceRegion: String?) -> Bool {
        let codes = [storefrontCountry, deviceRegion]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
        guard !codes.isEmpty else { return false }
        return !codes.contains(where: adFreeCountries.contains)
    }

    #if DEBUG
    /// `-AdRegion <country code>` stands in for both the storefront and the region
    /// setting, to see the app as someone in or out of the region, for example `-AdRegion
    /// GBR` or `-AdRegion USA`. Compiled out of Release.
    static var debugOverride: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-AdRegion"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    #endif
}
