import XCTest
@testable import Mirrorpress

/// Prova completa con MAMP: due copie (cloni APFS) di un sito locale, una fa da "server" servita da `php -S`.
/// Si attiva con MIRRORPRESS_E2E=1 (sito: MIRRORPRESS_E2E_SITE, predefinito villapatrizia). Non tocca il sito originale.
@MainActor
final class EndToEndTests: XCTestCase {
    let port = 8899
    var tmp: URL!
    var server: Process?
    let localDB = "mirrorpress_e2e_local"
    let remoteDB = "mirrorpress_e2e_remote"

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["MIRRORPRESS_E2E"] == "1" else { throw XCTSkip("MIRRORPRESS_E2E=1 per eseguirlo") }
        guard LocalEnv.phpBinary != nil else { throw XCTSkip("PHP di MAMP non trovato") }
        tmp = AppPaths.temp()
        setenv("MIRRORPRESS_SUPPORT_DIR", tmp.appendingPathComponent("support").path, 1)
    }

    override func tearDown() async throws {
        server?.terminate()
        if tmp != nil {
            _ = try? await mysql("DROP DATABASE IF EXISTS \(localDB); DROP DATABASE IF EXISTS \(remoteDB);")
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    @discardableResult
    func mysql(_ sql: String) async throws -> String {
        let r = try await Shell.run("/Applications/MAMP/Library/bin/mysql80/bin/mysql",
                                    ["-uroot", "-proot", "-h127.0.0.1", "-P8889", "-N", "-e", sql])
        XCTAssertTrue(r.ok, r.stderr)
        return r.text
    }

    /// Clona cartella + database del sito sorgente con un nome di DB, prefisso e indirizzo nuovi.
    func cloneSite(from src: URL, to dst: URL, db: String, prefix: String, url: String?) async throws {
        let cp = try await Shell.run("/bin/cp", ["-cR", src.path, dst.path])
        XCTAssertTrue(cp.ok, cp.stderr)
        let cfgURL = dst.appendingPathComponent("wp-config.php")
        var cfg = try String(contentsOf: cfgURL)
        let srcInfo = LocalEnv.wpConfig(at: src)
        cfg = cfg.replacingOccurrences(of: "'\(srcInfo["DB_NAME"]!)'", with: "'\(db)'")
        cfg = cfg.replacingOccurrences(of: "$table_prefix = '\(srcInfo["table_prefix"]!)'", with: "$table_prefix = '\(prefix)'")
        try cfg.write(to: cfgURL, atomically: true, encoding: .utf8)
        try await mysql("DROP DATABASE IF EXISTS \(db); CREATE DATABASE \(db) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;")

        let source = LocalBridge(root: src, workdir: tmp.appendingPathComponent("w-src"), db: nil)
        let target = LocalBridge(root: dst, workdir: tmp.appendingPathComponent("w-\(db)"), db: nil)
        let info = SiteInfo(raw: try await source.call("info", [:]))
        let tables = Compare.tables(try await source.call("db_tables", ["budget": 0]))
        var map: [String: String] = [:]
        for t in tables where t.name.hasPrefix(info.dbPrefix) { map[t.name] = "trvclone_" + prefix + t.name.dropFirst(info.dbPrefix.count) }
        let dump = tmp.appendingPathComponent("clone-\(db).sql.gz")
        try await source.stream("db_dump", ["map": map], to: dump)
        _ = try await target.callRaw("db_import", ["guard": "trvclone_", "file": dump.path], body: Data())
        if let url, let from = info.siteURL {
            _ = try await target.call("db_replace", ["tables": Array(map.values), "pairs": Compare.replacePairs(fromURL: from, toURL: url, fromRoot: "", toRoot: "")])
        }
        var swap: [String: String] = [:]
        for v in map.values { swap[v] = String(v.dropFirst("trvclone_".count)) }
        _ = try await target.call("db_swap", ["map": swap, "prefix_from": info.dbPrefix, "prefix_to": prefix])
    }

    func startServer(root: URL) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: LocalEnv.phpBinary!)
        p.arguments = ["-d", "mysqli.default_socket=\(LocalEnv.mampSocket)", "-d", "post_max_size=4M", "-S", "127.0.0.1:\(port)", "-t", root.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        server = p
        for _ in 0..<50 {
            if (try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/readme.html")!)) != nil { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("php -S non parte")
    }

    func testFullRoundTrip() async throws {
        let siteName = ProcessInfo.processInfo.environment["MIRRORPRESS_E2E_SITE"] ?? "villapatrizia"
        let src = LocalEnv.mampHtdocs.appendingPathComponent(siteName)
        let localDir = tmp.appendingPathComponent("locale")
        let remoteDir = tmp.appendingPathComponent("server/public_html")
        try FileManager.default.createDirectory(at: remoteDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        let remoteURL = "http://127.0.0.1:\(port)"

        try await cloneSite(from: src, to: localDir, db: localDB, prefix: "wp_", url: nil)
        try await cloneSite(from: src, to: remoteDir, db: remoteDB, prefix: "rx_", url: remoteURL)

        // Differenze volute: un file cambiato in locale, uno nuovo in locale, un media solo sul server,
        // un titolo cambiato sul server e un post nuovo solo in locale.
        let theme = try FileManager.default.contentsOfDirectory(atPath: localDir.appendingPathComponent("wp-content/themes").path).first { !$0.hasPrefix(".") && !$0.hasSuffix(".php") }!
        let changedFile = "wp-content/themes/\(theme)/mirrorpress-e2e.css"
        try "body{color:red}".write(to: localDir.appendingPathComponent(changedFile), atomically: true, encoding: .utf8)
        try "body{color:blue}".write(to: remoteDir.appendingPathComponent(changedFile), atomically: true, encoding: .utf8)
        try "solo in locale".write(to: localDir.appendingPathComponent("nuovo file.txt"), atomically: true, encoding: .utf8)
        let mediaRel = "wp-content/uploads/mirrorpress-e2e-media.bin"
        try FileManager.default.createDirectory(at: remoteDir.appendingPathComponent("wp-content/uploads"), withIntermediateDirectories: true)
        let bigMedia = Data((0..<(9 << 20)).map { UInt8($0 % 253) })   // più grande di post_max_size: va a pezzi
        try bigMedia.write(to: remoteDir.appendingPathComponent(mediaRel))
        try bigMedia.write(to: localDir.appendingPathComponent("wp-content/uploads/mirrorpress-e2e-big.bin"))
        try await mysql("UPDATE \(remoteDB).rx_posts SET post_title = CONCAT(post_title, ' (server)') WHERE ID = (SELECT m FROM (SELECT MIN(ID) m FROM \(remoteDB).rx_posts WHERE post_type='page') x)")

        try await startServer(root: remoteDir)

        var site = SiteProfile()
        site.name = "E2E"
        site.localPath = localDir.path
        site.remoteURL = remoteURL
        site.connection = .sftp
        let session = SiteSession(site: site)
        session.installHook = { file, name in
            try FileManager.default.copyItem(at: file, to: remoteDir.appendingPathComponent(name))
        }

        // 1. Analisi
        await session.analyze()
        XCTAssertNil(session.lastError, session.lastError ?? "")
        XCTAssertTrue(session.bridgeInstalled)
        func status(_ p: String) -> FileStatus? { session.files.first { $0.path == p }?.status }
        XCTAssertEqual(status(changedFile), .changed)
        XCTAssertEqual(status("nuovo file.txt"), .onlyLocal)
        XCTAssertEqual(status(mediaRel), .onlyRemote)
        XCTAssertEqual(status("wp-config.php"), .changed)
        XCTAssertEqual(status("wp-includes/version.php"), .same)
        XCTAssertEqual(session.files.filter { $0.status == .unknown }.count, 0)
        let posts = session.tables.first { $0.key == "posts" }
        XCTAssertEqual(posts?.status, .changed)
        XCTAssertEqual(posts?.rowsChanged, 1)
        let otherChanged = session.tables.filter { $0.status != .same && $0.key != "posts" }.map(\.key)
        XCTAssertEqual(otherChanged, [], "tabelle diverse oltre a posts: \(otherChanged)")
        XCTAssertTrue(session.issues.contains { $0.title.contains("media") }, session.issues.map(\.title).joined(separator: "\n"))
        let details = await session.rowDetails(posts!)
        XCTAssertTrue(details.remote.first?["post_title"].string?.hasSuffix("(server)") ?? false)

        // 2. Invio file (uno grande a pezzi, con un nome con spazio)
        await session.pushFiles([changedFile, "nuovo file.txt", "wp-content/uploads/mirrorpress-e2e-big.bin"])
        XCTAssertNil(session.lastError, session.lastError ?? "")
        XCTAssertEqual(try String(contentsOf: remoteDir.appendingPathComponent(changedFile)), "body{color:red}")
        XCTAssertEqual(try String(contentsOf: remoteDir.appendingPathComponent("nuovo file.txt")), "solo in locale")
        XCTAssertEqual(try Data(contentsOf: remoteDir.appendingPathComponent("wp-content/uploads/mirrorpress-e2e-big.bin")), bigMedia)

        // 3. Scarico il media che c'è solo sul server
        await session.pullFiles([mediaRel])
        XCTAssertNil(session.lastError, session.lastError ?? "")
        XCTAssertEqual(try Data(contentsOf: localDir.appendingPathComponent(mediaRel)), bigMedia)

        // 4. Backup dei file e ripristino
        await session.loadBackups()
        XCTAssertNil(session.lastError, session.lastError ?? "")
        XCTAssertFalse(session.backups.isEmpty)

        // 5. Invio di tutto il database: poi locale e server devono risultare uguali
        let keys = session.tables.filter { $0.local != nil }.map(\.key)
        await session.pushDatabase(keys: keys)
        XCTAssertNil(session.lastError, session.lastError ?? "")
        let siteurl = try await mysql("SELECT option_value FROM \(remoteDB).rx_options WHERE option_name='siteurl'")
        XCTAssertEqual(siteurl.trimmingCharacters(in: .whitespacesAndNewlines), remoteURL)
        let roles = try await mysql("SELECT COUNT(*) FROM \(remoteDB).rx_options WHERE option_name='rx_user_roles'")
        XCTAssertEqual(roles.trimmingCharacters(in: .whitespacesAndNewlines), "1")
        let leftovers = try await mysql("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='\(remoteDB)' AND table_name LIKE 'trv%'")
        XCTAssertEqual(leftovers.trimmingCharacters(in: .whitespacesAndNewlines), "0")

        await session.analyze()
        XCTAssertNil(session.lastError, session.lastError ?? "")
        let still = session.tables.filter { $0.status != .same }.map(\.key)
        XCTAssertEqual(still, [], "dopo l'invio restano tabelle diverse: \(still)")
        // Il sito "remoto" risponde ancora (WordPress carica con il nuovo database).
        let (_, resp) = try await URLSession.shared.data(from: URL(string: remoteURL + "/")!)
        XCTAssertLessThan((resp as? HTTPURLResponse)?.statusCode ?? 500, 500)

        // 6. Scarico il database in locale (giro inverso)
        await session.pullDatabase(keys: keys)
        XCTAssertNil(session.lastError, session.lastError ?? "")
        let localURLAfter = try await mysql("SELECT option_value FROM \(localDB).wp_options WHERE option_name='siteurl'")
        XCTAssertTrue(localURLAfter.contains("localhost:8888"), localURLAfter)

        // 7. Il ponte va via
        let bridges = { (try? FileManager.default.contentsOfDirectory(atPath: remoteDir.path))?.filter { $0.hasPrefix("mirrorpress-") } ?? [] }
        XCTAssertEqual(bridges().count, 1)
        await session.removeBridge()
        XCTAssertEqual(bridges().count, 0)
    }
}
