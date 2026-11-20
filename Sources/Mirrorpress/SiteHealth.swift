import Foundation
import AppKit

// MARK: - Salute del sito: cosa vede un visitatore

/// Esito del controllo di un indirizzo: cosa si vede, perché e come risolvere.
struct HealthReport: Hashable {
    enum Level: Int, Comparable {
        case ok = 0, notice = 1, warning = 2, error = 3      // notice = voluto (manutenzione, password), o non verificabile
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    /// Il tipo di problema: decide anche quali azioni offrire.
    enum Kind: String { case ok, critical, database, maintenanceStuck, comingSoon, serverError, phpVisible, phpWarnings,
                        phpSource, blank, authRequired, forbidden, notFound, redirectLoop, gateway, dns, certificate,
                        timeout, refused, offline, network, other }

    var side: Side
    var url: String
    var level: Level
    var kind: Kind
    var title: String
    var explanation: String
    var steps: [String]
    var detail: String
    var status: Int?
    var checkedAt = Date()

    var needsAttention: Bool { level >= .warning }
}

/// Quello che è tornato da una richiesta HTTP (o l'errore di rete).
struct HTTPSnapshot {
    var status: Int?
    var headers: [String: String] = [:]   // chiavi minuscole
    var body = ""
    var finalURL: URL?
    var errorCode: Int?                   // NSURLErrorDomain
    var errorText = ""
}

enum SiteHealth {
    // MARK: Richiesta

    /// Scarica la pagina come un visitatore (senza cache, segue i redirect, al massimo 1 MB).
    static func fetch(_ url: URL, httpUser: String = "", httpPassword: String = "", timeout: TimeInterval = 20) async -> HTTPSnapshot {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 10
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh) Mirrorpress-health", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,*/*", forHTTPHeaderField: "Accept")
        if !httpUser.isEmpty {
            let token = Data("\(httpUser):\(httpPassword)".utf8).base64EncodedString()
            req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        var snap = HTTPSnapshot()
        do {
            let (data, resp) = try await session.data(for: req)
            if let h = resp as? HTTPURLResponse {
                snap.status = h.statusCode
                for (k, v) in h.allHeaderFields { snap.headers[String(describing: k).lowercased()] = String(describing: v) }
            }
            snap.finalURL = resp.url
            snap.body = String(decoding: data.prefix(1 << 20), as: UTF8.self)
        } catch {
            let ns = error as NSError
            snap.errorCode = ns.domain == NSURLErrorDomain ? ns.code : nil
            snap.errorText = ns.localizedDescription
        }
        return snap
    }

    /// Controllo completo di un indirizzo: se c'è un errore riprova (errori intermittenti) e prova anche wp-login.php.
    static func check(_ urlString: String, side: Side, httpUser: String = "", httpPassword: String = "") async -> HealthReport? {
        let s = urlString.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, let url = URL(string: s.hasSuffix("/") ? s : s + "/"), url.scheme?.hasPrefix("http") == true else { return nil }
        let first = await fetch(url, httpUser: httpUser, httpPassword: httpPassword)
        var report = classify(first, url: url.absoluteString, side: side)
        guard report.level == .error, ![.offline, .dns, .certificate].contains(report.kind) else { return report }

        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let second = await fetch(url, httpUser: httpUser, httpPassword: httpPassword)
        let again = classify(second, url: url.absoluteString, side: side)
        if again.level < .warning {
            report.level = .warning
            report.title = L("Errore intermittente: %@", report.title)
            report.explanation = L("Al primo tentativo il sito ha dato questo errore, al secondo ha risposto («%@»). Succede con errori che dipendono dalla cache, dal carico o da un'operazione pianificata (cron).", again.title) + " " + report.explanation
            return report
        }
        // Il pannello funziona anche se il sito no? Allora si può entrare e disattivare il plugin.
        if [.critical, .serverError, .blank, .phpVisible].contains(report.kind) {
            let login = await fetch(url.appendingPathComponent("wp-login.php"), httpUser: httpUser, httpPassword: httpPassword, timeout: 15)
            if login.status == 200, login.body.contains("user_login") {
                report.steps.insert(L("La pagina di accesso (wp-login.php) funziona: puoi entrare nel pannello e disattivare il plugin sospetto da lì."), at: min(1, report.steps.count))
            }
        }
        return report
    }

    // MARK: Classificazione (pura, testata)

