import Foundation

enum Manifest {
    /// Scansione della cartella locale con le stesse esclusioni del ponte.
    static func scanLocal(root: URL, excludes: ExcludeMatcher) -> [String: FileEntry] {
        var out: [String: FileEntry] = [:]
        let fm = FileManager.default
        var stack = [""]
        let extraExcludes = ExcludeMatcher([".mirrorpress-*", "mirrorpress-*.php", ".travaso-*", "travaso-*.php"])
        while let dirRel = stack.popLast() {
            let dirURL = dirRel.isEmpty ? root : root.appendingPathComponent(dirRel, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: dirURL.path) else { continue }
            for name in names {
                let rel = dirRel.isEmpty ? name : dirRel + "/" + name
                if excludes.excludes(rel, name: name) || extraExcludes.excludes(rel, name: name) { continue }
                let path = dirURL.appendingPathComponent(name).path
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let type = st.st_mode & S_IFMT
                if type == S_IFLNK { continue }
                if type == S_IFDIR { stack.append(rel); continue }
                if type == S_IFREG {
                    out[rel] = FileEntry(size: Int64(st.st_size), mtime: Int64(st.st_mtimespec.tv_sec))
                }
            }
        }
        return out
    }

    /// Legge il manifest del ponte: intestazione, poi blocchi [lunghezza 4 byte][gzip] fino a lunghezza 0.
    static func parseRemote(_ data: Data) throws -> (files: [String: FileEntry], unreadable: [String]) {
        guard let nl = data.firstIndex(of: 0x0a) else { throw fail(L("Elenco file del server non valido.")) }
        let header = String(decoding: data[data.startIndex..<nl], as: UTF8.self)
        guard header.hasPrefix("TRVM1") else { throw fail(L("Elenco file del server non valido.")) }
        let gz = header == "TRVM1Z"
        var i = nl + 1
        var text = ""
        while i + 4 <= data.endIndex {
            let len = Int(data[i]) << 24 | Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
            i += 4
            if len == 0 { break }
            guard i + len <= data.endIndex else { throw fail(L("Elenco file del server troncato: riprova.")) }
            let chunk = data.subdata(in: i..<(i + len))
            i += len
            text += String(decoding: gz ? try Gzip.decompress(chunk) : chunk, as: UTF8.self)
        }
        var files: [String: FileEntry] = [:]
        var unreadable: [String] = []
        var complete = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            if parts.first == "#" { complete = true; continue }
            if parts.first == "!" { unreadable.append(parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? "" : ""); continue }
            guard parts.count >= 3, let path = String(parts[0]).removingPercentEncoding,
                  let size = Int64(parts[1]), let mtime = Int64(parts[2]) else { continue }
            files[path] = FileEntry(size: size, mtime: mtime)
        }
        guard complete else { throw fail(L("Elenco file del server incompleto (il server ha interrotto la risposta).")) }
        return (files, unreadable)
    }
}

enum Compare {
    static func isSensitive(_ path: String) -> Bool {
        SiteProfile.sensitiveFiles.contains(path)
    }

    /// Dump e archivi: mai selezionati in automatico (in una cartella pubblica sono scaricabili da chiunque).
    static func isJunk(_ path: String) -> Bool {
        let p = path.lowercased()
        return [".sql", ".sql.gz", ".zip", ".tar.gz", ".tgz", ".bak", ".wpress"].contains { p.hasSuffix($0) }
    }

