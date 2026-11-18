import Foundation

/// Una voce di una cartella remota (per «Sfoglia…»).
struct RemoteEntry: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isDir: Bool
    let size: Int64?
}

/// Serve solo a mettere e togliere il ponte sul server, a provare la connessione e a sfogliare le cartelle:
/// i trasferimenti veri passano dal ponte via HTTPS, uguali per ogni hosting.
/// Usa solo strumenti di macOS: curl per FTP/FTPS, sftp di OpenSSH per SFTP.
struct Transport {
    let site: SiteProfile
    let password: String

    var remoteDir: String { Self.normalizeDir(site.remotePath) }

    static func normalizeDir(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        if !p.hasPrefix("/") { p = "/" + p }
        if !p.hasSuffix("/") { p += "/" }
        return p
    }

    private var protocolName: String {
        switch site.connection {
        case .ftp: return "FTP"
        case .ftps: return "FTPS"
        case .sftp: return "SFTP"
        case .manual: return L("manuale")
        }
    }

    // MARK: Operazioni

    /// Elenca la cartella remota (prova di connessione): restituisce i nomi dei file.
    func list() async throws -> [String] {
        try await entries(in: remoteDir).map(\.name)
    }

    /// Elenca una cartella qualsiasi del server, con il tipo di ogni voce.
    func entries(in dir: String) async throws -> [RemoteEntry] {
        let dir = Self.normalizeDir(dir)
        switch site.connection {
        case .ftp, .ftps:
            let r = try await curl([ftpURL(dir)], op: L("elenco della cartella %@", dir))
            return Self.parseListing(r.text)
        case .sftp:
            let r = try await sftp(["ls -la \"\(dir)\""], op: L("elenco della cartella %@", dir))
            return Self.parseListing(r.text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("sftp>") }.joined(separator: "\n"))
        case .manual:
            return []
        }
    }

    func upload(_ local: URL, as name: String) async throws {
        switch site.connection {
        case .ftp, .ftps:
            _ = try await curl(["-T", local.path, ftpURL(remoteDir + name)], op: L("caricamento di %@ in %@", name, remoteDir))
        case .sftp:
            _ = try await sftp(["put \"\(local.path)\" \"\(remoteDir + name)\"", "chmod 644 \"\(remoteDir + name)\""],
                               op: L("caricamento di %@ in %@", name, remoteDir))
        case .manual:
            break
        }
    }

    /// Dimensione di un file nella cartella remota (nil se non c'è o non si riesce a leggerla).
    func size(of name: String) async -> Int64? {
        guard let list = try? await entries(in: remoteDir) else { return nil }
        return list.first { $0.name == name }?.size
    }

    func delete(_ name: String) async throws {
        switch site.connection {
        case .ftp, .ftps:
            _ = try await curl(["-Q", "DELE \(remoteDir + name)", ftpURL("/")], op: L("rimozione di %@", remoteDir + name))
        case .sftp:
            _ = try await sftp(["rm \"\(remoteDir + name)\""], op: L("rimozione di %@", remoteDir + name))
        case .manual:
            break
        }
    }

    /// Cerca le cartelle con WordPress (wp-config.php) a partire da `start`, scendendo di `depth` livelli.
    /// Serve a suggerire la cartella giusta quando quella del profilo è sbagliata.
    func findWordPress(from start: String = "/", depth: Int = 2, limit: Int = 25) async -> [String] {
        var found: [String] = []
        var queue: [(String, Int)] = [(Self.normalizeDir(start), 0)]
        var visited = 0
        while !queue.isEmpty, visited < limit {
            let (dir, level) = queue.removeFirst()
            visited += 1
            guard let list = try? await entries(in: dir) else { continue }
            if list.contains(where: { $0.name == "wp-config.php" && !$0.isDir }) { found.append(dir); continue }
            guard level < depth else { continue }
            for e in list where e.isDir && !e.name.hasPrefix(".") && !Self.skipWhenSearching.contains(e.name.lowercased()) {
                queue.append((dir + e.name + "/", level + 1))
            }
        }
        return found
    }

    private static let skipWhenSearching: Set<String> = ["wp-content", "wp-admin", "wp-includes", "node_modules", "logs", "log", "tmp",
                                                         "cgi-bin", "mail", "etc", "ssl", "_da_eliminare"]

    // MARK: Elenchi (formato «ls -l» di Unix e formato IIS/Windows)

    static func parseListing(_ text: String) -> [RemoteEntry] {
        var out: [RemoteEntry] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("total ") { continue }
            let first = line.first!
            if "dl-".contains(first) {
                // drwxr-xr-x  2 user group  4096 Jan 01 12:00 nome con spazi
                let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
                guard parts.count == 9 else { continue }
                var name = String(parts[8]).trimmingCharacters(in: .whitespaces)
                if first == "l", let r = name.range(of: " -> ") { name = String(name[..<r.lowerBound]) }
                if name == "." || name == ".." { continue }
                out.append(RemoteEntry(name: name, isDir: first == "d" || first == "l", size: Int64(parts[4])))
            } else if first.isNumber {
                // 01-01-24  12:00PM       <DIR>          nome
                let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count == 4 else { continue }
                let isDir = parts[2] == "<DIR>"
                out.append(RemoteEntry(name: String(parts[3]).trimmingCharacters(in: .whitespaces), isDir: isDir, size: isDir ? nil : Int64(parts[2])))
            }
        }
        return out.sorted { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
    }

    // MARK: curl (FTP / FTPS)

    private func ftpURL(_ path: String) -> String {
        let encoded = path.split(separator: "/", omittingEmptySubsequences: false).map { String($0).rawURLEncoded }.joined(separator: "/")
        return "ftp://\(site.host):\(site.port)\(encoded.hasPrefix("/") ? "" : "/")\(encoded)"
    }

    private func curl(_ args: [String], op: String) async throws -> Shell.Result {
        // Credenziali in un file .netrc temporaneo: mai sulla riga di comando (visibile con ps).
        let dir = AppPaths.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let netrc = dir.appendingPathComponent("netrc")
        try "machine \(site.host) login \(site.username) password \(password)\n".write(to: netrc, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: netrc.path)
        // -v: il dialogo col server finisce nei dettagli del Log (ripulito dalla password).
        var a = ["--verbose", "--silent", "--show-error", "--netrc-file", netrc.path, "--connect-timeout", "20", "--max-time", "300",
                 "--ftp-pasv", "--ftp-create-dirs"]
        if site.connection == .ftps { a += ["--ssl-reqd"] }
        if site.allowInvalidCertificates { a += ["--insecure"] }
        let r = try await Shell.run("/usr/bin/curl", a + args)
        guard r.ok else { throw explainCurl(r.status, stderr: r.stderr, op: op) }
        return r
    }

    /// Solo le righe utili del dialogo FTP: comandi inviati (password oscurata), risposte, errori TLS.
    private func ftpDialogue(_ stderr: String) -> String {
        var lines: [String] = []
        for raw in stderr.split(whereSeparator: \.isNewline) {
            var l = String(raw)
            if l.hasPrefix("> PASS") { l = "> PASS ****" }
            if !password.isEmpty { l = l.replacingOccurrences(of: password, with: "****") }
            if l.hasPrefix("< ") || l.hasPrefix("> ") || l.hasPrefix("curl:")
                || (l.hasPrefix("* ") && (l.localizedCaseInsensitiveContains("connected") || l.localizedCaseInsensitiveContains("error")
                                           || l.localizedCaseInsensitiveContains("certificate") || l.localizedCaseInsensitiveContains("fail"))) {
                lines.append(l)
            }
        }
        return lines.suffix(30).joined(separator: "\n")
    }

    /// Ultima risposta del server FTP con codice d'errore (4xx/5xx), es. "550 Permission denied".
    private func lastFTPReply(_ stderr: String) -> String? {
        stderr.split(whereSeparator: \.isNewline).map(String.init)
            .filter { $0.hasPrefix("< 4") || $0.hasPrefix("< 5") }.last.map { String($0.dropFirst(2)) }
    }

    func explainCurl(_ code: Int32, stderr: String, op: String) -> MirrorpressError {
        let reply = lastFTPReply(stderr)
        let curlLine = stderr.split(whereSeparator: \.isNewline).last { $0.hasPrefix("curl:") }.map(String.init) ?? ""
        var head = L("Codice curl: %d", Int(code))
        if let reply { head += " · " + L("risposta del server: %@", reply) }
        let detail = [
            L("Operazione: %@", op),
            L("Connessione: %@ %@@%@:%d, cartella remota %@", protocolName, site.username, site.host, site.port, remoteDir),
            head,
            "",
            ftpDialogue(stderr),
        ].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let browse = L("Usa «Sfoglia…» nel profilo per scegliere la cartella che contiene wp-config.php (su Aruba di solito è /www.dominio.it).")

        switch code {
        case 6:
            return fail(L("Server FTP «%@» non trovato.", site.host), hint: L("Controlla il nome del server nel profilo (es. ftp.dominio.it)."), detail: detail)
        case 7, 28:
            return fail(L("Connessione a %@ porta %d non riuscita (porta chiusa o timeout).", site.host, site.port),
                        hint: L("Controlla server e porta (FTP/FTPS 21, SFTP 22) e che l'hosting non blocchi il tuo IP."), detail: detail)
        case 9:
            return fail(L("La cartella remota %@ non esiste o non è accessibile.", remoteDir), hint: browse, detail: detail)
        case 25:
            return fail(L("Il server FTP ha rifiutato di scrivere in %@ (%@).", remoteDir, reply ?? "550"),
                        hint: L("La cartella non è scrivibile con questo utente o non è quella del sito.") + " " + browse, detail: detail)
        case 35, 60:
            return fail(L("Problema col certificato TLS del server FTP."),
                        hint: L("Attiva «Accetta certificati TLS non validi» nel profilo: sugli hosting condivisi il certificato FTP è spesso intestato al server, non al dominio."), detail: detail)
        case 64:
            return fail(L("Il server non supporta FTPS."), hint: L("Scegli FTP o SFTP nel profilo."), detail: detail)
        case 67:
            return fail(L("Utente o password FTP non corretti."),
                        hint: L("Ricontrolla utente e password nel profilo (su Aruba l'utente è del tipo 12345678@aruba.it)."), detail: detail)
        case 78:
            return fail(L("File o cartella non trovati sul server."), hint: browse, detail: detail)
        case 21:
            return fail(L("Il server FTP ha rifiutato il comando (%@).", reply ?? "?"), hint: nil, detail: detail)
        default:
            let msg = curlLine.isEmpty ? L("Errore FTP (codice curl %d).", Int(code))
                : L("Errore FTP: %@", String(curlLine.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            return fail(msg, hint: reply.map { L("Il server ha risposto: %@", $0) }, detail: detail)
        }
    }

    // MARK: sftp (OpenSSH)

    private func sftp(_ commands: [String], op: String) async throws -> Shell.Result {
        let dir = AppPaths.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let batch = dir.appendingPathComponent("batch")
        try commands.joined(separator: "\n").appending("\n").write(to: batch, atomically: true, encoding: .utf8)
        var env: [String: String] = [:]
        // BatchMode=no va PRIMA di -b, altrimenti sftp lo forza a yes e la password non viene chiesta.
        var args = ["-o", "BatchMode=no", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=20",
                    "-o", "NumberOfPasswordPrompts=1", "-P", String(site.port), "-b", batch.path]
        if !password.isEmpty {
            let askpass = dir.appendingPathComponent("askpass.sh")
            try "#!/bin/sh\nprintf '%s\\n' \"$MIRRORPRESS_SSH_PASSWORD\"\n".write(to: askpass, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
            env = ["SSH_ASKPASS": askpass.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0", "MIRRORPRESS_SSH_PASSWORD": password]
            args = ["-o", "PreferredAuthentications=password,keyboard-interactive,publickey"] + args
        }
        args.append("\(site.username)@\(site.host)")
        let r = try await Shell.run("/usr/bin/sftp", args, env: env)
        guard r.ok else {
            var e = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !password.isEmpty { e = e.replacingOccurrences(of: password, with: "****") }
            let detail = [
                L("Operazione: %@", op),
                L("Connessione: %@ %@@%@:%d, cartella remota %@", protocolName, site.username, site.host, site.port, remoteDir),
                L("Comandi: %@", commands.joined(separator: " ; ")),
                L("Codice di uscita: %d", Int(r.status)),
                "",
                e,
            ].joined(separator: "\n")
            if e.contains("Permission denied (") {
                throw fail(L("Accesso SFTP negato."), hint: L("Utente, password o chiave SSH non corretti."), detail: detail)
            }
            if e.contains("Host key verification failed") || e.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
                throw fail(L("La chiave del server SFTP è cambiata."), hint: L("Verifica col tuo hosting e aggiorna ~/.ssh/known_hosts."), detail: detail)
            }
            if e.contains("No such file") || e.contains("not found") {
                throw fail(L("La cartella remota %@ non esiste.", remoteDir),
                           hint: L("Usa «Sfoglia…» nel profilo per scegliere la cartella che contiene wp-config.php."), detail: detail)
            }
            if e.contains("Permission denied") {
                throw fail(L("Il server SFTP ha rifiutato di scrivere in %@ (permessi).", remoteDir),
                           hint: L("La cartella non è scrivibile con questo utente o non è quella del sito."), detail: detail)
            }
            if e.contains("Connection refused") || e.contains("timed out") || e.contains("Could not resolve") {
                throw fail(L("Connessione SFTP a %@ non riuscita.", site.host), hint: L("Controlla server e porta (di solito 22)."), detail: detail)
            }
            let last = e.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(r.status)"
            throw fail(L("Errore SFTP: %@", last), hint: nil, detail: detail)
        }
        return r
    }
}
