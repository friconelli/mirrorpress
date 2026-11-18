import Foundation
import AppKit

/// Lo stato di lavoro su un sito: connessione, analisi, trasferimenti, backup.
@MainActor
final class SiteSession: ObservableObject {
    @Published var site: SiteProfile
    @Published private(set) var busy: String?             // testo dell'operazione in corso
    @Published private(set) var progress: Double?          // 0...1 se noto
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var localInfo: SiteInfo?
    @Published private(set) var remoteInfo: SiteInfo?
    @Published var files: [FileDiff] = []
    @Published private(set) var tables: [TableDiff] = []
    @Published private(set) var issues: [Issue] = []
    @Published private(set) var analyzedAt: Date?
    @Published private(set) var backups: [JSONValue] = []
    @Published private(set) var bridgeInstalled = false
    /// In modalità manuale: il ponte da caricare a mano, in attesa di conferma.
    @Published var manualBridgeFile: URL?
    @Published var lastError: String?

    private var remote: RemoteBridge?
    /// Solo per i test: installa il ponte senza FTP/SFTP (file temporaneo, nome).
    var installHook: ((URL, String) async throws -> Void)?
    private var bridgeName: String?
    private var cancelRequested = false
    private var localTables: [TableInfo] = []
    private var remoteTables: [TableInfo] = []

    init(site: SiteProfile) { self.site = site }

