import Foundation

/// Un lato del mirrorpress: parla con il ponte PHP (in locale da riga di comando, sul server via HTTPS).
protocol BridgeEndpoint: AnyObject, Sendable {
    var side: Side { get }
    /// Richiesta JSON → risposta JSON (lancia un errore se il ponte risponde ok:false).
    func call(_ action: String, _ params: [String: Any]) async throws -> JSONValue
    /// Corpo binario (upload, pezzi di dump) con i parametri nella riga "J {json}".
    func callRaw(_ action: String, _ params: [String: Any], body: Data) async throws -> JSONValue
    /// Risposta binaria (manifest, dump, download) salvata su file.
    func stream(_ action: String, _ params: [String: Any], to file: URL) async throws
}

enum BridgeScript {
    /// Il ponte incluso nell'app (o nei sorgenti, durante lo sviluppo con `swift run`).
    static var url: URL {
        if let u = Bundle.main.resourceURL?.appendingPathComponent("Bridge/mirrorpress-bridge.php"),
           FileManager.default.fileExists(atPath: u.path) { return u }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Bridge/mirrorpress-bridge.php")
    }

    static var source: String { (try? String(contentsOf: url)) ?? "" }

    /// Copia personalizzata per il server: token segreto e scadenza.
    static func personalized(token: String, expires: Date) -> String {
        source.replacingOccurrences(of: "'__MIRRORPRESS_TOKEN__'", with: "'\(token)'")
            .replacingOccurrences(of: "0 /*__MIRRORPRESS_EXPIRES__*/", with: String(Int(expires.timeIntervalSince1970)))
    }
}

private func bridgeResult(_ data: Data, context: String, diagnostics: (() -> String)? = nil) throws -> JSONValue {
    guard let json = try? JSONValue.parse(data), case .object = json else {
        let text = String(decoding: data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = diagnostics?() ?? (text.isEmpty ? "" : L("Risposta: %@", text))
        if text.isEmpty {
            throw fail(L("Il ponte (%@) ha dato una risposta vuota.", context),
                       hint: L("Di solito PHP si è interrotto (errore fatale, memoria, tempo massimo) oppure l'antivirus o il firewall dell'hosting ha bloccato o svuotato il file del ponte. Guarda i dettagli tecnici."),
                       detail: detail)
        }
        if text.lowercased().contains("<html") || text.lowercased().hasPrefix("<!doctype") {
            throw fail(L("Al posto del ponte (%@) ha risposto una pagina HTML.", context),
                       hint: L("L'indirizzo del sito non punta alla cartella remota scelta, oppure un firewall o una pagina di cortesia intercetta la richiesta."),
                       detail: detail)
        }
        throw fail(L("Risposta non valida dal ponte (%@).", context),
                   hint: L("Il ponte ha stampato qualcosa di inatteso, spesso un avviso PHP dell'hosting: è nei dettagli tecnici."), detail: detail)
    }
    if !json["ok"].truthy {
        throw fail(json["error"].string ?? L("errore sconosciuto"), hint: json["hint"].string,
                   detail: [json["detail"].string, diagnostics?()].compactMap { $0 }.joined(separator: "\n"))
    }
    return json
}

private func encodeParams(_ params: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: params, options: [.withoutEscapingSlashes])
}

/// Se un flusso binario inizia con una risposta JSON d'errore, la trasforma in eccezione.
private func checkStreamFile(_ file: URL) throws {
    guard let fh = try? FileHandle(forReadingFrom: file) else { return }
    defer { try? fh.close() }
    let head = fh.readData(ofLength: 2)
    if head == Data("{\"".utf8) {
        let all = (try? Data(contentsOf: file)) ?? Data()
        _ = try bridgeResult(all, context: "stream")
    }
}

// MARK: - Locale

final class LocalBridge: BridgeEndpoint, @unchecked Sendable {
    let side = Side.local
    let root: URL
    let workdir: URL
    let db: [String: Any]?

    init(root: URL, workdir: URL, db: [String: Any]?) {
        self.root = root
        self.workdir = workdir
        self.db = db
    }

