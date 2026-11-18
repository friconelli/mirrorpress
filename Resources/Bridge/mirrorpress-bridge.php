<?php
/*
 * Mirrorpress bridge — ponte temporaneo tra l'app Mirrorpress e un sito (WordPress o PHP).
 *
 * Lo stesso file gira in due modi:
 *  - sul server, via HTTPS: ogni richiesta è firmata (HMAC-SHA256 con il token qui sotto) e il file
 *    smette di rispondere dopo la scadenza (e prova a cancellarsi da solo);
 *  - in locale, da riga di comando con il PHP di MAMP: `php mirrorpress-bridge.php <azione>` con il corpo
 *    della richiesta su stdin e MIRRORPRESS_ROOT / MIRRORPRESS_WORKDIR nell'ambiente.
 *
 * Non carica WordPress: legge wp-config.php e parla direttamente con MySQL, così funziona anche
 * con un sito rotto. Compatibile con PHP 7.0+.
 */

define('TRV_TOKEN', '__MIRRORPRESS_TOKEN__');
define('TRV_EXPIRES', 0 /*__MIRRORPRESS_EXPIRES__*/);
define('TRV_VERSION', '1');
define('TRV_CLI', PHP_SAPI === 'cli');

@ini_set('display_errors', '0');
@set_time_limit(0);
@ignore_user_abort(true);
error_reporting(E_ALL & ~E_DEPRECATED & ~E_NOTICE & ~E_WARNING);

// Errori fatali (memoria, tempo, funzioni mancanti): invece di una risposta vuota, un JSON che li spiega.
$GLOBALS['trv_sent'] = false;
register_shutdown_function('trv_on_shutdown');
function trv_on_shutdown() {
    $e = error_get_last();
    if (!$e || !in_array($e['type'], array(E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR, E_USER_ERROR), true)) return;
    if ($GLOBALS['trv_sent']) return;
    if (!TRV_CLI && !headers_sent()) { http_response_code(200); header('Content-Type: application/json; charset=utf-8'); }
    echo json_encode(array(
        'ok' => false,
        'error' => 'PHP fatal error: ' . $e['message'],
        'hint' => 'Errore PHP sul lato che esegue il ponte: spesso memoria (memory_limit) o tempo massimo (max_execution_time) dell\'hosting.',
        'detail' => basename($e['file']) . ':' . $e['line'] . "\nPHP " . PHP_VERSION . ' · memory_limit ' . ini_get('memory_limit')
            . ' · max_execution_time ' . ini_get('max_execution_time') . ' · disable_functions ' . ini_get('disable_functions'),
    ), JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PARTIAL_OUTPUT_ON_ERROR);
}

// ---------------------------------------------------------------- bootstrap

if (TRV_CLI) {
    $root = getenv('MIRRORPRESS_ROOT');
    define('TRV_ROOT', rtrim($root ? $root : getcwd(), '/'));
    $action = isset($argv[1]) ? $argv[1] : 'ping';
    $body = stream_get_contents(STDIN);
} else {
    define('TRV_ROOT', rtrim(str_replace('\\', '/', __DIR__), '/'));
    if (TRV_EXPIRES > 0 && time() > TRV_EXPIRES) {
        @unlink(__FILE__);
        http_response_code(410);
        exit;
    }
    if ($_SERVER['REQUEST_METHOD'] !== 'POST' || !isset($_GET['a'], $_GET['t'], $_GET['s'])) {
        http_response_code(404);
        exit;
    }
    $action = (string)$_GET['a'];
    $ts = (int)$_GET['t'];
    $body = file_get_contents('php://input');
    $expected = hash_hmac('sha256', $ts . "\n" . $action . "\n" . hash('sha256', $body), TRV_TOKEN);
    if (TRV_TOKEN === '__MIRRORPRESS' . '_TOKEN__' || !hash_equals($expected, (string)$_GET['s']) || abs(time() - $ts) > 900) {
        http_response_code(403);
        exit;
    }
    @ini_set('zlib.output_compression', 'Off');
    while (ob_get_level()) @ob_end_clean();
    header('Cache-Control: no-store');
    header('X-Robots-Tag: noindex');
}

// Le azioni con corpo binario (upload, db_import) hanno i parametri in una prima riga "J {json}".
$req = array();
if (in_array($action, array('upload', 'db_import'), true)) {
    if (substr($body, 0, 2) === 'J ') {
        $nl = strpos($body, "\n");
        $req = json_decode(substr($body, 2, $nl - 2), true);
        $body = (string)substr($body, $nl + 1);
    }
} elseif ($body !== '' && $body !== false) {
    $req = json_decode($body, true);
}
if (!is_array($req)) $req = array();
$GLOBALS['trv_db_req'] = $req;

try {
    switch ($action) {
        case 'ping':         trv_json(trv_ping()); break;
        case 'info':         trv_json(trv_info($req)); break;
        case 'manifest':     trv_manifest($req); break;
        case 'hash':         trv_json(trv_hash($req)); break;
        case 'code_scan':    trv_json(trv_code_scan($req)); break;
        case 'download':     trv_download($req); break;
        case 'upload':       trv_json(trv_upload($body, isset($req['session']) ? (string)$req['session'] : '')); break;
        case 'commit':       trv_json(trv_commit($req)); break;
        case 'trash':        trv_json(trv_trash($req)); break;
        case 'db_tables':    trv_json(trv_db_tables($req)); break;
        case 'db_rows':      trv_json(trv_db_rows($req)); break;
        case 'db_dump':      trv_db_dump_stream($req); break;
        case 'db_import':    trv_json(trv_db_import($body, $req)); break;
        case 'db_replace':   trv_json(trv_db_replace($req)); break;
        case 'db_swap':      trv_json(trv_db_swap($req)); break;
        case 'db_drop_staging': trv_json(trv_db_drop_staging($req)); break;
        case 'backup_db':    trv_json(trv_backup_db($req)); break;
        case 'backups':      trv_json(trv_backups()); break;
        case 'fetch':        trv_fetch($req); break;
        case 'restore':      trv_json(trv_restore($req)); break;
        case 'cleanup':      trv_json(trv_cleanup($req)); break;
        case 'selfdestruct': trv_json(array('ok' => TRV_CLI ? true : @unlink(__FILE__))); break;
        default: trv_json(array('ok' => false, 'error' => 'azione sconosciuta: ' . $action));
    }
} catch (Exception $e) {
    trv_json(array('ok' => false, 'error' => $e->getMessage()));
} catch (Error $e) {
    trv_json(array('ok' => false, 'error' => 'PHP: ' . $e->getMessage() . ' (riga ' . $e->getLine() . ')'));
}
exit;

// ---------------------------------------------------------------- helpers

function trv_json($data) {
    if (!isset($data['ok'])) $data['ok'] = true;
    $GLOBALS['trv_sent'] = true;
    if (!TRV_CLI) header('Content-Type: application/json; charset=utf-8');
    $out = json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PARTIAL_OUTPUT_ON_ERROR);
    if ($out === false) $out = json_encode(array('ok' => false, 'error' => 'json_encode: ' . json_last_error_msg()));
    echo $out;
}

function trv_fail($msg) { throw new Exception($msg); }

/** Percorso relativo sicuro (niente .., niente assoluti) → percorso assoluto sotto la root. */
function trv_abs($rel) {
    $rel = str_replace('\\', '/', (string)$rel);
    if ($rel === '' || $rel[0] === '/' || strpos($rel, "\0") !== false) trv_fail('percorso non valido: ' . $rel);
    foreach (explode('/', $rel) as $part) {
        if ($part === '..' || $part === '.' || $part === '') trv_fail('percorso non valido: ' . $rel);
    }
    return TRV_ROOT . '/' . $rel;
}

function trv_mkdirp($dir) {
    if (!is_dir($dir) && !@mkdir($dir, 0755, true) && !is_dir($dir)) trv_fail('impossibile creare la cartella ' . $dir);
}

/** Cartella di lavoro privata (backup, staging, cache, _da_eliminare): fuori dalla webroot se si può. */
function trv_workdir() {
    static $dir = null;
    if ($dir !== null) return $dir;
    $env = TRV_CLI ? getenv('MIRRORPRESS_WORKDIR') : false;
    if ($env) { $dir = rtrim($env, '/'); trv_mkdirp($dir); return $dir; }
    $name = '.mirrorpress-' . substr(sha1(TRV_ROOT), 0, 10);
    $parent = dirname(TRV_ROOT);
    $candidates = array();
    if ($parent !== TRV_ROOT && $parent !== '/' && $parent !== '') $candidates[] = $parent . '/' . $name;
    $candidates[] = TRV_ROOT . '/' . $name;
    foreach ($candidates as $c) {
        if (is_dir($c) && is_writable($c)) { $dir = $c; break; }
        if (@mkdir($c, 0755, true)) { $dir = $c; break; }
    }
    if ($dir === null) trv_fail('impossibile creare la cartella di lavoro (permessi?)');
    if (!file_exists($dir . '/.htaccess')) @file_put_contents($dir . '/.htaccess', "Require all denied\nDeny from all\n");
    if (!file_exists($dir . '/index.php')) @file_put_contents($dir . '/index.php', "<?php http_response_code(404);\n");
    return $dir;
}