    static func classify(_ r: HTTPSnapshot, url: String, side: Side) -> HealthReport {
        func rep(_ level: HealthReport.Level, _ kind: HealthReport.Kind, _ title: String, _ why: String, _ steps: [String], extra: String = "") -> HealthReport {
            var d = [url]
            if let s = r.status { d.append("HTTP \(s)") }
            if let f = r.finalURL, f.absoluteString != url { d.append(L("Arrivo: %@", f.absoluteString)) }
            if let srv = r.headers["server"] { d.append("server: \(srv)") }
            if !r.errorText.isEmpty { d.append(r.errorText) }
            if !extra.isEmpty { d.append(extra) }
            return HealthReport(side: side, url: url, level: level, kind: kind, title: title, explanation: why, steps: steps,
                                detail: d.joined(separator: "\n"), status: r.status)
        }
        let local = side == .local

        // Errori di rete
        if let code = r.errorCode {
            switch code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return rep(.notice, .offline, L("Il Mac non è connesso a internet"), L("Non si può verificare il sito adesso."), [])
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return rep(.error, .dns, L("Il dominio non risponde (DNS)"), L("Il nome del sito non porta a nessun server."),
                           [L("Controlla che il dominio non sia scaduto (pannello del registrar o dell'hosting)."),
                            L("Se hai cambiato hosting o DNS da poco, aspetta la propagazione (fino a 24-48 ore)."),
                            L("Verifica che l'indirizzo nel profilo sia scritto giusto.")])
            case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorSecureConnectionFailed, NSURLErrorClientCertificateRejected:
                return rep(.error, .certificate, L("Certificato HTTPS non valido o scaduto"), L("I browser mostrano «Connessione non sicura» e molti visitatori se ne vanno."),
                           [L("Rinnova o riattiva il certificato SSL nel pannello dell'hosting (spesso Let's Encrypt, gratuito)."),
                            L("Controlla che il certificato copra il nome esatto (con e senza www)."),
                            L("Se il dominio è appena passato a un altro hosting, il certificato va emesso di nuovo lì.")])
            case NSURLErrorHTTPTooManyRedirects:
                return rep(.error, .redirectLoop, L("Redirect infiniti"), L("Il sito rimanda a sé stesso all'infinito: il browser dice «troppi reindirizzamenti»."),
                           [L("Controlla siteurl e home nel database (o WP_HOME/WP_SITEURL nel wp-config): devono avere lo stesso schema (https) e lo stesso www del dominio."),
                            L("Dietro un proxy (Aruba, Cloudflare) WordPress può non accorgersi dell'HTTPS: aggiungi nel wp-config `if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') $_SERVER['HTTPS'] = 'on';`."),
                            L("Disattiva per prova i plugin di redirect/SSL (Really Simple SSL, Redirection) e le regole di redirect nel .htaccess.")])
            case NSURLErrorTimedOut:
                return rep(.error, .timeout, L("Il sito non risponde (tempo scaduto)"), L("Il server ha accettato la connessione ma non ha mandato la pagina in tempo."),
                           [L("Riprova fra qualche minuto: può essere un picco di carico."),
                            L("Se dura, controlla nel pannello dell'hosting uso di CPU e processi PHP: un plugin può bloccare tutto (cron, backup, import)."),
                            L("Premi «Diagnosi» per leggere gli ultimi errori PHP.")])
            case NSURLErrorCannotConnectToHost:
                if local { return rep(.notice, .refused, L("MAMP è spento"), L("Il server locale non risponde a questo indirizzo."), [L("Avvia MAMP (Apache e MySQL) e ricontrolla.")]) }
                return rep(.error, .refused, L("Il server rifiuta la connessione"), L("Nessun server web risponde sull'indirizzo del sito."),
                           [L("Controlla nel pannello dell'hosting che il servizio sia attivo e non sospeso (fatture, abusi)."),
                            L("Verifica che il dominio punti all'IP giusto.")])
            default:
                return rep(.error, .network, L("Errore di rete: %@", r.errorText), L("La richiesta non è arrivata al sito."), [L("Riprova fra poco; se dura, controlla dominio e hosting.")])
            }
        }