    var localRoot: URL { URL(fileURLWithPath: site.localPath, isDirectory: true) }
    var localURL: String {
        let u = site.localURL.trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? (localInfo?.siteURL ?? "") : u
    }
    var remoteURL: String {
        let u = site.remoteURL.trimmingCharacters(in: .whitespaces)
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    private lazy var local: LocalBridge = makeLocal()

    private func makeLocal() -> LocalBridge {
        LocalBridge(root: localRoot, workdir: AppPaths.workdir(for: site), db: dbParams(site.localDBOverride, password: Secret.localDB.get(site)))
    }

    private func dbParams(_ o: DBOverride, password: String) -> [String: Any]? {
        if o.isEmpty { return nil }
        return ["name": o.name, "user": o.user, "pass": password, "host": o.host, "prefix": o.prefix]
    }

    func profileChanged(_ s: SiteProfile) {
        let connectionChanged = s.remoteURL != site.remoteURL || s.host != site.host || s.remotePath != site.remotePath || s.connection != site.connection
        site = s
        local = makeLocal()
        if connectionChanged { remote = nil; bridgeInstalled = false }
    }

    // MARK: - Registro

    func note(_ text: String, _ kind: LogLine.Kind = .info, hint: String? = nil, detail: String? = nil) {
        log.append(LogLine(text: text, kind: kind, hint: hint, detail: detail))
    }

    func clearLog() { log.removeAll() }

    func cancel() { cancelRequested = true }

    private func checkCancel() throws {
        if cancelRequested { throw fail(L("Operazione annullata.")) }
    }

    /// Esegue un'operazione mostrando lo stato e registrando l'esito.
    private func perform(_ title: String, _ body: () async throws -> Void) async {
        guard busy == nil else { return }
        busy = title
        progress = nil
        cancelRequested = false
        lastError = nil
        note(title + "…")
        do {
            try await body()
        } catch {
            let e = (error as? MirrorpressError) ?? describeNetworkError(error, url: nil)
            lastError = e.errorDescription
            note(e.errorDescription ?? error.localizedDescription, .error, hint: e.hint, detail: e.detail)
        }
        busy = nil
        progress = nil
    }

    private func status(_ text: String, _ p: Double? = nil) {
        busy = text
        progress = p
    }

    // MARK: - Ponte sul server

    /// Installa (o riusa) il ponte sul server e verifica che risponda.
    private func ensureRemote() async throws -> RemoteBridge {
        if let remote, bridgeInstalled {
            if (try? await remote.call("ping", [:])) != nil { return remote }
            bridgeInstalled = false
        }
        guard let base = site.bridgeBaseURL else { throw fail(L("Manca l'indirizzo del sito sul server nel profilo.")) }
        if let reason = LocalEnv.pipelineReason(for: localRoot) { throw fail(reason) }
        let token = Hashing.randomHex(32)
        let name = "mirrorpress-\(Hashing.randomHex(8)).php"
        let source = BridgeScript.personalized(token: token, expires: Date().addingTimeInterval(4 * 3600))
        guard source.contains(token) else { throw fail(L("Ponte PHP non trovato nell'app.")) }
        let tmp = AppPaths.temp().appendingPathComponent(name)
        try source.write(to: tmp, atomically: true, encoding: .utf8)

        let bridge = RemoteBridge(url: base.appendingPathComponent(name), token: token,
                                  db: dbParams(site.remoteDBOverride, password: Secret.remoteDB.get(site)),
                                  httpUser: site.httpAuthUser, httpPassword: Secret.httpAuth.get(site),
                                  allowInvalidCertificates: site.allowInvalidCertificates)
        if site.connection == .manual {
            manualBridgeFile = tmp
            remote = bridge
            bridgeName = name
            throw fail(L("Carica il file %@ nella cartella del sito sul server (con il file manager dell'hosting), poi premi «Ho caricato il ponte».", name))
        }
        let transport = Transport(site: site, password: Secret.connection.get(site))
        let localSize = Int64(source.utf8.count)
        if let installHook {
            status(L("Installo il ponte sul server…"))
            try await installHook(tmp, name)
        } else {
            // Prima di caricare: la cartella remota è davvero quella del sito?
            status(L("Controllo la cartella remota…"))
            let names = try await transport.list()
            let isWordPress = FileManager.default.fileExists(atPath: localRoot.appendingPathComponent("wp-config.php").path)
            if isWordPress && site.remoteDBOverride.isEmpty && !names.contains("wp-config.php") {
                let found = await transport.findWordPress(from: "/")
                let listing = L("Contenuto di %@: %@", transport.remoteDir, names.isEmpty ? L("(vuota)") : names.prefix(30).joined(separator: ", "))
                throw fail(L("Nella cartella remota %@ non c'è wp-config.php: non è la cartella del sito.", transport.remoteDir),
                           hint: found.isEmpty ? L("Usa «Sfoglia…» nel profilo per scegliere la cartella che contiene wp-config.php.")
                                               : L("WordPress trovato in: %@. Sceglila nel profilo con «Sfoglia…».", found.joined(separator: ", ")),
                           detail: listing)
            }
            status(L("Installo il ponte sul server…"))
            note(L("Carico %@ in %@ (%@).", name, transport.remoteDir, site.connection.label))
            try await transport.upload(tmp, as: name)
            if let size = await transport.size(of: name), size != localSize {
                throw fail(L("Il ponte caricato sul server è incompleto (%@ byte invece di %@).", String(size), String(localSize)),
                           hint: L("L'antivirus dell'hosting potrebbe averlo bloccato o svuotato, oppure lo spazio è esaurito."),
                           detail: L("File: %@%@", transport.remoteDir, name))
            }
        }
        try? FileManager.default.removeItem(at: tmp)
        remote = bridge
        bridgeName = name
        let ping: JSONValue
        do {
            ping = try await bridge.call("ping", [:])
        } catch let e as MirrorpressError {
            // Dopo un errore ricontrollo il file sul server: se è sparito o svuotato è stato l'antivirus.
            guard installHook == nil, site.connection != .manual else { throw e }
            let after = await transport.size(of: name)
            let state = after.map { L("Sul server il file del ponte ora pesa %@ byte (caricati %@).", String($0), String(localSize)) }
                ?? L("Sul server il file del ponte non c'è più (caricati %@ byte): l'antivirus dell'hosting l'ha rimosso.", String(localSize))
            if let after, after == localSize { throw e.adding(detail: state) }
            throw fail(L("L'hosting ha bloccato il ponte appena caricato."),
                       hint: L("L'antivirus o il firewall dell'hosting ha rimosso o svuotato il file. Chiedi all'assistenza di consentire il file o usa la modalità manuale."),
                       detail: [state, e.detail].compactMap { $0 }.joined(separator: "\n"))
        }
        bridgeInstalled = true
        note(L("Ponte attivo sul server (PHP %@, scade fra 4 ore).", ping["php"].string ?? "?"), .success)
        return bridge
    }

    /// Modalità manuale: l'utente ha caricato il ponte.
    func confirmManualBridge() async {
        guard let remote else { return }
        await perform(L("Verifico il ponte")) {
            _ = try await remote.call("ping", [:])
            bridgeInstalled = true
            manualBridgeFile = nil
            note(L("Ponte raggiungibile."), .success)
        }
    }

    /// Toglie il ponte dal server (si cancella da solo; se non riesce, via FTP/SFTP).
    func removeBridge() async {
        guard let remote, bridgeInstalled else { return }
        let removed = (try? await remote.call("selfdestruct", [:]))?["ok"].truthy ?? false
        if !removed, let bridgeName, site.connection != .manual {
            try? await Transport(site: site, password: Secret.connection.get(site)).delete(bridgeName)
        }
        bridgeInstalled = false
        self.remote = nil
        note(L("Ponte rimosso dal server."))
    }

    func testConnection() async {
        await perform(L("Provo la connessione")) {
            if site.connection != .manual {
                let transport = Transport(site: site, password: Secret.connection.get(site))
                let names = try await transport.list()
                note(L("Connessione riuscita: %d elementi in %@.", names.count, transport.remoteDir), .success,
                     detail: names.prefix(60).joined(separator: "\n"))
                if !names.contains("wp-config.php") && !names.contains("index.php") && !names.contains("index.html") {
                    let found = await transport.findWordPress(from: "/")
                    note(L("In %@ non c'è wp-config.php né index.php: non sembra la cartella del sito.", transport.remoteDir), .warning,
                         hint: found.isEmpty ? L("Usa «Sfoglia…» nel profilo per scegliere la cartella giusta.")
                                             : L("WordPress trovato in: %@. Sceglila nel profilo con «Sfoglia…».", found.joined(separator: ", ")))
                    return
                }
            }
            let r = try await ensureRemote()
            let info = try await r.call("ping", [:])
            note(L("Il ponte risponde da %@.", info["root"].string ?? ""), .success)
        }
    }

    // MARK: - Analisi

    func analyze() async {
        await perform(L("Analisi di %@", site.name)) {
            let remote = try await ensureRemote()
            status(L("Leggo le informazioni dei due lati…"))
            async let li = local.call("info", [:])
            async let ri = remote.call("info", [:])
            let l = SiteInfo(raw: try await li), r = SiteInfo(raw: try await ri)
            localInfo = l
            remoteInfo = r
            try checkCancel()

            // File
            status(L("Elenco i file…"))
            let excludes = ExcludeMatcher(site.excludes)
            let manifestFile = AppPaths.temp().appendingPathComponent("manifest")
            async let remoteManifest: Void = remote.stream("manifest", ["exclude": site.excludes], to: manifestFile)
            let root = localRoot
            let localFiles = await Task.detached { Manifest.scanLocal(root: root, excludes: excludes) }.value
            try await remoteManifest
            let parsed = try Manifest.parseRemote(try Data(contentsOf: manifestFile))
            for u in parsed.unreadable { note(L("Cartella non leggibile sul server: %@", u), .warning) }
            var diffs = Compare.files(local: localFiles, remote: parsed.files, compareContent: site.compareContent)
            let conflicts = Compare.caseConflicts(local: localFiles, remote: parsed.files)
            note(L("File: %d in locale, %d sul server.", localFiles.count, parsed.files.count))
            try checkCancel()

            // Contenuto dei file con la stessa dimensione
            let toHash = diffs.filter { $0.status == .unknown }.map(\.path)
            if !toHash.isEmpty {
                var remoteHashes: [String: String] = [:]
                var localHashes: [String: String] = [:]
                let lroot = localRoot
                let localTask = Task.detached { () -> [String: String] in
                    var out: [String: String] = [:]
                    for p in toHash { out[p] = Hashing.md5(file: lroot.appendingPathComponent(p)) ?? "" }
                    return out
                }
                var i = 0
                while i < toHash.count {
                    try checkCancel()
                    status(L("Confronto il contenuto dei file… %d/%d", i, toHash.count), Double(i) / Double(toHash.count))
                    let batch = Array(toHash[i..<min(i + 1500, toHash.count)])
                    let res = try await remote.call("hash", ["paths": batch])
                    for (k, v) in res["hashes"].object { remoteHashes[k] = v.string ?? "" }
                    i += max(1, res["done"].int ?? batch.count)
                }
                localHashes = await localTask.value
                Compare.applyHashes(&diffs, local: localHashes, remote: remoteHashes)
            }
            files = diffs

            // Database
            var tdiffs: [TableDiff] = []
            if l.hasDB && r.hasDB {
                status(L("Confronto il database…"))
                let lp = Compare.normalizePairs(url: localURL, root: l.root, prefix: l.dbPrefix)
                let rp = Compare.normalizePairs(url: remoteURL.isEmpty ? (r.siteURL ?? "") : remoteURL, root: r.root, prefix: r.dbPrefix)
                async let lt = tablesAll(local, normalize: lp)
                async let rt = tablesAll(remote, normalize: rp)
                localTables = try await lt
                remoteTables = try await rt
                tdiffs = Compare.tables(local: localTables, localPrefix: l.dbPrefix, remote: remoteTables, remotePrefix: r.dbPrefix)
            }
            tables = tdiffs
            issues = Analysis.issues(local: l, remote: r, profile: site, files: diffs, tables: tdiffs, caseConflicts: conflicts)
            analyzedAt = Date()
            let changed = diffs.filter { $0.status != .same }.count
            note(L("Analisi completata: %d file diversi, %d tabelle diverse, %d segnalazioni.", changed,
                   tdiffs.filter { $0.status != .same }.count, issues.count), .success)
        }
    }

    /// db_tables a più riprese: il ponte si ferma prima dei limiti di tempo del server.
    private func tablesAll(_ b: BridgeEndpoint, normalize: [[String]]) async throws -> [TableInfo] {
        var result: [String: TableInfo] = [:]
        var pending: [String]? = nil
        repeat {
            var p: [String: Any] = ["normalize": normalize, "row_hashes": 50000, "budget": 20]
            if let pending { p["tables"] = pending }
            let r = try await b.call("db_tables", p)
            for t in Compare.tables(r) where t.hash != nil || result[t.name] == nil { result[t.name] = t }
            let next = r["pending"].array.compactMap(\.string)
            if next.isEmpty || next == pending ?? [] { pending = nil; break }
            pending = next
        } while pending != nil
        return result.values.sorted { $0.name < $1.name }
    }

    /// Righe di una tabella diversa (per mostrare quali contenuti cambiano).
    func rowDetails(_ t: TableDiff) async -> (local: [JSONValue], remote: [JSONValue]) {
        guard let remote else { return ([], []) }
        let keys = Array((t.keysChanged + t.keysOnlyLocal + t.keysOnlyRemote).prefix(300))
        let cols: [String]
        switch t.key {
        case "posts": cols = ["post_title", "post_type", "post_status", "post_modified"]
        case "postmeta": cols = ["post_id", "meta_key", "meta_value"]
        case "options": cols = ["option_name", "option_value"]
        case "users": cols = ["user_login", "user_email"]
        case "usermeta": cols = ["user_id", "meta_key"]
        case "terms": cols = ["name", "slug"]
        case "comments": cols = ["comment_author", "comment_date", "comment_content"]
        default: cols = []
        }
        var l: [JSONValue] = [], r: [JSONValue] = []
        if let lt = t.local { l = (try? await local.call("db_rows", ["table": lt.name, "columns": cols, "keys": keys]))?["rows"].array ?? [] }
        if let rt = t.remote { r = (try? await remote.call("db_rows", ["table": rt.name, "columns": cols, "keys": keys]))?["rows"].array ?? [] }
        return (l, r)
    }

    // MARK: - File

    /// Invia i file al server: staging, poi commit (con backup degli originali sul server).
    func pushFiles(_ paths: [String]) async {
        await perform(L("Invio %d file al server", paths.count)) {
            let remote = try await ensureRemote()
            let session = "s" + Hashing.randomHex(8)
            let limit = chunkLimit()
            var body = Data()
            var sent: Int64 = 0
            let entries: [(String, FileEntry)] = paths.compactMap { p in files.first { $0.path == p }?.local.map { (p, $0) } }
            let total = max(1, entries.reduce(Int64(0)) { $0 + $1.1.size })
            @MainActor func flush() async throws {
                guard !body.isEmpty else { return }
                body += Data("E\n".utf8)
                _ = try await remote.callRaw("upload", ["session": session], body: body)
                body = Data()
            }
            do {
                for (path, entry) in entries {
                    try checkCancel()
                    let url = localRoot.appendingPathComponent(path)
                    guard let fh = try? FileHandle(forReadingFrom: url) else { throw fail(L("Non riesco a leggere %@", path)) }
                    defer { try? fh.close() }
                    var offset: Int64 = 0
                    repeat {
                        let room = max(64 * 1024, limit - body.count - 1024)
                        let piece = fh.readData(ofLength: Int(min(Int64(room), entry.size - offset)))
                        body += Data("P \(offset) \(piece.count) \(entry.size) \(entry.mtime) \(path.rawURLEncoded)\n".utf8)
                        body += piece
                        offset += Int64(piece.count)
                        sent += Int64(piece.count)
                        if body.count >= limit - 1024 {
                            status(L("Invio file… %@ di %@", Format.bytes(sent), Format.bytes(total)), Double(sent) / Double(total))
                            try await flush()
                        }
                    } while offset < entry.size
                }
                try await flush()
                status(L("Metto in linea i file…"))
                let list: [[String: Any]] = entries.map { ["path": $0.0, "size": $0.1.size, "mtime": $0.1.mtime] }
                let r = try await remote.call("commit", ["session": session, "files": list, "note": L("invio di %d file", entries.count)])
                note(L("%d file aggiornati sul server. Originali salvati nel backup %@.", r["done"].array.count, r["backup"].string ?? ""), .success)
                markSynced(paths)
            } catch {
                _ = try? await remote.call("cleanup", ["session": session])
                throw error
            }
        }
    }

    /// Scarica i file dal server; quelli locali sovrascritti finiscono in un backup locale.
    func pullFiles(_ paths: [String]) async {
        await perform(L("Scarico %d file dal server", paths.count)) {
            let remote = try await ensureRemote()
            let backupDir = AppPaths.workdir(for: site).appendingPathComponent("backup-locale/\(Self.stamp())-file", isDirectory: true)
            let entries = paths.compactMap { p in files.first { $0.path == p }?.remote.map { (p, $0) } }
            let total = max(1, entries.reduce(Int64(0)) { $0 + $1.1.size })
            var done: Int64 = 0
            var batch: [String] = []
            var batchSize: Int64 = 0
            @MainActor func flush() async throws {
                guard !batch.isEmpty else { return }
                let tmp = AppPaths.temp().appendingPathComponent("download")
                try await remote.stream("download", ["paths": batch], to: tmp)
                try DownloadReader.extract(tmp, into: localRoot, backupDir: backupDir) { _, size in done += size }
                try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
                status(L("Scarico file… %@ di %@", Format.bytes(done), Format.bytes(total)), Double(done) / Double(total))
                batch = []
                batchSize = 0
            }
            for (p, e) in entries {
                try checkCancel()
                batch.append(p)
                batchSize += e.size
                if batchSize > 48 << 20 || batch.count >= 400 { try await flush() }
            }
            try await flush()
            let saved = (try? FileManager.default.contentsOfDirectory(atPath: backupDir.path))?.isEmpty == false
            note(L("%d file scaricati in locale.", entries.count) + (saved ? " " + L("Le versioni locali sostituite sono in %@.", backupDir.path) : ""), .success)
            markSynced(paths)
        }
    }

    /// "Elimina" sul server: sposta in _da_eliminare nella cartella di lavoro di Mirrorpress.
    func trashRemote(_ paths: [String]) async {
        await perform(L("Sposto %d file del server in _da_eliminare", paths.count)) {
            let remote = try await ensureRemote()
            let r = try await remote.call("trash", ["paths": paths])
            note(L("%d file spostati in %@ sul server (da cancellare a mano quando vuoi).", r["moved"].array.count, r["folder"].string ?? "_da_eliminare"), .success)
            files.removeAll { paths.contains($0.path) && $0.status == .onlyRemote }
        }
    }

    /// "Elimina" in locale: nel Cestino del Mac.
    func trashLocal(_ paths: [String]) async {
        await perform(L("Sposto %d file locali nel Cestino", paths.count)) {
            for p in paths { try FileManager.default.trashItem(at: localRoot.appendingPathComponent(p), resultingItemURL: nil) }
            files.removeAll { paths.contains($0.path) && $0.status == .onlyLocal }
            note(L("%d file spostati nel Cestino.", paths.count), .success)
        }
    }

    private func markSynced(_ paths: [String]) {
        let set = Set(paths)
        for i in files.indices where set.contains(files[i].path) { files[i].status = .same }
    }

    private func chunkLimit() -> Int {
        let post = Int(remoteInfo?.postMaxSize ?? 0)
        let fromServer = post > 0 ? post - 256 * 1024 : 8 << 20
        return max(1 << 20, min(8 << 20, fromServer))
    }

    // MARK: - Database

    /// Invia il database locale al server: backup del server, import in tabelle temporanee,
    /// sostituzione degli indirizzi, scambio atomico.
    func pushDatabase(keys: [String]) async {
        await perform(L("Invio il database al server")) {
            let remote = try await ensureRemote()
            guard let l = localInfo, let r = remoteInfo else { throw fail(L("Prima fai l'analisi.")) }
            guard !remoteURL.isEmpty, !localURL.isEmpty else { throw fail(L("Mancano gli indirizzi locale e remoto.")) }
            let guardPrefix = "trv" + Hashing.randomHex(3) + "_"
            let (map, swap) = try stagingMaps(keys: keys, sourceTables: localTables, sourcePrefix: l.dbPrefix, targetPrefix: r.dbPrefix, guard: guardPrefix)

            status(L("Backup del database del server…"))
            let b = try await remote.call("backup_db", ["note": L("prima dell'invio del database da Mirrorpress")])
            note(L("Backup del server: %@ (%@).", b["backup"].string ?? "", Format.bytes(b["size"].int64)), .success)
            try checkCancel()

            status(L("Esporto il database locale…"))
            let dump = AppPaths.temp().appendingPathComponent("dump.sql")
            try await local.stream("db_dump", ["map": map, "raw": true], to: dump)
            do {
                try await sendDump(dump, to: remote, guard: guardPrefix)
                try checkCancel()
                status(L("Aggiorno indirizzi e percorsi…"))
                let pairs = Compare.replacePairs(fromURL: localURL, toURL: remoteURL, fromRoot: l.root, toRoot: r.root)
                let rr = try await remote.call("db_replace", ["tables": Array(map.values), "pairs": pairs])
                note(L("Indirizzi aggiornati in %d righe.", rr["changed"].int ?? 0))
                status(L("Scambio le tabelle…"))
                let s = try await remote.call("db_swap", ["map": swap, "prefix_from": l.dbPrefix, "prefix_to": r.dbPrefix, "flush_rewrite": true])
                note(L("Database del server aggiornato: %d tabelle.", s["swapped"].int ?? 0), .success)
            } catch {
                _ = try? await remote.call("cleanup", ["guard": guardPrefix])
                throw error
            }
            try? FileManager.default.removeItem(at: dump.deletingLastPathComponent())
            markTablesSynced(keys)
        }
    }

    /// Scarica il database del server in locale (con backup del database locale).
    func pullDatabase(keys: [String]) async {
        await perform(L("Scarico il database dal server")) {
            let remote = try await ensureRemote()
            guard let l = localInfo, let r = remoteInfo else { throw fail(L("Prima fai l'analisi.")) }
            guard !remoteURL.isEmpty, !localURL.isEmpty else { throw fail(L("Mancano gli indirizzi locale e remoto.")) }
            let guardPrefix = "trv" + Hashing.randomHex(3) + "_"
            let (map, swap) = try stagingMaps(keys: keys, sourceTables: remoteTables, sourcePrefix: r.dbPrefix, targetPrefix: l.dbPrefix, guard: guardPrefix)

            status(L("Backup del database locale…"))
            let b = try await local.call("backup_db", ["note": L("prima di scaricare il database dal server")])
            note(L("Backup locale: %@.", b["backup"].string ?? ""), .success)

            status(L("Scarico il database del server…"))
            let dump = AppPaths.temp().appendingPathComponent("dump.sql.gz")
            try await remote.stream("db_dump", ["map": map], to: dump)
            do {
                status(L("Importo in locale…"))
                _ = try await local.callRaw("db_import", ["guard": guardPrefix, "file": dump.path], body: Data())
                let pairs = Compare.replacePairs(fromURL: remoteURL, toURL: localURL, fromRoot: r.root, toRoot: l.root)
                let rr = try await local.call("db_replace", ["tables": Array(map.values), "pairs": pairs])
                note(L("Indirizzi aggiornati in %d righe.", rr["changed"].int ?? 0))
                let s = try await local.call("db_swap", ["map": swap, "prefix_from": r.dbPrefix, "prefix_to": l.dbPrefix, "flush_rewrite": true])
                note(L("Database locale aggiornato: %d tabelle.", s["swapped"].int ?? 0), .success)
            } catch {
                _ = try? await local.call("cleanup", ["guard": guardPrefix])
                throw error
            }
            try? FileManager.default.removeItem(at: dump.deletingLastPathComponent())
            markTablesSynced(keys)
        }
    }

    /// sorgente → staging (per il dump) e staging → destinazione (per lo scambio).
    private func stagingMaps(keys: [String], sourceTables: [TableInfo], sourcePrefix: String, targetPrefix: String,
                             guard g: String) throws -> ([String: String], [String: String]) {
        var map: [String: String] = [:], swap: [String: String] = [:]
        let wanted = Set(keys)
        for t in sourceTables {
            let key = !sourcePrefix.isEmpty && t.name.hasPrefix(sourcePrefix) ? String(t.name.dropFirst(sourcePrefix.count)) : "⟨\(t.name)⟩"
            guard wanted.contains(key) else { continue }
            let target = key.hasPrefix("⟨") ? t.name : targetPrefix + key
            let staging = g + target
            guard staging.count <= 64 else { throw fail(L("Nome tabella troppo lungo per il trasferimento: %@", t.name)) }
            map[t.name] = staging
            swap[staging] = target
        }
        guard !map.isEmpty else { throw fail(L("Nessuna tabella selezionata.")) }
        return (map, swap)
    }

    /// Spezza il dump (un'istruzione per riga) in pacchetti compressi e li esegue sul server.
    private func sendDump(_ file: URL, to remote: RemoteBridge, guard g: String) async throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        let reader = try LineReader(url: file)
        let target = min(6 << 20, max(1 << 20, chunkLimit() * 3))  // SQL compresso ~ 1/4
        var chunk = Data()
        var read: Int64 = 0
        var sawEnd = false
        @MainActor func flush() async throws {
            guard !chunk.isEmpty else { return }
            let z = try Gzip.deflate(chunk)
            _ = try await remote.callRaw("db_import", ["guard": g, "z": "deflate"], body: z)
            chunk = Data()
        }
        while let line = reader.nextLine() {
            try checkCancel()
            read += Int64(line.count)
            if line.starts(with: Data("-- MIRRORPRESS-END".utf8)) { sawEnd = true }
            chunk += line
            if chunk.count >= target {
                status(L("Invio il database… %@ di %@", Format.bytes(read), Format.bytes(size)), size > 0 ? Double(read) / Double(size) : nil)
                try await flush()
            }
        }
        try await flush()
        guard sawEnd else { throw fail(L("Il dump locale è incompleto: niente è stato cambiato sul server.")) }
    }

