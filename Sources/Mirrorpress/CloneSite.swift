import Foundation

/// Creazione di una copia completa del sito dall'altra parte:
/// - dal server al Mac: cartella in MAMP, database nuovo, wp-config e .htaccess per MAMP, poi file e database;
/// - dal Mac al server: wp-config (database dell'hosting) e .htaccess nella cartella vuota, poi file e database.
/// Ogni passo usa le stesse operazioni (con backup) del resto dell'app.
extension SiteSession {
    enum CloneStep: String, CaseIterable, Identifiable {
        case prepare, analyze, files, database, verify
        var id: String { rawValue }
        var title: String {
            switch self {
            case .prepare: return L("Preparo wp-config.php, .htaccess e il database")
            case .analyze: return L("Leggo i due lati")
            case .files: return L("Copio i file")
            case .database: return L("Copio il database e aggiorno gli indirizzi")
            case .verify: return L("Controllo finale")
            }
        }
    }

    static let mampMySQL = "/Applications/MAMP/Library/bin/mysql80/bin/mysql"

    /// MySQL di MAMP da riga di comando (password via variabile d'ambiente, non sulla riga di comando).
    private func mamp(_ sql: String) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.mampMySQL) else {
            throw fail(L("Non trovo MySQL di MAMP."), hint: L("Avvia MAMP (o installalo) e riprova."))
        }
        let r = try await Shell.run(Self.mampMySQL, ["-uroot", "-h127.0.0.1", "-P8889", "-N", "-B", "-e", sql], env: ["MYSQL_PWD": "root"])
        guard r.ok else {
            throw fail(L("MySQL di MAMP ha dato un errore."), hint: L("Controlla che MAMP sia avviato."), detail: r.stderr)
        }
        return r.text
    }

    // MARK: Dal server al Mac

    /// Passo 1 della copia locale: cartella, database MAMP, wp-config.php e .htaccess riscritti.
    func prepareLocalClone(dbName: String) async {
        await perform(L("Preparo la copia sul Mac")) {
            let fm = FileManager.default
            let db = SiteCloner.slug(dbName)
            guard !db.isEmpty else { throw fail(L("Scegli un nome per il database locale.")) }
            if fm.fileExists(atPath: localRoot.appendingPathComponent("wp-config.php").path) {
                throw fail(L("Nella cartella %@ c'è già un sito.", localRoot.path), hint: L("Per allinearlo usa Push/Pull o il mirroring guidato."))
            }
            if let items = try? fm.contentsOfDirectory(atPath: localRoot.path), items.contains(where: { !$0.hasPrefix(".") }) {
                throw fail(L("La cartella %@ non è vuota.", localRoot.path), hint: L("Scegli nel profilo una cartella nuova o vuota."))
            }
            // Database: nuovo, oppure già esistente ma vuoto.
            let exists = try await mamp("SHOW DATABASES LIKE '\(db)'").trimmingCharacters(in: .whitespacesAndNewlines) == db
            if exists {
                let n = Int(try await mamp("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '\(db)'").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                if n > 0 { throw fail(L("Il database locale «%@» esiste già e contiene %d tabelle.", db, n), hint: L("Scegli un altro nome: Mirrorpress non sovrascrive database esistenti.")) }
            } else {
                _ = try await mamp("CREATE DATABASE `\(db)` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci")
                note(L("Database locale «%@» creato in MAMP.", db), .success)
            }

            // wp-config.php e .htaccess del server, riscritti per MAMP.
            let remote = try await ensureRemote()
            let tmp = AppPaths.temp()
            let dl = tmp.appendingPathComponent("download")
            try await remote.stream("download", ["paths": ["wp-config.php", ".htaccess"]], to: dl)
            let staging = tmp.appendingPathComponent("files", isDirectory: true)
            try DownloadReader.extract(dl, into: staging, backupDir: tmp.appendingPathComponent("b")) { _, _ in }
            guard let config = try? String(contentsOf: staging.appendingPathComponent("wp-config.php"), encoding: .utf8) else {
                throw fail(L("Non riesco a leggere wp-config.php dal server."))
            }
            let htaccess = try? String(contentsOf: staging.appendingPathComponent(".htaccess"), encoding: .utf8)
            let url = localURLForClone
            if site.localURL.trimmingCharacters(in: .whitespaces).isEmpty { site.localURL = url }   // il database locale è ancora vuoto
            let (newConfig, notes) = SiteCloner.rewriteWPConfig(config, db: DBCredentials(name: db, user: "root", password: "root", host: "localhost"),
                                                                url: url, toLocal: true)
            try fm.createDirectory(at: localRoot, withIntermediateDirectories: true)
            try newConfig.write(to: localRoot.appendingPathComponent("wp-config.php"), atomically: true, encoding: .utf8)
            try SiteCloner.rewriteHtaccess(htaccess, url: url, toLocal: true).write(to: localRoot.appendingPathComponent(".htaccess"), atomically: true, encoding: .utf8)
            try? fm.removeItem(at: tmp)
            local = LocalBridge(root: localRoot, workdir: AppPaths.workdir(for: site), db: nil)
            note(L("wp-config.php scritto per MAMP (database «%@», utente root) e .htaccess per %@.", db, SiteCloner.base(of: url)), .success,
                 detail: (notes + [htaccess.map { L(".htaccess originale del server:\n%@", $0) } ?? ""]).joined(separator: "\n"))
        }
    }

    /// Indirizzo locale della copia: quello del profilo, oppure http://localhost:8888/<cartella>.
    var localURLForClone: String {
        let u = site.localURL.trimmingCharacters(in: .whitespaces)
        if !u.isEmpty { return u.hasSuffix("/") ? String(u.dropLast()) : u }
        let rel = localRoot.path.replacingOccurrences(of: LocalEnv.mampHtdocs.path, with: "")
        return "http://localhost:8888" + (rel.hasPrefix("/") ? rel : "/" + rel)
    }

    // MARK: Dal Mac al server

    /// Passo 1 della copia sul server: wp-config.php (database dell'hosting) e .htaccess caricati nella cartella vuota.
    func prepareRemoteClone(db: DBCredentials) async {
        await perform(L("Preparo la copia sul server")) {
            guard !db.name.isEmpty, !db.user.isEmpty, !db.host.isEmpty else {
                throw fail(L("Servono nome, utente, password e server del database dell'hosting."))
            }
            guard let config = try? String(contentsOf: localRoot.appendingPathComponent("wp-config.php"), encoding: .utf8) else {
                throw fail(L("Non trovo wp-config.php sul Mac."))
            }
            guard site.connection != .manual || installHook != nil else {
                throw fail(L("Per creare la copia serve una connessione FTP o SFTP."), hint: L("Inseriscila nel profilo del sito."))
            }
            let transport = Transport(site: site, password: Secret.connection.get(site))
            let names = installHook == nil ? try await transport.list() : []
            if names.contains("wp-config.php") {
                throw fail(L("Sul server c'è già un wp-config.php."), hint: L("C'è già un sito: per allinearlo usa Push/Pull o il mirroring guidato."))
            }
            let url = remoteURL
            let (newConfig, notes) = SiteCloner.rewriteWPConfig(config, db: db, url: url, toLocal: false)
            var cleaned = newConfig
            // In produzione niente errori a video.
            cleaned = SiteCloner.setDefine(cleaned, "WP_DEBUG", "false")
            let htaccess = try? String(contentsOf: localRoot.appendingPathComponent(".htaccess"), encoding: .utf8)
            let tmp = AppPaths.temp()
            defer { try? FileManager.default.removeItem(at: tmp) }
            let c = tmp.appendingPathComponent("wp-config.php"), h = tmp.appendingPathComponent(".htaccess")
            try cleaned.write(to: c, atomically: true, encoding: .utf8)
            try SiteCloner.rewriteHtaccess(htaccess, url: url, toLocal: false).write(to: h, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: c.path)
            status(L("Carico wp-config.php e .htaccess…"))
            if let installHook {
                try await installHook(c, "wp-config.php")
                try await installHook(h, ".htaccess")
            } else {
                try await transport.upload(c, as: "wp-config.php")
                try await transport.upload(h, as: ".htaccess")
            }
            remoteMissing = false
            note(L("wp-config.php (database «%@» su %@) e .htaccess per %@ caricati sul server.", db.name, db.host, SiteCloner.base(of: url)), .success,
                 detail: notes.joined(separator: "\n"))
        }
    }

    // MARK: Il resto della copia (uguale nei due versi)

    /// Esegue i passi dopo la preparazione e restituisce l'esito di ciascuno. `target` = lato che riceve la copia.
    func runClone(target: Side, prepare: () async -> Void, progress: (CloneStep, Bool?) -> Void) async {
        func step(_ s: CloneStep, _ body: () async -> Void) async -> Bool {
            progress(s, nil)
            lastError = nil
            await body()
            let ok = lastError == nil
            progress(s, ok)
            return ok
        }
        guard await step(.prepare, prepare) else { return }
        guard await step(.analyze, { await analyze() }) else { return }
        if target == .remote, let e = remoteInfo?.dbError {
            lastError = L("Il server non riesce ad aprire il database: %@", e)
            note(lastError!, .error, hint: L("Controlla nome, utente, password e server del database nel pannello dell'hosting, poi riprova: wp-config.php sul server va corretto a mano o cancellato."))
            progress(.database, false)
            return
        }
        let movable = files.filter { f in
            let a = SyncRules.area(f.path)
            return a != .protected && a != .generated && (target == .local ? SyncTree.pullable(f) : SyncTree.pushable(f))
        }.map(\.path)
        guard await step(.files, { if target == .local { await pullFiles(movable) } else { await pushFiles(movable) } }) else { return }
        let keys = tables.filter { target == .local ? $0.remote != nil : $0.local != nil }.map(\.key)
        guard await step(.database, {
            if keys.isEmpty { return }
            if target == .local { await pullDatabase(keys: keys) } else { await pushDatabase(keys: keys) }
        }) else { return }
        _ = await step(.verify, { await analyze() })
    }
}
