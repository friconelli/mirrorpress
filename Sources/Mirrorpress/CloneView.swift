import SwiftUI

/// Riquadro mostrato quando un lato non ha ancora il sito: propone di crearne la copia.
/// Una copia da eseguire (il foglio con l'avanzamento sta in SyncView, che resta anche quando il riquadro sparisce).
struct CloneJob: Identifiable {
    let target: Side
    let db: DBCredentials
    let id = UUID()
}

struct CloneCard: View {
    @ObservedObject var session: SiteSession
    let target: Side                       // lato su cui creare la copia
    let start: (CloneJob) -> Void
    private static var autoStarted = false
    @State private var dbName = ""
    @State private var dbUser = ""
    @State private var dbPassword = ""
    @State private var dbHost = "localhost"

    var body: some View {
        let toMac = target == .local
        let color = toMac ? Theme.local : Theme.remote
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: toMac ? "laptopcomputer.and.arrow.down" : "server.rack").font(.system(size: 26)).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(toMac ? L("Il sito non c'è ancora sul Mac") : L("La cartella del server è vuota")).font(Theme.font(.title3, .heavy))
                    Text(toMac
                         ? L("Mirrorpress può creare una copia completa del sito del server in %@: cartella, database in MAMP, file e contenuti, con indirizzi aggiornati.", session.site.localPath)
                         : L("Mirrorpress può creare in %@ una copia completa del sito del Mac: file, database e indirizzi aggiornati per %@.", session.site.remotePath.isEmpty ? "/" : session.site.remotePath, session.remoteURL))
                        .font(Theme.font(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Cosa viene personalizzato").font(Theme.font(.caption, .bold)).foregroundStyle(.secondary)
                Label(toMac ? L("wp-config.php: database MAMP (utente root), cache dell'hosting spenta, inclusioni dell'hosting commentate.")
                            : L("wp-config.php: database dell'hosting qui sotto, WP_DEBUG spento."), systemImage: "doc.badge.gearshape")
                Label(toMac ? L(".htaccess: solo le regole di WordPress con RewriteBase %@ (quelle dell'hosting restano sul server).", SiteCloner.base(of: session.localURLForClone))
                            : L(".htaccess: regole di WordPress con RewriteBase %@, le tue regole personalizzate restano.", SiteCloner.base(of: session.remoteURL)), systemImage: "arrow.triangle.branch")
                Label(L("Database: indirizzi e percorsi sostituiti anche nei dati serializzati."), systemImage: "link")
            }
            .font(Theme.font(.caption))
            if toMac {
                FieldRow("Database in MAMP") { TextField("", text: $dbName, prompt: Text("nome_sito")) }
                FieldRow("Indirizzo sul Mac") { Text(verbatim: session.localURLForClone).font(Theme.mono).foregroundStyle(.secondary) }
            } else {
                Text("I dati del database li trovi nel pannello dell'hosting (su Aruba: Database → MySQL). Il database deve esistere ed essere vuoto.")
                    .font(Theme.font(.caption)).foregroundStyle(.secondary)
                FieldRow("Nome database") { TextField("", text: $dbName, prompt: Text("Sql1234567_1")) }
                FieldRow("Utente") { TextField("", text: $dbUser) }
                FieldRow("Password") { SecureField("", text: $dbPassword) }
                FieldRow("Server database") { TextField("", text: $dbHost, prompt: Text("localhost  oppure  31.11.39.x")) }
            }
            HStack {
                Spacer()
                Button { start(job) } label: {
                    Label(toMac ? L("Crea la copia sul Mac") : L("Crea la copia sul server"), systemImage: toMac ? "arrow.down" : "arrow.up")
                }
                .buttonStyle(SyncButtonStyle(color: color, filled: true))
                .disabled(session.busy != nil || dbName.isEmpty || (!toMac && (dbUser.isEmpty || dbHost.isEmpty)))
            }
        }
        .font(Theme.font(.body))
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(color.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(color.opacity(0.35)))
        .onAppear {
            if dbName.isEmpty && toMac { dbName = SiteCloner.slug(session.localRoot.lastPathComponent) }
            // Solo per prove: `--clone <db> [utente password host]` avvia subito la copia.
            let a = CommandLine.arguments
            if !Self.autoStarted, let i = a.firstIndex(of: "--clone"), i + 1 < a.count {
                Self.autoStarted = true
                dbName = a[i + 1]
                if !toMac, i + 4 < a.count { dbUser = a[i + 2]; dbPassword = a[i + 3]; dbHost = a[i + 4] }
                start(job)
            }
        }
    }

    private var job: CloneJob {
        let toMac = target == .local
        return CloneJob(target: target, db: DBCredentials(name: dbName, user: toMac ? "root" : dbUser, password: toMac ? "root" : dbPassword,
                                                          host: toMac ? "localhost" : dbHost))
    }
}

struct CloneProgressSheet: View {
    @ObservedObject var session: SiteSession
    let target: Side
    let db: DBCredentials
    let close: () -> Void
    @State private var state: [SiteSession.CloneStep: Bool?] = [:]
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(target == .local ? L("Copia del sito sul Mac") : L("Copia del sito sul server")).font(Theme.font(.title3, .heavy))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SiteSession.CloneStep.allCases) { s in
                    HStack(spacing: 10) {
                        Group {
                            switch state[s] {
                            case .none: Image(systemName: "circle").foregroundStyle(.tertiary)
                            case .some(.none): ProgressView().controlSize(.small)
                            case .some(.some(true)): Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                            case .some(.some(false)): Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                            }
                        }
                        .frame(width: 18)
                        Text(s.title).font(Theme.font(.callout, .semibold))
                    }
                }
            }
            if let busy = session.busy {
                Text(busy).font(Theme.font(.caption)).foregroundStyle(.secondary).lineLimit(1)
                if let p = session.progress { ProgressView(value: p).tint(Theme.amber) }
            }
            if finished {
                let failed = state.values.contains { $0 == false }
                if failed {
                    Label(session.lastError ?? L("Copia interrotta."), systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.font(.callout, .semibold)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                    Text("I passi già fatti restano. Correggi il problema (dettagli nel Log) e riprova: i file già copiati non vengono ricopiati.")
                        .font(Theme.font(.caption)).foregroundStyle(.secondary)
                } else {
                    Label(target == .local ? L("Fatto: il sito è sul Mac. Aprilo in MAMP con l'indirizzo locale.") : L("Fatto: il sito è sul server."),
                          systemImage: "checkmark.seal.fill").font(Theme.font(.callout, .semibold)).foregroundStyle(Theme.ok)
                    if let u = URL(string: target == .local ? session.localURLForClone : session.remoteURL) {
                        Link(destination: u) { Label(L("Apri %@", u.absoluteString), systemImage: "safari") }
                    }
                }
            }
            HStack {
                Spacer()
                Button(finished ? L("Chiudi") : L("Annulla")) {
                    if finished { close() } else { session.cancel() }
                }
                .keyboardShortcut(finished ? .defaultAction : .cancelAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task {
            await session.runClone(target: target, prepare: {
                if target == .local { await session.prepareLocalClone(dbName: db.name) } else { await session.prepareRemoteClone(db: db) }
            }, progress: { step, ok in state[step] = .some(ok) })
            finished = true
        }
    }
}
