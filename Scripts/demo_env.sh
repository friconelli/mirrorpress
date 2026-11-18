#!/bin/bash
# Ambiente di prova per l'interfaccia, senza toccare siti veri né i profili dell'app:
#   copia (clone APFS) un sito MAMP come "locale" e come "server" (prefisso e indirizzo diversi, qualche differenza
#   voluta), avvia il server con `php -S` e scrive il profilo in una home finta.
# Uso:  Scripts/demo_env.sh [sito]        prepara e stampa il comando per aprire l'app
#       Scripts/demo_env.sh --clean       ferma il server e cancella copie e database di prova
set -euo pipefail
DEMO=/tmp/mirrorpress-demo
PHP="$(ls -d /Applications/MAMP/bin/php/php8* | sort -V | tail -1)/bin/php"
MYSQL=/Applications/MAMP/Library/bin/mysql80/bin/mysql
B="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Resources/Bridge/mirrorpress-bridge.php"
PORT=8898
sql() { "$MYSQL" -uroot -proot -h127.0.0.1 -P8889 -N -e "$1" 2>/dev/null; }
run() { "$PHP" -d mysqli.default_socket=/Applications/MAMP/tmp/mysql/mysql.sock "$B" "$@"; }

if [[ "${1:-}" == "--clean" ]]; then
  pkill -f "php.*-S 127.0.0.1:$PORT" || true
  sql "DROP DATABASE IF EXISTS mirrorpress_demo_local; DROP DATABASE IF EXISTS mirrorpress_demo_remote"
  rm -rf "$DEMO"
  echo "Pulito."; exit 0
fi

SITE="${1:-villapatrizia}"
SRC=/Applications/MAMP/htdocs/$SITE
"$0" --clean >/dev/null
mkdir -p "$DEMO/server" "$DEMO/home/Library/Application Support/Mirrorpress" "$DEMO/work"
clone() { # $1 cartella  $2 db  $3 prefisso  $4 url (vuoto = invariato)
  /bin/cp -cR "$SRC" "$1"
  local name pfx
  name=$(grep -E "define\( *'DB_NAME'" "$SRC/wp-config.php" | sed -E "s/.*'DB_NAME' *, *'([^']+)'.*/\1/")
  pfx=$(grep -E '^\$table_prefix' "$SRC/wp-config.php" | sed -E "s/.*'([^']+)'.*/\1/")
  sed -i '' "s/'$name'/'$2'/; s/^\$table_prefix *= *'$pfx'/\$table_prefix = '$3'/" "$1/wp-config.php"
  sql "CREATE DATABASE $2 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci"
  local map tables
  map=$(MIRRORPRESS_ROOT=$SRC MIRRORPRESS_WORKDIR=$DEMO/work run db_tables <<<'{"budget":0}' | /usr/bin/python3 -c "import json,sys;d=json.load(sys.stdin);p=sys.argv[1];n=sys.argv[2];print(json.dumps({'map':{t['name']:'trvdemo_'+n+t['name'][len(p):] for t in d['tables'] if t['name'].startswith(p)}}))" "$pfx" "$3")
  MIRRORPRESS_ROOT=$SRC MIRRORPRESS_WORKDIR=$DEMO/work run db_dump <<<"$map" > "$DEMO/work/$2.sql.gz"
  export MIRRORPRESS_ROOT=$1 MIRRORPRESS_WORKDIR=$DEMO/work
  run db_import <<<"J {\"guard\":\"trvdemo_\",\"file\":\"$DEMO/work/$2.sql.gz\"}" >/dev/null
  tables=$(/usr/bin/python3 -c "import json,sys;print(json.dumps(list(json.loads(sys.argv[1])['map'].values())))" "$map")
  if [[ -n "$4" ]]; then
    from=$(MIRRORPRESS_ROOT=$SRC run info <<<'{}' | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin)['db']['options']['siteurl'])")
    run db_replace <<<"{\"tables\":$tables,\"pairs\":[[\"$from\",\"$4\"]]}" >/dev/null
  fi
  run db_swap <<<"$(/usr/bin/python3 -c "import json,sys;m=json.loads(sys.argv[1])['map'];print(json.dumps({'map':{v:v[len('trvdemo_'):] for v in m.values()},'prefix_from':sys.argv[2],'prefix_to':sys.argv[3]}))" "$map" "$pfx" "$3")" >/dev/null
  unset MIRRORPRESS_ROOT
}
clone "$DEMO/locale" mirrorpress_demo_local wp_ ""
clone "$DEMO/server/public_html" mirrorpress_demo_remote srv_ "http://127.0.0.1:$PORT"

# Differenze volute.
R=$DEMO/server/public_html; L=$DEMO/locale
echo "/* modifica in locale */" >> "$(ls -d "$L"/wp-content/themes/*/style.css | head -1)"
echo "nota" > "$L/appunti-locali.txt"
echo "-- dump" > "$L/vecchio-dump.sql"
mkdir -p "$R/wp-content/uploads/2026/11"; IMG="$(find "$L/wp-content/uploads" -type f \( -name '*.jpg' -o -name '*.webp' -o -name '*.png' \) | head -1)"
if [[ -n "$IMG" ]]; then cp "$IMG" "$R/wp-content/uploads/2026/11/foto-dal-cliente.${IMG##*.}"; else head -c 200000 /dev/urandom > "$R/wp-content/uploads/2026/11/foto-dal-cliente.jpg"; fi
echo "<?php // sospetto" > "$R/wp-content/uploads/2026/11/cache.php"
sql "UPDATE mirrorpress_demo_remote.srv_posts SET post_title=CONCAT(post_title,' — modificato sul server'), post_modified_gmt=UTC_TIMESTAMP() WHERE post_type='page' ORDER BY ID LIMIT 2"
sql "UPDATE mirrorpress_demo_remote.srv_options SET option_value='0' WHERE option_name='blog_public'"

nohup "$PHP" -d mysqli.default_socket=/Applications/MAMP/tmp/mysql/mysql.sock -S 127.0.0.1:$PORT -t "$R" >/dev/null 2>&1 &
cat > "$DEMO/home/Library/Application Support/Mirrorpress/sites.json" <<JSON
[{"id":"6B1F2E0A-0000-4000-8000-00000000DE70","name":"Villa Patrizia (demo)","localPath":"$L","localURL":"","remoteURL":"http://127.0.0.1:$PORT",
"connection":"sftp","host":"127.0.0.1","port":22,"username":"demo","remotePath":"/public_html","allowInvalidCertificates":false,"httpAuthUser":"",
"localDBOverride":{"name":"","user":"","host":"","prefix":""},"remoteDBOverride":{"name":"","user":"","host":"","prefix":""},
"excludes":$(/usr/bin/python3 -c 'import json;print(json.dumps([".DS_Store",".git","node_modules","_da_eliminare","*.log","wp-content/cache"]))'),"compareContent":true,"notes":""}]
JSON
echo "Pronto. Apri l'app con:"
echo "  CFFIXED_USER_HOME=$DEMO/home .build/Mirrorpress.app/Contents/MacOS/Mirrorpress --bridge-dir $R --analyze"
