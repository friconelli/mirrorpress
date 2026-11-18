import Foundation

/// Una criticità trovata nel codice di un lato (Mac o server).
struct CodeFinding: Identifiable, Hashable {
    let id = UUID()
    let side: Side
    let path: String
    let line: Int
    let rule: String
    let severity: Severity
    let snippet: String
    var extra = ""          // es. versione di PHP, versione ufficiale confrontata

    var info: CodeRule { CodeRule.of(rule) }
}

/// Testi delle regole: cosa vuol dire e cosa fare.
struct CodeRule {
    let title: String
    let explanation: String
    let category: String

    static func of(_ id: String) -> CodeRule {
        let sec = L("Sicurezza"), compat = L("Compatibilità"), clean = L("Pulizia"), integ = L("Integrità")
        switch id {
        case "eval_obfuscated": return CodeRule(title: L("Codice nascosto eseguito con eval"), explanation: L("Tipico dei malware: decodifica ed esegue codice nascosto. Se non l'hai scritto tu, il sito è probabilmente compromesso."), category: sec)
        case "eval_input": return CodeRule(title: L("Esegue codice ricevuto dal browser"), explanation: L("Chiunque può far eseguire codice al sito: è una backdoor."), category: sec)
        case "exec_input": return CodeRule(title: L("Comandi di sistema presi dalla richiesta"), explanation: L("Permette di lanciare comandi sul server dall'esterno: è una backdoor."), category: sec)
        case "preg_e": return CodeRule(title: L("preg_replace con il modificatore /e"), explanation: L("Esegue codice e non esiste più da PHP 7: oggi lo usano quasi solo i malware."), category: sec)
        case "var_function_input": return CodeRule(title: L("Funzione scelta dalla richiesta"), explanation: L("Il nome della funzione da eseguire arriva dal browser: è una backdoor."), category: sec)
        case "shell_signature": return CodeRule(title: L("Firma di una web shell nota"), explanation: L("Il file contiene il nome di un noto strumento d'attacco."), category: sec)
        case "long_base64": return CodeRule(title: L("Blocco di dati codificato molto lungo"), explanation: L("Può essere un'immagine o una libreria, ma spesso nasconde codice malevolo: controlla da dove viene."), category: sec)
        case "hex_obfuscation": return CodeRule(title: L("Testo offuscato in esadecimale"), explanation: L("Codice scritto per non essere letto: frequente nei malware."), category: sec)
        case "php_in_uploads": return CodeRule(title: L("File PHP nella cartella dei media"), explanation: L("In uploads ci vanno immagini e documenti: un PHP lì è quasi sempre il risultato di un attacco."), category: sec)
        case "php8_removed": return CodeRule(title: L("Funzione eliminata in PHP 8"), explanation: L("Con il PHP del server questa riga provoca un errore fatale e la pagina si rompe."), category: compat)
        case "syntax": return CodeRule(title: L("Errore di sintassi PHP"), explanation: L("Con il PHP del server il file non si carica: dopo il Push il sito si romperebbe."), category: compat)
        case "debug_dump": return CodeRule(title: L("Stampa di debug rimasta nel codice"), explanation: L("var_dump, print_r e simili mostrano dati interni ai visitatori."), category: clean)
        case "display_errors": return CodeRule(title: L("Errori PHP mostrati ai visitatori"), explanation: L("display_errors attivo espone percorsi e dettagli del server."), category: clean)
        case "local_url": return CodeRule(title: L("Indirizzo o percorso del Mac nel codice"), explanation: L("localhost, 127.0.0.1 o /Applications/MAMP scritti nel tema: sul server non funzionano."), category: clean)
        case "core_modified": return CodeRule(title: L("File di WordPress modificato"), explanation: L("È diverso dall'originale ufficiale di questa versione: segno di attacco o di una modifica a mano che si perde al prossimo aggiornamento."), category: integ)
        case "core_extra": return CodeRule(title: L("File PHP estraneo dentro WordPress"), explanation: L("In wp-admin e wp-includes c'è un PHP che WordPress non ha: tipico di un attacco."), category: integ)
        case "core_missing": return CodeRule(title: L("File di WordPress mancante"), explanation: L("Manca un file del core: reinstalla WordPress dalla bacheca (Aggiornamenti → Reinstalla)."), category: integ)
        case "plugin_modified": return CodeRule(title: L("File di plugin diverso dall'originale"), explanation: L("Non corrisponde alla versione ufficiale su wordpress.org: modificato a mano o compromesso."), category: integ)
        case "plugin_extra": return CodeRule(title: L("File PHP in più dentro un plugin"), explanation: L("La versione ufficiale del plugin non ha questo file: controlla che non sia stato aggiunto da un attacco."), category: integ)
        default: return CodeRule(title: id, explanation: "", category: sec)
        }
    }
}

