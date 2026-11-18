import SwiftUI

struct DatabaseView: View {
    @ObservedObject var session: SiteSession
    @State private var checked: Set<String> = []
    @State private var selected: TableDiff.ID?
    @State private var details: (local: [JSONValue], remote: [JSONValue])?
    @State private var loadingDetails = false
    @State private var confirm: Side?   // lato da sovrascrivere
    @State private var acceptLoss = false
    @State private var onlyDifferent = false

    private var visible: [TableDiff] {
        // Prima le diverse, poi le altre in ordine alfabetico.
        session.tables.filter { !onlyDifferent || $0.status != .same }
            .sorted { ($0.status == .same ? 1 : 0, $0.key) < ($1.status == .same ? 1 : 0, $1.key) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if session.analyzedAt == nil {
                Text("Nessuna analisi ancora.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.tables.isEmpty {
                Text("Nessun database confrontato (sito senza database o non raggiungibile: vedi Panoramica).")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    table.frame(minWidth: 640)
                    detailPanel.frame(minWidth: 240, idealWidth: 280, maxWidth: 420)
                }
            }
            actions
        }
        .onAppear { if checked.isEmpty { selectAllLocal() } }
        .onChange(of: session.analyzedAt) { _ in selectAllLocal() }
        .onChange(of: selected) { _ in loadDetails() }
        .sheet(item: Binding(get: { confirm.map { SideBox(side: $0) } }, set: { confirm = $0?.side })) { box in
            DBConfirmSheet(session: session, target: box.side, keys: Array(checked).sorted(), acceptLoss: $acceptLoss) {
                confirm = nil
            }
        }
    }

    private var table: some View {
        Table(visible, selection: $selected) {
            TableColumn("") { (t: TableDiff) in
                Toggle("", isOn: Binding(get: { checked.contains(t.key) }, set: { if $0 { checked.insert(t.key) } else { checked.remove(t.key) } }))
                    .labelsHidden()
            }
            .width(24)
            TableColumn("Tabella") { (t: TableDiff) in
                Text(t.key).font(Theme.font(.callout, .semibold)).help(t.key)
            }
            .width(min: 140, ideal: 180, max: 260)
            TableColumn("Stato") { (t: TableDiff) in
                HStack(spacing: 5) {
                    Circle().fill(Theme.color(t.status)).frame(width: 8, height: 8)
                    Text(t.status.label).font(Theme.font(.caption, .semibold))
                }
            }
            .width(90)
            TableColumn("Righe locale") { (t: TableDiff) in Text(t.local?.rows.map(String.init) ?? "—").font(Theme.font(.callout)) }
                .width(80)
            TableColumn("Righe server") { (t: TableDiff) in Text(t.remote?.rows.map(String.init) ?? "—").font(Theme.font(.callout)) }
                .width(80)
            TableColumn("Differenze") { (t: TableDiff) in
                HStack(spacing: 4) {
                    if t.rowsChanged > 0 { Badge(text: L("%d cambiate", t.rowsChanged), color: Theme.warn) }
                    if t.rowsOnlyLocal > 0 { Badge(text: L("+%d locale", t.rowsOnlyLocal), color: Theme.local) }
                    if t.rowsOnlyRemote > 0 { Badge(text: L("+%d server", t.rowsOnlyRemote), color: Theme.remote) }
                }
            }
            .width(min: 140, ideal: 220)
        }
    }

