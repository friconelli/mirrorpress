# Mirrorpress

App macOS (SwiftUI) per sincronizzare siti WordPress (e PHP in genere) tra la copia in locale (MAMP) e quella sull'hosting: confronta file e database, mostra differenze, problemi e incongruenze e aggiorna il lato che scegli, con backup automatici. Funziona con qualsiasi hosting con PHP: SFTP, FTPS, FTP o caricando a mano un file.

Non serve per i progetti che si pubblicano con Vercel, Netlify o una pipeline (GitHub Actions, GitLab CI, build Next/Astro/Nuxt): Mirrorpress li riconosce e non li accetta.

## Come funziona

1. **Il ponte.** All'analisi Mirrorpress carica sul server (via SFTP/FTPS/FTP, o a mano) un solo file PHP con nome casuale, `mirrorpress-xxxxxxxx.php`. Ogni richiesta è firmata con HMAC-SHA256 e un token segreto generato al momento; senza firma il file risponde 404. Scade da solo dopo 4 ore (e si cancella), e viene tolto alla chiusura dell'app o con «Togli il ponte».
2. **Stesso codice ai due lati.** Lo stesso `Resources/Bridge/mirrorpress-bridge.php` gira anche in locale, da riga di comando con il PHP di MAMP. Locale e server parlano la stessa lingua: elenco file, MD5, informazioni, dump, import, cerca/sostituisci, scambio tabelle.
3. **Niente WordPress caricato.** Il ponte legge `wp-config.php` e parla direttamente con MySQL: funziona anche con un sito rotto, e anche con PHP 7.0.

## Cosa confronta

- **File**: solo in locale, solo sul server, diversi (dimensione, poi MD5 con cache sul server), uguali. File sensibili (`wp-config.php`, `.htaccess`, `.user.ini`, `robots.txt`…) e dump/archivi non vengono mai selezionati in automatico. Esclusioni modificabili per sito.
- **Database**: tabella per tabella e riga per riga (fino a 50.000 righe per tabella), normalizzando indirizzi, percorsi e prefissi diversi; transient, cron e sessioni sono ignorati. Per le tabelle diverse mostra quali righe cambiano (titoli dei post, opzioni…).
- **Problemi e incongruenze**: versioni di WordPress e PHP, plugin che richiedono un PHP più nuovo del server, plugin/temi solo da un lato o con versioni diverse, contenuti, commenti, utenti e righe (ordini, moduli) più recenti sul server che andrebbero persi, media caricati in produzione, PHP sospetti in `uploads`, maiuscole/minuscole (Mac vs Linux), collation MySQL 8 su MariaDB, prefissi diversi, `WP_DEBUG` a video, «scoraggia i motori di ricerca», siteurl http/https, spazio disco, cache, multisito, manutenzione.

## Come scrive (in sicurezza)

- **File verso il server**: caricati a pezzi (anche oltre `post_max_size`) in una cartella di staging, poi messi in linea tutti insieme solo se l'invio è completo. Gli originali vanno in un backup ripristinabile.
- **File verso il locale**: ogni file è scritto con nome temporaneo e rinominato; le versioni locali sostituite finiscono in un backup nella cartella dell'app.
- **Eliminare**: sul server niente viene cancellato, i file vanno in `_da_eliminare`; in locale nel Cestino.
- **Database**: backup completo del lato di destinazione → import in tabelle temporanee (`trvxxxxxx_…`, il sito continua a funzionare) → cerca/sostituisci di indirizzi e percorsi anche nei dati serializzati (ricalcola le lunghezze) e nel JSON → `RENAME TABLE` atomico. Prefisso tabelle diverso gestito (anche `user_roles` e i permessi in `usermeta`). Collation convertite per MariaDB/MySQL 5.7. Se qualcosa va storto prima dello scambio non cambia niente. Prima di inviare, se il server ha righe che il locale non ha, bisogna confermarlo esplicitamente.
- **Backup sul server**: nella cartella di lavoro `.mirrorpress-<hash>` *fuori dalla webroot* quando l'hosting lo permette (altrimenti dentro, protetta da `.htaccess`). Mirrorpress non li cancella mai. Si possono scaricare (DB) e ripristinare dalla scheda «Backup».

Password FTP/SFTP, HTTP e database nel Portachiavi. Le credenziali FTP passano a `curl` in un `.netrc` temporaneo, quella SFTP via `SSH_ASKPASS`: mai sulla riga di comando. Usa solo strumenti di macOS (`curl`, `sftp`) più il PHP di MAMP (o Homebrew; percorso configurabile nelle Impostazioni).

## Log e diagnosi

La scheda **Log** registra ogni passo. Ogni errore dice cosa è successo, cosa fare (💡) e ha i **dettagli tecnici** espandibili: operazione, connessione (utente@server:porta, cartella), dialogo FTP col server (password oscurata), indirizzo del ponte, codice HTTP, intestazioni dell'hosting (WAF, cache), inizio della risposta. «Copia log» copia tutto come testo. Prima di installare il ponte l'app controlla che la cartella remota contenga `wp-config.php` e, se non la trova, cerca WordPress nelle cartelle vicine e le suggerisce; dopo il caricamento verifica la dimensione del file (antivirus degli hosting che lo svuotano o lo tolgono). Il ponte, in caso di errore fatale PHP, risponde con un JSON che lo spiega invece di una pagina vuota.

