import Foundation

/// One list setup can offer for a TV, and why.
public struct ProfileMatch: Identifiable, Equatable {
    public enum Kind: Equatable {
        /// A hand-written profile whose `match` fits this TV exactly (tested with Purio TV).
        case tested
        /// A community list that names this TV's device or product in its header (made for this model).
        case model
        /// A community list for another model of the same platform: the closest one.
        case closest
    }
    public var id: String { profile.id }
    public let profile: DebloatProfile
    public let kind: Kind
    /// List apps installed on this TV and still enabled: what setup would offer.
    public let present: Int
    /// Which of the TV's names the list mentions ("BeyondTV4"); empty for a closest match.
    public let named: [String]
    let score: Double
}

/// Picks cleanyourtv lists for a TV the way an agent would: the list whose own unit is this TV (its device and product
/// names, read by the importer from the list's header), or failing that the one whose brand's own apps are most present
/// on it. Plain scoring, no guessing about packages: whichever list is chosen, only its own entries are ever offered,
/// and the safety checks still run.
public enum ProfileMatcher {
    public static func rank(_ properties: [String: String], installed: Set<String>, disabled: Set<String> = [],
                            in profiles: [DebloatProfile], limit: Int = 8) -> [ProfileMatch] {
        let value = { (key: String) in (properties[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let device = value("ro.product.device"), product = value("ro.product.name"), model = value("ro.product.model")
        let maker = value("ro.product.manufacturer")
        let names = { (p: DebloatProfile, kind: String) in Set((p.manifest.names?[kind] ?? []).map { $0.lowercased() }) }
        // A board name several lists share (BeyondTV4 is on 11) doesn't say which of them this TV is.
        let deviceShared = !device.isEmpty && profiles.filter { $0.isCommunity && names($0, "device").contains(device) }.count > 1
        var out = [ProfileMatch]()
        for profile in profiles {
            let present = profile.list.entries.filter { installed.contains($0.package) && !disabled.contains($0.package) }.count
            if !profile.isCommunity {
                if profile.matches(properties) { out.append(ProfileMatch(profile: profile, kind: .tested, present: present, named: [], score: 100)) }
                continue
            }
            guard present > 0 else { continue }
            let products = names(profile, "product"), devices = names(profile, "device"), models = names(profile, "model")
            let productHit = !product.isEmpty && products.contains(product)
            let deviceHit = !device.isEmpty && devices.contains(device)
            let modelHit = !model.isEmpty && models.contains(model)
            // Its own unit: the same product, or the same model, or a board name only this list uses (and no other product named).
            let identifies = productHit || modelHit || (deviceHit && !deviceShared && (products.isEmpty || productHit))
            var score = (productHit ? 3.0 : 0) + (modelHit ? 2 : 0) + (deviceHit ? (deviceShared ? 1 : 2) : 0)
            let brand = (profile.manifest.brand ?? "").lowercased()
            let sameBrand = !maker.isEmpty && (brand.contains(maker) || (!brand.isEmpty && maker.contains(brand)))
            if sameBrand { score += 0.5 }
            // The brand's own apps tell platforms apart; Google's and Android's are on every TV.
            let vendor = profile.list.entries.filter { !($0.package.hasPrefix("com.google.") || $0.package.hasPrefix("com.android.") || $0.package.hasPrefix("android.")) }
            let pool = vendor.isEmpty ? profile.list.entries : vendor
            let overlap = Double(pool.filter { installed.contains($0.package) }.count) / Double(max(1, pool.count))
            score += overlap * 2
            guard identifies || deviceHit || (sameBrand && overlap >= 0.3) || overlap >= 0.6 else { continue }
            let named = [(productHit, properties["ro.product.name"]), (deviceHit, properties["ro.product.device"]), (modelHit, properties["ro.product.model"])]
                .compactMap { $0.0 ? $0.1?.trimmingCharacters(in: .whitespaces) : nil }
            out.append(ProfileMatch(profile: profile, kind: identifies ? .model : .closest, present: present, named: identifies ? named : [], score: score))
        }
        return Array(out.sorted { $0.score != $1.score ? $0.score > $1.score : $0.profile.manifest.name < $1.profile.manifest.name }.prefix(limit))
    }
}
