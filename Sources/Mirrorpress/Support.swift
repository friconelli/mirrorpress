import Foundation
import CryptoKit

// MARK: - JSON dinamico

/// Le risposte del ponte PHP sono tipizzate in modo lasco (WP_DEBUG può essere bool o stringa):
/// si leggono con questo tipo, senza far fallire la decodifica.
enum JSONValue: Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    static func parse(_ data: Data) throws -> JSONValue {
        JSONValue(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    subscript(key: String) -> JSONValue {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> JSONValue {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var int: Int? {
        switch self {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    var int64: Int64 { if case .number(let n) = self { return Int64(n) }; return Int64(string ?? "") ?? 0 }
    /// Valore "vero" alla PHP: true, 1, "1", "true".
    var truthy: Bool {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return !["", "0", "false"].contains(s.lowercased())
        default: return false
        }
    }
    var array: [JSONValue] { if case .array(let a) = self { return a }; return [] }
    var object: [String: JSONValue] { if case .object(let o) = self { return o }; return [:] }
    var isNull: Bool { self == .null }
}

// MARK: - Gzip

enum Gzip {
    /// Decomprime un membro gzip (formato di gzencode/deflate_init di PHP).
    static func decompress(_ data: Data) throws -> Data {
        let b = [UInt8](data.prefix(512))
        guard b.count >= 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw MirrorpressError.message(L("Dati compressi non validi.")) }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { // FEXTRA
            let xlen = Int(data[data.startIndex + i]) | Int(data[data.startIndex + i + 1]) << 8
            i += 2 + xlen
        }
        if flags & 0x08 != 0 { while data[data.startIndex + i] != 0 { i += 1 }; i += 1 } // FNAME
        if flags & 0x10 != 0 { while data[data.startIndex + i] != 0 { i += 1 }; i += 1 } // FCOMMENT
        if flags & 0x02 != 0 { i += 2 } // FHCRC
        let body = data.subdata(in: (data.startIndex + i)..<(data.endIndex - 8))
        return try (body as NSData).decompressed(using: .zlib) as Data
    }

    /// Deflate grezzo (il ponte lo legge con gzinflate).
    static func deflate(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .zlib) as Data
    }

    static func isGzip(_ data: Data) -> Bool {
        data.count > 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }
}

// MARK: - Errori, hash, formati

/// Errore con tre livelli: cosa è successo (message), cosa fare (hint), dati tecnici per capire (detail).
/// Il Log mostra tutti e tre; message da solo deve già essere comprensibile.
enum MirrorpressError: LocalizedError {
    case message(String)
    case detailed(message: String, hint: String?, detail: String?)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .detailed(let m, _, _): return m
        }
    }
    var hint: String? { if case .detailed(_, let h, _) = self { return h }; return nil }
    var detail: String? { if case .detailed(_, _, let d) = self { return d }; return nil }

    /// Stesso errore con altri dati tecnici in coda.
    func adding(detail extra: String) -> MirrorpressError {
        let d = [detail, extra].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        return .detailed(message: errorDescription ?? "", hint: hint, detail: d)
    }
}

func fail(_ message: String) -> MirrorpressError { .message(message) }

func fail(_ message: String, hint: String?, detail: String? = nil) -> MirrorpressError {
    .detailed(message: message, hint: hint, detail: detail)
}

/// Traduce gli errori di rete di macOS in messaggi chiari, con i dati tecnici a parte.
func describeNetworkError(_ error: Error, url: URL?) -> MirrorpressError {
    if let e = error as? MirrorpressError { return e }
    let ns = error as NSError
    let place = url.map { L("Indirizzo: %@", $0.absoluteString) } ?? ""
    let detail = [place, "\(ns.domain) \(ns.code): \(ns.localizedDescription)"].filter { !$0.isEmpty }.joined(separator: "\n")
    guard let u = error as? URLError else { return fail(error.localizedDescription, hint: nil, detail: detail) }
    switch u.code {
    case .cannotFindHost, .dnsLookupFailed:
        return fail(L("Il dominio del sito non risponde (DNS)."), hint: L("Controlla l'indirizzo del sito nel profilo."), detail: detail)
    case .timedOut:
        return fail(L("Il server non ha risposto in tempo."), hint: L("Riprova: se si ripete, l'hosting potrebbe limitare le richieste lunghe."), detail: detail)
    case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
        return fail(L("Connessione al sito non riuscita."), hint: L("Controlla la connessione a Internet e l'indirizzo del sito."), detail: detail)
    case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .secureConnectionFailed:
        return fail(L("Certificato HTTPS del sito non valido."), hint: L("Attiva «Accetta certificati TLS non validi» nel profilo, oppure usa l'indirizzo con il dominio giusto."), detail: detail)
    case .httpTooManyRedirects:
        return fail(L("Il sito rimanda in un giro di redirect."), hint: L("Usa nel profilo l'indirizzo finale del sito (con o senza www, https)."), detail: detail)
    default:
        return fail(u.localizedDescription, hint: nil, detail: detail)
    }
}

enum Hashing {
    static func md5(file url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var h = Insecure.MD5()
        while true {
            let chunk = fh.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            h.update(data: chunk)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func hmacSHA256(key: String, message: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(key.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func randomHex(_ bytes: Int) -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    static func date(_ t: TimeInterval) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}

extension String {
    /// Percent-encoding come rawurlencode di PHP (RFC 3986).
    var rawURLEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }

    /// Versione con le barre "\/" come nel JSON di WordPress.
    var jsonEscapedSlashes: String { replacingOccurrences(of: "/", with: "\\/") }

    func trimmingSlashes() -> String { trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
}

// MARK: - Esclusioni

/// Stesse regole di trv_excluded() nel ponte: "nome" vale a qualunque livello, "a/b" è ancorato alla root.
struct ExcludeMatcher {
    let patterns: [String]

    init(_ patterns: [String]) {
        self.patterns = patterns.map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    func excludes(_ rel: String, name: String) -> Bool {
        for p in patterns {
            if p.contains("/") {
                if fnmatch(p, rel, 0) == 0 || rel.hasPrefix(p + "/") { return true }
            } else if fnmatch(p, name, 0) == 0 {
                return true
            }
        }
        return false
    }
}