        let status = r.status ?? 0
        let text = visibleText(r.body)
        let lower = (r.body + " " + text).lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { lower.contains($0) } }
        let isWPDie = r.body.contains("id=\"error-page\"") || r.body.contains("wp-die-message")

        if has(["errore critico", "critical error on this website", "there has been a critical error", "errore critico in questo sito"]) {
            return rep(.error, .critical, L("WordPress: «Si è verificato un errore critico»"),
                       L("Un errore PHP fatale ferma il sito: quasi sempre un plugin o il tema, spesso dopo un aggiornamento di WordPress, di un plugin o della versione di PHP."),
                       [L("Premi «Diagnosi»: Mirrorpress carica WordPress sul server e ti dice quale plugin o tema si rompe, con file e riga, e può disattivarlo."),
                        L("Guarda la posta dell'amministratore: WordPress manda una mail con il link alla «modalità di recupero» per entrare e disattivare il colpevole."),
                        L("Se è successo dopo un aggiornamento, disattiva quel plugin rinominando la sua cartella in wp-content/plugins (via FTP)."),
                        L("Se l'hosting ha cambiato versione di PHP, rimetti la precedente dal pannello e aggiorna tema e plugin.")],
                       extra: excerpt(text))
        }
        if has(["error establishing a database connection", "errore nello stabilire una connessione al database", "errore durante la connessione al database"]) {
            return rep(.error, .database, L("WordPress non riesce a collegarsi al database"),
                       L("I file ci sono ma il database non risponde o rifiuta le credenziali scritte nel wp-config."),
                       [L("Controlla nel pannello dell'hosting che il database esista e sia attivo (su Aruba: MySQL → stato e spazio occupato)."),
                        L("Confronta DB_NAME, DB_USER, DB_PASSWORD e DB_HOST nel wp-config con i dati del pannello: una password cambiata nel pannello va cambiata anche lì."),
                        L("Se il database ha superato lo spazio disponibile o il server MySQL è giù, serve l'assistenza dell'hosting."),
                        L("Premi «Diagnosi» per vedere l'errore esatto di MySQL.")])
        }
        if has(["briefly unavailable for scheduled maintenance", "momentaneamente non disponibile per manutenzione", "temporaneamente non disponibile per manutenzione"]) {
            return rep(.error, .maintenanceStuck, L("Bloccato in manutenzione dopo un aggiornamento"),
                       L("WordPress mette il file .maintenance durante gli aggiornamenti e lo toglie alla fine: se l'aggiornamento si interrompe, il sito resta così."),
                       [L("Se un aggiornamento è in corso, aspetta un paio di minuti."),
                        L("Altrimenti togli il file .maintenance dalla cartella del sito (Mirrorpress lo sposta in _da_eliminare con «Diagnosi»)."),
                        L("Poi entra nel pannello e controlla che plugin e WordPress siano aggiornati del tutto: un aggiornamento a metà può lasciare file mancanti.")])
        }
        if status == 503 || status >= 400 && has(["coming soon", "under construction", "in costruzione", "maintenance mode", "modalità manutenzione"]) {
            if has(["coming soon", "under construction", "in costruzione", "maintenance mode", "modalità manutenzione", "torneremo presto", "be back soon"]) || r.headers["retry-after"] != nil {
                return rep(.notice, .comingSoon, L("Sito in costruzione o in manutenzione (voluto)"),
                           L("Il sito mostra una pagina di cortesia ai visitatori (HTTP %d). Di solito è un plugin di manutenzione o «coming soon» acceso apposta.", status),
                           [L("Se è voluto, va bene così: chi è collegato al pannello vede il sito vero."),
                            L("Per pubblicarlo, spegni la modalità manutenzione dal plugin che la gestisce."),
                            L("Le pagine escluse dalla manutenzione (per esempio le lingue) restano visibili: controlla che sia quello che vuoi.")],
                           extra: excerpt(text))
            }
            if status == 503 {
                return rep(.error, .gateway, L("Servizio non disponibile (HTTP 503)"),
                           L("Il server non riesce a servire il sito: sovraccarico, limiti di risorse superati o sito sospeso."),
                           [L("Riprova fra qualche minuto."), L("Controlla nel pannello dell'hosting che il sito non sia sospeso e i limiti di risorse."), L("Premi «Diagnosi» per leggere gli ultimi errori PHP.")],
                           extra: excerpt(text))
            }
        }
        if let line = firstMatch(#"(?:PHP )?(?:Fatal error|Parse error)\s*:[^\n]{0,400}"#, in: text) {
            return rep(.error, .phpVisible, L("Errore PHP fatale visibile sulla pagina"),
                       L("PHP si è fermato e il messaggio arriva ai visitatori (con i percorsi del server)."),
                       [L("Il file e la riga nel messaggio dicono quale plugin o tema è il colpevole: aggiornalo o disattivalo."),
                        L("Premi «Diagnosi» per la conferma e per disattivarlo con un clic."),
                        L("Poi spegni la visualizzazione degli errori: WP_DEBUG_DISPLAY false nel wp-config.")],
                       extra: line)
        }
        if (200..<300).contains(status), r.body.contains("<?php") {
            return rep(.error, .phpSource, L("Il server mostra il codice PHP invece di eseguirlo"),
                       L("PHP non è attivo per questa cartella: chiunque può leggere il codice (e le password del wp-config se finisse in vista)."),
                       [L("Controlla nel pannello dell'hosting che PHP sia attivo per il dominio."),
                        L("Togli dal .htaccess eventuali righe AddHandler/SetHandler copiate da un altro hosting.")])
        }
        if status >= 500 && status != 503 {
            if [502, 504].contains(status) {
                return rep(.error, .gateway, L("Il server non risponde (HTTP %d)", status),
                           L("Il proxy dell'hosting non riceve la pagina da PHP in tempo: PHP è bloccato o sovraccarico."),
                           [L("Riprova fra qualche minuto."), L("Se dura, controlla nel pannello i processi PHP e i limiti di risorse."), L("Premi «Diagnosi» per leggere gli ultimi errori PHP.")])
            }
            return rep(.error, .serverError, L("Errore interno del server (HTTP %d)", status),
                       isWPDie ? L("WordPress si è fermato con un errore.") : L("Il server non riesce a generare la pagina: errore PHP con gli errori nascosti, oppure una regola del .htaccess non supportata."),
                       [L("Premi «Diagnosi»: legge gli ultimi errori PHP del server e prova ad avviare WordPress per trovare il colpevole."),
                        L("Se è comparso dopo aver copiato il sito da un altro hosting, controlla il .htaccess (direttive php_value, AddHandler, Options)."),
                        L("Controlla nel pannello dell'hosting il log degli errori e il limite di memoria PHP.")],
                       extra: excerpt(text))
        }
        if status == 401 {
            return rep(.notice, .authRequired, L("Il sito chiede una password (HTTP 401)"),
                       L("È protetto da una password del server: normale per uno staging."),
                       [L("Se è il sito pubblico, togli la protezione dal pannello dell'hosting (o dal .htaccess)."),
                        L("Per far entrare Mirrorpress, scrivi utente e password HTTP nel profilo.")])
        }
        if status == 403 {
            return rep(.error, .forbidden, L("Accesso negato (HTTP 403)"), L("Il server rifiuta di mostrare la pagina."),
                       [L("Controlla il .htaccess: regole «Deny from all» o «Require» copiate per errore."),
                        L("Controlla i permessi: cartelle 755, file 644, index.php leggibile."),
                        L("Un firewall dell'hosting (WAF) o un plugin di sicurezza può bloccare il tuo IP: prova da un'altra rete.")])
        }
        if status == 404 && (r.body.contains("wp-content") || r.body.contains("wp-includes")) {
            // Risponde WordPress: il sito c'è, è la home che non si trova (lingue, permalink).
            return rep(local ? .warning : .error, .notFound, L("WordPress non trova la home (HTTP 404)"),
                       L("Il sito funziona ma la pagina iniziale risulta «non trovata». Succede con i siti in più lingue, dove la home vera è /it/ o /en/, o dopo aver copiato il sito, finché non si risalvano i permalink."),
                       [L("Apri il sito nel browser e prova una pagina interna, per esempio /it/: se funziona, il problema è solo la home."),
                        L("Nel pannello di WordPress vai in Impostazioni → Permalink e premi «Salva le modifiche»."),
                        L("Se il sito è in più lingue, controlla nel plugin delle lingue qual è la lingua principale e come appare nell'indirizzo.")])
        }
        if status == 404 && local {
            return rep(.warning, .notFound, L("Il sito in locale non è a questo indirizzo (HTTP 404)"),
                       L("MAMP risponde, ma a questo indirizzo non c'è WordPress."),
                       [L("Premi «Analizza»: Mirrorpress legge l'indirizzo giusto dal database locale."),
                        L("Oppure scrivi l'indirizzo esatto nel profilo, alla voce «Indirizzo locale»."),
                        L("In MAMP controlla che la cartella dei documenti sia htdocs (Impostazioni → Server).")])
        }
        if status == 404 {
            return rep(.error, .notFound, L("Pagina non trovata (HTTP 404) sulla home"), L("Il dominio risponde ma nella cartella non c'è il sito."),
                       [L("Controlla nel pannello dell'hosting che il dominio punti alla cartella dove hai caricato WordPress."),
                        L("Verifica che nella cartella ci siano index.php e .htaccess."),
                        L("Se la home è una pagina di WordPress, risalva i permalink dal pannello.")])
        }
        if (400..<500).contains(status) {
            return rep(.warning, .other, L("Il sito risponde con HTTP %d", status), L("Il server non mostra la pagina."), [L("Apri il sito nel browser per vedere il messaggio.")], extra: excerpt(text))
        }
        if (200..<300).contains(status) {
            if text.count < 20 && !r.body.lowercased().contains("<img") && !r.body.lowercased().contains("<script") {
                return rep(.error, .blank, L("Pagina bianca"), L("Il server risponde ma la pagina è vuota: di solito un errore PHP con la visualizzazione degli errori spenta."),
                           [L("Premi «Diagnosi» per leggere gli ultimi errori PHP e trovare il plugin o tema colpevole."),
                            L("Se hai cambiato tema o PHP da poco, torna alla situazione precedente.")])
            }
            if let line = firstMatch(#"(?:Warning|Deprecated|Notice)\s*:[^\n]{0,300}\bon line \d+"#, in: text) {
                return rep(.warning, .phpWarnings, L("Avvisi PHP visibili ai visitatori"),
                           L("Il sito funziona ma mostra messaggi tecnici con i percorsi del server."),
                           [L("Nel wp-config del server metti WP_DEBUG false (o almeno WP_DEBUG_DISPLAY false)."),
                            L("Aggiorna il plugin o il tema indicato nel messaggio.")],
                           extra: line)
            }
        }
        return rep(.ok, .ok, L("Il sito risponde (HTTP %d)", status), "", [])
    }

    /// Testo che vede il visitatore: senza head, script e stili, entità decodificate, spazi compressi.
    static func visibleText(_ html: String) -> String {
        var t = html
        for tag in ["head", "script", "style", "noscript"] {
            t = t.replacingOccurrences(of: "<\(tag)\\b[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        t = t.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#039;": "'", "&rsquo;": "’", "&rsaquo;": "›", "&egrave;": "è", "&agrave;": "à"]
        for (k, v) in entities { t = t.replacingOccurrences(of: k, with: v) }
        t = t.replacingOccurrences(of: "[ \\t\\r]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func excerpt(_ text: String) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
        return one.count > 400 ? String(one.prefix(400)) + "…" : one
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespaces)
    }

    /// L'indirizzo locale: quello del profilo, quello letto dal database, oppure MAMP (localhost:8888/cartella).
    static func localAddress(_ site: SiteProfile, known: String = "") -> String {
        let u = site.localURL.trimmingCharacters(in: .whitespaces)
        if !u.isEmpty { return u }
        if !known.isEmpty { return known }
        let htdocs = "/Applications/MAMP/htdocs/"
        if site.localPath.hasPrefix(htdocs) {
            let rel = String(site.localPath.dropFirst(htdocs.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return "http://localhost:8888/" + rel
        }
        return ""
    }
}

// MARK: - Controllo periodico di tutti i siti

@MainActor
final class HealthMonitor: ObservableObject {
    @Published private(set) var reports: [UUID: [Side: HealthReport]] = [:]
    @Published private(set) var checking: Set<UUID> = []
    private var timer: Timer?
    /// Indirizzi locali letti dal database durante l'analisi (più affidabili della deduzione da MAMP).
    var knownLocalURL: [UUID: String] = [:]

    func report(_ id: UUID, _ side: Side) -> HealthReport? { reports[id]?[side] }

    /// Il problema più grave del sito (server prima del locale a parità di gravità).
    func worst(_ id: UUID) -> HealthReport? {
        [reports[id]?[.remote], reports[id]?[.local]].compactMap { $0 }.max { $0.level < $1.level }
    }

    func start(_ sites: @escaping () -> [SiteProfile]) {
        guard timer == nil else { return }
        Task { await checkAll(sites()) }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkAll(sites()) }
        }
    }

    func checkAll(_ sites: [SiteProfile]) async {
        await withTaskGroup(of: Void.self) { group in
            for s in sites { group.addTask { await self.check(s) } }
        }
    }

    func check(_ site: SiteProfile) async {
        guard !checking.contains(site.id) else { return }
        checking.insert(site.id)
        defer { checking.remove(site.id) }
        let pass = site.httpAuthUser.isEmpty ? "" : Secret.httpAuth.get(site)
        async let remote = SiteHealth.check(site.remoteURL, side: .remote, httpUser: site.httpAuthUser, httpPassword: pass)
        async let local = SiteHealth.check(SiteHealth.localAddress(site, known: knownLocalURL[site.id] ?? ""), side: .local)
        var out: [Side: HealthReport] = [:]
        out[.remote] = await remote
        out[.local] = await local
        reports[site.id] = out
        updateDockBadge()
    }

    private func updateDockBadge() {
        let n = reports.values.filter { ($0[.remote]?.level ?? .ok) == .error }.count
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }
}