    private var detailPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let t = session.tables.first(where: { $0.id == selected }) {
                    Text(t.key).font(Theme.font(.title3, .heavy))
                    Text(verbatim: "\(t.local?.name ?? "—") ⇄ \(t.remote?.name ?? "—")").font(Theme.font(.caption)).foregroundStyle(.secondary)
                    if let l = t.local, let r = t.remote, l.collation != r.collation {
                        Label(L("Collation diverse: %@ / %@", l.collation, r.collation), systemImage: "textformat").font(Theme.font(.caption))
                    }
                    if t.status == .same {
                        Label("Contenuto identico (a parte indirizzi, percorsi e cache).", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.ok)
                    } else if t.status == .changed && t.local?.rowHashes == nil {
                        Text("Tabella troppo grande per il confronto riga per riga: il contenuto è diverso.").foregroundStyle(.secondary)
                    }
                    if loadingDetails { ProgressView().controlSize(.small) }
                    if let details {
                        rowsBlock(L("Righe diverse o mancanti — locale"), details.local, Theme.local)
                        rowsBlock(L("Righe diverse o mancanti — server"), details.remote, Theme.remote)
                    }
                } else {
                    Text("Seleziona una tabella per vedere quali righe cambiano.").foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.card)
    }

    private func rowsBlock(_ title: String, _ rows: [JSONValue], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.font(.caption, .bold)).foregroundStyle(color)
            if rows.isEmpty { Text("—").foregroundStyle(.tertiary) }
            ForEach(Array(rows.prefix(80).enumerated()), id: \.offset) { _, row in
                Text(row.object.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.string ?? "NULL")" }.joined(separator: " · "))
                    .font(Theme.font(.caption)).lineLimit(3).textSelection(.enabled)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.06)))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Text("\(checked.count) tabelle selezionate").font(Theme.font(.callout)).foregroundStyle(.secondary)
            Menu("Seleziona") {
                Button("Tutte quelle in locale") { selectAllLocal() }
                Button("Solo le diverse") { checked = Set(session.tables.filter { $0.status == .changed || $0.status == .onlyLocal }.map(\.key)) }
                Button("Solo i contenuti (post, pagine, termini)") {
                    checked = Set(session.tables.map(\.key).filter { ["posts", "postmeta", "terms", "termmeta", "term_taxonomy", "term_relationships"].contains($0) })
                }
                Button("Nessuna") { checked = [] }
            }
            .menuStyle(.borderlessButton).fixedSize()
            Toggle("Solo diverse", isOn: $onlyDifferent).toggleStyle(.checkbox)
            Spacer()
            Button { acceptLoss = false; confirm = .local } label: { Label("Scarica in locale", systemImage: "arrow.down.to.line") }
                .buttonStyle(ActionButtonStyle(color: Theme.local))
                .disabled(checked.isEmpty || session.busy != nil || session.remoteInfo == nil)
            Button { acceptLoss = false; confirm = .remote } label: { Label("Invia al server", systemImage: "arrow.up.to.line") }
                .buttonStyle(ActionButtonStyle(color: Theme.remote))
                .disabled(checked.isEmpty || session.busy != nil || session.remoteInfo == nil)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }

    private func selectAllLocal() {
        checked = Set(session.tables.filter { $0.local != nil }.map(\.key))
    }

    private func loadDetails() {
        details = nil
        guard let t = session.tables.first(where: { $0.id == selected }), t.status == .changed,
              t.rowsChanged + t.rowsOnlyLocal + t.rowsOnlyRemote > 0 else { return }
        loadingDetails = true
        Task {
            let d = await session.rowDetails(t)
            if selected == t.id { details = d }
            loadingDetails = false
        }
    }
}

private struct SideBox: Identifiable { let side: Side; var id: String { side.rawValue } }

/// Conferma del mirrorpress del database: cosa succede, cosa si perde, quali indirizzi cambiano.
struct DBConfirmSheet: View {
    @ObservedObject var session: SiteSession
    let target: Side
    let keys: [String]
    @Binding var acceptLoss: Bool
    let close: () -> Void

    private var losses: [TableDiff] {
        let set = Set(keys)
        return session.tables.filter { set.contains($0.key) && (target == .remote ? $0.rowsOnlyRemote > 0 : $0.rowsOnlyLocal > 0) }
    }