    private func php(_ action: String, stdin: Data? = nil, stdinFile: URL? = nil, stdoutFile: URL? = nil) async throws -> Shell.Result {
        guard let php = LocalEnv.phpBinary else { throw fail(L("PHP non trovato: installa MAMP o indica il percorso di PHP nelle impostazioni.")) }
        var args = ["-d", "memory_limit=2048M", "-d", "display_errors=0"]
        if FileManager.default.fileExists(atPath: LocalEnv.mampSocket) {
            args += ["-d", "mysqli.default_socket=\(LocalEnv.mampSocket)"]
        }
        args += [BridgeScript.url.path, action]
        let r = try await Shell.run(php, args, env: ["MIRRORPRESS_ROOT": root.path, "MIRRORPRESS_WORKDIR": workdir.path],
                                    stdin: stdin, stdinFile: stdinFile, stdoutFile: stdoutFile)
        if !r.ok && r.stdout.isEmpty && stdoutFile == nil {
            throw fail(L("PHP locale ha restituito un errore: %@", r.stderr))
        }
        return r
    }

    private func withDB(_ p: [String: Any]) -> [String: Any] {
        var p = p
        if let db, p["db"] == nil { p["db"] = db }
        return p
    }

    func call(_ action: String, _ params: [String: Any]) async throws -> JSONValue {
        let r = try await php(action, stdin: try encodeParams(withDB(params)))
        return try bridgeResult(r.stdout, context: L("locale"))
    }

    func callRaw(_ action: String, _ params: [String: Any], body: Data) async throws -> JSONValue {
        var data = Data("J ".utf8)
        data += try encodeParams(withDB(params))
        data += Data("\n".utf8)
        data += body
        let r = try await php(action, stdin: data)
        return try bridgeResult(r.stdout, context: L("locale"))
    }

    func stream(_ action: String, _ params: [String: Any], to file: URL) async throws {
        let r = try await php(action, stdin: try encodeParams(withDB(params)), stdoutFile: file)
        if !r.ok { throw fail(L("PHP locale: %@", r.stderr.isEmpty ? "exit \(r.status)" : r.stderr)) }
        try checkStreamFile(file)
    }
}

// MARK: - Remoto

final class RemoteBridge: NSObject, BridgeEndpoint, URLSessionDelegate, @unchecked Sendable {
    let side = Side.remote
    let url: URL
    let token: String
    let db: [String: Any]?
    private let basicAuth: String?
    private let allowInvalidCertificates: Bool
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 900
        cfg.timeoutIntervalForResource = 6 * 3600
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    init(url: URL, token: String, db: [String: Any]?, httpUser: String, httpPassword: String, allowInvalidCertificates: Bool) {
        self.url = url
        self.token = token
        self.db = db
        self.allowInvalidCertificates = allowInvalidCertificates
        basicAuth = httpUser.isEmpty ? nil : Data("\(httpUser):\(httpPassword)".utf8).base64EncodedString()
    }