// MARK: - Diagnosi con il ponte

/// Esito dell'azione "diagnose" del ponte: log degli errori, .maintenance, database e prova di avvio di WordPress.
struct Diagnosis {
    struct Culprit: Hashable {
        let kind: String     // plugins, mu-plugins, themes, core
        let slug: String
        var label: String {
            switch kind {
            case "plugins": return L("il plugin «%@»", slug)
            case "mu-plugins": return L("il plugin obbligatorio (mu-plugin) «%@»", slug)
            case "themes": return L("il tema «%@»", slug)
            default: return L("un file del core di WordPress (%@)", slug)
            }
        }
        var canDisable: Bool { kind == "plugins" || kind == "mu-plugins" }
    }

    let side: Side
    let raw: JSONValue
    var date = Date()

    var bootResult: String? { raw["boot"]["result"].string }      // ok, fatal, exit
    var bootMessage: String { raw["boot"]["message"].string ?? "" }
    var bootFile: String { raw["boot"]["file"].string ?? "" }
    var bootLine: Int { raw["boot"]["line"].int ?? 0 }
    var bootOutput: String { raw["boot"]["output"].string ?? "" }
    var maintenance: Bool { !raw["maintenance"].isNull }
    var maintenanceAge: Int { raw["maintenance"]["age"].int ?? 0 }
    var dbError: String? { raw["db"].truthy ? nil : raw["db_error"].string }
    var logs: [(path: String, fatal: Int, last: [String], mtime: Int)] {
        raw["logs"].array.map { ($0["path"].string ?? "", $0["fatal"].int ?? 0, $0["last"].array.compactMap(\.string), $0["mtime"].int ?? 0) }
    }
    /// Errori fatali più recenti dai log (tutti i file), dal più recente.
    var recentFatals: [String] { logs.flatMap(\.last).sorted { (Self.logDate($0) ?? .distantPast) > (Self.logDate($1) ?? .distantPast) } }