    private func markTablesSynced(_ keys: [String]) {
        let set = Set(keys)
        tables = tables.map { t in
            var t = t
            if set.contains(t.key) { t.status = .same; t.rowsChanged = 0; t.rowsOnlyLocal = 0; t.rowsOnlyRemote = 0 }
            return t
        }
    }

    // MARK: - Backup

    func loadBackups() async {
        await perform(L("Leggo i backup del server")) {
            let remote = try await ensureRemote()
            let r = try await remote.call("backups", [:])
            backups = r["backups"].array
            note(L("%d backup sul server in %@.", backups.count, r["workdir"].string ?? ""))
        }
    }

    func restoreBackup(_ id: String) async {
        await perform(L("Ripristino il backup %@", id)) {
            let remote = try await ensureRemote()
            let r = try await remote.call("restore", ["id": id])
            note(L("Backup %@ ripristinato.", id), .success)
            _ = r
        }
    }

    /// Scarica un backup del database del server nella cartella dell'app.
    func downloadBackup(_ id: String) async {
        await perform(L("Scarico il backup %@", id)) {
            let remote = try await ensureRemote()
            let dest = AppPaths.downloads(for: site).appendingPathComponent("\(id).sql.gz")
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            let out = try FileHandle(forWritingTo: dest)
            defer { try? out.close() }
            var offset = 0
            let part = AppPaths.temp().appendingPathComponent("part")
            while true {
                try checkCancel()
                try await remote.stream("fetch", ["path": "backups/\(id)/db.sql.gz", "offset": offset, "length": 8 << 20], to: part)
                let d = try Data(contentsOf: part)
                out.write(d)
                offset += d.count
                status(L("Scarico il backup… %@", Format.bytes(Int64(offset))))
                if d.count < 8 << 20 { break }
            }
            note(L("Backup salvato in %@.", dest.path), .success)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        }
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

// MARK: - Lettori di file

/// Legge un file riga per riga (righe anche lunghe) o a blocchi, senza caricarlo tutto in memoria.
final class LineReader {
    private let fh: FileHandle
    private var buffer = Data()
    private var pos = 0
    private var eof = false

    init(url: URL) throws { fh = try FileHandle(forReadingFrom: url) }
    deinit { try? fh.close() }

    private func fill(_ minBytes: Int = 1 << 20) -> Bool {
        if eof { return false }
        if pos > 0 { buffer.removeSubrange(0..<pos); pos = 0 }
        let more = fh.readData(ofLength: max(1 << 20, minBytes))
        if more.isEmpty { eof = true; return false }
        buffer.append(more)
        return true
    }

    /// La riga compreso il "\n" finale.
    func nextLine() -> Data? {
        var scanned = 0  // byte dopo pos già controllati, senza "\n"
        while true {
            if let nl = buffer[(pos + scanned)...].firstIndex(of: 0x0a) {
                let line = buffer.subdata(in: pos..<(nl + 1))
                pos = nl + 1
                return line
            }
            scanned = buffer.count - pos
            if !fill() {
                if pos >= buffer.count { return nil }
                let rest = buffer.subdata(in: pos..<buffer.count)
                pos = buffer.count
                return rest
            }
        }
    }

    /// Fino a n byte (meno solo a fine file).
    func read(_ n: Int) -> Data {
        while buffer.count - pos < n && fill(n - (buffer.count - pos)) {}
        let end = min(buffer.count, pos + n)
        let out = buffer.subdata(in: pos..<end)
        pos = end
        return out
    }
}

enum DownloadReader {
    /// Estrae il flusso del ponte ("F dimensione mtime percorso\n" + byte, … "E\n") nella cartella locale.
    /// Ogni file è scritto accanto con un nome temporaneo e poi rinominato; l'originale va in backupDir.
    static func extract(_ file: URL, into root: URL, backupDir: URL, onFile: (String, Int64) -> Void) throws {
        let reader = try LineReader(url: file)
        let fm = FileManager.default
        var ended = false
        while let raw = reader.nextLine() {
            let line = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .newlines)
            if line == "E" { ended = true; break }
            if line.hasPrefix("M ") { continue } // sparito sul server nel frattempo
            let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard parts.count == 4, parts[0] == "F", let size = Int(parts[1]), let mtime = TimeInterval(parts[2]),
                  let rel = parts[3].removingPercentEncoding,
                  !rel.split(separator: "/").contains(".."), !rel.hasPrefix("/") else {
                throw fail(L("Download dal server non valido."))
            }
            let dest = root.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).mirrorpress-tmp")
            fm.createFile(atPath: tmp.path, contents: nil)
            let out = try FileHandle(forWritingTo: tmp)
            var left = size
            while left > 0 {
                let piece = reader.read(min(left, 4 << 20))
                if piece.isEmpty { break }
                out.write(piece)
                left -= piece.count
            }
            try out.close()
            guard left == 0 else { try? fm.removeItem(at: tmp); throw fail(L("Download interrotto: riprova.")) }
            if fm.fileExists(atPath: dest.path) {
                let b = backupDir.appendingPathComponent(rel)
                try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: b)
                try fm.copyItem(at: dest, to: b)
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: tmp, to: dest)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: dest.path)
            onFile(rel, Int64(size))
        }
        guard ended else { throw fail(L("Download incompleto: riprova.")) }
    }
}
