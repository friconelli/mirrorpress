import Foundation

/// Le informazioni di un lato, lette dall'azione "info" del ponte.
struct SiteInfo {
    struct Plugin: Hashable { let slug: String; let file: String; let name: String; let version: String; let requiresPHP: String }
    struct Theme: Hashable { let slug: String; let name: String; let version: String; let requiresPHP: String; let parent: String }
    struct Content: Hashable { let count: Int; let modified: String? }

    let raw: JSONValue
    var php: String { raw["php"].string ?? "" }
    var root: String { raw["root"].string ?? "" }
    var server: String { raw["server"].string ?? "" }
    var isWordPress: Bool { raw["wordpress"].truthy }
    var wpVersion: String? { raw["wp"]["version"].string }
    var dbServer: String? { raw["db"]["server"].string }
    var dbName: String? { raw["db"]["name"].string }
    var dbPrefix: String { raw["db"]["prefix"].string ?? raw["config"]["table_prefix"].string ?? "" }
    var dbSize: Int64 { raw["db"]["size"].int64 }
    var dbError: String? { raw["db_error"].string }
    var hasDB: Bool { !raw["db"].isNull }
    var siteURL: String? { raw["db"]["options"]["siteurl"].string }
    var homeURL: String? { raw["db"]["options"]["home"].string }
    var blogPublic: String? { raw["db"]["options"]["blog_public"].string }
    var activePlugins: [String] { raw["db"]["options"]["active_plugins"].array.compactMap(\.string) }
    var stylesheet: String? { raw["db"]["options"]["stylesheet"].string }
    var collations: [String: Int] { raw["db"]["collations"].object.compactMapValues(\.int) }
    var postMaxSize: Int64 { raw["limits"]["post_max_size"].int64 }
    var diskFree: Int64 { raw["limits"]["disk_free"].int64 }
    var maxExecution: Int { raw["limits"]["max_execution_time"].int ?? 0 }
    var memoryLimit: String { raw["limits"]["memory_limit"].string ?? "" }
    var writable: Bool { raw["writable"].truthy }
    var maintenance: Bool { raw["wp"]["maintenance"].truthy }
    var debug: Bool { raw["config"]["WP_DEBUG"].truthy }
    var debugDisplay: Bool { debug && (raw["config"]["WP_DEBUG_DISPLAY"].isNull || raw["config"]["WP_DEBUG_DISPLAY"].truthy) }
    var wpHomeConstant: String? { raw["config"]["WP_HOME"].string }
    var multisite: Bool { raw["config"]["MULTISITE"].truthy }
    var dropins: [String] { raw["wp"]["dropins"].array.compactMap(\.string) }
    var extensions: [String: Bool] { raw["extensions"].object.mapValues(\.truthy) }

    var plugins: [Plugin] {
        raw["wp"]["plugins"].array.map {
            Plugin(slug: $0["slug"].string ?? "", file: $0["file"].string ?? "", name: $0["name"].string ?? "",
                   version: $0["version"].string ?? "", requiresPHP: $0["requires_php"].string ?? "")
        }
    }
    var themes: [Theme] {
        raw["wp"]["themes"].array.map {
            Theme(slug: $0["slug"].string ?? "", name: $0["name"].string ?? "", version: $0["version"].string ?? "",
                  requiresPHP: $0["requires_php"].string ?? "", parent: $0["parent"].string ?? "")
        }
    }
    var posts: [String: Content] {
        raw["db"]["content"]["posts"].object.mapValues { Content(count: $0["count"].int ?? 0, modified: $0["modified"].string) }
    }
    var comments: Content? {
        let c = raw["db"]["content"]["comments"]
        return c.isNull ? nil : Content(count: c["count"].int ?? 0, modified: c["modified"].string)
    }
    var users: Content? {
        let c = raw["db"]["content"]["users"]
        return c.isNull ? nil : Content(count: c["count"].int ?? 0, modified: c["modified"].string)
    }
}

enum Version {
    /// "8.2.12" → "8.2"
    static func minor(_ v: String) -> String { v.split(separator: ".").prefix(2).joined(separator: ".") }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: .numeric)
    }

    /// MariaDB riporta "10.6.12-MariaDB"; MySQL "8.0.40".
    static func dbFlavor(_ v: String) -> String { v.lowercased().contains("mariadb") ? "MariaDB" : "MySQL" }
}

