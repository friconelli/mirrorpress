import Foundation

/// `Mirrorpress --import-profiles` legge da stdin un array JSON di profili (con "password" facoltativa),
/// li aggiunge o aggiorna (stessa cartella locale = stesso profilo) e salva le password nel Portachiavi.
/// Le password non passano mai dalla riga di comando né da file. Stampa solo un riepilogo ed esce.
enum ProfileImport {
    struct Entry: Decodable {
        var name: String
        var localPath: String
        var remoteURL: String
        var connection: ConnectionKind
        var host: String
        var port: Int
        var username: String
        var remotePath: String
        var allowInvalidCertificates: Bool?
        var notes: String?
        var password: String?
    }

    @MainActor
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--import-profiles") else { return }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            FileHandle.standardError.write(Data("JSON non valido\n".utf8)); exit(1)
        }
        let store = SiteStore()
        for e in entries {
            var site = store.sites.first { $0.localPath == e.localPath } ?? SiteProfile()
            let isNew = !store.sites.contains { $0.id == site.id }
            site.name = e.name
            site.localPath = e.localPath
            site.remoteURL = e.remoteURL
            site.connection = e.connection
            site.host = e.host
            site.port = e.port
            site.username = e.username
            site.remotePath = e.remotePath
            if let v = e.allowInvalidCertificates { site.allowInvalidCertificates = v }
            if let n = e.notes { site.notes = n }
            store.upsert(site)
            if let pw = e.password, !pw.isEmpty { Secret.connection.set(pw, for: site) }
            print("\(isNew ? "nuovo" : "aggiornato"): \(site.name) → \(site.connection.rawValue)://\(site.host):\(site.port)\(site.remotePath) · \(site.remoteURL)")
        }
        exit(0)
    }
}
