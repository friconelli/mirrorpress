#!/bin/bash
# Prova completa del ponte PHP con MAMP, senza toccare il sito di partenza:
#   copia il DB di un sito locale in un database di prova (`mirrorpress_test`, prefisso diverso, URL di produzione finto),
#   poi controlla che i dati serializzati siano integri e che il confronto normalizzato dica "tutto uguale".
#   Prova anche upload + commit + backup + trash dei file in una cartella temporanea.
# Uso: Scripts/test_bridge.sh [sito-in-htdocs]      (predefinito: villapatrizia)
set -euo pipefail

SITE="${1:-villapatrizia}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="$ROOT_DIR/Resources/Bridge/mirrorpress-bridge.php"
PHP="$(ls -d /Applications/MAMP/bin/php/php8* | sort -V | tail -1)/bin/php"
MYSQL=/Applications/MAMP/Library/bin/mysql80/bin/mysql
SRC=/Applications/MAMP/htdocs/$SITE
W="$(mktemp -d)"; trap 'rm -rf "$W"; "$MYSQL" -uroot -proot -h127.0.0.1 -P8889 -e "DROP DATABASE IF EXISTS mirrorpress_test" 2>/dev/null' EXIT
export MIRRORPRESS_WORKDIR="$W/work"
TEST_URL="https://www.mirrorpress-test.example"
DBO='{"name":"mirrorpress_test","user":"root","pass":"root","host":"localhost","prefix":"xx_"}'

run() { "$PHP" -d mysqli.default_socket=/Applications/MAMP/tmp/mysql/mysql.sock "$B" "$@"; }
py() { /usr/bin/python3 -c "$@"; }
ok() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "==> Sito di partenza: $SRC"
"$MYSQL" -uroot -proot -h127.0.0.1 -P8889 -e "DROP DATABASE IF EXISTS mirrorpress_test; CREATE DATABASE mirrorpress_test CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci" 2>/dev/null

INFO="$(MIRRORPRESS_ROOT=$SRC run info <<<'{}')"
URL="$(py "import json,sys;print(json.loads(sys.argv[1])['db']['options']['siteurl'])" "$INFO")"
PFX="$(py "import json,sys;print(json.loads(sys.argv[1])['db']['prefix'])" "$INFO")"
ok "info: $URL, prefisso $PFX"

TABLES="$(MIRRORPRESS_ROOT=$SRC run db_tables <<<'{"budget":0}')"
MAP="$(py "import json,sys;d=json.loads(sys.argv[1]);p=sys.argv[2];print(json.dumps({'map':{t['name']:'trvtmp_xx_'+t['name'][len(p):] for t in d['tables'] if t['name'].startswith(p)}}))" "$TABLES" "$PFX")"
MIRRORPRESS_ROOT=$SRC run db_dump <<<"$MAP" > "$W/dump.sql.gz"
gunzip -c "$W/dump.sql.gz" | tail -1 | grep -q MIRRORPRESS-END || fail "dump troncato"
ok "dump $(du -h "$W/dump.sql.gz" | cut -f1)"

# Dump parziale: con una mappa di due tabelle escono solo quelle due (Push di una parte del database).
PART="$(py "import json,sys;m=json.loads(sys.argv[1])['map'];k=[x for x in m if x.endswith(('posts','options'))][:2];print(json.dumps({'map':{x:m[x] for x in k}}))" "$MAP")"
NCREATE="$(MIRRORPRESS_ROOT=$SRC run db_dump <<<"$PART" | gunzip -c | grep -c '^CREATE TABLE')"
[[ "$NCREATE" == "2" ]] || fail "dump parziale: $NCREATE tabelle invece di 2"
ok "dump parziale: solo le tabelle scelte"

mkdir -p "$W/remote"
export MIRRORPRESS_ROOT="$W/remote"
R="$({ echo "J {\"guard\":\"trvtmp_\",\"db\":$DBO}"; cat "$W/dump.sql.gz"; } | run db_import)"
[[ "$R" == *'"ok":true'* ]] || fail "import: $R"; ok "import in staging"