function trv_ini_bytes($v) {
    $v = trim((string)$v);
    if ($v === '') return 0;
    $n = (float)$v;
    switch (strtolower(substr($v, -1))) {
        case 'g': $n *= 1024;
        case 'm': $n *= 1024;
        case 'k': $n *= 1024;
    }
    return (int)$n;
}

// ---------------------------------------------------------------- wp-config e database

function trv_wpconfig_path() {
    if (is_file(TRV_ROOT . '/wp-config.php')) return TRV_ROOT . '/wp-config.php';
    $up = dirname(TRV_ROOT) . '/wp-config.php';
    if (is_file($up) && !is_file(dirname(TRV_ROOT) . '/wp-settings.php')) return $up;
    return null;
}

function trv_wpconfig() {
    static $cfg = null;
    if ($cfg !== null) return $cfg;
    $cfg = array();
    $path = trv_wpconfig_path();
    if (!$path) return $cfg;
    $src = file_get_contents($path);
    // Toglie i commenti per non leggere define() disattivati.
    $src = preg_replace('~/\*.*?\*/~s', '', $src);
    $src = preg_replace('~^\s*(//|#).*$~m', '', $src);
    if (preg_match_all('~define\s*\(\s*([\'"])([A-Z0-9_]+)\1\s*,\s*(\'((?:[^\'\\\\]|\\\\.)*)\'|"((?:[^"\\\\]|\\\\.)*)"|true|false|TRUE|FALSE|[0-9.]+)\s*\)~', $src, $m, PREG_SET_ORDER)) {
        foreach ($m as $d) {
            $raw = $d[3];
            if (isset($d[4]) && $d[4] !== '' && $raw[0] === "'") $val = str_replace(array("\\'", '\\\\'), array("'", '\\'), $d[4]);
            elseif (isset($d[5]) && $raw[0] === '"') $val = stripcslashes($d[5]);
            elseif ($raw[0] === "'" || $raw[0] === '"') $val = '';
            elseif (strtolower($raw) === 'true') $val = true;
            elseif (strtolower($raw) === 'false') $val = false;
            else $val = $raw;
            $cfg[$d[2]] = $val;
        }
    }
    if (preg_match('~\$table_prefix\s*=\s*([\'"])(.*?)\1~', $src, $p)) $cfg['table_prefix'] = $p[2];
    return $cfg;
}

function trv_db_settings($req = array()) {
    $c = trv_wpconfig();
    $o = isset($req['db']) && is_array($req['db']) ? $req['db'] : array();
    return array(
        'name' => isset($o['name']) && $o['name'] !== '' ? $o['name'] : (isset($c['DB_NAME']) ? $c['DB_NAME'] : ''),
        'user' => isset($o['user']) && $o['user'] !== '' ? $o['user'] : (isset($c['DB_USER']) ? $c['DB_USER'] : ''),
        'pass' => isset($o['pass']) && $o['pass'] !== '' ? $o['pass'] : (isset($c['DB_PASSWORD']) ? $c['DB_PASSWORD'] : ''),
        'host' => isset($o['host']) && $o['host'] !== '' ? $o['host'] : (isset($c['DB_HOST']) ? $c['DB_HOST'] : 'localhost'),
        'prefix' => isset($o['prefix']) && $o['prefix'] !== '' ? $o['prefix'] : (isset($c['table_prefix']) ? $c['table_prefix'] : 'wp_'),
    );
}

function trv_db($fresh = false) {
    static $db = null;
    if ($db !== null && !$fresh) return $db;
    if (!function_exists('mysqli_init')) trv_fail('estensione mysqli non disponibile');
    $s = trv_db_settings($GLOBALS['trv_db_req']);
    if ($s['name'] === '') trv_fail('database non configurato (wp-config.php non trovato o senza DB_NAME)');
    $host = $s['host']; $port = null; $socket = null;
    if (strpos($host, 'p:') === 0) $host = substr($host, 2);
    if (preg_match('~^(.*?):(\d+)$~', $host, $m)) { $host = $m[1]; $port = (int)$m[2]; }
    elseif (preg_match('~^(.*?):(/.+)$~', $host, $m)) { $host = $m[1]; $socket = $m[2]; }
    mysqli_report(MYSQLI_REPORT_OFF);
    $conn = mysqli_init();
    @$conn->options(MYSQLI_OPT_CONNECT_TIMEOUT, 15);
    if (!@$conn->real_connect($host, $s['user'], $s['pass'], $s['name'], $port, $socket)) {
        trv_fail('connessione al database fallita: ' . mysqli_connect_error());
    }
    $conn->set_charset('utf8mb4');
    $conn->query("SET SESSION sql_mode = 'NO_AUTO_VALUE_ON_ZERO'");
    $conn->query('SET FOREIGN_KEY_CHECKS = 0');
    if ($fresh) return $conn;
    $db = $conn;
    return $db;
}

function trv_q($sql, $db = null) {
    $db = $db ? $db : trv_db();
    $r = $db->query($sql);
    if ($r === false) trv_fail('MySQL: ' . $db->error . ' — ' . substr($sql, 0, 300));
    return $r;
}

function trv_qi($name) { return '`' . str_replace('`', '``', $name) . '`'; }

function trv_server_version($db = null) {
    $db = $db ? $db : trv_db();
    $r = trv_q('SELECT VERSION()', $db)->fetch_row();
    return $r[0];
}

function trv_base_tables() {
    $out = array();
    $r = trv_q("SHOW FULL TABLES WHERE Table_type = 'BASE TABLE'");
    while ($row = $r->fetch_row()) $out[] = $row[0];
    return $out;
}

// ---------------------------------------------------------------- ping / info

function trv_ping() {
    return array(
        'bridge' => TRV_VERSION,
        'php' => PHP_VERSION,
        'root' => TRV_ROOT,
        'wordpress' => trv_wpconfig_path() !== null,
        'expires' => TRV_EXPIRES,
        'time' => time(),
    );
}

function trv_headers($file, $fields) {
    $data = @file_get_contents($file, false, null, 0, 8192);
    $out = array();
    if ($data === false) return $out;
    $data = str_replace("\r", "\n", $data);
    foreach ($fields as $key => $label) {
        if (preg_match('/^[ \t\/*#@]*' . preg_quote($label, '/') . ':(.*)$/mi', $data, $m)) $out[$key] = trim(preg_replace('/\s*(?:\*\/|\?>).*/', '', $m[1]));
        else $out[$key] = '';
    }
    return $out;
}