## Hosting provati

- **Aruba** (16noniassisi.it, FTPS implicito porta 990, WAF attivo): funziona. Con TLS 1.3 il server FTP di Aruba salva **vuoti** i file oltre ~8 KB senza dare errore: Mirrorpress usa TLS 1.2 (`--tls-max 1.2`), sempre cifrato. Se un ponte arriva incompleto l'app fa due prove (testo e PHP minimo) e dice nel Log se è il trasferimento o l'antivirus, poi riprova con lftp.

## Ponte a mano

Se l'FTP non va (o per scelta, connessione «Manuale») l'app prepara il ponte in `~/Library/Application Support/Mirrorpress/ponte-manuale` (permessi 600) e spiega dove caricarlo. Sicurezza: risponde solo a richieste firmate HMAC-SHA256 con un token casuale di 256 bit generato per quel file, rifiuta firme più vecchie di 15 minuti, senza firma risponde 404; l'app lo usa solo in HTTPS con certificato valido; alla scadenza (4 ore) si disattiva e si cancella; la copia locale col token viene cancellata appena il ponte risponde.

## Importare i profili

`Mirrorpress --import-profiles` legge da stdin un array JSON di profili con `password` facoltativa (stessa cartella locale = aggiorna il profilo) e salva le password nel Portachiavi: niente password sulla riga di comando o su file. Usato per importare i siti da FileZilla (`~/.config/filezilla/sitemanager.xml`, Protocol 0 = FTP con TLS se disponibile, 1 = SFTP, 3 = FTPS implicito 990).

## Icone dei siti

Prese dalla favicon del sito (prima `apple-touch-icon`, poi `<link rel=icon>`, poi `/favicon.ico`), in cache 7 giorni in `Application Support/Mirrorpress/favicon`; senza favicon l'iniziale colorata.

## Profilo di un sito

- **Locale**: cartella (es. `/Applications/MAMP/htdocs/sito`), indirizzo locale (vuoto = `siteurl` del DB).
- **Server**: indirizzo pubblico (`https://www.sito.it`), connessione, host, utente, password, **cartella remota** = quella con `wp-config.php` vista dall'FTP (pulsante **Sfoglia…**: si naviga nel server e le cartelle con WordPress sono segnate) (es. `/www.sito.it` su Aruba, `/public_html` su cPanel). L'indirizzo deve servire proprio quella cartella: il ponte è raggiunto su `<indirizzo>/mirrorpress-xxxx.php`.
- **Avanzate**: password HTTP per staging protetti, database a mano per siti non WordPress, esclusioni, confronto MD5 on/off.

## Aggiornamenti

L'app controlla le GitHub Releases di `friconelli/mirrorpress` all'avvio e ogni 6 ore (disattivabile nelle Impostazioni); la versione e «Verifica aggiornamenti» sono in fondo alla barra laterale e nel menu dell'app. Un clic scarica, sostituisce e riavvia.

## Nome

Fino alla 0.1 si chiamava *Travaso*: al primo avvio Mirrorpress sposta profili e backup da `~/Library/Application Support/Travaso` e legge le password salvate col vecchio nome nel Portachiavi. I file `travaso-*.php` e `.travaso-*` eventualmente rimasti sui server sono esclusi dal confronto.

## Requisiti, build, test

macOS 13+, Xcode per compilare. App universale (Apple Silicon + Intel), firmata ad-hoc.

```bash
./Scripts/build_app.sh --install         # compila, controlla il ponte con PHP 7.4, installa in /Applications
swift test                              # test unitari
MIRRORPRESS_E2E=1 swift test                # + prova completa con MAMP (copie temporanee, `php -S` come server finto)
Scripts/test_bridge.sh [sito]           # prova del solo ponte PHP (DB di prova mirrorpress_test, poi cancellato)
python3 Scripts/strings.py              # rigenera it/en .strings e segnala testi non tradotti
Scripts/demo_env.sh [sito]              # ambiente demo per l'interfaccia; --clean per toglierlo
```

Schermate di prova: `Mirrorpress --snapshot out.png --delay 25 --stage 1280 820 [--tab files] [--analyze] [-AppleLanguages "(en)"]`; `--bridge-dir <cartella>` installa il ponte copiandolo in una cartella invece che via FTP (solo per prove e demo).

## Pubblicare una nuova versione

```bash
Scripts/release.sh 0.2.0 "Note di rilascio"   # albero git pulito: imposta la versione, compila, tagga, crea la release con Mirrorpress.zip
```

L'app controlla le GitHub Releases di `friconelli/mirrorpress` all'avvio (repository non ancora creato).

## Icona

Generata in AppKit: `swift Scripts/generate_icon.swift AppIcon.iconset && iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns`.

## Da fare

- Provare su hosting veri (Aruba FTPS, SiteGround/cPanel SFTP): finora testato con MAMP e `php -S`.
- Firewall degli hosting (mod_security) che bloccano le richieste: i pacchetti SQL viaggiano compressi proprio per questo, da verificare.
- Diff testuale dei file diversi, ripristino dei backup locali, multisito.