    var body: some View {
        let toRemote = target == .remote
        let pairs = toRemote
            ? Compare.replacePairs(fromURL: session.localURL, toURL: session.remoteURL, fromRoot: session.localInfo?.root ?? "", toRoot: session.remoteInfo?.root ?? "")
            : Compare.replacePairs(fromURL: session.remoteURL, toURL: session.localURL, fromRoot: session.remoteInfo?.root ?? "", toRoot: session.localInfo?.root ?? "")
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: toRemote ? "arrow.up.to.line" : "arrow.down.to.line")
                    .font(Theme.font(size: 20, .bold)).foregroundStyle(toRemote ? Theme.remote : Theme.local)
                Text(toRemote ? L("Inviare %d tabelle al server?", keys.count) : L("Scaricare %d tabelle in locale?", keys.count))
                    .font(Theme.font(.title3, .heavy))
            }
            VStack(alignment: .leading, spacing: 6) {
                step("1", toRemote ? L("Backup completo del database del server (resta sul server, scaricabile da «Backup»).") : L("Backup completo del database locale."))
                step("2", L("Le tabelle vengono copiate con un nome temporaneo: il sito continua a funzionare."))
                step("3", L("Indirizzi e percorsi vengono sostituiti, anche nei dati serializzati."))
                step("4", L("Scambio istantaneo delle tabelle. Se qualcosa va storto prima, non cambia niente."))
            }
            if !pairs.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sostituzioni").font(Theme.font(.caption, .bold)).foregroundStyle(.secondary)
                    ForEach(pairs.prefix(4), id: \.self) { p in
                        Text(verbatim: "\(p[0])  →  \(p[1])").font(Theme.mono).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Text(L("Tabelle: %@", keys.joined(separator: ", "))).font(Theme.font(.caption)).foregroundStyle(.secondary).lineLimit(4)
            if !losses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(toRemote ? L("Il server ha dati che il locale non ha") : L("Il locale ha dati che il server non ha"), systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.font(.callout, .bold)).foregroundStyle(Theme.danger)
                    ForEach(losses) { t in
                        Text(L("• %@: %d righe andranno perse", t.key, toRemote ? t.rowsOnlyRemote : t.rowsOnlyLocal)).font(Theme.font(.callout))
                    }
                    Toggle(L("Ho capito, quei dati si perdono (restano nel backup)"), isOn: $acceptLoss).toggleStyle(.checkbox)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.danger.opacity(0.08)))
            }
            HStack {
                Spacer()
                Button("Annulla", action: close).keyboardShortcut(.cancelAction)
                Button(toRemote ? L("Invia il database") : L("Scarica il database")) {
                    close()
                    Task { if toRemote { await session.pushDatabase(keys: keys) } else { await session.pullDatabase(keys: keys) } }
                }
                .buttonStyle(ActionButtonStyle(color: toRemote ? Theme.remote : Theme.local))
                .disabled(!losses.isEmpty && !acceptLoss)
            }
        }
        .padding(24)
        .frame(width: 560)
        .font(Theme.font(.body))
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n).font(Theme.font(.caption, .heavy)).foregroundStyle(.white).frame(width: 18, height: 18)
                .background(Circle().fill(Theme.amber))
            Text(text).font(Theme.font(.callout))
        }
    }
}

// MARK: - Backup

struct BackupsView: View {
    @ObservedObject var session: SiteSession
    @State private var restoreID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Backup fatti da Mirrorpress sul server").font(Theme.font(.headline, .bold))
                Spacer()
                Button { Task { await session.loadBackups() } } label: { Label("Aggiorna elenco", systemImage: "arrow.clockwise") }
                    .buttonStyle(ChipButtonStyle(color: Theme.remote))
                    .disabled(session.busy != nil)
                Button { NSWorkspace.shared.open(AppPaths.workdir(for: session.site)) } label: { Label("Backup locali", systemImage: "folder") }
                    .buttonStyle(ChipButtonStyle(color: Theme.local))
            }
            .padding(.horizontal, 20).padding(.bottom, 10)
            List(session.backups.indices, id: \.self) { i in
                let b = session.backups[i]
                let id = b["id"].string ?? ""
                HStack(spacing: 12) {
                    Image(systemName: b["type"].string == "db" ? "cylinder.split.1x2.fill" : "doc.on.doc.fill")
                        .foregroundStyle(b["type"].string == "db" ? Theme.remote : Theme.local).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b["note"].string ?? id).font(Theme.font(.callout, .semibold))
                        Text("\(Format.date(TimeInterval(b["created"].int ?? 0))) · " + (b["type"].string == "db" ? Format.bytes(b["size"].int64) : L("%d file sostituiti", b["file_count"].int ?? 0)))
                            .font(Theme.font(.caption)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if b["type"].string == "db" {
                        Button("Scarica") { Task { await session.downloadBackup(id) } }.buttonStyle(ChipButtonStyle(color: Theme.local))
                    }
                    Button("Ripristina…") { restoreID = id }.buttonStyle(ChipButtonStyle(color: Theme.danger))
                }
                .padding(.vertical, 4)
                .disabled(session.busy != nil)
            }
            Text("I backup restano sul server, nella cartella di lavoro di Mirrorpress (fuori dalla cartella pubblica quando l'hosting lo permette). Mirrorpress non li cancella mai.")
                .font(Theme.font(.caption)).foregroundStyle(.secondary).padding(20)
        }
        .confirmationDialog("Ripristinare questo backup sul server?", isPresented: Binding(get: { restoreID != nil }, set: { if !$0 { restoreID = nil } })) {
            Button("Ripristina", role: .destructive) {
                if let id = restoreID { Task { await session.restoreBackup(id) } }
                restoreID = nil
            }
        } message: {
            Text("Database: le tabelle del backup sostituiscono quelle attuali. File: tornano le versioni salvate e i file creati da quell'invio finiscono in _da_eliminare.")
        }
    }
}
