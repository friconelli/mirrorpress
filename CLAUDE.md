# Mirrorpress

Nome scelto da Federico il 18/11/2026 (prima *Travaso*; migrazione di Application Support e Portachiavi in `Storage.swift`). Repo pubblico github.com/friconelli/mirrorpress, aggiornamenti in-app dalle Releases.

App macOS SwiftUI (SwiftPM, nessuna dipendenza) per sincronizzare siti WordPress/PHP tra MAMP e qualsiasi hosting. Struttura come crocini/port-manager: `Sources/Mirrorpress`, `Scripts/build_app.sh`, `Resources/Info.plist`, updater su GitHub Releases. Leggi il README prima di tutto.

- **Il cuore è `Resources/Bridge/mirrorpress-bridge.php`**: stesso file in locale (CLI con PHP di MAMP, env `MIRRORPRESS_ROOT`/`MIRRORPRESS_WORKDIR`) e sul server (HTTPS, query `a`/`t`/`s` con HMAC di `ts\naction\nsha256(body)`). Deve restare compatibile con **PHP 7.0** (niente arrow function, `str_starts_with`, `match`, tipi): `build_app.sh` lo controlla con il PHP 7.4 di MAMP. Azioni binarie (`upload`, `db_import`) hanno i parametri nella prima riga `J {json}`.
- Dopo ogni modifica al ponte: `Scripts/test_bridge.sh` e `MIRRORPRESS_E2E=1 swift test`. L'E2E clona un sito MAMP (cloni APFS + DB `mirrorpress_e2e_*`) e usa `php -S` come server: non tocca né il sito né i dati dell'app (`MIRRORPRESS_SUPPORT_DIR`).
- Regole di sicurezza da non rompere: sul server niente `unlink` di file del sito (si sposta in `_da_eliminare`); backup prima di ogni scrittura; DB solo via tabelle di staging `trv…_` + `RENAME` atomico, con guardia sul prefisso in `db_import`; percorsi validati (`trv_abs`, e in Swift `DownloadReader`).
- In `options` l'unica chiave con il prefisso tabelle è `{prefix}user_roles` (`wp_page_for_privacy_policy` & co. sono nomi fissi: bug già trovato e corretto).
- Il confronto DB normalizza URL/percorsi/chiavi col prefisso (`Compare.normalizePairs`) e salta transient/cron/rewrite_rules/session_tokens: se aggiungi eccezioni, aggiornale nel ponte (`trv_db_tables`).
- **Lingue** IT/EN come Crocini: chiavi = testi italiani. Nuova stringa → aggiungerla in `Scripts/strings.py` e lanciarlo (genera entrambi i .strings e fallisce se manca qualcosa). Le interpolazioni SwiftUI con espressioni complesse vanno spezzate in variabili d'appoggio.
- Font Bricolage Grotesque via `Theme.font(...)`; colori: locale `Theme.local` (blu), server `Theme.remote` (vino), accento `Theme.amber`.
- Nel Bash tool `cp`/`rm` sono alias verbosi/interattivi: usare `/bin/cp -f`.
- Bundle id `com.federicomancinelli.mirrorpress`. Repository pubblico `friconelli/mirrorpress`: release con `Scripts/release.sh`.
- **Errori**: usare `fail(messaggio, hint:, detail:)` (`MirrorpressError`), il Log mostra suggerimento e dettagli tecnici. Mai mettere password nei dettagli: `Transport.ftpDialogue` oscura `PASS`.
- **Sfoglia…** (`RemoteBrowser.swift`) usa `Transport.entries(in:)`/`parseListing` (formati Unix e IIS); `findWordPress` cerca `wp-config.php` fino a 2-3 livelli.
- **FTP con TLS: sempre `--tls-max 1.2`** (Aruba tronca a 0 byte gli upload TLS 1.3 sopra ~8 KB, verificato il 18/11/2026 su 16noni). Porta 990 = FTPS implicito (`ftps://`).
- Il ponte remoto verifica SEMPRE il certificato HTTPS (`allowInvalidCertificates` vale solo per l'FTP) e rifiuta indirizzi http (salvo localhost).
- Le schermate con `--snapshot` escono con `NSApp.terminate` così il delegate toglie i ponti; se si interrompe l'app a forza, il ponte resta sul server fino alla scadenza.
- **UI**: la scheda principale è `SyncView` (Push/Pull per area e ad albero, regole in `SyncRules.swift`, testate in CoreTests); il mirroring guidato è `GuidedMirror.swift` (gruppi di tabelle in `GuidedItem.dbGroups`). La vecchia tabella dei file (FilesView) non c'è più.
- Chiusura: `applicationShouldTerminate` stacca i ponti e manda `selfdestruct` fuori dal main thread, aspettando al massimo 6 s (mai `terminateLater`: si bloccava). Prove: `--guided push|pull [review]` apre il mirroring guidato; con un foglio aperto l'app non esce da sola dopo `--snapshot` (chiuderla con kill).
- **Controllo del codice**: regole PHP in `trv_code_rules()`/`trv_code_scan` del ponte (stesse ai due lati), testi e checksum ufficiali in `CodeCheck.swift`, vista in `CodeCheckView.swift`. Nuova regola → aggiungerla in entrambi (id) e provarla su un file costruito apposta; prova da riga di comando: `--analyze --check-code --tab overview`.
- **Copia (clone)**: `SiteCloner` (wp-config/.htaccess, puro e testato) + `CloneSite.swift` (passi: prepara → analizza → file → database → verifica) + `CloneView.swift`. Il foglio dell'avanzamento sta in `SyncView` (`cloneJob`), non nel riquadro: il riquadro sparisce appena il lato esiste e si portava via il foglio. Database MAMP via `mysql` con `MYSQL_PWD` (mai la password sulla riga di comando).