/// Trova problemi e incongruenze tra locale e server.
enum Analysis {
    static func issues(local: SiteInfo, remote: SiteInfo, profile: SiteProfile,
                       files: [FileDiff], tables: [TableDiff], caseConflicts: [(String, String)]) -> [Issue] {
        var out: [Issue] = []
        func add(_ s: Severity, _ area: String, _ title: String, _ detail: String = "") {
            out.append(Issue(severity: s, area: area, title: title, detail: detail))
        }
        let A_SRV = L("Server"), A_WP = L("WordPress"), A_DB = L("Database"), A_FILE = L("File"), A_PLUG = L("Plugin e temi")

        // Server e PHP
        if Version.minor(local.php) != Version.minor(remote.php) {
            let older = Version.compare(remote.php, local.php) == .orderedAscending
            add(older ? .warning : .info, A_SRV, L("PHP diverso: locale %@, server %@", local.php, remote.php),
                older ? L("Il server ha un PHP più vecchio: codice scritto in locale potrebbe non funzionare.") : "")
        }
        if Version.compare(remote.php, "7.4") == .orderedAscending {
            add(.warning, A_SRV, L("PHP %@ sul server è fuori supporto", remote.php), L("Chiedi all'hosting di passare almeno a PHP 8.1."))
        }
        if !remote.writable { add(.error, A_SRV, L("La cartella del sito sul server non è scrivibile da PHP"), L("I file non si possono aggiornare via ponte: controlla i permessi o l'utente PHP dell'hosting.")) }
        if remote.extensions["mysqli"] == false { add(.error, A_SRV, L("Il server non ha l'estensione mysqli")) }
        if remote.extensions["zlib"] == false { add(.warning, A_SRV, L("Il server non ha zlib: i trasferimenti saranno più lenti")) }
        if remote.diskFree > 0 {
            let needed = files.filter { $0.status == .onlyLocal || $0.status == .changed }.reduce(Int64(0)) { $0 + ($1.local?.size ?? 0) } * 2 + local.dbSize * 2
            if remote.diskFree < needed {
                add(.error, A_SRV, L("Spazio sul server forse insufficiente"), L("Liberi %@, servono circa %@ (file + backup).", Format.bytes(remote.diskFree), Format.bytes(needed)))
            }
        }
        if remote.maintenance { add(.warning, A_WP, L("Il sito sul server è in manutenzione (.maintenance)"), L("Un aggiornamento si è interrotto: il sito mostra la pagina di manutenzione.")) }

        // WordPress
        if local.isWordPress, remote.isWordPress {
            if let lv = local.wpVersion, let rv = remote.wpVersion, lv != rv {
                add(.warning, A_WP, L("Versione di WordPress diversa: locale %@, server %@", lv, rv),
                    L("Il database va con la versione dei file: aggiorna prima i file del core (wp-admin, wp-includes) o WordPress sul lato più vecchio."))
            }
            if remote.debugDisplay { add(.warning, A_WP, L("WP_DEBUG attivo sul server con errori a video"), L("I visitatori possono vedere avvisi PHP e percorsi del server.")) }
            if remote.blogPublic == "0" { add(.warning, A_WP, L("Sul server è attivo «Scoraggia i motori di ricerca»"), L("Il sito non viene indicizzato: va bene solo per uno staging.")) }
            if let h = remote.wpHomeConstant { add(.info, A_WP, L("WP_HOME è fisso nel wp-config del server (%@)", h), L("siteurl/home del database vengono ignorati lì.")) }
            if local.multisite || remote.multisite { add(.warning, A_WP, L("Multisito: il trasferimento del database va fatto con cautela"), L("Gli indirizzi dei sottositi stanno anche nelle tabelle wp_blogs e wp_site.")) }
            if let su = remote.siteURL, !profile.remoteURL.isEmpty, normalizedURL(su) != normalizedURL(profile.remoteURL) {
                add(.warning, A_WP, L("Indirizzo del sito sul server diverso dal profilo"), L("Nel database: %@ — nel profilo: %@. Il trasferimento del database userà quello del profilo.", su, profile.remoteURL))
            }
            if let su = remote.siteURL, su.hasPrefix("http://"), profile.remoteURL.hasPrefix("https://") {
                add(.warning, A_WP, L("Il server ha siteurl in http mentre il sito è in https"), L("Contenuto misto e redirect: il trasferimento del database lo corregge."))
            }
            if let s = remote.siteURL, let h = remote.homeURL, normalizedURL(s) != normalizedURL(h) {
                add(.info, A_WP, L("Sul server siteurl e home sono diversi"), "\(s) — \(h)")
            }
            for d in remote.dropins where d == "object-cache.php" || d == "advanced-cache.php" {
                add(.info, A_WP, L("Cache attiva sul server (%@)", d), L("Dopo un aggiornamento svuota la cache del plugin o dell'hosting."))
            }
            for d in local.dropins where d == "object-cache.php" || d == "advanced-cache.php" {
                if !remote.dropins.contains(d) { add(.warning, A_WP, L("%@ solo in locale", d), L("Portarlo sul server può rompere il sito se lì manca il servizio di cache (Redis/Memcached).")) }
            }
        }

        // Plugin e temi
        let lp = Dictionary(local.plugins.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        let rp = Dictionary(remote.plugins.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        for (slug, p) in lp.sorted(by: { $0.key < $1.key }) {
            if let r = rp[slug] {
                if p.version != r.version { add(.info, A_PLUG, L("%@: versione %@ in locale, %@ sul server", p.name, p.version, r.version)) }
            } else {
                add(.info, A_PLUG, L("Plugin solo in locale: %@ %@", p.name, p.version))
            }
            if !p.requiresPHP.isEmpty, Version.compare(remote.php, p.requiresPHP) == .orderedAscending {
                add(.error, A_PLUG, L("%@ richiede PHP %@, il server ha %@", p.name, p.requiresPHP, remote.php))
            }
        }
        for (slug, p) in rp.sorted(by: { $0.key < $1.key }) where lp[slug] == nil {
            add(.warning, A_PLUG, L("Plugin solo sul server: %@ %@", p.name, p.version), L("Qualcuno l'ha installato in produzione: portalo in locale prima di sovrascrivere il database."))
        }
        let la = Set(local.activePlugins), ra = Set(remote.activePlugins)
        for f in la.subtracting(ra).sorted() where !remote.activePlugins.isEmpty || !local.activePlugins.isEmpty {
            add(.info, A_PLUG, L("Attivo in locale ma non sul server: %@", f))
        }
        for f in ra.subtracting(la).sorted() { add(.info, A_PLUG, L("Attivo sul server ma non in locale: %@", f)) }
        if let ls = local.stylesheet, let rs = remote.stylesheet, ls != rs {
            add(.warning, A_PLUG, L("Tema attivo diverso: locale %@, server %@", ls, rs))
        }
        for t in local.themes where !t.requiresPHP.isEmpty && Version.compare(remote.php, t.requiresPHP) == .orderedAscending {
            add(.error, A_PLUG, L("Il tema %@ richiede PHP %@, il server ha %@", t.name, t.requiresPHP, remote.php))
        }

        // Database
        if let e = local.dbError { add(.error, A_DB, L("Database locale non raggiungibile"), e + " — " + L("MAMP è acceso?")) }
        if let e = remote.dbError { add(.error, A_DB, L("Database del server non raggiungibile"), e) }
        if let l = local.dbServer, let r = remote.dbServer {
            let lf = Version.dbFlavor(l), rf = Version.dbFlavor(r)
            if lf != rf || Version.minor(l) != Version.minor(r) {
                add(.info, A_DB, L("Database diversi: locale %@ %@, server %@ %@", lf, Version.minor(l), rf, Version.minor(r)),
                    L("Mirrorpress converte le collation incompatibili (utf8mb4_0900, uca1400) durante il trasferimento."))
            }
        }
        let bad = local.collations.keys.filter { $0.contains("0900") }
        if !bad.isEmpty, let r = remote.dbServer, Version.dbFlavor(r) == "MariaDB" || Version.compare(r, "8.0") == .orderedAscending {
            add(.info, A_DB, L("Tabelle locali con collation MySQL 8 (%@)", bad.joined(separator: ", ")), L("Il server non le conosce: vengono convertite in utf8mb4_unicode_520_ci al momento del trasferimento."))
        }
        if !local.dbPrefix.isEmpty, !remote.dbPrefix.isEmpty, local.dbPrefix != remote.dbPrefix {
            add(.info, A_DB, L("Prefisso tabelle diverso: locale %@, server %@", local.dbPrefix, remote.dbPrefix), L("Gestito in automatico (anche ruoli e permessi utente)."))
        }
        // Contenuti più recenti sul server: sovrascrivere il DB li cancellerebbe.
        for (type, r) in remote.posts.sorted(by: { $0.key < $1.key }) where type != "revision" {
            let l = local.posts[type]
            // Date GMT "AAAA-MM-GG hh:mm:ss": il confronto tra stringhe basta.
            if let rm = r.modified, rm > (l?.modified ?? "") {
                add(.warning, A_DB, L("Contenuti «%@» più recenti sul server", type),
                    L("Server: %d, ultimo aggiornamento %@ — locale: %d, %@. Se invii il database li perdi: prima scaricali.", r.count, rm, l?.count ?? 0, l?.modified ?? "—"))
            }
        }
        if let rc = remote.comments, rc.count > (local.comments?.count ?? 0) {
            add(.warning, A_DB, L("Sul server ci sono commenti che in locale mancano (%d contro %d)", rc.count, local.comments?.count ?? 0))
        }
        if let ru = remote.users, ru.count > (local.users?.count ?? 0) {
            add(.warning, A_DB, L("Sul server ci sono utenti che in locale mancano (%d contro %d)", ru.count, local.users?.count ?? 0))
        }
        for t in tables where t.rowsOnlyRemote > 0 {
            add(.warning, A_DB, L("Tabella %@: %d righe solo sul server", t.key, t.rowsOnlyRemote), L("Esempi: ordini, iscrizioni, messaggi dei moduli. Inviare il database le cancellerebbe."))
        }
        for t in tables where t.status == .onlyRemote {
            add(.info, A_DB, L("Tabella solo sul server: %@", t.key), L("Non viene toccata dal trasferimento del database."))
        }

        // File
        let onlyRemoteCode = files.filter { $0.status == .onlyRemote && ($0.path.hasPrefix("wp-content/plugins/") || $0.path.hasPrefix("wp-content/themes/")) }
        if !onlyRemoteCode.isEmpty {
            add(.warning, A_FILE, L("%d file di plugin/temi esistono solo sul server", onlyRemoteCode.count), L("Modifiche fatte direttamente in produzione?"))
        }
        let suspicious = files.filter { f in
            f.status == .onlyRemote && f.path.hasSuffix(".php") && (f.path.hasPrefix("wp-content/uploads/") || f.path.hasPrefix("wp-includes/") || f.path.hasPrefix("wp-admin/"))
        }
        if !suspicious.isEmpty {
            add(.error, A_FILE, L("%d file PHP sospetti sul server", suspicious.count),
                L("File PHP che in locale non esistono dentro uploads/wp-includes/wp-admin: possibile malware. Primo: %@", suspicious[0].path))
        }
        let uploadsRemote = files.filter { $0.status == .onlyRemote && $0.path.hasPrefix("wp-content/uploads/") && !$0.path.hasSuffix(".php") }
        if !uploadsRemote.isEmpty {
            add(.warning, A_FILE, L("%d media caricati sul server e assenti in locale", uploadsRemote.count), L("Scaricali per avere il locale allineato."))
        }
        for (l, r) in caseConflicts.prefix(20) {
            add(.warning, A_FILE, L("Maiuscole/minuscole diverse: %@ ↔ %@", l, r), L("Su Mac sono lo stesso file, sul server Linux no: i link possono rompersi."))
        }
        for f in files where f.sensitive && f.status == .changed {
            add(.info, A_FILE, L("%@ è diverso tra locale e server", f.path), L("Non viene mai inviato in automatico: controllalo a mano."))
        }
        let junk = files.filter { $0.status == .onlyLocal && Compare.isJunk($0.path) }
        for f in junk.prefix(10) {
            add(.warning, A_FILE, L("File da non pubblicare: %@", f.path), L("Dump e archivi nella cartella del sito sono scaricabili da chiunque: aggiungili alle esclusioni."))
        }
        return out.sorted { $0.severity == $1.severity ? $0.area < $1.area : $0.severity > $1.severity }
    }

    static func normalizedURL(_ s: String) -> String {
        var u = s.lowercased().trimmingCharacters(in: .whitespaces)
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }
}
