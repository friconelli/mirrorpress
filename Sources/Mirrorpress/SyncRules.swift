import Foundation

/// Le aree di un sito WordPress, ognuna con la sua regola di sincronizzazione.
/// È la «guida» dell'app: dice cosa di solito va dal Mac al server, cosa al contrario e cosa mai.
enum SyncArea: String, CaseIterable, Identifiable {
    case code, media, core, other, generated, protected
    var id: String { rawValue }

    var title: String {
        switch self {
        case .code: return L("Tema e plugin")
        case .media: return L("Media caricati")
        case .core: return L("WordPress (core)")
        case .other: return L("Altri file")
        case .generated: return L("Cache e file generati")
        case .protected: return L("Da non sincronizzare")
        }
    }

    var symbol: String {
        switch self {
        case .code: return "paintbrush.pointed"
        case .media: return "photo.on.rectangle"
        case .core: return "w.circle"
        case .other: return "folder"
        case .generated: return "arrow.triangle.2.circlepath"
        case .protected: return "lock"
        }
    }

    /// La regola in una frase, mostrata sotto il titolo dell'area.
    var rule: String {
        switch self {
        case .code:
            return L("Il codice lo scrivi in locale: di solito Push ↑ verso il server. Se qualcuno aggiorna i plugin dal pannello del sito, prima fai Pull ↓.")
        case .media:
            return L("Immagini e PDF li caricano sul sito: di solito Pull ↓ per averli anche sul Mac. Push ↑ solo per i media che hai aggiunto tu in locale.")
        case .core:
            return L("Sono i file di WordPress. Meglio aggiornare WordPress dal pannello su entrambi i lati: sincronizzali solo se le versioni coincidono.")
        case .other:
            return L("File fuori da WordPress (verifiche Google, pagine statiche, script): decidi caso per caso.")
        case .generated:
            return L("Cache, log e file che i plugin ricreano da soli: non serve sincronizzarli, si rigenerano.")
        case .protected:
            return L("Hanno impostazioni diverse tra Mac e server (accesso al database, indirizzi, regole del server, cache dell'hosting): non vanno mai copiati in blocco.")
        }
    }

    /// Direzione consigliata (nil = nessuna).
    var suggested: Side? {
        switch self {
        case .code: return .remote
        case .media: return .local
        default: return nil
        }
    }

    /// Le aree in cui si può fare Push/Pull di gruppo.
    var bulkAllowed: Bool { self != .protected && self != .generated }
}

enum SyncRules {
    /// Perché un file non va sincronizzato (nil = si può).
    static func protectedReason(_ path: String) -> String? {
        let p = path.lowercased()
        let name = (p as NSString).lastPathComponent
        switch p {
        case "wp-config.php": return L("Contiene utente e password del database e le chiavi di sicurezza: sul Mac e sul server sono diversi.")
        case ".htaccess": return L("Regole del server web (redirect, https, cache, protezioni dell'hosting): ogni ambiente ha le sue.")
        case ".user.ini", "php.ini": return L("Impostazioni PHP dell'hosting (memoria, limiti di upload).")
        case "web.config": return L("Regole del server Windows/IIS.")
        case ".env": return L("Variabili e password dell'ambiente.")
        case "robots.txt": return L("Spesso il locale o lo staging bloccano i motori di ricerca: copiarlo in produzione può togliere il sito da Google.")
        case ".maintenance": return L("File temporaneo di WordPress durante gli aggiornamenti: copiarlo mette il sito in manutenzione.")
        case "wp-content/advanced-cache.php", "wp-content/object-cache.php":
            return L("Creato dal plugin di cache in base al server (Redis, Memcached, percorsi): diverso su ogni hosting.")
        case "wp-content/db.php": return L("Sostituisce il collegamento al database (plugin di cache o dell'hosting).")
        case "wp-content/debug.log": return L("Log degli errori di quell'ambiente.")
        default: break
        }
        if p.hasPrefix("wp-content/mu-plugins/") {
            let hosting = ["wpengine", "wpe-", "kinsta", "sg-", "siteground", "endurance", "bluehost", "flywheel", "pantheon", "aruba",
                           "godaddy", "gd-system", "pressable", "cloudways", "breeze", "imunify", "wp-cache-memcached", "pagely", "wpcomsh"]
            if hosting.contains(where: { p.contains($0) }) {
                return L("Plugin installato dall'hosting: esiste solo lì e non va copiato altrove.")
            }
        }
        if Compare.isJunk(path) {
            return L("Backup o archivio: in una cartella pubblica è scaricabile da chiunque, non pubblicarlo.")
        }
        if name == ".ds_store" || name == "thumbs.db" { return L("File di sistema del Mac/Windows.") }
        return nil
    }

