import Foundation

/// Esegue un programma fuori dal thread principale, con stdin da file o dati, e raccoglie l'output.
enum Shell {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
        var ok: Bool { status == 0 }
        var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    static func run(_ executable: String, _ args: [String], env: [String: String] = [:],
                    stdin: Data? = nil, stdinFile: URL? = nil, stdoutFile: URL? = nil,
                    cwd: URL? = nil) async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: executable)
                    p.arguments = args
                    var environment = ProcessInfo.processInfo.environment
                    for (k, v) in env { environment[k] = v }
                    p.environment = environment
                    if let cwd { p.currentDirectoryURL = cwd }

                    let outPipe = Pipe(), errPipe = Pipe()
                    var outHandle: FileHandle?
                    if let stdoutFile {
                        FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
                        outHandle = try FileHandle(forWritingTo: stdoutFile)
                        p.standardOutput = outHandle
                    } else {
                        p.standardOutput = outPipe
                    }
                    p.standardError = errPipe
                    if let stdinFile {
                        p.standardInput = try FileHandle(forReadingFrom: stdinFile)
                    } else if stdin != nil {
                        p.standardInput = Pipe()
                    } else {
                        p.standardInput = FileHandle.nullDevice
                    }

                    // Legge stdout/stderr mentre il processo gira (pipe piene = blocco).
                    var out = Data(), err = Data()
                    let group = DispatchGroup()
                    if stdoutFile == nil {
                        group.enter()
                        DispatchQueue.global().async { out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                    }
                    group.enter()
                    DispatchQueue.global().async { err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

                    try p.run()
                    if let stdin, let pipe = p.standardInput as? Pipe {
                        DispatchQueue.global().async {
                            pipe.fileHandleForWriting.write(stdin)
                            try? pipe.fileHandleForWriting.close()
                        }
                    }
                    p.waitUntilExit()
                    group.wait()
                    try? outHandle?.close()
                    cont.resume(returning: Result(status: p.terminationStatus, stdout: out,
                                                  stderr: String(decoding: err, as: UTF8.self)))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

/// L'ambiente locale: PHP e MySQL di MAMP (o di Homebrew), e il riconoscimento dei progetti con pipeline.
enum LocalEnv {
    static let mampSocket = "/Applications/MAMP/tmp/mysql/mysql.sock"

    /// Il PHP più recente disponibile: MAMP prima, poi Homebrew.
    /// PHP di MAMP con la stessa versione principale (es. 8.3) del server, o la più vicina: per controllare la sintassi.
    static func mampPHP(matching version: String) -> (path: String, version: String)? {
        let base = "/Applications/MAMP/bin/php"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        let wanted = version.split(separator: ".").prefix(2).compactMap { Int($0) }
        guard wanted.count == 2 else { return nil }
        let available: [(String, [Int])] = dirs.compactMap { d in
            guard d.hasPrefix("php"), FileManager.default.isExecutableFile(atPath: "\(base)/\(d)/bin/php") else { return nil }
            let v = d.dropFirst(3).split(separator: ".").compactMap { Int($0) }
            return v.count >= 2 ? (d, v) : nil
        }
        func distance(_ v: [Int]) -> Int { abs((v[0] * 100 + v[1]) - (wanted[0] * 100 + wanted[1])) }
        guard let best = available.min(by: { distance($0.1) < distance($1.1) }) else { return nil }
        return ("\(base)/\(best.0)/bin/php", "\(best.1[0]).\(best.1[1])")
    }

    static var phpBinary: String? {
        if let custom = UserDefaults.standard.string(forKey: "phpPath"), FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }
        let base = "/Applications/MAMP/bin/php"
        if let dirs = try? FileManager.default.contentsOfDirectory(atPath: base) {
            let best = dirs.filter { $0.hasPrefix("php8") || $0.hasPrefix("php7") }
                .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
                .last { FileManager.default.isExecutableFile(atPath: "\(base)/\($0)/bin/php") }
            if let best { return "\(base)/\(best)/bin/php" }
        }
        for p in ["/opt/homebrew/bin/php", "/usr/local/bin/php"] where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    static var mampHtdocs: URL { URL(fileURLWithPath: "/Applications/MAMP/htdocs", isDirectory: true) }

    /// Motivo per cui un progetto NON va sincronizzato a mano (Vercel, Netlify, pipeline CI): nil se va bene.
    static func pipelineReason(for folder: URL) -> String? {
        let fm = FileManager.default
        func has(_ p: String) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent(p).path) }
        if has("vercel.json") || has(".vercel") { return L("Il progetto si pubblica con Vercel.") }
        if has("netlify.toml") || has(".netlify") { return L("Il progetto si pubblica con Netlify.") }
        if has("wp-config.php") || has("wp-settings.php") { return nil }  // WordPress: si sincronizza anche se ha un repo
        let wf = folder.appendingPathComponent(".github/workflows")
        if let files = try? fm.contentsOfDirectory(atPath: wf.path) {
            for f in files where f.hasSuffix(".yml") || f.hasSuffix(".yaml") {
                let txt = (try? String(contentsOf: wf.appendingPathComponent(f))) ?? ""
                if txt.range(of: "deploy|rsync|ftp|ssh-action|pages", options: [.regularExpression, .caseInsensitive]) != nil {
                    return L("Il progetto ha una pipeline di deploy su GitHub Actions (%@).", f)
                }
            }
        }
        if has(".gitlab-ci.yml") { return L("Il progetto ha una pipeline GitLab CI.") }
        if let pkg = try? String(contentsOf: folder.appendingPathComponent("package.json")),
           pkg.contains("\"next\"") || pkg.contains("\"astro\"") || pkg.contains("\"@sveltejs/kit\"") || pkg.contains("\"nuxt\"") {
            return L("È un progetto JavaScript con build (Next, Astro, Nuxt…): si pubblica con la sua pipeline.")
        }
        return nil
    }

    /// Legge le costanti principali da wp-config.php (per precompilare il profilo).
    static func wpConfig(at folder: URL) -> [String: String] {
        guard let src = try? String(contentsOf: folder.appendingPathComponent("wp-config.php")) else { return [:] }
        var out: [String: String] = [:]
        let re = try! NSRegularExpression(pattern: #"define\s*\(\s*['"]([A-Z_]+)['"]\s*,\s*['"]([^'"]*)['"]"#)
        for m in re.matches(in: src, range: NSRange(src.startIndex..., in: src)) {
            if let k = Range(m.range(at: 1), in: src), let v = Range(m.range(at: 2), in: src) { out[String(src[k])] = String(src[v]) }
        }
        let pre = try! NSRegularExpression(pattern: #"\$table_prefix\s*=\s*['"]([^'"]*)['"]"#)
        if let m = pre.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)), let r = Range(m.range(at: 1), in: src) {
            out["table_prefix"] = String(src[r])
        }
        return out
    }

    static func isWordPress(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("wp-includes/version.php").path)
    }
}