function trv_info($req) {
    $info = trv_ping();
    $cfg = trv_wpconfig();
    $info['server'] = isset($_SERVER['SERVER_SOFTWARE']) ? $_SERVER['SERVER_SOFTWARE'] : (TRV_CLI ? 'cli' : '');
    $info['os'] = PHP_OS;
    $info['extensions'] = array(
        'mysqli' => extension_loaded('mysqli'), 'zlib' => extension_loaded('zlib'),
        'zip' => class_exists('ZipArchive'), 'mbstring' => extension_loaded('mbstring'),
        'curl' => extension_loaded('curl'), 'gd' => extension_loaded('gd'),
        'imagick' => extension_loaded('imagick'), 'intl' => extension_loaded('intl'),
    );
    $info['limits'] = array(
        'memory_limit' => ini_get('memory_limit'),
        'post_max_size' => trv_ini_bytes(ini_get('post_max_size')),
        'upload_max_filesize' => trv_ini_bytes(ini_get('upload_max_filesize')),
        'max_execution_time' => (int)ini_get('max_execution_time'),
        'disk_free' => @disk_free_space(TRV_ROOT) ?: 0,
    );
    $info['writable'] = is_writable(TRV_ROOT);
    $info['config'] = array(
        'WP_DEBUG' => isset($cfg['WP_DEBUG']) ? $cfg['WP_DEBUG'] : false,
        'WP_DEBUG_DISPLAY' => isset($cfg['WP_DEBUG_DISPLAY']) ? $cfg['WP_DEBUG_DISPLAY'] : null,
        'WP_DEBUG_LOG' => isset($cfg['WP_DEBUG_LOG']) ? $cfg['WP_DEBUG_LOG'] : false,
        'MULTISITE' => isset($cfg['MULTISITE']) ? $cfg['MULTISITE'] : false,
        'WP_HOME' => isset($cfg['WP_HOME']) ? $cfg['WP_HOME'] : null,
        'WP_SITEURL' => isset($cfg['WP_SITEURL']) ? $cfg['WP_SITEURL'] : null,
        'DISALLOW_FILE_MODS' => isset($cfg['DISALLOW_FILE_MODS']) ? $cfg['DISALLOW_FILE_MODS'] : false,
        'DB_CHARSET' => isset($cfg['DB_CHARSET']) ? $cfg['DB_CHARSET'] : null,
        'DB_NAME' => isset($cfg['DB_NAME']) ? $cfg['DB_NAME'] : null,
        'table_prefix' => isset($cfg['table_prefix']) ? $cfg['table_prefix'] : null,
    );

    // Versione di WordPress, plugin e temi letti dai file.
    $wp = array('version' => null, 'plugins' => array(), 'themes' => array());
    if (is_file(TRV_ROOT . '/wp-includes/version.php')) {
        $v = file_get_contents(TRV_ROOT . '/wp-includes/version.php');
        if (preg_match('~\$wp_version\s*=\s*[\'"]([^\'"]+)~', $v, $m)) $wp['version'] = $m[1];
    }
    $pdir = TRV_ROOT . '/wp-content/plugins';
    if (is_dir($pdir)) {
        foreach (scandir($pdir) as $entry) {
            if ($entry[0] === '.' || $entry === 'index.php') continue;
            $path = $pdir . '/' . $entry;
            $files = is_dir($path) ? glob($path . '/*.php') : (substr($entry, -4) === '.php' ? array($path) : array());
            foreach ((array)$files as $f) {
                $h = trv_headers($f, array('name' => 'Plugin Name', 'version' => 'Version', 'requires_php' => 'Requires PHP', 'requires_wp' => 'Requires at least'));
                if ($h['name'] !== '') {
                    $wp['plugins'][] = array('file' => $entry . (is_dir($path) ? '/' . basename($f) : ''), 'slug' => $entry,
                        'name' => $h['name'], 'version' => $h['version'], 'requires_php' => $h['requires_php'], 'requires_wp' => $h['requires_wp']);
                    break;
                }
            }
        }
    }
    $tdir = TRV_ROOT . '/wp-content/themes';
    if (is_dir($tdir)) {
        foreach (scandir($tdir) as $entry) {
            if ($entry[0] === '.' || !is_file($tdir . '/' . $entry . '/style.css')) continue;
            $h = trv_headers($tdir . '/' . $entry . '/style.css', array('name' => 'Theme Name', 'version' => 'Version', 'requires_php' => 'Requires PHP', 'template' => 'Template'));
            $wp['themes'][] = array('slug' => $entry, 'name' => $h['name'], 'version' => $h['version'], 'requires_php' => $h['requires_php'], 'parent' => $h['template']);
        }
    }
    $mu = TRV_ROOT . '/wp-content/mu-plugins';
    $wp['mu_plugins'] = is_dir($mu) ? array_values(array_filter(scandir($mu), function ($f) { return substr($f, -4) === '.php'; })) : array();
    $wp['dropins'] = array_values(array_filter(array('object-cache.php', 'advanced-cache.php', 'db.php', 'maintenance.php'), function ($f) { return is_file(TRV_ROOT . '/wp-content/' . $f); }));
    $wp['maintenance'] = is_file(TRV_ROOT . '/.maintenance');

    // Database (se raggiungibile).
    $info['db'] = null;
    try {
        $db = trv_db();
        $s = trv_db_settings($GLOBALS['trv_db_req']);
        $p = $s['prefix'];
        $d = array('server' => trv_server_version(), 'name' => $s['name'], 'prefix' => $p, 'tables' => 0, 'size' => 0, 'collations' => array());
        $r = trv_q('SHOW TABLE STATUS');
        while ($row = $r->fetch_assoc()) {
            if ($row['Engine'] === null) continue;
            $d['tables']++;
            $d['size'] += (int)$row['Data_length'] + (int)$row['Index_length'];
            $c = (string)$row['Collation'];
            $d['collations'][$c] = isset($d['collations'][$c]) ? $d['collations'][$c] + 1 : 1;
        }
        $opts = array();
        $ot = $p . 'options';
        $chk = trv_q("SHOW TABLES LIKE '" . $db->real_escape_string($ot) . "'");
        if ($chk->num_rows) {
            $r = trv_q("SELECT option_name, option_value FROM " . trv_qi($ot) . " WHERE option_name IN ('siteurl','home','template','stylesheet','active_plugins','db_version','blogname','permalink_structure','WPLANG','blog_public','admin_email')");
            while ($row = $r->fetch_assoc()) $opts[$row['option_name']] = $row['option_value'];
            if (isset($opts['active_plugins'])) {
                $ap = @unserialize($opts['active_plugins'], array('allowed_classes' => false));
                $opts['active_plugins'] = is_array($ap) ? array_values($ap) : array();
            }
            $pt = $p . 'posts';
            $counts = array();
            $r = @$db->query("SELECT post_type, COUNT(*) c, MAX(post_modified_gmt) m FROM " . trv_qi($pt) . " WHERE post_status NOT IN ('auto-draft','inherit','trash') OR post_type = 'attachment' GROUP BY post_type");
            if ($r) while ($row = $r->fetch_assoc()) $counts[$row['post_type']] = array('count' => (int)$row['c'], 'modified' => $row['m']);
            $d['content'] = array('posts' => $counts);
            foreach (array('comments' => 'comment_date_gmt', 'users' => 'user_registered') as $t => $col) {
                $r = @$db->query("SELECT COUNT(*), MAX(" . $col . ") FROM " . trv_qi($p . $t));
                if ($r) { $row = $r->fetch_row(); $d['content'][$t] = array('count' => (int)$row[0], 'modified' => $row[1]); }
            }
        }
        $d['options'] = $opts;
        $info['db'] = $d;
    } catch (Exception $e) {
        $info['db_error'] = $e->getMessage();
    }
    $info['wp'] = $wp;
    return $info;
}

// ---------------------------------------------------------------- file

/** Esclusioni: "nome" vale per qualunque cartella/file con quel nome, "a/b" è ancorato alla root. */
function trv_excluded($rel, $name, $patterns) {
    foreach ($patterns as $p) {
        $p = rtrim($p, '/');
        if ($p === '') continue;
        if (strpos($p, '/') !== false) {
            if (fnmatch($p, $rel) || strpos($rel, $p . '/') === 0) return true;
        } elseif (fnmatch($p, $name)) {
            return true;
        }
    }
    return false;
}

function trv_hash_cache_load() {
    $f = trv_workdir() . '/cache/hashes.ser';
    $c = is_file($f) ? @unserialize(file_get_contents($f), array('allowed_classes' => false)) : array();
    return is_array($c) ? $c : array();
}

function trv_hash_cache_save($c) {
    trv_mkdirp(trv_workdir() . '/cache');
    @file_put_contents(trv_workdir() . '/cache/hashes.ser', serialize($c));
}

function trv_file_md5($abs, $size, $mtime, &$cache, &$dirty) {
    $key = substr($abs, strlen(TRV_ROOT) + 1);
    if (isset($cache[$key]) && $cache[$key][0] === $size && $cache[$key][1] === $mtime) return $cache[$key][2];
    $h = @md5_file($abs);
    if ($h === false) return '';
    $cache[$key] = array($size, $mtime, $h);
    $dirty = true;
    return $h;
}

