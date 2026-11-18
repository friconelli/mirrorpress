import Foundation
import Security

/// Password nel Portachiavi di macOS (mai nel file dei profili).
enum Keychain {
    static let service = "com.federicomancinelli.mirrorpress"

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if value.isEmpty { SecItemDelete(query as CFDictionary); return }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Nome precedente dell'app (Travaso): le password salvate allora si leggono e si copiano al primo uso.
    static let legacyService = "com.federicomancinelli.travaso"

    static func get(_ account: String) -> String {
        let v = read(account, service: service)
        if !v.isEmpty { return v }
        let old = read(account, service: legacyService)
        if !old.isEmpty { set(old, account: account) }
        return old
    }

    private static func read(_ account: String, service: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    static func delete(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

/// Segreti di un profilo, uno per voce del Portachiavi.
enum Secret: String, CaseIterable {
    case connection = "conn"      // password FTP/SFTP
    case httpAuth = "http"        // password della protezione HTTP del sito
    case localDB = "localdb"
    case remoteDB = "remotedb"

    func get(_ site: SiteProfile) -> String { Keychain.get(site.keychainAccount + "." + rawValue) }
    func set(_ value: String, for site: SiteProfile) { Keychain.set(value, account: site.keychainAccount + "." + rawValue) }
}

/// Cartelle dell'app in ~/Library/Application Support/Mirrorpress.
enum AppPaths {
    static var support: URL {
        // MIRRORPRESS_SUPPORT_DIR: solo per i test, per non scrivere nei dati veri dell'app.
        let base = ProcessInfo.processInfo.environment["MIRRORPRESS_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mirrorpress", isDirectory: true)
        migrateLegacy(to: base)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// L'app si chiamava Travaso: al primo avvio sposta profili e backup nella cartella nuova.
    private static func migrateLegacy(to base: URL) {
        let fm = FileManager.default
        guard ProcessInfo.processInfo.environment["MIRRORPRESS_SUPPORT_DIR"] == nil, !fm.fileExists(atPath: base.path) else { return }
        let old = base.deletingLastPathComponent().appendingPathComponent("Travaso", isDirectory: true)
        if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: base) }
    }
    static var sitesFile: URL { support.appendingPathComponent("sites.json") }

    /// Lavoro locale di un sito (backup del DB locale, staging, cache): fuori da htdocs.
    static func workdir(for site: SiteProfile) -> URL {
        let u = support.appendingPathComponent("siti/\(site.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Copie locali dei backup scaricati dal server.
    static func downloads(for site: SiteProfile) -> URL {
        let u = workdir(for: site).appendingPathComponent("backup-server", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func temp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("mirrorpress-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

@MainActor
final class SiteStore: ObservableObject {
    @Published var sites: [SiteProfile] = []

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: AppPaths.sitesFile),
              let list = try? JSONDecoder().decode([SiteProfile].self, from: data) else { return }
        sites = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(sites) {
            try? data.write(to: AppPaths.sitesFile, options: .atomic)
        }
    }

    func upsert(_ site: SiteProfile) {
        if let i = sites.firstIndex(where: { $0.id == site.id }) { sites[i] = site } else { sites.append(site) }
        sites.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    func remove(_ site: SiteProfile) {
        sites.removeAll { $0.id == site.id }
        for s in Secret.allCases { Keychain.delete(account: site.keychainAccount + "." + s.rawValue) }
        save()
    }
}