extension SiteSession {
    /// Controllo del codice dai due lati: regole (malware, PHP 8, debug, indirizzi locali), integrità di WordPress e dei plugin
    /// rispetto ai checksum ufficiali, sintassi del tema con la stessa versione di PHP del server.
    func checkCode() async {
        await perform(L("Controllo del codice")) {
            guard analyzedAt != nil, let l = localInfo, let r = remoteInfo else { throw fail(L("Prima fai l'analisi.")) }
            let remote = try await ensureRemote()
            var out: [CodeFinding] = []
            let php8 = (Int(r.php.split(separator: ".").first ?? "") ?? 0) >= 8
            let localPaths = files.filter { $0.local != nil }.map(\.path)
            let remotePaths = files.filter { $0.remote != nil }.map(\.path)

            // 1. Regole sul codice (stesso ponte, stesse regole ai due lati).
            for (side, endpoint, paths) in [(Side.local, local as BridgeEndpoint, localPaths), (Side.remote, remote as BridgeEndpoint, remotePaths)] {
                let todo = paths.filter(Self.isScannable)
                var i = 0
                while i < todo.count {
                    try checkCancel()
                    status(L("Leggo il codice (%@)… %d/%d", side.label, i, todo.count), Double(i) / Double(max(1, todo.count)))
                    let batch = Array(todo[i..<min(i + 600, todo.count)])
                    let res = try await endpoint.call("code_scan", ["paths": batch, "php8": php8])
                    for f in res["findings"].array {
                        out.append(CodeFinding(side: side, path: f["path"].string ?? "", line: f["line"].int ?? 0, rule: f["rule"].string ?? "",
                                               severity: f["severity"].string == "error" ? .error : .warning, snippet: f["snippet"].string ?? "",
                                               extra: f["rule"].string == "php8_removed" ? "PHP \(r.php)" : ""))
                    }
                    i += max(1, res["done"].int ?? batch.count)
                }
            }

            // 2. Integrità del core rispetto ai checksum ufficiali di wordpress.org.
            for (side, info, endpoint, paths) in [(Side.local, l, local as BridgeEndpoint, Set(localPaths)), (Side.remote, r, remote as BridgeEndpoint, Set(remotePaths))] {
                guard let version = info.wpVersion else { continue }
                status(L("Confronto WordPress %@ con l'originale (%@)…", version, side.label))
                guard let sums = await Self.coreChecksums(version) else {
                    note(L("Checksum ufficiali di WordPress %@ non disponibili: integrità del core non verificata.", version), .warning)
                    continue
                }
                let core = sums.filter { Self.isCodeFile($0.key) && !$0.key.hasPrefix("wp-content/") && $0.key != "wp-config-sample.php" }
                let present = core.keys.filter { paths.contains($0) }
                let hashes = try await hashAll(Array(present), side: side, endpoint: endpoint)
                for (path, expected) in core {
                    if !paths.contains(path) {
                        out.append(CodeFinding(side: side, path: path, line: 0, rule: "core_missing", severity: .warning, snippet: "", extra: "WordPress \(version)"))
                    } else if let h = hashes[path], !h.isEmpty, h != expected {
                        out.append(CodeFinding(side: side, path: path, line: 0, rule: "core_modified", severity: .error, snippet: "", extra: "WordPress \(version)"))
                    }
                }
                for p in paths where (p.hasPrefix("wp-admin/") || p.hasPrefix("wp-includes/")) && Self.isPHP(p) && sums[p] == nil {
                    out.append(CodeFinding(side: side, path: p, line: 0, rule: "core_extra", severity: .error, snippet: "", extra: "WordPress \(version)"))
                }
            }

            // 3. Integrità dei plugin sul server (quelli di wordpress.org hanno i checksum pubblici).
            for (n, plugin) in r.plugins.enumerated() where !plugin.slug.isEmpty && !plugin.version.isEmpty {
                try checkCancel()
                status(L("Confronto i plugin con gli originali… %d/%d", n, r.plugins.count), Double(n) / Double(max(1, r.plugins.count)))
                guard let sums = await Self.pluginChecksums(plugin.slug, plugin.version) else { continue }   // plugin a pagamento o personalizzati
                let base = "wp-content/plugins/\(plugin.slug)/"
                let mine = remotePaths.filter { $0.hasPrefix(base) && Self.isCodeFile($0) }
                let hashes = try await hashAll(mine, side: .remote, endpoint: remote)
                for p in mine {
                    let rel = String(p.dropFirst(base.count))
                    if let expected = sums[rel] {
                        if let h = hashes[p], !h.isEmpty, !expected.contains(h) {
                            out.append(CodeFinding(side: .remote, path: p, line: 0, rule: "plugin_modified", severity: .error, snippet: "", extra: "\(plugin.name) \(plugin.version)"))
                        }
                    } else if Self.isPHP(p) {
                        out.append(CodeFinding(side: .remote, path: p, line: 0, rule: "plugin_extra", severity: .warning, snippet: "", extra: "\(plugin.name) \(plugin.version)"))
                    }
                }
            }

            // 4. Sintassi del codice proprio (tema attivo e mu-plugins) con il PHP di MAMP più vicino a quello del server.
            if let (phpPath, phpVersion) = LocalEnv.mampPHP(matching: r.php) {
                let themes = [l.stylesheet].compactMap { $0 }.map { "wp-content/themes/\($0)/" }
                    + l.themes.filter { $0.slug == l.stylesheet && !$0.parent.isEmpty }.map { "wp-content/themes/\($0.parent)/" }
                let own = localPaths.filter { p in Self.isPHP(p) && (themes.contains { p.hasPrefix($0) } || p.hasPrefix("wp-content/mu-plugins/")) }
                status(L("Controllo la sintassi con PHP %@…", phpVersion))
                out += await Self.lint(own, root: localRoot, php: phpPath, version: phpVersion)
            }

            codeFindings = out.sorted { ($0.severity.rawValue, $0.side == .remote ? 1 : 0, $0.path) > ($1.severity.rawValue, $1.side == .remote ? 1 : 0, $1.path) }
            codeCheckedAt = Date()
            let errors = out.filter { $0.severity == .error }.count
            note(L("Controllo del codice: %d criticità gravi, %d avvisi.", errors, out.count - errors), errors > 0 ? .warning : .success)
        }
    }

