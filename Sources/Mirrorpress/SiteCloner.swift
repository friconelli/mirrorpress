import Foundation

/// Dati di accesso a un database (per il wp-config della copia).
struct DBCredentials {
    var name: String
    var user: String
    var password: String
    var host: String
}

/// Riscrive i file che cambiano da un ambiente all'altro quando si crea una copia del sito:
/// wp-config.php (database, indirizzi, cache, inclusioni dell'hosting) e .htaccess (regole di WordPress e RewriteBase).
enum SiteCloner {
    /// Stringa PHP tra apici singoli.
    static func phpQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// Sostituisce il valore di `define('NOME', …)`; se la costante non c'è e `addIfMissing`, la aggiunge prima di «That's all».
    static func setDefine(_ src: String, _ name: String, _ phpValue: String, addIfMissing: Bool = false) -> String {
        let pattern = "define\\s*\\(\\s*(['\"])\(NSRegularExpression.escapedPattern(for: name))\\1\\s*,\\s*('(?:\\\\.|[^'\\\\])*'|\"(?:\\\\.|[^\"\\\\])*\"|[^)]*?)\\s*\\)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return src }
        let range = NSRange(src.startIndex..., in: src)
        if re.firstMatch(in: src, range: range) != nil {
            let template = NSRegularExpression.escapedTemplate(for: "define( '\(name)', \(phpValue) )")
            return re.stringByReplacingMatches(in: src, range: range, withTemplate: template)
        }
        guard addIfMissing else { return src }
        let line = "define( '\(name)', \(phpValue) );\n"
        if let r = src.range(of: "/* That's all") ?? src.range(of: "/** Absolute path") ?? src.range(of: "if ( ! defined( 'ABSPATH' ) )") {
            return src.replacingCharacters(in: r.lowerBound..<r.lowerBound, with: line)
        }
        return src + "\n" + line
    }

    /// wp-config.php per la copia: database nuovo, indirizzi nuovi, cache spenta in locale,
    /// inclusioni dell'hosting (percorsi assoluti fuori dal sito) commentate. Restituisce anche le note per il Log.
    static func rewriteWPConfig(_ src: String, db: DBCredentials, url: String, toLocal: Bool) -> (String, [String]) {
        var s = src
        var notes: [String] = []
        s = setDefine(s, "DB_NAME", phpQuote(db.name))
        s = setDefine(s, "DB_USER", phpQuote(db.user))
        s = setDefine(s, "DB_PASSWORD", phpQuote(db.password))
        s = setDefine(s, "DB_HOST", phpQuote(db.host))
        for c in ["WP_HOME", "WP_SITEURL"] where s.contains(c) {
            s = setDefine(s, c, phpQuote(url))
            notes.append(L("%@ impostato a %@.", c, url))
        }
        if toLocal {
            if s.range(of: "define\\s*\\(\\s*['\"]WP_CACHE['\"]", options: .regularExpression) != nil {
                s = setDefine(s, "WP_CACHE", "false")
                notes.append(L("WP_CACHE spento: la cache dell'hosting sul Mac non c'è."))
            }
            // Inclusioni con percorsi assoluti dell'hosting (es. WP Engine, SiteGround): sul Mac non esistono.
            var lines = s.components(separatedBy: "\n")
            for i in lines.indices {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") || t.hasPrefix("#") { continue }
                if t.range(of: "^(require|include)(_once)?\\s*\\(?\\s*['\"]/", options: .regularExpression) != nil {
                    lines[i] = "// [Mirrorpress] " + lines[i]
                    notes.append(L("Inclusione dell'hosting commentata: %@", t))
                }
            }
            s = lines.joined(separator: "\n")
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let header = toLocal ? "// Copia locale creata da Mirrorpress il \(stamp): database MAMP." : "// Copia sul server creata da Mirrorpress il \(stamp)."
        if let r = s.range(of: "<?php") {
            s.replaceSubrange(r, with: "<?php\n" + header)
        }
        return (s, notes)
    }

    /// Cartella del sito vista dal browser: "/" per un dominio, "/sito/" per http://localhost:8888/sito.
    static func base(of url: String) -> String {
        var p = URL(string: url)?.path ?? "/"
        if p.isEmpty { p = "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        if !p.hasSuffix("/") { p += "/" }
        return p
    }

    static func wordpressBlock(base: String) -> String {
        """
        # BEGIN WordPress
        <IfModule mod_rewrite.c>
        RewriteEngine On
        RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
        RewriteBase \(base)
        RewriteRule ^index\\.php$ - [L]
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteCond %{REQUEST_FILENAME} !-d
        RewriteRule . \(base)index.php [L]
        </IfModule>
        # END WordPress
        """
    }

    /// .htaccess per la copia. In locale solo il blocco di WordPress (le regole dell'hosting, es. https forzato o cache,
    /// su MAMP rompono il sito). Sul server si tengono le regole personalizzate del sito e si rifà il blocco di WordPress.
    static func rewriteHtaccess(_ src: String?, url: String, toLocal: Bool) -> String {
        let block = wordpressBlock(base: base(of: url))
        guard let src, !toLocal else {
            return "# Creato da Mirrorpress per la copia locale (le regole dell'hosting restano sul server).\n" + block + "\n"
        }
        if let a = src.range(of: "# BEGIN WordPress"), let b = src.range(of: "# END WordPress"), a.lowerBound < b.upperBound {
            return src.replacingCharacters(in: a.lowerBound..<b.upperBound, with: block)
        }
        return block + "\n\n" + src
    }

    /// Nome valido per un database o una cartella: minuscole, cifre, trattini bassi.
    static func slug(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let mapped = folded.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        let collapsed = mapped.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}