/** Elenco di tutti i file (gzip, una riga per file: percorso \t dimensione \t mtime). */
function trv_manifest($req) {
    $GLOBALS['trv_sent'] = true;
    $ex = isset($req['exclude']) ? (array)$req['exclude'] : array();
    $ex[] = '.mirrorpress-*';
    $ex[] = 'mirrorpress-*.php';
    $ex[] = '.travaso-*';
    $ex[] = 'travaso-*.php';
    if (!TRV_CLI) header('Content-Type: application/octet-stream');
    $gz = function_exists('gzencode');
    $buf = '';
    $count = 0;
    $skipped = 0;
    $stack = array('');
    $flush = function ($final) use (&$buf, $gz) {
        if ($buf === '' && !$final) return;
        $chunk = $gz ? gzencode($buf, 6) : $buf;
        echo pack('N', strlen($chunk)) . $chunk;
        $buf = '';
        flush();
    };
    echo $gz ? "TRVM1Z\n" : "TRVM1\n";
    while ($stack) {
        $dirRel = array_pop($stack);
        $dirAbs = $dirRel === '' ? TRV_ROOT : TRV_ROOT . '/' . $dirRel;
        $h = @opendir($dirAbs);
        if (!$h) { $buf .= "!\t" . rawurlencode($dirRel) . "\n"; continue; }
        while (($name = readdir($h)) !== false) {
            if ($name === '.' || $name === '..') continue;
            $rel = $dirRel === '' ? $name : $dirRel . '/' . $name;
            if (trv_excluded($rel, $name, $ex)) continue;
            $abs = $dirAbs . '/' . $name;
            if (is_link($abs)) { $skipped++; continue; }
            if (is_dir($abs)) { $stack[] = $rel; continue; }
            $st = @stat($abs);
            if (!$st) continue;
            $buf .= rawurlencode($rel) . "\t" . $st['size'] . "\t" . $st['mtime'] . "\n";
            $count++;
            if (strlen($buf) > 262144) $flush(false);
        }
        closedir($h);
    }
    $buf .= "#\t" . $count . "\t" . $skipped . "\n";
    $flush(true);
    echo pack('N', 0);
}

function trv_hash($req) {
    $paths = isset($req['paths']) ? (array)$req['paths'] : array();
    $cache = trv_hash_cache_load();
    $dirty = false;
    $out = array();
    $started = microtime(true);
    $done = 0;
    foreach ($paths as $rel) {
        $abs = trv_abs($rel);
        $st = @stat($abs);
        if ($st && is_file($abs)) $out[$rel] = trv_file_md5($abs, $st['size'], $st['mtime'], $cache, $dirty);
        $done++;
        // Non supera i tempi del server: il resto lo chiede l'app con una nuova richiesta.
        if (microtime(true) - $started > 20) break;
    }
    if ($dirty) trv_hash_cache_save($cache);
    return array('hashes' => (object)$out, 'done' => $done);
}

// ---------------------------------------------------------------- controllo del codice

/**
 * Regole per trovare criticità nel codice: [id, gravità, ambito, espressione regolare].
 * Ambito: "all" = ogni file analizzato; "own" = solo codice proprio (temi, mu-plugins, file nella root).
 */
function trv_code_rules() {
    return array(
        // Codice malevolo e backdoor
        array('eval_obfuscated', 'error', 'all', '~\b(eval|assert)\s*\(\s*(@?\s*)(base64_decode|gzinflate|gzuncompress|gzdecode|str_rot13|strrev|rawurldecode|hex2bin|convert_uudecode)\s*\(~i'),
        array('eval_input', 'error', 'all', '~\b(eval|assert|create_function)\s*\([^;]{0,80}\$_(POST|GET|REQUEST|COOKIE|SERVER)~i'),
        array('exec_input', 'error', 'all', '~\b(system|shell_exec|passthru|exec|popen|proc_open|pcntl_exec)\s*\([^;]{0,80}\$_(POST|GET|REQUEST|COOKIE)~i'),
        array('preg_e', 'error', 'all', '~preg_replace\s*\(\s*([\'"])(.).*\2[a-zA-Z]*e[a-zA-Z]*\1\s*,~'),
        array('var_function_input', 'error', 'all', '~\$\w+\s*=\s*\$_(POST|GET|REQUEST|COOKIE)\s*\[[^\]]+\]\s*;\s*@?\$\w+\s*\(~'),
        array('shell_signature', 'error', 'all', '~(FilesMan|WSOsetcookie|c99shell|r57shell|b374k|IndoXploit|AnonymousFox|Leaf PHPMailer|wp_vcd|tmpcontentx)~'),
        array('long_base64', 'warning', 'all', '~[A-Za-z0-9+/]{3000,}={0,2}~'),
        array('hex_obfuscation', 'warning', 'all', '~(\\\\x[0-9a-fA-F]{2}){40,}~'),
        // Funzioni eliminate in PHP 8 (solo codice proprio: i plugin di solito le controllano con function_exists)
        array('php8_removed', 'error8', 'own', '~(?<![\w>:$])(create_function|money_format|ereg|eregi|ereg_replace|split|mysql_connect|mysql_query|mysql_fetch_array|mysql_fetch_assoc|mysql_real_escape_string|each)\s*\(~'),
        // Residui di debug
        array('debug_dump', 'warning', 'own', '~(?<![\w>:$])(var_dump\s*\(|print_r\s*\([^,()]*\)\s*;|var_export\s*\([^,()]*\)\s*;|dd\s*\()~'),
        array('display_errors', 'warning', 'own', '~ini_set\s*\(\s*[\'"]display_errors[\'"]\s*,\s*[\'"]?(1|on|true)~i'),
        // Indirizzi e percorsi dell'ambiente locale scritti nel codice
        array('local_url', 'warning', 'own', '~(https?://(localhost|127\.0\.0\.1)[:/]|/Applications/MAMP/|/Users/[A-Za-z0-9._-]+/)~'),
    );
}

/** Analizza i file indicati (percorsi relativi) con un limite di tempo; l'app chiede il resto con un'altra richiesta. */
function trv_code_scan($req) {
    $paths = isset($req['paths']) ? (array)$req['paths'] : array();
    $php8 = !empty($req['php8']);
    $rules = trv_code_rules();
    $out = array();
    $started = microtime(true);
    $done = 0;
    foreach ($paths as $rel) {
        $done++;
        $abs = trv_abs($rel);
        if (!is_file($abs) || filesize($abs) > 2000000) continue;
        $data = @file_get_contents($abs);
        if ($data === false) continue;
        $low = strtolower($rel);
        $own = strpos($low, 'wp-content/themes/') === 0 || strpos($low, 'wp-content/mu-plugins/') === 0 || strpos($low, '/') === false;
        // Librerie di terzi dentro il tema (composer, npm): non sono codice proprio.
        if (strpos($low, '/vendor/') !== false || strpos($low, '/node_modules/') !== false) $own = false;
        $isJs = substr($low, -3) === '.js';
        $minified = substr($low, -7) === '.min.js' || ($isJs && strlen($data) > 2000 && substr_count($data, "\n") < 5);
        if (strpos($low, 'wp-content/uploads/') === 0 && preg_match('~\.(php\d?|phtml|phar)$~', $low)) {
            $silent = strlen($data) < 200 && stripos($data, 'silence') !== false;
            if (!$silent) $out[] = array('path' => $rel, 'line' => 1, 'rule' => 'php_in_uploads', 'severity' => 'error', 'snippet' => trv_snippet($data, 0));
        }
        foreach ($rules as $r) {
            list($id, $sev, $scope, $re) = $r;
            if ($scope === 'own' && !$own) continue;
            if ($sev === 'error8') { if (!$php8 || $isJs) continue; $sev = 'error'; }
            if ($isJs && in_array($id, array('debug_dump', 'display_errors', 'php8_removed', 'preg_e', 'var_function_input'), true)) continue;
            if ($minified && in_array($id, array('long_base64', 'hex_obfuscation', 'local_url'), true)) continue;
            if (!preg_match_all($re, $data, $m, PREG_OFFSET_CAPTURE)) continue;
            $n = 0;
            foreach ($m[0] as $hit) {
                // Righe commentate: non contano per debug e indirizzi locali.
                // Immagini e font incorporati (data:...;base64,) non sono codice nascosto.
                if ($id === 'long_base64' && stripos(substr($data, max(0, $hit[1] - 40), 40), 'base64,') !== false) continue;
                $lineStart = strrpos(substr($data, 0, $hit[1]), "\n");
                $lineText = substr($data, $lineStart === false ? 0 : $lineStart + 1, 300);
                $nl = strpos($lineText, "\n");
                $lineText = ltrim($nl === false ? $lineText : substr($lineText, 0, $nl));
                if (in_array($id, array('debug_dump', 'local_url', 'php8_removed'), true) && (strpos($lineText, '//') === 0 || strpos($lineText, '*') === 0 || strpos($lineText, '#') === 0)) continue;
                if ($id === 'php8_removed' && preg_match('~function\s+&?\s*' . preg_quote(rtrim($hit[0], " \t("), '~') . '~i', $lineText)) continue;
                $out[] = array('path' => $rel, 'line' => substr_count($data, "\n", 0, $hit[1]) + 1, 'rule' => $id, 'severity' => $sev, 'snippet' => trv_snippet($data, $hit[1]));
                if (++$n >= 5) break;
            }
        }
        if (microtime(true) - $started > 20) break;
    }
    return array('findings' => $out, 'done' => $done);
}