    /// MD5 di molti file di un lato (dal ponte a blocchi, con i limiti di tempo del server).
    private func hashAll(_ paths: [String], side: Side, endpoint: BridgeEndpoint) async throws -> [String: String] {
        var out: [String: String] = [:]
        if side == .local {
            let root = localRoot
            return await Task.detached {
                var o: [String: String] = [:]
                for p in paths { o[p] = Hashing.md5(file: root.appendingPathComponent(p)) ?? "" }
                return o
            }.value
        }
        var i = 0
        while i < paths.count {
            try checkCancel()
            let batch = Array(paths[i..<min(i + 1500, paths.count)])
            let res = try await endpoint.call("hash", ["paths": batch])
            for (k, v) in res["hashes"].object { out[k] = v.string ?? "" }
            i += max(1, res["done"].int ?? batch.count)
        }
        return out
    }

    static func isPHP(_ p: String) -> Bool {
        let e = (p as NSString).pathExtension.lowercased()
        return ["php", "php5", "php7", "phtml", "phar", "inc"].contains(e)
    }

    static func isCodeFile(_ p: String) -> Bool { isPHP(p) || (p as NSString).pathExtension.lowercased() == "js" }

    /// File da leggere con le regole: PHP ovunque (tranne il core, verificato con i checksum), JS solo nel codice proprio.
    static func isScannable(_ p: String) -> Bool {
        if p.hasPrefix("wp-admin/") || p.hasPrefix("wp-includes/") { return false }
        if p.contains("/node_modules/") { return false }
        if isPHP(p) { return true }
        if (p as NSString).pathExtension.lowercased() == "js" {
            return (p.hasPrefix("wp-content/themes/") || p.hasPrefix("wp-content/mu-plugins/")) && !p.hasSuffix(".min.js")
        }
        return false
    }