    private func request(_ action: String, body: Data) -> URLRequest {
        let ts = Int(Date().timeIntervalSince1970)
        let message = Data("\(ts)\n\(action)\n\(Hashing.sha256(body))".utf8)
        let sig = Hashing.hmacSHA256(key: token, message: message)
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "a", value: action), URLQueryItem(name: "t", value: String(ts)), URLQueryItem(name: "s", value: sig)]
        var r = URLRequest(url: c.url!)
        r.httpMethod = "POST"
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.setValue("Mirrorpress", forHTTPHeaderField: "User-Agent")
        if let basicAuth { r.setValue("Basic \(basicAuth)", forHTTPHeaderField: "Authorization") }
        return r
    }

    /// Dati tecnici di una risposta per il Log: indirizzo (senza firma), codice, intestazioni utili, inizio del corpo.
    private func diagnostics(_ action: String, _ response: URLResponse?, _ body: Data?) -> String {
        var lines = [L("Azione del ponte: %@", action), L("Indirizzo: %@", url.absoluteString)]
        if let http = response as? HTTPURLResponse {
            lines.append(L("HTTP %d · %@ byte", http.statusCode, String(body?.count ?? 0)))
            let interesting = ["content-type", "content-length", "server", "x-powered-by", "location", "x-servername",
                               "x-aruba-waf", "x-aruba-cache", "cf-ray", "x-litespeed-cache", "x-sucuri-id", "x-cache"]
            for (k, v) in http.allHeaderFields {
                guard let key = (k as? String)?.lowercased(), interesting.contains(key) || key.hasPrefix("x-aruba") else { continue }
                lines.append("  \(key): \(v)")
            }
        }
        if let body, !body.isEmpty {
            let text = String(decoding: body.prefix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(L("Inizio della risposta:"))
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    private func checkHTTP(_ action: String, _ response: URLResponse, body: Data?) throws {
        let detail = diagnostics(action, response, body)
        guard let http = response as? HTTPURLResponse else { throw fail(L("Nessuna risposta dal server."), hint: nil, detail: detail) }
        if let via = http.value(forHTTPHeaderField: "x-vercel-id") ?? http.value(forHTTPHeaderField: "x-nf-request-id"), !via.isEmpty {
            throw fail(L("Il sito è servito da Vercel/Netlify: si pubblica con la sua pipeline, non con Mirrorpress."), hint: nil, detail: detail)
        }
        let waf = http.allHeaderFields.keys.contains { (($0 as? String) ?? "").lowercased().contains("waf") }
        switch http.statusCode {
        case 200: return
        case 404:
            throw fail(L("Ponte non trovato all'indirizzo del sito (404)."),
                       hint: L("Il file è stato caricato in una cartella che non corrisponde a %@. Scegli con «Sfoglia…» la cartella giusta o correggi l'indirizzo del sito.", url.deletingLastPathComponent().absoluteString),
                       detail: detail)
        case 403:
            throw fail(L("Richiesta al ponte rifiutata (403)."),
                       hint: waf ? L("L'hosting ha un firewall (WAF) attivo che probabilmente blocca le richieste del ponte: chiedi all'assistenza di consentirlo o prova la modalità manuale.")
                                 : L("Firma rifiutata (orologio del server molto sballato) o richiesta bloccata da un firewall dell'hosting."),
                       detail: detail)
        case 401:
            throw fail(L("Il sito chiede una password HTTP (401)."), hint: L("Inseriscila nel profilo, sezione Avanzate."), detail: detail)
        case 410:
            throw fail(L("Il ponte sul server è scaduto."), hint: L("Rifai l'analisi per reinstallarlo."), detail: detail)
        case 500...599:
            throw fail(L("Errore del server (%d) eseguendo il ponte.", http.statusCode),
                       hint: L("PHP si è interrotto: versione di PHP troppo vecchia, memoria o funzioni disattivate dall'hosting. Guarda i dettagli e il log degli errori dell'hosting."),
                       detail: detail)
        default:
            throw fail(L("Il server ha risposto %d.", http.statusCode), hint: nil, detail: detail)
        }
    }

    private func send(_ action: String, body: Data) async throws -> JSONValue {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.upload(for: request(action, body: body), from: body)
        } catch {
            throw describeNetworkError(error, url: url).adding(detail: L("Azione del ponte: %@", action))
        }
        try checkHTTP(action, response, body: data)
        return try bridgeResult(data, context: L("server"), diagnostics: { self.diagnostics(action, response, data) })
    }

    private func withDB(_ p: [String: Any]) -> [String: Any] {
        var p = p
        if let db, p["db"] == nil { p["db"] = db }
        return p
    }

    func call(_ action: String, _ params: [String: Any]) async throws -> JSONValue {
        try await send(action, body: try encodeParams(withDB(params)))
    }

    func callRaw(_ action: String, _ params: [String: Any], body: Data) async throws -> JSONValue {
        var data = Data("J ".utf8)
        data += try encodeParams(withDB(params))
        data += Data("\n".utf8)
        data += body
        return try await send(action, body: data)
    }

    func stream(_ action: String, _ params: [String: Any], to file: URL) async throws {
        let body = try encodeParams(withDB(params))
        var req = request(action, body: body)
        req.httpBody = body
        let tmp: URL, response: URLResponse
        do {
            (tmp, response) = try await session.download(for: req)
        } catch {
            throw describeNetworkError(error, url: url).adding(detail: L("Azione del ponte: %@", action))
        }
        try checkHTTP(action, response, body: try? Data(contentsOf: tmp))
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: tmp, to: file)
        try checkStreamFile(file)
    }

    // Certificati non validi (hosting condivisi con certificato di un altro dominio): solo se richiesto.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if allowInvalidCertificates, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