function trv_snippet($data, $offset) {
    $s = substr($data, max(0, $offset - 20), 140);
    $s = preg_replace('~\s+~', ' ', $s);
    if (function_exists('mb_convert_encoding')) $s = mb_convert_encoding($s, 'UTF-8', 'UTF-8');
    return trim($s);
}

/** Scarica file: per ciascuno "F dimensione mtime percorso\n" e poi i byte. Fine: "E\n". */
function trv_download($req) {
    $GLOBALS['trv_sent'] = true;
    $paths = isset($req['paths']) ? (array)$req['paths'] : array();
    if (!TRV_CLI) header('Content-Type: application/octet-stream');
    foreach ($paths as $rel) {
        $abs = trv_abs($rel);
        if (!is_file($abs)) { echo 'M ' . rawurlencode($rel) . "\n"; continue; }
        $size = filesize($abs);
        echo 'F ' . $size . ' ' . filemtime($abs) . ' ' . rawurlencode($rel) . "\n";
        $fh = fopen($abs, 'rb');
        $sent = 0;
        while ($sent < $size && !feof($fh)) {
            $chunk = fread($fh, min(1048576, $size - $sent));
            if ($chunk === false || $chunk === '') break;
            echo $chunk;
            $sent += strlen($chunk);
        }
        fclose($fh);
        if ($sent < $size) echo str_repeat("\0", $size - $sent); // file cambiato durante la lettura
        flush();
    }
    echo "E\n";
}

function trv_session_dir($session) {
    if (!preg_match('~^[a-zA-Z0-9_-]{6,64}$~', $session)) trv_fail('sessione non valida');
    return trv_workdir() . '/staging/' . $session;
}

/** Riceve file (anche a pezzi) nella cartella di staging; diventano veri solo con "commit". */
function trv_upload($body, $session) {
    $dir = trv_session_dir($session);
    $pos = 0;
    $len = strlen($body);
    $written = array();
    if (substr($body, 0, 2) === "\x1f\x8b") { $body = gzdecode($body); $len = strlen($body); }
    while ($pos < $len) {
        $nl = strpos($body, "\n", $pos);
        if ($nl === false) trv_fail('upload malformato');
        $line = substr($body, $pos, $nl - $pos);
        $pos = $nl + 1;
        if ($line === 'E') break;
        $parts = explode(' ', $line);
        if (count($parts) !== 6 || $parts[0] !== 'P') trv_fail('upload malformato: ' . substr($line, 0, 80));
        $offset = (int)$parts[1]; $n = (int)$parts[2]; $total = (int)$parts[3];
        $rel = rawurldecode($parts[5]);
        trv_abs($rel); // validazione
        $target = $dir . '/' . $rel;
        trv_mkdirp(dirname($target));
        $fh = fopen($target, $offset === 0 ? 'wb' : 'cb');
        if (!$fh) trv_fail('impossibile scrivere ' . $rel);
        fseek($fh, $offset);
        fwrite($fh, substr($body, $pos, $n));
        fclose($fh);
        $pos += $n;
        $written[] = array('path' => $rel, 'complete' => $offset + $n >= $total);
    }
    return array('received' => count($written));
}

function trv_new_backup($type, $note) {
    $id = date('Ymd-His') . '-' . $type . '-' . substr(bin2hex(function_exists('random_bytes') ? random_bytes(4) : uniqid()), 0, 6);
    $dir = trv_workdir() . '/backups/' . $id;
    trv_mkdirp($dir);
    file_put_contents($dir . '/meta.json', json_encode(array('id' => $id, 'type' => $type, 'note' => $note, 'created' => time(), 'files' => array())));
    return array($id, $dir);
}