    // MARK: Checksum ufficiali

    private static var coreCache: [String: [String: String]] = [:]

    static func coreChecksums(_ version: String) async -> [String: String]? {
        if let c = coreCache[version] { return c }
        guard let url = URL(string: "https://api.wordpress.org/core/checksums/1.0/?version=\(version)&locale=en_US"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONValue.parse(data) else { return nil }
        var sums = json["checksums"].object
        if sums.isEmpty { sums = json["checksums"][version].object }
        let out = sums.compactMapValues(\.string)
        guard !out.isEmpty else { return nil }
        coreCache[version] = out
        return out
    }

    /// Checksum di un plugin di wordpress.org: percorso relativo → MD5 ammessi (alcuni file ne hanno più d'uno).
    static func pluginChecksums(_ slug: String, _ version: String) async -> [String: Set<String>]? {
        guard let s = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let v = version.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://downloads.wordpress.org/plugin-checksums/\(s)/\(v).json"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONValue.parse(data) else { return nil }
        var out: [String: Set<String>] = [:]
        for (path, entry) in json["files"].object {
            let md5 = entry["md5"]
            if let one = md5.string { out[path] = [one] } else { out[path] = Set(md5.array.compactMap(\.string)) }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: Sintassi

    static func lint(_ paths: [String], root: URL, php: String, version: String) async -> [CodeFinding] {
        await withTaskGroup(of: CodeFinding?.self) { group in
            var out: [CodeFinding] = []
            var it = paths.makeIterator()
            func add(_ p: String) {
                group.addTask {
                    guard let r = try? await Shell.run(php, ["-n", "-l", root.appendingPathComponent(p).path]), !r.ok else { return nil }
                    let msg = (r.text + r.stderr).split(whereSeparator: \.isNewline).first { $0.contains("error") }.map(String.init) ?? r.text
                    let line = msg.range(of: "on line ").flatMap { Int(msg[$0.upperBound...].prefix { $0.isNumber }) } ?? 0
                    let clean = msg.replacingOccurrences(of: root.path + "/", with: "").replacingOccurrences(of: "PHP Parse error:  ", with: "")
                    return CodeFinding(side: .local, path: p, line: line, rule: "syntax", severity: .error, snippet: clean, extra: "PHP \(version)")
                }
            }
            for _ in 0..<6 { if let p = it.next() { add(p) } }
            while let r = await group.next() {
                if let r { out.append(r) }
                if let p = it.next() { add(p) }
            }
            return out
        }
    }
}