    /// Primo confronto per presenza e dimensione; quelli con la stessa dimensione restano `.unknown`
    /// finché non arriva l'MD5 (oppure diventano `.same` se il confronto del contenuto è spento).
    static func files(local: [String: FileEntry], remote: [String: FileEntry], compareContent: Bool) -> [FileDiff] {
        var out: [FileDiff] = []
        out.reserveCapacity(max(local.count, remote.count))
        for (path, l) in local {
            if let r = remote[path] {
                let status: FileStatus = l.size != r.size ? .changed : (compareContent ? .unknown : .same)
                out.append(FileDiff(path: path, local: l, remote: r, status: status, sensitive: isSensitive(path)))
            } else {
                out.append(FileDiff(path: path, local: l, remote: nil, status: .onlyLocal, sensitive: isSensitive(path)))
            }
        }
        for (path, r) in remote where local[path] == nil {
            out.append(FileDiff(path: path, local: nil, remote: r, status: .onlyRemote, sensitive: isSensitive(path)))
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func applyHashes(_ diffs: inout [FileDiff], local: [String: String], remote: [String: String]) {
        for i in diffs.indices where diffs[i].status == .unknown {
            guard let l = local[diffs[i].path], let r = remote[diffs[i].path], !l.isEmpty, !r.isEmpty else { continue }
            diffs[i].status = l == r ? .same : .changed
        }
    }

    /// Percorsi uguali a meno di maiuscole/minuscole: su Mac sono lo stesso file, su Linux no.
    static func caseConflicts(local: [String: FileEntry], remote: [String: FileEntry]) -> [(String, String)] {
        var byLower: [String: String] = [:]
        for p in remote.keys { byLower[p.lowercased()] = p }
        var out: [(String, String)] = []
        for p in local.keys where remote[p] == nil {
            if let r = byLower[p.lowercased()], r != p { out.append((p, r)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    // MARK: Tabelle

    static func tables(_ json: JSONValue) -> [TableInfo] {
        json["tables"].array.map { t in
            var rh: [String: String]? = nil
            if case .object(let o) = t["row_hashes"] { rh = o.compactMapValues { $0.string } }
            return TableInfo(name: t["name"].string ?? "", rows: t["rows"].int, size: t["size"].int64,
                             hash: t["hash"].string, collation: t["collation"].string ?? "",
                             engine: t["engine"].string ?? "", rowHashes: rh)
        }
    }

    /// Accoppia le tabelle per nome senza prefisso (il prefisso può essere diverso tra locale e server).
    static func tables(local: [TableInfo], localPrefix: String, remote: [TableInfo], remotePrefix: String) -> [TableDiff] {
        func key(_ name: String, _ prefix: String) -> String {
            !prefix.isEmpty && name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : "⟨\(name)⟩"
        }
        var l: [String: TableInfo] = [:], r: [String: TableInfo] = [:]
        for t in local { l[key(t.name, localPrefix)] = t }
        for t in remote { r[key(t.name, remotePrefix)] = t }
        var out: [TableDiff] = []
        for k in Set(l.keys).union(r.keys) {
            let a = l[k], b = r[k]
            var d = TableDiff(key: k, local: a, remote: b, status: .unknown)
            if a == nil { d.status = .onlyRemote }
            else if b == nil { d.status = .onlyLocal }
            else if let ha = a?.hash, let hb = b?.hash { d.status = ha == hb ? .same : .changed }
            if d.status == .changed, let ra = a?.rowHashes, let rb = b?.rowHashes {
                for (key, h) in ra {
                    if let other = rb[key] { if other != h { d.keysChanged.append(key) } } else { d.keysOnlyLocal.append(key) }
                }
                for key in rb.keys where ra[key] == nil { d.keysOnlyRemote.append(key) }
                d.rowsChanged = d.keysChanged.count
                d.rowsOnlyLocal = d.keysOnlyLocal.count
                d.rowsOnlyRemote = d.keysOnlyRemote.count
            }
            out.append(d)
        }
        return out.sorted { $0.key < $1.key }
    }

    /// Coppie per normalizzare il confronto (URL, percorsi e chiavi col prefisso diversi tra i due lati).
    static func normalizePairs(url: String, root: String, prefix: String) -> [[String]] {
        var pairs: [[String]] = []
        let u = url.trimmingSlashes().isEmpty ? "" : (url.hasSuffix("/") ? String(url.dropLast()) : url)
        if !u.isEmpty {
            pairs.append([u, "{URL}"])
            pairs.append([u.jsonEscapedSlashes, "{URLJ}"])
            if let enc = u.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { pairs.append([enc, "{URLE}"]) }
            // Variante senza protocollo (//dominio/percorso).
            if let r = u.range(of: "://") { pairs.append([String(u[u.index(after: r.lowerBound)...]), "{URLP}"]) }
        }
        if !root.isEmpty { pairs.append([root, "{ROOT}"]) }
        if !prefix.isEmpty {
            for k in ["user_roles", "capabilities", "user_level", "user-settings", "user-settings-time", "dashboard_quick_press_last_post_id"] {
                pairs.append([prefix + k, "{P}" + k])
            }
        }
        return pairs
    }

    /// Coppie cerca/sostituisci per portare il database da un lato all'altro (prima le più lunghe).
    static func replacePairs(fromURL: String, toURL: String, fromRoot: String, toRoot: String) -> [[String]] {
        var pairs: [[String]] = []
        let f = fromURL.hasSuffix("/") ? String(fromURL.dropLast()) : fromURL
        let t = toURL.hasSuffix("/") ? String(toURL.dropLast()) : toURL
        if !f.isEmpty, !t.isEmpty, f != t {
            pairs.append([f, t])
            pairs.append([f.jsonEscapedSlashes, t.jsonEscapedSlashes])
            if let fe = f.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
               let te = t.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { pairs.append([fe, te]) }
            // Lo stesso indirizzo con l'altro protocollo (contenuti inseriti a mano con http/https).
            if f.hasPrefix("http://") { pairs.append(["https://" + f.dropFirst(7), t]) }
            else if f.hasPrefix("https://") { pairs.append(["http://" + f.dropFirst(8), t]) }
        }
        if !fromRoot.isEmpty, !toRoot.isEmpty, fromRoot != toRoot { pairs.append([fromRoot, toRoot]) }
        return pairs.sorted { $0[0].count > $1[0].count }
    }
}