function trv_backup_meta($dir, $patch) {
    $m = json_decode(@file_get_contents($dir . '/meta.json'), true);
    if (!is_array($m)) $m = array();
    foreach ($patch as $k => $v) $m[$k] = $v;
    file_put_contents($dir . '/meta.json', json_encode($m, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
}

/** Porta in produzione i file ricevuti: prima copia gli originali nel backup, poi rename. */
function trv_commit($req) {
    $dir = trv_session_dir(isset($req['session']) ? (string)$req['session'] : '');
    $files = isset($req['files']) ? (array)$req['files'] : array();
    list($bid, $bdir) = trv_new_backup('files', isset($req['note']) ? $req['note'] : 'push file');
    $done = array(); $errors = array(); $backedUp = array(); $created = array();
    // Prima verifica tutto, poi scrive: se manca un pezzo non tocca niente.
    foreach ($files as $f) {
        $rel = $f['path'];
        trv_abs($rel);
        $src = $dir . '/' . $rel;
        if (!is_file($src) || filesize($src) !== (int)$f['size']) $errors[] = array('path' => $rel, 'error' => 'file incompleto sul server');
    }
    if ($errors) return array('ok' => false, 'error' => 'upload incompleto, nessun file modificato', 'errors' => $errors);
    foreach ($files as $f) {
        $rel = $f['path'];
        $abs = trv_abs($rel);
        $src = $dir . '/' . $rel;
        if (is_file($abs)) {
            trv_mkdirp(dirname($bdir . '/files/' . $rel));
            if (@copy($abs, $bdir . '/files/' . $rel)) $backedUp[] = $rel;
        } else {
            $created[] = $rel;
        }
        trv_mkdirp(dirname($abs));
        if (!@rename($src, $abs)) {
            if (!@copy($src, $abs)) { $errors[] = array('path' => $rel, 'error' => 'scrittura non riuscita (permessi?)'); continue; }
            @unlink($src);
        }
        if (!empty($f['mtime'])) @touch($abs, (int)$f['mtime']);
        $done[] = $rel;
    }
    trv_backup_meta($bdir, array('files' => $backedUp, 'created' => $created));
    trv_rrmdir($dir);
    return array('ok' => !$errors, 'done' => $done, 'errors' => $errors, 'backup' => $bid, 'error' => $errors ? count($errors) . ' file non scritti' : null);
}

function trv_rrmdir($dir) {
    // Solo per la cartella di staging dell'app: non tocca mai file del sito.
    if (strpos($dir, trv_workdir() . '/staging/') !== 0 || !is_dir($dir)) return;
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
    foreach ($it as $f) { if ($f->isDir()) @rmdir($f->getPathname()); else @unlink($f->getPathname()); }
    @rmdir($dir);
}

/** "Elimina" sul server: sposta in _da_eliminare, non cancella mai. */
function trv_trash($req) {
    $paths = isset($req['paths']) ? (array)$req['paths'] : array();
    $base = trv_workdir() . '/_da_eliminare/' . date('Ymd-His');
    $moved = array(); $errors = array();
    foreach ($paths as $rel) {
        $abs = trv_abs($rel);
        if (!file_exists($abs)) continue;
        trv_mkdirp(dirname($base . '/' . $rel));
        if (@rename($abs, $base . '/' . $rel)) $moved[] = $rel; else $errors[] = $rel;
    }
    return array('ok' => !$errors, 'moved' => $moved, 'errors' => $errors, 'folder' => $base, 'error' => $errors ? 'non spostati: ' . implode(', ', $errors) : null);
}

// ---------------------------------------------------------------- database: confronto

function trv_primary_key($table) {
    $pk = array();
    $r = trv_q('SHOW KEYS FROM ' . trv_qi($table) . " WHERE Key_name = 'PRIMARY'");
    while ($row = $r->fetch_assoc()) $pk[(int)$row['Seq_in_index']] = $row['Column_name'];
    ksort($pk);
    return array_values($pk);
}

/** Normalizza un valore per il confronto: URL e percorsi diversi tra locale e remoto non contano. */
function trv_norm($v, $pairs) {
    if ($v === null) return "\0N";
    if (!$pairs) return $v;
    $changed = false;
    foreach ($pairs as $p) {
        if ($p[0] !== '' && strpos($v, $p[0]) !== false) { $v = str_replace($p[0], $p[1], $v); $changed = true; }
    }
    if ($changed) $v = preg_replace('~s:\d+:"~', 's:#:"', $v);
    return $v;
}

/** Elenco tabelle con righe e impronta del contenuto (e, se richiesto, impronta di ogni riga). */
function trv_db_tables($req) {
    $db = trv_db();
    $s = trv_db_settings($GLOBALS['trv_db_req']);
    $only = isset($req['tables']) ? (array)$req['tables'] : null;
    $rowsLimit = isset($req['row_hashes']) ? (int)$req['row_hashes'] : 0;
    $pairs = isset($req['normalize']) ? (array)$req['normalize'] : array();
    $deadline = microtime(true) + (isset($req['budget']) ? (float)$req['budget'] : 25);
    $status = array();
    $r = trv_q('SHOW TABLE STATUS');
    while ($row = $r->fetch_assoc()) if ($row['Engine'] !== null) $status[$row['Name']] = $row;
    $out = array();
    $pending = array();
    foreach ($status as $name => $st) {
        if ($only !== null && !in_array($name, $only, true)) continue;
        $t = array('name' => $name, 'engine' => $st['Engine'], 'collation' => $st['Collation'],
            'size' => (int)$st['Data_length'] + (int)$st['Index_length'], 'rows' => null, 'hash' => null);
        if (microtime(true) > $deadline) { $pending[] = $name; $out[] = $t; continue; }
        $pk = trv_primary_key($name);
        $t['pk'] = $pk;
        $order = $pk ? ' ORDER BY ' . implode(',', array_map('trv_qi', $pk)) : '';
        $skip = '';
        if ($name === $s['prefix'] . 'options') $skip = " WHERE option_name NOT LIKE '\\_transient\\_%' AND option_name NOT LIKE '\\_site\\_transient\\_%' AND option_name NOT IN ('cron','rewrite_rules','recently_activated')";
        if ($name === $s['prefix'] . 'usermeta') $skip = " WHERE meta_key NOT IN ('session_tokens')";
        $conn = trv_db(true);
        $res = $conn->query('SELECT * FROM ' . trv_qi($name) . $skip . $order, MYSQLI_USE_RESULT);
        if (!$res) { $t['error'] = $conn->error; $out[] = $t; continue; }
        $ctx = hash_init('md5');
        $n = 0;
        $rowmap = array();
        $keepRows = $rowsLimit > 0;
        while ($row = $res->fetch_assoc()) {
            $vals = array();
            foreach ($row as $v) $vals[] = trv_norm($v, $pairs);
            $line = implode("\x1e", $vals);
            hash_update($ctx, $line . "\x1d");
            if ($keepRows) {
                if ($n >= $rowsLimit) { $keepRows = false; $rowmap = null; }
                else {
                    $key = $pk ? implode("\x1f", array_map(function ($c) use ($row) { return (string)$row[$c]; }, $pk)) : md5($line);
                    $rowmap[$key] = substr(md5($line), 0, 12);
                }
            }
            $n++;
        }
        $res->free();
        $conn->close();
        $t['rows'] = $n;
        $t['hash'] = hash_final($ctx);
        if ($rowsLimit > 0) $t['row_hashes'] = $rowmap === null ? null : (object)$rowmap;
        $out[] = $t;
    }
    return array('tables' => $out, 'pending' => $pending, 'prefix' => $s['prefix'], 'server' => trv_server_version());
}

/** Alcune colonne di righe precise (per mostrare quali post sono diversi). */
function trv_db_rows($req) {
    $table = (string)$req['table'];
    $cols = isset($req['columns']) ? (array)$req['columns'] : array();
    $keys = isset($req['keys']) ? array_slice((array)$req['keys'], 0, 500) : array();
    $pk = trv_primary_key($table);
    if (count($pk) !== 1 || !$keys) return array('rows' => array());
    $db = trv_db();
    $existing = array();
    $r = trv_q('SHOW COLUMNS FROM ' . trv_qi($table));
    while ($c = $r->fetch_assoc()) $existing[] = $c['Field'];
    $cols = $cols ? array_values(array_intersect($cols, $existing)) : array_slice(array_values(array_diff($existing, $pk)), 0, 4);
    array_unshift($cols, $pk[0]);
    $in = implode(',', array_map(function ($k) use ($db) { return "'" . $db->real_escape_string($k) . "'"; }, $keys));
    $r = trv_q('SELECT ' . implode(',', array_map('trv_qi', array_unique($cols))) . ' FROM ' . trv_qi($table) . ' WHERE ' . trv_qi($pk[0]) . ' IN (' . $in . ')');
    $rows = array();
    while ($row = $r->fetch_assoc()) {
        foreach ($row as $k => $v) if (is_string($v) && strlen($v) > 200) $row[$k] = substr($v, 0, 200) . '…';
        $rows[] = $row;
    }
    return array('rows' => $rows);
}

// ---------------------------------------------------------------- database: dump

/** CREATE TABLE compatibile con MySQL 5.7/8 e MariaDB, su una riga, col nome di destinazione. */
function trv_portable_create($sql, $from, $to, $map, $suffix) {
    $sql = preg_replace('~^CREATE TABLE `' . preg_quote(str_replace('`', '``', $from), '~') . '`~', 'CREATE TABLE ' . trv_qi($to), $sql);
    $sql = str_replace(array('utf8mb4_0900_ai_ci', 'utf8mb4_0900_as_ci', 'utf8mb4_0900_as_cs', 'utf8mb4_0900_bin', 'utf8mb4_uca1400_ai_ci', 'utf8mb4_uca1400_as_cs', 'utf8mb4_uca1400_as_ci'),
        array('utf8mb4_unicode_520_ci', 'utf8mb4_unicode_520_ci', 'utf8mb4_bin', 'utf8mb4_bin', 'utf8mb4_unicode_520_ci', 'utf8mb4_bin', 'utf8mb4_unicode_520_ci'), $sql);
    $sql = preg_replace('~\butf8mb3_(\w+)~', 'utf8_$1', $sql);
    $sql = preg_replace('~\butf8mb3\b~', 'utf8', $sql);
    $sql = preg_replace("~\s*DEFAULT ENCRYPTION\s*=\s*'[YN]'~i", '', $sql);
    $sql = preg_replace('~/\*!80016\s*~', '', $sql);
    $sql = preg_replace('~\s*/\*!\d+\s*\*/~', '', $sql);
    $sql = preg_replace('~ENGINE=Aria~i', 'ENGINE=InnoDB', $sql);
    $sql = preg_replace('~\s*(PAGE_CHECKSUM|TRANSACTIONAL)=\d~i', '', $sql);
    // Vincoli: i nomi devono essere unici nel database (le tabelle di staging convivono con quelle vere).
    $sql = preg_replace_callback('~CONSTRAINT `([^`]+)`~', function ($m) use ($suffix) {
        return 'CONSTRAINT `' . substr($m[1], 0, 56) . '_' . $suffix . '`';
    }, $sql);
    $sql = preg_replace_callback('~REFERENCES `([^`]+)`~', function ($m) use ($map) {
        return 'REFERENCES ' . trv_qi(isset($map[$m[1]]) ? $map[$m[1]] : $m[1]);
    }, $sql);
    return str_replace(array("\r\n", "\n", "\r"), ' ', $sql);
}

/** Scrive il dump: un'istruzione per riga, così l'import può spezzarlo dove vuole. */
function trv_dump($out, $tables, $map) {
    $db = trv_db();
    $suffix = substr(md5(uniqid('', true)), 0, 6);
    $out("SET NAMES utf8mb4;\n");
    foreach ($tables as $table) {
        $to = isset($map[$table]) ? $map[$table] : $table;
        $row = trv_q('SHOW CREATE TABLE ' . trv_qi($table))->fetch_row();
        $out('DROP TABLE IF EXISTS ' . trv_qi($to) . ";\n");
        $out(trv_portable_create($row[1], $table, $to, $map, $suffix) . ";\n");
        $conn = trv_db(true);
        $res = $conn->query('SELECT * FROM ' . trv_qi($table), MYSQLI_USE_RESULT);
        if (!$res) trv_fail('MySQL: ' . $conn->error);
        $fields = $res->fetch_fields();
        $binary = array();
        $blobTypes = array(MYSQLI_TYPE_TINY_BLOB, MYSQLI_TYPE_MEDIUM_BLOB, MYSQLI_TYPE_LONG_BLOB, MYSQLI_TYPE_BLOB, MYSQLI_TYPE_STRING, MYSQLI_TYPE_VAR_STRING, MYSQLI_TYPE_BIT, MYSQLI_TYPE_GEOMETRY);
        foreach ($fields as $i => $f) $binary[$i] = $f->charsetnr == 63 && in_array($f->type, $blobTypes, true);
        $prefix = 'INSERT INTO ' . trv_qi($to) . ' VALUES ';
        $stmt = '';
        while ($r = $res->fetch_row()) {
            $vals = array();
            foreach ($r as $i => $v) {
                if ($v === null) $vals[] = 'NULL';
                elseif ($binary[$i]) $vals[] = $v === '' ? "''" : '0x' . bin2hex($v);
                else $vals[] = "'" . $db->real_escape_string($v) . "'";
            }
            $tuple = '(' . implode(',', $vals) . ')';
            if ($stmt !== '' && strlen($stmt) + strlen($tuple) > 500000) { $out($stmt . ";\n"); $stmt = ''; }
            $stmt .= ($stmt === '' ? $prefix : ',') . $tuple;
        }
        if ($stmt !== '') $out($stmt . ";\n");
        $res->free();
        $conn->close();
    }
}

function trv_dump_tables_and_map($req) {
    $all = trv_base_tables();
    $map = isset($req['map']) && is_array($req['map']) ? $req['map'] : array();
    if (isset($req['tables']) && $req['tables']) {
        $tables = array_values(array_intersect((array)$req['tables'], $all));
    } elseif ($map) {
        // Con una mappa si esportano SOLO le tabelle mappate (invio di una parte del database).
        $tables = array_values(array_intersect(array_keys($map), $all));
    } else {
        $tables = $all;
    }
    return array($tables, $map);
}

/** Dump in streaming (gzip). */
function trv_db_dump_stream($req) {
    $GLOBALS['trv_sent'] = true;
    list($tables, $map) = trv_dump_tables_and_map($req);
    if (!TRV_CLI) header('Content-Type: application/octet-stream');
    if (!empty($req['raw']) || !function_exists('deflate_init')) {
        $out = function ($s) { echo $s; };
        trv_dump($out, $tables, $map);
        echo "-- MIRRORPRESS-END\n";
        return;
    }
    $gz = deflate_init(ZLIB_ENCODING_GZIP, array('level' => 6));
    $out = function ($s) use ($gz) { echo deflate_add($gz, $s, ZLIB_NO_FLUSH); };
    trv_dump($out, $tables, $map);
    $out("-- MIRRORPRESS-END\n");
    echo deflate_add($gz, '', ZLIB_FINISH);
}

/** Backup completo del database in un file .sql.gz nella cartella di lavoro. */
function trv_backup_db($req) {
    list($id, $dir) = trv_new_backup('db', isset($req['note']) ? $req['note'] : 'backup database');
    $file = $dir . '/db.sql.gz';
    $fh = gzopen($file, 'wb6');
    if (!$fh) trv_fail('impossibile scrivere il backup');
    $out = function ($s) use ($fh) { gzwrite($fh, $s); };
    trv_dump($out, trv_base_tables(), array());
    $out("-- MIRRORPRESS-END\n");
    gzclose($fh);
    trv_backup_meta($dir, array('size' => filesize($file), 'tables' => count(trv_base_tables())));
    return array('backup' => $id, 'size' => filesize($file));
}

// ---------------------------------------------------------------- database: import, sostituzioni, scambio

function trv_exec_sql_lines($lines, $guard) {
    $db = trv_db();
    $n = 0;
    foreach ($lines as $i => $line) {
        $line = rtrim($line, "\r\n");
        if ($line === '' || strpos($line, '-- ') === 0 || $line === '--') continue;
        if ($guard !== '' && preg_match('~^(DROP TABLE IF EXISTS|CREATE TABLE|INSERT INTO) `([^`]+)`~', $line, $m) && strpos($m[2], $guard) !== 0) {
            trv_fail('istruzione fuori dalle tabelle di staging: ' . substr($line, 0, 120));
        }
        if (substr($line, -1) === ';') $line = substr($line, 0, -1);
        if (!$db->query($line)) trv_fail('MySQL (riga ' . ($i + 1) . '): ' . $db->error . ' — ' . substr($line, 0, 200));
        $n++;
    }
    return $n;
}

/** Esegue un pezzo di dump (gzip): solo istruzioni complete, una per riga. */
function trv_db_import($body, $req) {
    $guard = isset($req['guard']) ? (string)$req['guard'] : '';
    // In locale si importa direttamente da un file (anche grande), riga per riga.
    if (TRV_CLI && !empty($req['file'])) {
        $fh = gzopen($req['file'], 'rb');
        if (!$fh) trv_fail('file SQL non leggibile');
        $n = 0; $line = '';
        while (!gzeof($fh)) {
            $line .= gzgets($fh, 1048576);
            if (substr($line, -1) !== "\n" && !gzeof($fh)) continue;
            $n += trv_exec_sql_lines(array($line), $guard);
            $line = '';
        }
        gzclose($fh);
        return array('statements' => $n);
    }
    if (isset($req['z']) && $req['z'] === 'deflate') $body = gzinflate($body);
    elseif (substr($body, 0, 2) === "\x1f\x8b") $body = gzdecode($body);
    if ($body === false) trv_fail('pacchetto SQL non valido');
    $n = trv_exec_sql_lines(explode("\n", $body), $guard);
    return array('statements' => $n);
}

/** Lettore del formato serialize() di PHP che sostituisce dentro le stringhe e ricalcola le lunghezze. */
function trv_ser_walk($s, &$i, $pairs, &$changed) {
    $len = strlen($s);
    if ($i >= $len) return null;
    $t = $s[$i];
    switch ($t) {
        case 'N':
            if (substr($s, $i, 2) !== 'N;') return null;
            $i += 2; return 'N;';
        case 'b': case 'i': case 'd': case 'r': case 'R':
            $end = strpos($s, ';', $i);
            if ($end === false || $s[$i + 1] !== ':') return null;
            $tok = substr($s, $i, $end - $i + 1);
            $i = $end + 1; return $tok;
        case 's': case 'S':
            if (!preg_match('~\G[sS]:(\d+):"~', $s, $m, 0, $i)) return null;
            $n = (int)$m[1];
            $start = $i + strlen($m[0]);
            if (substr($s, $start + $n, 2) !== '";') return null;
            $str = substr($s, $start, $n);
            $i = $start + $n + 2;
            $new = trv_replace_value($str, $pairs, $changed);
            return 's:' . strlen($new) . ':"' . $new . '";';
        case 'a':
            if (!preg_match('~\Ga:(\d+):\{~', $s, $m, 0, $i)) return null;
            $i += strlen($m[0]);
            $res = $m[0];
            for ($k = 0; $k < (int)$m[1] * 2; $k++) {
                $part = trv_ser_walk($s, $i, $pairs, $changed);
                if ($part === null) return null;
                $res .= $part;
            }
            if (!isset($s[$i]) || $s[$i] !== '}') return null;
            $i++; return $res . '}';
        case 'O':
            if (!preg_match('~\GO:(\d+):"([^"]*)":(\d+):\{~', $s, $m, 0, $i)) return null;
            $i += strlen($m[0]);
            $res = $m[0];
            for ($k = 0; $k < (int)$m[3] * 2; $k++) {
                $part = trv_ser_walk($s, $i, $pairs, $changed);
                if ($part === null) return null;
                $res .= $part;
            }
            if (!isset($s[$i]) || $s[$i] !== '}') return null;
            $i++; return $res . '}';
        case 'C': case 'E':
            // Serializzazione personalizzata o enum: si lascia com'è (niente URL dentro, di solito).
            if ($t === 'E') {
                if (!preg_match('~\GE:(\d+):"~', $s, $m, 0, $i)) return null;
                $end = $i + strlen($m[0]) + (int)$m[1] + 2;
                $tok = substr($s, $i, $end - $i); $i = $end; return $tok;
            }
            if (!preg_match('~\GC:(\d+):"([^"]*)":(\d+):\{~', $s, $m, 0, $i)) return null;
            $end = $i + strlen($m[0]) + (int)$m[3] + 1;
            $tok = substr($s, $i, $end - $i); $i = $end; return $tok;
    }
    return null;
}

function trv_replace_value($v, $pairs, &$changed) {
    $hit = false;
    foreach ($pairs as $p) if ($p[0] !== '' && strpos($v, $p[0]) !== false) { $hit = true; break; }
    if (!$hit) return $v;
    if (preg_match('~^(a|O|s):\d+:~', $v)) {
        $i = 0;
        $c = false;
        $r = trv_ser_walk($v, $i, $pairs, $c);
        if ($r !== null && $i === strlen($v)) { if ($c) $changed = true; return $r; }
    }
    $new = $v;
    foreach ($pairs as $p) if ($p[0] !== '') $new = str_replace($p[0], $p[1], $new);
    if ($new !== $v) $changed = true;
    return $new;
}

/** Cerca e sostituisci sicuro (dati serializzati compresi) sulle tabelle indicate. */
function trv_db_replace($req) {
    $tables = isset($req['tables']) ? (array)$req['tables'] : array();
    $pairs = array();
    foreach ((array)$req['pairs'] as $p) if (is_array($p) && count($p) === 2 && $p[0] !== '' && $p[0] !== $p[1]) $pairs[] = array((string)$p[0], (string)$p[1]);
    if (!$pairs) return array('changed' => 0);
    $db = trv_db();
    $total = 0;
    $report = array();
    foreach ($tables as $table) {
        $pk = trv_primary_key($table);
        $cols = array();
        $r = trv_q('SHOW COLUMNS FROM ' . trv_qi($table));
        while ($c = $r->fetch_assoc()) {
            if (preg_match('~char|text|json|enum|set~i', $c['Type']) && !in_array($c['Field'], $pk, true)) $cols[] = $c['Field'];
        }
        if (!$cols) continue;
        if (!$pk) { $report[$table] = 'senza chiave primaria: saltata'; continue; }
        $where = array();
        foreach ($cols as $c) foreach ($pairs as $p) $where[] = trv_qi($c) . " LIKE '%" . $db->real_escape_string(addcslashes($p[0], '%_\\')) . "%'";
        $sel = 'SELECT ' . implode(',', array_map('trv_qi', array_merge($pk, $cols))) . ' FROM ' . trv_qi($table) . ' WHERE ' . implode(' OR ', $where);
        $reader = trv_db(true);
        $res = $reader->query($sel, MYSQLI_USE_RESULT);
        if (!$res) trv_fail('MySQL: ' . $reader->error);
        $updates = array();
        while ($row = $res->fetch_assoc()) {
            $set = array();
            foreach ($cols as $c) {
                if ($row[$c] === null) continue;
                $changed = false;
                $new = trv_replace_value($row[$c], $pairs, $changed);
                if ($changed) $set[] = trv_qi($c) . "='" . $db->real_escape_string($new) . "'";
            }
            if ($set) {
                $w = array();
                foreach ($pk as $k) $w[] = trv_qi($k) . "='" . $db->real_escape_string($row[$k]) . "'";
                $updates[] = 'UPDATE ' . trv_qi($table) . ' SET ' . implode(',', $set) . ' WHERE ' . implode(' AND ', $w);
            }
        }
        $res->free();
        $reader->close();
        foreach ($updates as $u) trv_q($u);
        $total += count($updates);
        if ($updates) $report[$table] = count($updates);
    }
    return array('changed' => $total, 'tables' => (object)$report);
}

/** Sostituisce in un colpo solo le tabelle vere con quelle di staging (RENAME atomico). */
function trv_db_swap($req) {
    $map = isset($req['map']) ? (array)$req['map'] : array(); // staging => destinazione
    if (!$map) trv_fail('niente da scambiare');
    $db = trv_db();
    $existing = trv_base_tables();
    $renames = array(); $olds = array();
    $tag = substr(md5(uniqid('', true)), 0, 5);
    foreach ($map as $staging => $target) {
        if (!in_array($staging, $existing, true)) trv_fail('tabella di staging mancante: ' . $staging);
        if (in_array($target, $existing, true)) {
            $old = substr('trvold' . $tag . '_' . $target, 0, 64);
            $renames[] = trv_qi($target) . ' TO ' . trv_qi($old);
            $olds[] = $old;
        }
        $renames[] = trv_qi($staging) . ' TO ' . trv_qi($target);
    }
    trv_q('RENAME TABLE ' . implode(', ', $renames));
    foreach ($olds as $o) trv_q('DROP TABLE IF EXISTS ' . trv_qi($o));

    // Prefisso diverso tra locale e remoto: WordPress lo usa anche dentro options e usermeta.
    $fixed = 0;
    if (!empty($req['prefix_from']) && !empty($req['prefix_to']) && $req['prefix_from'] !== $req['prefix_to']) {
        $from = $req['prefix_from']; $to = $req['prefix_to'];
        $like = $db->real_escape_string(addcslashes($from, '%_\\')) . '%';
        $len = strlen($from) + 1;
        $ot = trv_qi($to . 'options'); $ut = trv_qi($to . 'usermeta');
        if (in_array($to . 'options', array_merge($existing, array_values($map)), true)) {
            // In options l'unica chiave col prefisso è {prefix}user_roles (wp_page_for_privacy_policy & co. sono nomi fissi).
            trv_q("UPDATE $ot SET option_name = '" . $db->real_escape_string($to . 'user_roles') . "' WHERE option_name = '" . $db->real_escape_string($from . 'user_roles') . "'");
            $fixed += $db->affected_rows;
        }
        if (in_array($to . 'usermeta', array_merge($existing, array_values($map)), true)) {
            trv_q("UPDATE $ut SET meta_key = CONCAT('" . $db->real_escape_string($to) . "', SUBSTRING(meta_key, $len)) WHERE meta_key LIKE '$like'");
            $fixed += $db->affected_rows;
        }
    }
    if (!empty($req['flush_rewrite']) && !empty($req['prefix_to'])) {
        @$db->query('DELETE FROM ' . trv_qi($req['prefix_to'] . 'options') . " WHERE option_name = 'rewrite_rules'");
    }
    return array('swapped' => count($map), 'prefix_fixed' => $fixed);
}

function trv_db_drop_staging($req) {
    $guard = isset($req['guard']) ? (string)$req['guard'] : '';
    if (strlen($guard) < 6 || strpos($guard, 'trv') !== 0) trv_fail('prefisso di staging non valido');
    $n = 0;
    foreach (trv_base_tables() as $t) if (strpos($t, $guard) === 0) { trv_q('DROP TABLE IF EXISTS ' . trv_qi($t)); $n++; }
    return array('dropped' => $n);
}

// ---------------------------------------------------------------- backup

function trv_backups() {
    $base = trv_workdir() . '/backups';
    $out = array();
    if (is_dir($base)) {
        foreach (scandir($base) as $id) {
            if ($id[0] === '.') continue;
            $m = json_decode(@file_get_contents($base . '/' . $id . '/meta.json'), true);
            if (!is_array($m)) continue;
            $m['id'] = $id;
            $m['file_count'] = isset($m['files']) ? count($m['files']) : 0;
            unset($m['files'], $m['created_files']);
            $out[] = $m;
        }
    }
    usort($out, function ($a, $b) { return $b['created'] - $a['created']; });
    return array('backups' => $out, 'workdir' => trv_workdir());
}

/** Legge un pezzo di un file della cartella di lavoro (backup grandi scaricati a rate). */
function trv_fetch($req) {
    $GLOBALS['trv_sent'] = true;
    $rel = (string)$req['path'];
    if (strpos($rel, '..') !== false) trv_fail('percorso non valido');
    $abs = trv_workdir() . '/' . ltrim($rel, '/');
    if (!is_file($abs)) trv_fail('file non trovato');
    $offset = isset($req['offset']) ? (int)$req['offset'] : 0;
    $len = isset($req['length']) ? (int)$req['length'] : 8388608;
    if (!TRV_CLI) { header('Content-Type: application/octet-stream'); header('X-Mirrorpress-Size: ' . filesize($abs)); }
    $fh = fopen($abs, 'rb');
    fseek($fh, $offset);
    $left = $len;
    while ($left > 0 && !feof($fh)) { $c = fread($fh, min(1048576, $left)); echo $c; $left -= strlen($c); }
    fclose($fh);
}

/** Ripristina un backup: database (reimport) o file (gli attuali vanno in _da_eliminare). */
function trv_restore($req) {
    $id = (string)$req['id'];
    if (!preg_match('~^[\w.-]+$~', $id)) trv_fail('backup non valido');
    $dir = trv_workdir() . '/backups/' . $id;
    $m = json_decode(@file_get_contents($dir . '/meta.json'), true);
    if (!is_array($m)) trv_fail('backup non trovato');
    if ($m['type'] === 'db') {
        $fh = gzopen($dir . '/db.sql.gz', 'rb');
        $db = trv_db();
        $n = 0; $line = '';
        while (!gzeof($fh)) {
            $line .= gzgets($fh, 1048576);
            if (substr($line, -1) !== "\n" && !gzeof($fh)) continue;
            $n += trv_exec_sql_lines(array($line), '');
            $line = '';
        }
        gzclose($fh);
        return array('restored' => 'db', 'statements' => $n);
    }
    $files = isset($m['files']) ? $m['files'] : array();
    $created = isset($m['created']) ? $m['created'] : array();
    $trash = trv_trash(array('paths' => $created));
    $done = 0;
    foreach ($files as $rel) {
        $abs = trv_abs($rel);
        trv_mkdirp(dirname($abs));
        if (@copy($dir . '/files/' . $rel, $abs)) $done++;
    }
    return array('restored' => 'files', 'files' => $done, 'removed' => count($trash['moved']));
}

/** Pulizia della sessione: staging e tabelle temporanee. Non tocca backup né _da_eliminare. */
function trv_cleanup($req) {
    if (!empty($req['session'])) trv_rrmdir(trv_session_dir((string)$req['session']));
    $dropped = 0;
    if (!empty($req['guard'])) { $r = trv_db_drop_staging(array('guard' => $req['guard'])); $dropped = $r['dropped']; }
    return array('dropped' => $dropped);
}