    /// Chi rompe il sito: dal file dell'errore fatale all'avvio, altrimenti dall'ultimo errore nei log.
    var culprit: Culprit? {
        if bootResult == "fatal", let c = Self.culprit(in: bootFile) { return c }
        if bootResult == "fatal", let c = Self.culprit(in: bootMessage) { return c }
        for line in recentFatals { if let c = Self.culprit(in: line) { return c } }
        return nil
    }

    static func culprit(in text: String) -> Culprit? {
        if let r = text.range(of: #"wp-content/(plugins|mu-plugins|themes)/([^/\s:'"]+)"#, options: .regularExpression) {
            let parts = text[r].split(separator: "/")
            if parts.count >= 3 { return Culprit(kind: String(parts[1]), slug: String(parts[2])) }
        }
        if let r = text.range(of: #"wp-(includes|admin)/[^\s:'"]+"#, options: .regularExpression) { return Culprit(kind: "core", slug: String(text[r])) }
        return nil
    }

    static func logDate(_ line: String) -> Date? {
        guard let r = line.range(of: #"^\[(\d{2}-\w{3}-\d{4} \d{2}:\d{2}:\d{2})"#, options: .regularExpression) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "dd-MMM-yyyy HH:mm:ss"
        return f.date(from: String(line[r].dropFirst()))
    }

    /// Spiegazione in parole semplici e cosa fare.
    var verdict: (title: String, text: String, steps: [String]) {
        if maintenance, maintenanceAge > 600 {
            return (L("C'è un file .maintenance rimasto da un aggiornamento interrotto"),
                    L("È lì da %@: WordPress mostra la pagina di manutenzione a tutti.", Format.duration(maintenanceAge)),
                    [L("Premi «Togli .maintenance»: il file finisce in _da_eliminare e il sito torna visibile."),
                     L("Poi dal pannello completa gli aggiornamenti rimasti a metà.")])
        }
        if let e = dbError {
            var steps = [L("Confronta DB_NAME, DB_USER, DB_PASSWORD e DB_HOST nel wp-config con i dati del database nel pannello dell'hosting.")]
            let l = e.lowercased()
            if l.contains("access denied") { steps.insert(L("MySQL rifiuta utente o password: probabilmente la password del database è stata cambiata nel pannello e non nel wp-config."), at: 0) }
            if l.contains("unknown database") { steps.insert(L("Il database con quel nome non esiste: controlla DB_NAME (su Aruba ha la forma Sql1234567_1)."), at: 0) }
            if l.contains("can't connect") || l.contains("no such file") || l.contains("connection refused") || l.contains("getaddrinfo") {
                steps.insert(L("Il server MySQL non risponde: controlla DB_HOST e lo stato del database nel pannello; se è giù serve l'assistenza dell'hosting."), at: 0)
            }
            return (L("Il database non risponde"), e, steps)
        }
        if bootResult == "fatal" {
            let place = bootFile.isEmpty ? "" : "\(bootFile):\(bootLine)"
            let who = culprit
            var steps: [String] = []
            if let who, who.canDisable {
                steps.append(L("Premi «Disattiva %@»: la cartella viene rinominata (niente viene cancellato) e WordPress lo spegne. Il sito dovrebbe tornare subito.", who.slug))
                steps.append(L("Poi aggiorna il plugin o cercane una versione compatibile con PHP %@, e riattivalo.", raw["php"].string ?? ""))
            } else if let who, who.kind == "themes" {
                steps.append(L("Il tema si rompe: aggiornalo, oppure correggi il file indicato. Se è un tema tuo, confrontalo con la versione in locale e invia quella giusta da «Sincronizza»."))
            } else if let who, who.kind == "core" {
                steps.append(L("Un file del core è rotto o mancante (aggiornamento a metà?): reinstalla la stessa versione di WordPress da Bacheca → Aggiornamenti, oppure invia wp-admin e wp-includes dal locale se ha la stessa versione."))
            }
            let mem = bootMessage.lowercased().contains("allowed memory size")
            if mem { steps.insert(L("È finita la memoria: alza WP_MEMORY_LIMIT nel wp-config (per esempio a 256M) o il limite di memoria PHP nel pannello."), at: 0) }
            if bootMessage.contains("undefined function") || bootMessage.contains("Unsupported operand") || bootMessage.contains("must be of type") {
                steps.append(L("Questo tipo di errore viene spesso da codice vecchio su un PHP nuovo: controlla se l'hosting ha cambiato versione di PHP."))
            }
            return (who.map { L("Il sito si rompe per colpa di %@", $0.label) } ?? L("WordPress si ferma con un errore fatale"),
                    bootMessage + (place.isEmpty ? "" : "\n" + place), steps)
        }
        if bootResult == "exit" {
            let out = bootOutput
            if out.lowercased().contains("database") {
                return (L("WordPress si ferma: problema di database"), out, [L("Controlla le tabelle e il prefisso ($table_prefix nel wp-config): devono corrispondere a quelle del database.")])
            }
            if let to = raw["boot"]["redirect"].string, !to.isEmpty {
                return (L("Durante l'avvio WordPress reindirizza a %@", to), out,
                        [L("Un plugin (sicurezza, lingua, manutenzione, SSL) manda altrove anche le richieste interne: se il sito va in loop di redirect, il colpevole è probabilmente lui."),
                         L("Controlla siteurl e home e i plugin di redirect.")])
            }
            return (L("WordPress si ferma da solo durante l'avvio"), out.isEmpty ? L("Nessun messaggio.") : out,
                    [L("Un plugin (sicurezza, cache, redirect) interrompe il caricamento: il messaggio qui sopra dice quale."),
                     L("Se il messaggio non basta, disattiva i plugin uno alla volta.")])
        }
        if let line = recentFatals.first {
            let who = culprit
            return (who.map { L("L'ultimo errore fatale nei log viene da %@", $0.label) } ?? L("Ci sono errori fatali recenti nei log"),
                    line,
                    [L("WordPress si avvia, quindi l'errore nasce mentre si disegna la pagina (tema o plugin che stampano contenuti) o in una pagina precisa."),
                     who?.canDisable == true ? L("Se l'errore è recente, prova a disattivare %@.", who!.slug) : L("Aggiorna o correggi il file indicato nell'errore.")])
        }
        if bootResult == "ok" {
            return (L("WordPress si avvia senza errori"),
                    L("Plugin, tema e database si caricano (in %d ms). Se il sito mostrava un errore, ora sembra passato: era intermittente o è già stato risolto.", raw["boot"]["ms"].int ?? 0),
                    [L("Ricontrolla il sito; se l'errore torna, ripeti la diagnosi subito dopo per leggere il log.")])
        }
        return (L("Nessun errore trovato"), "", [])
    }
}

extension Format {
    static func duration(_ seconds: Int) -> String {
        if seconds < 3600 { return L("%d minuti", max(1, seconds / 60)) }
        if seconds < 86400 * 2 { return L("%d ore", seconds / 3600) }
        return L("%d giorni", seconds / 86400)
    }
}

// MARK: - Diagnosi e correzioni dalla sessione

extension SiteSession {
    /// Si può installare il ponte sul server? (servono i dati di connessione, o il ponte a mano)
    var canReachRemoteBridge: Bool {
        site.connection == .manual || (!site.host.trimmingCharacters(in: .whitespaces).isEmpty && !site.username.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func endpoint(_ side: Side) async throws -> BridgeEndpoint {
        side == .remote ? try await ensureRemote() : local
    }

    /// Log degli errori, .maintenance, database e prova di avvio di WordPress sul lato scelto.
    func diagnose(_ side: Side) async {
        await perform(side == .remote ? L("Diagnosi del sito sul server") : L("Diagnosi del sito in locale")) {
            let e = try await endpoint(side)
            status(L("Leggo i log degli errori e provo ad avviare WordPress…"))
            let d = Diagnosis(side: side, raw: try await e.call("diagnose", ["boot": true]))
            diagnosis[side] = d
            let v = d.verdict
            let fine = d.bootResult == "ok" && d.recentFatals.isEmpty && d.dbError == nil && !d.maintenance
            note(v.title, fine ? .success : .warning, hint: v.steps.joined(separator: " "),
                 detail: ([v.text] + d.recentFatals.prefix(6)).filter { !$0.isEmpty }.joined(separator: "\n"))
        }
    }

    /// Spegne un plugin rinominandone la cartella (reversibile), poi ripete la diagnosi.
    func disableExtension(_ c: Diagnosis.Culprit, side: Side) async {
        await perform(L("Disattivo %@", c.slug)) {
            let r = try await endpoint(side).call("toggle_ext", ["kind": c.kind, "slug": c.slug, "on": false])
            note(L("%@ rinominato in %@: WordPress lo considera disattivato.", r["from"].string ?? c.slug, r["to"].string ?? ""), .success,
                 hint: L("Per riattivarlo: «Riattiva» qui, oppure rinomina la cartella togliendo .off-mirrorpress."))
            disabledExtensions[side, default: []].insert(c)
        }
        await diagnose(side)
    }

    func enableExtension(_ c: Diagnosis.Culprit, side: Side) async {
        await perform(L("Riattivo %@", c.slug)) {
            _ = try await endpoint(side).call("toggle_ext", ["kind": c.kind, "slug": c.slug, "on": true])
            note(L("Cartella di %@ rimessa a posto. Riattiva il plugin dal pannello di WordPress (Plugin → Attiva).", c.slug), .success)
            disabledExtensions[side]?.remove(c)
        }
    }

    /// Toglie il .maintenance rimasto (in _da_eliminare, non cancellato).
    func removeMaintenance(_ side: Side) async {
        await perform(L("Tolgo .maintenance")) {
            let r = try await endpoint(side).call("trash", ["paths": [".maintenance"]])
            note(L(".maintenance spostato in %@.", r["folder"].string ?? "_da_eliminare"), .success)
        }
        await diagnose(side)
    }
}
