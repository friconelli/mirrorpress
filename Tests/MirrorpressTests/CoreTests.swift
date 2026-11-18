import XCTest
@testable import Mirrorpress

final class CoreTests: XCTestCase {
    func testExcludeMatcherMatchesBridgeRules() {
        let m = ExcludeMatcher([".DS_Store", "node_modules/", "wp-content/cache", "*.log"])
        XCTAssertTrue(m.excludes(".DS_Store", name: ".DS_Store"))
        XCTAssertTrue(m.excludes("a/b/.DS_Store", name: ".DS_Store"))
        XCTAssertTrue(m.excludes("x/node_modules", name: "node_modules"))
        XCTAssertTrue(m.excludes("wp-content/cache", name: "cache"))
        XCTAssertTrue(m.excludes("wp-content/cache/page/x.html", name: "x.html"))
        XCTAssertFalse(m.excludes("wp-content/plugins/cache", name: "cache"))
        XCTAssertTrue(m.excludes("debug.log", name: "debug.log"))
        XCTAssertFalse(m.excludes("wp-config.php", name: "wp-config.php"))
    }

    func testGzipRoundTripWithPHP() async throws {
        // Un blocco gzip prodotto da PHP (gzencode) si deve leggere in Swift.
        guard let php = LocalEnv.phpBinary else { throw XCTSkip("PHP non disponibile") }
        let r = try await Shell.run(php, ["-r", "echo gzencode(str_repeat('mirrorpress ', 1000));"])
        let plain = try Gzip.decompress(r.stdout)
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), String(repeating: "mirrorpress ", count: 1000))
        // E un deflate fatto in Swift si legge in PHP (gzinflate).
        let z = try Gzip.deflate(Data("ciao ☕️".utf8))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("z-\(UUID())")
        try z.write(to: tmp)
        let back = try await Shell.run(php, ["-r", "echo gzinflate(file_get_contents($argv[1]));", tmp.path])
        XCTAssertEqual(back.text, "ciao ☕️")
    }

    func testFileDiff() {
        let local = ["a.php": FileEntry(size: 10, mtime: 1), "b.css": FileEntry(size: 5, mtime: 1), "c.js": FileEntry(size: 3, mtime: 1),
                     "wp-config.php": FileEntry(size: 9, mtime: 1)]
        let remote = ["a.php": FileEntry(size: 10, mtime: 9), "b.css": FileEntry(size: 6, mtime: 1), "d.txt": FileEntry(size: 1, mtime: 1),
                      "wp-config.php": FileEntry(size: 8, mtime: 1)]
        var d = Compare.files(local: local, remote: remote, compareContent: true)
        func st(_ p: String) -> FileStatus? { d.first { $0.path == p }?.status }
        XCTAssertEqual(st("a.php"), .unknown)
        XCTAssertEqual(st("b.css"), .changed)
        XCTAssertEqual(st("c.js"), .onlyLocal)
        XCTAssertEqual(st("d.txt"), .onlyRemote)
        XCTAssertTrue(d.first { $0.path == "wp-config.php" }!.sensitive)
        Compare.applyHashes(&d, local: ["a.php": "x"], remote: ["a.php": "x"])
        XCTAssertEqual(st("a.php"), .same)
    }

    func testCaseConflicts() {
        let c = Compare.caseConflicts(local: ["img/Logo.PNG": FileEntry(size: 1, mtime: 1)], remote: ["img/logo.png": FileEntry(size: 1, mtime: 1)])
        XCTAssertEqual(c.count, 1)
    }

    func testTableDiffWithDifferentPrefixes() {
        let l = [TableInfo(name: "wp_posts", rows: 3, size: 0, hash: "h1", collation: "", engine: "", rowHashes: ["1": "a", "2": "b", "3": "c"]),
                 TableInfo(name: "wp_options", rows: 1, size: 0, hash: "same", collation: "", engine: "", rowHashes: nil)]
        let r = [TableInfo(name: "x9_posts", rows: 3, size: 0, hash: "h2", collation: "", engine: "", rowHashes: ["1": "a", "2": "B", "4": "d"]),
                 TableInfo(name: "x9_options", rows: 1, size: 0, hash: "same", collation: "", engine: "", rowHashes: nil),
                 TableInfo(name: "x9_wc_orders", rows: 5, size: 0, hash: "o", collation: "", engine: "", rowHashes: nil)]
        let d = Compare.tables(local: l, localPrefix: "wp_", remote: r, remotePrefix: "x9_")
        let posts = d.first { $0.key == "posts" }!
        XCTAssertEqual(posts.status, .changed)
        XCTAssertEqual(posts.rowsChanged, 1)
        XCTAssertEqual(posts.rowsOnlyLocal, 1)
        XCTAssertEqual(posts.rowsOnlyRemote, 1)
        XCTAssertEqual(d.first { $0.key == "options" }?.status, .same)
        XCTAssertEqual(d.first { $0.key == "wc_orders" }?.status, .onlyRemote)
    }

    func testReplacePairsLongestFirstAndEscaped() {
        let p = Compare.replacePairs(fromURL: "http://localhost:8888/sito/", toURL: "https://www.sito.it",
                                     fromRoot: "/Applications/MAMP/htdocs/sito", toRoot: "/home/u/public_html")
        XCTAssertTrue(p.contains(["http://localhost:8888/sito", "https://www.sito.it"]))
        XCTAssertTrue(p.contains(["http:\\/\\/localhost:8888\\/sito", "https:\\/\\/www.sito.it"]))
        XCTAssertTrue(p.contains(["/Applications/MAMP/htdocs/sito", "/home/u/public_html"]))
        XCTAssertEqual(p, p.sorted { $0[0].count > $1[0].count })
    }

    func testLineReaderAndDownloadReader() throws {
        let dir = AppPaths.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Flusso come quello del ponte: un file di testo, un binario più grande del buffer, uno mancante.
        let big = Data((0..<(3 << 20)).map { UInt8($0 % 251) })
        var stream = Data("F 5 1700000000 dir%2Fa%20b.txt\nciao\n".utf8)
        stream += Data("F \(big.count) 1700000000 bin.dat\n".utf8) + big
        stream += Data("M sparito.txt\nE\n".utf8)
        let f = dir.appendingPathComponent("stream")
        try stream.write(to: f)
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("vecchio".utf8).write(to: root.appendingPathComponent("bin.dat"))
        var n = 0
        try DownloadReader.extract(f, into: root, backupDir: dir.appendingPathComponent("bk")) { _, _ in n += 1 }
        XCTAssertEqual(n, 2)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("dir/a b.txt")), "ciao\n")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("bin.dat")), big)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("bk/bin.dat")), "vecchio")

        // Righe lunghe a cavallo dei blocchi da 1 MB.
        let long = String(repeating: "x", count: 1_500_000)
        let lf = dir.appendingPathComponent("lines")
        try "a\n\(long)\nb".write(to: lf, atomically: true, encoding: .utf8)
        let r = try LineReader(url: lf)
        XCTAssertEqual(r.nextLine(), Data("a\n".utf8))
        XCTAssertEqual(r.nextLine()?.count, long.count + 1)
        XCTAssertEqual(r.nextLine(), Data("b".utf8))
        XCTAssertNil(r.nextLine())
    }

    func testRejectsPathTraversalInDownload() throws {
        let dir = AppPaths.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("s")
        try Data("F 1 0 ..%2Fevil\nx\nE\n".utf8).write(to: f)
        XCTAssertThrowsError(try DownloadReader.extract(f, into: dir.appendingPathComponent("r"), backupDir: dir) { _, _ in })
    }

    func testPipelineDetection() throws {
        let dir = AppPaths.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(LocalEnv.pipelineReason(for: dir))
        try "{}".write(to: dir.appendingPathComponent("vercel.json"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(LocalEnv.pipelineReason(for: dir))
    }

    func testAnalysisFlagsRemoteOnlyContent() throws {
        let local = SiteInfo(raw: try JSONValue.parse(Data(#"{"php":"8.3.1","root":"/l","wordpress":true,"wp":{"version":"6.6","plugins":[{"slug":"acf","name":"ACF","version":"6","requires_php":"8.4"}]},"db":{"server":"8.0.40","prefix":"wp_","options":{"siteurl":"http://localhost:8888/x"},"content":{"posts":{"post":{"count":3,"modified":"2026-01-01 10:00:00"}}}}}"#.utf8)))
        let remote = SiteInfo(raw: try JSONValue.parse(Data(#"{"php":"8.1.2","root":"/r","wordpress":true,"writable":true,"wp":{"version":"6.5","plugins":[{"slug":"wordfence","name":"Wordfence","version":"7"}]},"db":{"server":"10.6.1-MariaDB","prefix":"wp_","options":{"siteurl":"https://x.it","blog_public":"0"},"content":{"posts":{"post":{"count":4,"modified":"2026-02-01 10:00:00"}}}}}"#.utf8)))
        var p = SiteProfile()
        p.remoteURL = "https://x.it"
        let issues = Analysis.issues(local: local, remote: remote, profile: p, files: [], tables: [], caseConflicts: [])
        let titles = issues.map(\.title).joined(separator: "\n")
        XCTAssertTrue(titles.contains("WordPress"), titles)
        XCTAssertTrue(titles.contains("Wordfence"), titles)
        XCTAssertTrue(titles.contains("ACF"), titles)            // richiede PHP 8.4
        XCTAssertTrue(titles.contains("post"), titles)           // contenuti più recenti sul server
        XCTAssertTrue(titles.contains("motori di ricerca"), titles)
        XCTAssertEqual(issues.first?.severity, .error)
    }

    func testParseFTPListing() {
        let unix = """
        drwxr-xr-x    5 19101689 www          4096 Nov 18 13:10 www.16noniassisi.it
        -rw-r--r--    1 19101689 www          3629 Sep  7 14:41 wp-config.php
        drwxr-xr-x    2 u g 4096 Jan  1  2025 .
        lrwxrwxrwx    1 u g   12 Jan  1  2025 html -> public_html
        -rw-r--r--    1 u g  120 Jan  1  2025 file con spazi.txt
        """
        let e = Transport.parseListing(unix)
        XCTAssertEqual(e.map(\.name), ["html", "www.16noniassisi.it", "file con spazi.txt", "wp-config.php"])
        XCTAssertTrue(e[1].isDir)
        XCTAssertEqual(e.last?.size, 3629)
        let iis = "01-15-24  10:30AM       <DIR>          public_html\n01-15-24  10:31AM                 1234 index.php"
        let w = Transport.parseListing(iis)
        XCTAssertEqual(w.map(\.name), ["public_html", "index.php"])
        XCTAssertEqual(w[1].size, 1234)
    }

    func testSyncRulesAreas() {
        XCTAssertEqual(SyncRules.area("wp-config.php"), .protected)
        XCTAssertEqual(SyncRules.area(".htaccess"), .protected)
        XCTAssertEqual(SyncRules.area("wp-content/object-cache.php"), .protected)
        XCTAssertEqual(SyncRules.area("wp-content/mu-plugins/wpengine-common/plugin.php"), .protected)
        XCTAssertEqual(SyncRules.area("wp-content/uploads/backup-2024.zip"), .protected)
        XCTAssertEqual(SyncRules.area("wp-content/uploads/elementor/css/post-12.css"), .generated)
        XCTAssertEqual(SyncRules.area("wp-content/debug.log"), .protected)
        XCTAssertEqual(SyncRules.area("wp-content/uploads/2024/05/foto.jpg"), .media)
        XCTAssertEqual(SyncRules.area("wp-content/themes/16noni/style.css"), .code)
        XCTAssertEqual(SyncRules.area("wp-content/plugins/acf/acf.php"), .code)
        XCTAssertEqual(SyncRules.area("wp-includes/version.php"), .core)
        XCTAssertEqual(SyncRules.area("wp-login.php"), .core)
        XCTAssertEqual(SyncRules.area("google1234.html"), .other)
    }

    func testSyncTreeCountsAndCompaction() {
        let e = FileEntry(size: 1, mtime: 0)
        let files = [
            FileDiff(path: "wp-content/themes/t/style.css", local: e, remote: e, status: .changed, sensitive: false),
            FileDiff(path: "wp-content/themes/t/inc/a.php", local: e, remote: nil, status: .onlyLocal, sensitive: false),
            FileDiff(path: "wp-content/plugins/p/p.php", local: nil, remote: e, status: .onlyRemote, sensitive: false),
        ]
        XCTAssertEqual(SyncTree.commonFolder(files), "wp-content/")
        let top = SyncTree.rows(files, expanded: [])
        XCTAssertEqual(top.map(\.name), ["plugins/p", "themes/t"])
        XCTAssertEqual(top[1].push.count, 2)
        XCTAssertEqual(top[1].pull.count, 1)
        XCTAssertEqual(top[0].push.count, 0)
        let open = SyncTree.rows(files, expanded: ["wp-content/themes/t/"])
        XCTAssertEqual(open.map(\.name), ["plugins/p", "themes/t", "inc", "style.css"])
        XCTAssertEqual(open[2].depth, 1)
    }

    func testClonerRewritesWPConfig() {
        let src = """
        <?php
        define( 'DB_NAME', 'Sql123_1' );
        define('DB_USER', "utente");
        define( 'DB_PASSWORD', 'p\\'a$s' );
        define( 'DB_HOST', '31.11.39.1' );
        define( 'WP_HOME', 'https://www.sito.it' );
        define( 'WP_CACHE', true );
        require_once('/nas/content/live/sito/wpe-config.php');
        require_once ABSPATH . 'wp-settings.php';
        $table_prefix = 'xy_';
        """
        let (out, notes) = SiteCloner.rewriteWPConfig(src, db: DBCredentials(name: "sito", user: "root", password: "ro'ot", host: "localhost"),
                                                      url: "http://localhost:8888/sito", toLocal: true)
        XCTAssertTrue(out.contains("define( 'DB_NAME', 'sito' )"))
        XCTAssertTrue(out.contains("define( 'DB_USER', 'root' )"))
        XCTAssertTrue(out.contains("define( 'DB_PASSWORD', 'ro\\'ot' )"))
        XCTAssertTrue(out.contains("define( 'DB_HOST', 'localhost' )"))
        XCTAssertTrue(out.contains("define( 'WP_HOME', 'http://localhost:8888/sito' )"))
        XCTAssertTrue(out.contains("define( 'WP_CACHE', false )"))
        XCTAssertTrue(out.contains("// [Mirrorpress] require_once('/nas/"))
        XCTAssertTrue(out.contains("require_once ABSPATH . 'wp-settings.php';"))
        XCTAssertFalse(out.contains("// [Mirrorpress] require_once ABSPATH"))
        XCTAssertTrue(out.contains("$table_prefix = 'xy_';"))
        XCTAssertGreaterThanOrEqual(notes.count, 3)
        // Il risultato deve essere PHP valido.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wpc-\(UUID().uuidString).php")
        try? out.write(to: tmp, atomically: true, encoding: .utf8)
        if let php = LocalEnv.phpBinary {
            let p = Process(); p.executableURL = URL(fileURLWithPath: php); p.arguments = ["-n", "-l", tmp.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, out)
        }
    }

    func testClonerHtaccess() {
        let remote = "Header set X-Test 1\n# BEGIN WordPress\nRewriteBase /\n# END WordPress\nRewriteCond %{HTTPS} off\n"
        let local = SiteCloner.rewriteHtaccess(remote, url: "http://localhost:8888/sito", toLocal: true)
        XCTAssertTrue(local.contains("RewriteBase /sito/"))
        XCTAssertTrue(local.contains("RewriteRule . /sito/index.php [L]"))
        XCTAssertFalse(local.contains("HTTPS"))
        let server = SiteCloner.rewriteHtaccess("Header set X-Test 1\n# BEGIN WordPress\nRewriteBase /sito/\n# END WordPress\n", url: "https://www.sito.it", toLocal: false)
        XCTAssertTrue(server.contains("Header set X-Test 1"))
        XCTAssertTrue(server.contains("RewriteBase /\n"))
        XCTAssertFalse(server.contains("/sito/"))
        XCTAssertEqual(SiteCloner.slug("Villa Patrizia (demo)"), "villa_patrizia_demo")
    }
}