R="$(run db_import <<<"J {\"guard\":\"trvtmp_\",\"db\":$DBO}
DROP TABLE IF EXISTS \`xx_posts\`;")"
[[ "$R" == *'fuori dalle tabelle di staging'* ]] || fail "la guardia non ha bloccato un DROP fuori staging: $R"; ok "guardia staging"

STAGED="$(py "import json,sys;print(json.dumps(list(json.loads(sys.argv[1])['map'].values())))" "$MAP")"
JURL="${URL//\//\\\\/}"; JTEST="${TEST_URL//\//\\\\/}"
R="$(run db_replace <<<"{\"db\":$DBO,\"tables\":$STAGED,\"pairs\":[[\"$URL\",\"$TEST_URL\"],[\"$JURL\",\"$JTEST\"]]}")"
[[ "$R" == *'"ok":true'* ]] || fail "replace: $R"; ok "sostituzioni: $(py "import json,sys;print(json.loads(sys.argv[1])['changed'])" "$R") righe"

SWAP="$(py "import json,sys;m=json.loads(sys.argv[1])['map'];print(json.dumps({'map':{v:'xx_'+v[len('trvtmp_xx_'):] for v in m.values()},'prefix_from':sys.argv[2],'prefix_to':'xx_','flush_rewrite':True,'db':json.loads(sys.argv[3])}))" "$MAP" "$PFX" "$DBO")"
R="$(run db_swap <<<"$SWAP")"
[[ "$R" == *'"ok":true'* ]] || fail "swap: $R"; ok "scambio atomico"

BAD="$("$PHP" -r '$db=new mysqli("127.0.0.1","root","root","mirrorpress_test",8889);$bad=0;foreach(["xx_options"=>"option_value","xx_postmeta"=>"meta_value","xx_usermeta"=>"meta_value"] as $t=>$c){$r=$db->query("SELECT $c FROM $t");while($x=$r->fetch_row()){if(preg_match("/^(a|O):\d+:/",(string)$x[0]) && @unserialize($x[0])===false)$bad++;}}echo $bad;')"
[[ "$BAD" == 0 ]] || fail "$BAD valori serializzati rotti"; ok "serializzati integri"

norm() { local p=$1 u=$2; printf '[["%s","{URL}"],["%s","{URLJ}"],["%suser_roles","{P}user_roles"],["%scapabilities","{P}capabilities"],["%suser_level","{P}user_level"],["%suser-settings","{P}user-settings"],["%sdashboard_quick_press_last_post_id","{P}dqp"]]' "$u" "${u//\//\\\\/}" $p $p $p $p $p; }
L="$(MIRRORPRESS_ROOT=$SRC run db_tables <<<"{\"normalize\":$(norm "$PFX" "$URL")}")"
RT="$(run db_tables <<<"{\"db\":$DBO,\"normalize\":$(norm xx_ "$TEST_URL")}")"
DIFF="$(py "
import json,sys
p=sys.argv[3]
l={t['name'][len(p):]:t['hash'] for t in json.loads(sys.argv[1])['tables'] if t['name'].startswith(p)}
r={t['name'][3:]:t['hash'] for t in json.loads(sys.argv[2])['tables']}
print(' '.join(k for k in l if l[k]!=r.get(k)))" "$L" "$RT" "$PFX")"
[[ -z "$DIFF" ]] || fail "tabelle diverse dopo il trasferimento: $DIFF"; ok "confronto normalizzato: identico"

echo "==> File"
mkdir -p "$W/remote/wp-content"; echo vecchio > "$W/remote/wp-content/a.txt"
S=sess$RANDOM$RANDOM
BODY="$W/up.bin"
{ echo "J {\"session\":\"$S\"}"; printf 'P 0 5 10 0 wp-content%%2Fa.txt\n'; printf 'nuovo'; printf 'P 5 5 10 0 wp-content%%2Fa.txt\n'; printf 'file!'; printf 'P 0 4 4 0 nuova%%20cartella%%2Fb.txt\n'; printf 'ciao'; } > "$BODY"
R="$(run upload < "$BODY")"; [[ "$R" == *'"received":3'* ]] || fail "upload: $R"
R="$(run commit <<<"{\"session\":\"$S\",\"files\":[{\"path\":\"wp-content/a.txt\",\"size\":10,\"mtime\":1700000000},{\"path\":\"nuova cartella/b.txt\",\"size\":4}]}")"
[[ "$R" == *'"ok":true'* ]] || fail "commit: $R"
[[ "$(cat "$W/remote/wp-content/a.txt")" == "nuovofile!" ]] || fail "contenuto a.txt"
BID="$(py "import json,sys;print(json.loads(sys.argv[1])['backup'])" "$R")"
[[ "$(cat "$MIRRORPRESS_WORKDIR/backups/$BID/files/wp-content/a.txt")" == "vecchio" ]] || fail "backup dell'originale"
ok "upload a pezzi + commit + backup"
R="$(run commit <<<"{\"session\":\"$S\",\"files\":[{\"path\":\"../evil.txt\",\"size\":1}]}")"
[[ "$R" == *'percorso non valido'* ]] || fail "percorso con .. accettato: $R"; ok "percorsi fuori root rifiutati"
R="$(run restore <<<"{\"id\":\"$BID\"}")"
[[ "$(cat "$W/remote/wp-content/a.txt")" == "vecchio" && ! -e "$W/remote/nuova cartella/b.txt" ]] || fail "ripristino: $R"; ok "ripristino backup file"
R="$(run trash <<<'{"paths":["wp-content/a.txt"]}')"
[[ ! -e "$W/remote/wp-content/a.txt" && -n "$(find "$MIRRORPRESS_WORKDIR/_da_eliminare" -name a.txt)" ]] || fail "trash: $R"; ok "eliminazione = spostamento in _da_eliminare"

echo "==> Tutto ok"