    static func isGenerated(_ path: String) -> Bool {
        let p = path.lowercased()
        let prefixes = ["wp-content/uploads/elementor/css/", "wp-content/uploads/elementor/screenshots/", "wp-content/uploads/cache/",
                        "wp-content/uploads/wc-logs/", "wp-content/uploads/wpo-cache/", "wp-content/uploads/siteground-optimizer-assets/",
                        "wp-content/uploads/fusion-styles/", "wp-content/uploads/bb-plugin/cache/", "wp-content/uploads/et-cache/",
                        "wp-content/uploads/oxygen/css/", "wp-content/uploads/wpcf7_uploads/", "wp-content/uploads/wpforms/cache/",
                        "wp-content/uploads/sucuri/", "wp-content/uploads/wp-file-manager-pro/", "wp-content/uploads/autoptimize/",
                        "wp-content/uploads/wphb-cache/", "wp-content/uploads/wp-optimize/", "wp-content/uploads/jetpack-",
                        "wp-content/cache/", "wp-content/et-cache/", "wp-content/w3tc-config/", "wp-content/wflogs/",
                        "wp-content/upgrade/", "wp-content/upgrade-temp-backup/", "wp-content/litespeed/"]
        if prefixes.contains(where: { p.hasPrefix($0) }) { return true }
        if p.hasSuffix(".log") || p.hasSuffix("/error_log") || p == "error_log" { return true }
        return false
    }

    static func area(_ path: String) -> SyncArea {
        if protectedReason(path) != nil { return .protected }
        if isGenerated(path) { return .generated }
        let p = path.lowercased()
        if p.hasPrefix("wp-content/uploads/") { return .media }
        if p.hasPrefix("wp-content/themes/") || p.hasPrefix("wp-content/plugins/") || p.hasPrefix("wp-content/mu-plugins/")
            || p.hasPrefix("wp-content/languages/") { return .code }
        if p.hasPrefix("wp-admin/") || p.hasPrefix("wp-includes/") { return .core }
        if !p.contains("/") && (p.hasPrefix("wp-") || ["index.php", "xmlrpc.php", "license.txt", "readme.html"].contains(p)) { return .core }
        if p == "wp-content/index.php" { return .core }
        return .other
    }
}

// MARK: - Albero delle differenze

/// Una cartella (o un file) dell'albero, con i conteggi di cosa c'è da inviare e da scaricare sotto di lei.
struct SyncNode: Identifiable {
    let id: String          // percorso relativo (cartelle con "/" finale)
    let name: String        // nome mostrato (catene di cartelle con un solo figlio compattate: "themes/16noni")
    let depth: Int
    let isFile: Bool
    let file: FileDiff?
    let push: [String]      // file che un Push di questo nodo invierebbe
    let pull: [String]      // file che un Pull scaricherebbe
}

enum SyncTree {
    /// Un file conta per il Push se esiste in locale ed è diverso; per il Pull se esiste sul server ed è diverso.
    static func pushable(_ f: FileDiff) -> Bool { f.local != nil && f.status != .same }
    static func pullable(_ f: FileDiff) -> Bool { f.remote != nil && f.status != .same }

    /// Righe visibili di un'area: cartelle aperte in `expanded`, catene a figlio unico compattate.
    /// Cartella comune di partenza di un gruppo di file (es. "wp-content/uploads/").
    static func commonFolder(_ files: [FileDiff]) -> String {
        guard var parts = files.first.map({ $0.folder.split(separator: "/").map(String.init) }) else { return "" }
        for f in files.dropFirst() {
            let other = f.folder.split(separator: "/").map(String.init)
            var i = 0
            while i < parts.count, i < other.count, parts[i] == other[i] { i += 1 }
            parts = Array(parts.prefix(i))
            if parts.isEmpty { break }
        }
        return parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
    }

    static func rows(_ files: [FileDiff], expanded: Set<String>) -> [SyncNode] {
        final class Dir {
            var dirs: [String: Dir] = [:]
            var files: [FileDiff] = []
            var push: [String] = []
            var pull: [String] = []
        }
        let root = Dir()
        for f in files {
            var d = root
            let parts = f.path.split(separator: "/").map(String.init)
            if pushable(f) { root.push.append(f.path) }
            if pullable(f) { root.pull.append(f.path) }
            for part in parts.dropLast() {
                let next = d.dirs[part] ?? Dir()
                d.dirs[part] = next
                d = next
                if pushable(f) { d.push.append(f.path) }
                if pullable(f) { d.pull.append(f.path) }
            }
            d.files.append(f)
        }
        var out: [SyncNode] = []
        func walk(_ d: Dir, prefix: String, depth: Int) {
            for key in d.dirs.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                var name = key, path = prefix + key + "/", node = d.dirs[key]!
                // Compatta "wp-content/themes/16noni" se ogni livello ha una sola sottocartella e nessun file.
                while node.files.isEmpty, node.dirs.count == 1, let (k, n) = node.dirs.first {
                    name += "/" + k
                    path += k + "/"
                    node = n
                }
                out.append(SyncNode(id: path, name: name, depth: depth, isFile: false, file: nil, push: node.push, pull: node.pull))
                if expanded.contains(path) { walk(node, prefix: path, depth: depth + 1) }
            }
            for f in d.files.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                out.append(SyncNode(id: f.path, name: f.name, depth: depth, isFile: true, file: f,
                                    push: pushable(f) ? [f.path] : [], pull: pullable(f) ? [f.path] : []))
            }
        }
        // L'area parte dalla cartella comune più profonda (es. wp-content/uploads/), senza mostrarla come riga.
        var start = root, prefix = ""
        while start.files.isEmpty, start.dirs.count == 1, let (k, n) = start.dirs.first {
            prefix += k + "/"
            start = n
        }
        walk(start, prefix: prefix, depth: 0)
        return out
    }
}
