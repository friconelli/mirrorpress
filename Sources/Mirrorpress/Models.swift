import Foundation

/// Come si raggiunge il server per installare il ponte. Tutto il resto passa dal ponte via HTTPS.
enum ConnectionKind: String, Codable, CaseIterable, Identifiable {
    case sftp, ftps, ftp, manual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sftp: return "SFTP (SSH)"
        case .ftps: return L("FTPS (TLS obbligatorio; porta 990 = implicito)")
        case .ftp: return L("FTP (TLS se disponibile)")
        case .manual: return L("Manuale (carico io il ponte)")
        }
    }
    var defaultPort: Int {
        switch self {
        case .sftp: return 22
        default: return 21
        }
    }
}

/// Profilo di un sito: lato locale (cartella + database MAMP) e lato remoto (hosting).
struct SiteProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""

    // Locale
    var localPath = ""
    var localURL = ""          // vuoto = letto da siteurl nel database locale

    // Remoto
    var remoteURL = ""         // indirizzo pubblico del sito (dove risponde la cartella remota)
    var connection: ConnectionKind = .sftp
    var host = ""
    var port = 22
    var username = ""
    var remotePath = ""        // cartella del sito sul server, come la vede l'FTP/SFTP
    var allowInvalidCertificates = false
    var httpAuthUser = ""      // se il sito è protetto da password (es. staging)

    // Database non WordPress o con wp-config particolare (vuoto = letto da wp-config.php)
    var localDBOverride = DBOverride()
    var remoteDBOverride = DBOverride()

    // Confronto
    var excludes: [String] = SiteProfile.defaultExcludes
    var compareContent = true  // MD5 dei file con la stessa dimensione
    var notes = ""

    static let defaultExcludes = [
        ".DS_Store", ".git", ".svn", ".idea", ".vscode", "node_modules", "Thumbs.db",
        "_da_eliminare", ".well-known", "cgi-bin", "error_log", "*.log",
        "wp-content/cache", "wp-content/upgrade", "wp-content/upgrade-temp-backup",
        "wp-content/ai1wm-backups", "wp-content/updraft", "wp-content/backups-dup-lite",
        "wp-content/wflogs", "wp-content/et-cache", "wp-content/litespeed",
    ]

    /// File da non sovrascrivere mai senza volerlo: mostrati nel confronto ma non selezionati.
    static let sensitiveFiles: Set<String> = [
        "wp-config.php", ".htaccess", ".user.ini", "php.ini", "web.config", "robots.txt", ".env",
    ]

    var bridgeBaseURL: URL? {
        let s = remoteURL.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        return URL(string: s.hasSuffix("/") ? s : s + "/")
    }

    var keychainAccount: String { id.uuidString }
}

struct DBOverride: Codable, Hashable {
    var name = ""
    var user = ""
    var host = ""
    var prefix = ""
    var isEmpty: Bool { name.isEmpty && user.isEmpty && host.isEmpty && prefix.isEmpty }
}

// MARK: - Risultati del confronto

struct FileEntry: Hashable {
    let size: Int64
    let mtime: Int64
}

enum FileStatus: String, CaseIterable, Identifiable {
    case onlyLocal, onlyRemote, changed, same, unknown
    var id: String { rawValue }
    var label: String {
        switch self {
        case .onlyLocal: return L("Solo in locale")
        case .onlyRemote: return L("Solo sul server")
        case .changed: return L("Diversi")
        case .same: return L("Uguali")
        case .unknown: return L("Da verificare")
        }
    }
}

struct FileDiff: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let local: FileEntry?
    let remote: FileEntry?
    var status: FileStatus
    var sensitive: Bool

    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
    /// Quale lato è stato modificato più di recente (indicativo: l'FTP cambia le date).
    var newerSide: Side? {
        guard let l = local, let r = remote, abs(l.mtime - r.mtime) > 2 else { return nil }
        return l.mtime > r.mtime ? .local : .remote
    }
}

enum Side: String { case local, remote
    var label: String { self == .local ? L("Locale") : L("Server") }
}

enum TableStatus: String {
    case same, changed, onlyLocal, onlyRemote, unknown
    var label: String {
        switch self {
        case .same: return L("Uguale")
        case .changed: return L("Diversa")
        case .onlyLocal: return L("Solo in locale")
        case .onlyRemote: return L("Solo sul server")
        case .unknown: return L("Non confrontata")
        }
    }
}

struct TableInfo: Hashable {
    let name: String
    let rows: Int?
    let size: Int64
    let hash: String?
    let collation: String
    let engine: String
    let rowHashes: [String: String]?
}

struct TableDiff: Identifiable, Hashable {
    var id: String { key }
    let key: String           // nome senza prefisso
    let local: TableInfo?
    let remote: TableInfo?
    var status: TableStatus
    var rowsChanged = 0
    var rowsOnlyLocal = 0
    var rowsOnlyRemote = 0
    var keysChanged: [String] = []
    var keysOnlyLocal: [String] = []
    var keysOnlyRemote: [String] = []
}

enum Severity: Int, Comparable {
    case info = 0, warning = 1, error = 2
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

struct Issue: Identifiable, Hashable {
    let id = UUID()
    let severity: Severity
    let area: String
    let title: String
    let detail: String
}

struct LogLine: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
    let kind: Kind
    /// Cosa fare per risolvere (mostrato sotto il messaggio).
    var hint: String? = nil
    /// Dati tecnici: comandi, indirizzi, risposte del server (in un riquadro espandibile).
    var detail: String? = nil
    enum Kind { case info, success, warning, error }

    /// Versione testuale, per «Copia log».
    var plain: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let mark: String
        switch kind { case .info: mark = "·"; case .success: mark = "OK"; case .warning: mark = "!"; case .error: mark = "ERRORE" }
        var s = "[\(f.string(from: date))] \(mark) \(text)"
        if let hint, !hint.isEmpty { s += "\n    → " + hint }
        if let detail, !detail.isEmpty {
            s += "\n" + detail.split(separator: "\n", omittingEmptySubsequences: false).map { "      " + $0 }.joined(separator: "\n")
        }
        return s
    }
}
