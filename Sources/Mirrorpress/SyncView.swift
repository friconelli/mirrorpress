import SwiftUI
import AppKit

/// La schermata principale: database in alto, poi i file divisi per area e ad albero,
/// ognuno con Pull ↓ (dal server al Mac) e Push ↑ (dal Mac al server).
struct SyncView: View {
    @ObservedObject var session: SiteSession
    var openDatabase: () -> Void = {}
    @State private var expanded: Set<String> = []
    @State private var openAreas: Set<SyncArea> = [.code]
    @State private var confirm: SyncRequest?
    @State private var dbTarget: Side?
    @State private var acceptLoss = false
    @State private var showRules = false
    @State private var showGuided = false

    private var byArea: [SyncArea: [FileDiff]] {
        Dictionary(grouping: session.files.filter { $0.status != .same }) { SyncRules.area($0.path) }
    }

    var body: some View {
        Group {
            if session.analyzedAt == nil {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        guidedBanner
                        legend
                        DatabaseSyncCard(session: session, openDatabase: openDatabase) { dbTarget = $0 }
                        HStack {
                            Text("File").font(Theme.font(.title3, .heavy))
                            Spacer()
                            Button { showRules = true } label: { Label("Cosa non sincronizzare con WordPress", systemImage: "questionmark.circle") }
                                .buttonStyle(.link).font(Theme.font(.callout))
                        }
                        .padding(.top, 6)
                        let groups = byArea
                        if groups.isEmpty {
                            Label("I file sul Mac e sul server sono uguali.", systemImage: "checkmark.seal.fill")
                                .font(Theme.font(.callout, .semibold)).foregroundStyle(Theme.ok)
                                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.ok.opacity(0.08)))
                        }
                        ForEach(SyncArea.allCases) { area in
                            if let files = groups[area], !files.isEmpty {
                                areaCard(area, files)
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .sheet(item: $confirm) { req in
            SyncConfirmSheet(session: session, request: req) { confirm = nil }
        }
        .sheet(item: Binding(get: { dbTarget.map { SyncSideBox(side: $0) } }, set: { dbTarget = $0?.side })) { box in
            let keys = session.tables.filter { box.side == .remote ? $0.local != nil : $0.remote != nil }.map(\.key).sorted()
            DBConfirmSheet(session: session, target: box.side, keys: keys, acceptLoss: $acceptLoss) { dbTarget = nil }
        }
        .sheet(isPresented: $showRules) { SyncRulesSheet() }
        .sheet(isPresented: $showGuided) { GuidedMirrorSheet(session: session) { showGuided = false } }
        .onChange(of: session.analyzedAt) { at in
            if at != nil, CommandLine.arguments.contains("--guided") { showGuided = true }
        }
    }

    // MARK: Parti

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.up.arrow.down.circle").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text("Prima confronta il Mac con il server").font(Theme.font(.title3, .bold))
            Text("L'analisi legge file e database dei due lati e non cambia niente.").foregroundStyle(.secondary)
            Button { Task { await session.analyze() } } label: { Label("Analizza", systemImage: "arrow.triangle.2.circlepath") }
                .buttonStyle(ActionButtonStyle(color: Theme.ink))
                .disabled(session.busy != nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var guidedBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "wand.and.stars").font(.system(size: 22)).foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mirroring guidato").font(Theme.font(.headline, .bold))
                Text("Scegli la direzione e cosa portare: prima il tema e i contenuti, poi, se vuoi, plugin, media e il resto. Backup automatici a ogni passo.")
                    .font(Theme.font(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { showGuided = true } label: { Label("Inizia", systemImage: "arrow.right") }
                .buttonStyle(ActionButtonStyle(color: Theme.ink))
                .disabled(session.busy != nil)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.amber.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.amber.opacity(0.35)))
    }

    private var legend: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                DirectionTag(side: .local)
                Text("dal server al Mac").foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                DirectionTag(side: .remote)
                Text("dal Mac al server").foregroundStyle(.secondary)
            }
            Spacer()
            Label("Prima di sovrascrivere si fa sempre un backup; sul server niente viene cancellato.", systemImage: "lifepreserver")
                .foregroundStyle(.secondary)
        }
        .font(Theme.font(.caption))
    }

    private func areaCard(_ area: SyncArea, _ files: [FileDiff]) -> some View {
        let push = files.filter(SyncTree.pushable).map(\.path)
        let pull = files.filter(SyncTree.pullable).map(\.path)
        let open = openAreas.contains(area)
        let base = SyncTree.commonFolder(files)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    withAnimation(Theme.spring) { if open { openAreas.remove(area) } else { openAreas.insert(area) } }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 90 : 0)).padding(.top, 5)
                        Image(systemName: area.symbol).font(.system(size: 17)).foregroundStyle(area == .protected ? Theme.warn : .primary)
                            .frame(width: 22).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(area.title).font(Theme.font(.headline, .bold))
                                Text(verbatim: L("%d file", files.count)).font(Theme.font(.caption)).foregroundStyle(.secondary)
                                if !base.isEmpty { Text(verbatim: base).font(Theme.mono).foregroundStyle(.tertiary).lineLimit(1) }
                            }
                            Text(area.rule).font(Theme.font(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                if area.bulkAllowed {
                    SyncButtons(pull: pull, push: push, suggested: area.suggested, large: true, disabled: session.busy != nil) { side, paths in
                        confirm = SyncRequest(side: side, paths: paths, scope: area.title)
                    }
                }
            }
            .padding(14)
            if open {
                Divider()
                let rows = SyncTree.rows(files, expanded: expanded)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { node in
                        SyncRow(session: session, node: node, area: area, expanded: expanded.contains(node.id)) {
                            if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
                        } request: { side, paths in
                            confirm = SyncRequest(side: side, paths: paths, scope: node.isFile ? node.name : node.id)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct SyncSideBox: Identifiable { let side: Side; var id: String { side.rawValue } }

/// Una richiesta di Push/Pull in attesa di conferma.
struct SyncRequest: Identifiable {
    let side: Side          // lato che riceve: .remote = Push, .local = Pull
    let paths: [String]
    let scope: String
    var id: String { side.rawValue + scope + String(paths.count) }
}

/// Etichetta «↓ Pull» / «↑ Push» con il colore del lato che riceve.
struct DirectionTag: View {
    let side: Side
    var body: some View {
        Text(side == .local ? "↓ Pull" : "↑ Push")
            .font(Theme.font(.caption, .bold))
            .foregroundStyle(side == .local ? Theme.local : Theme.remote)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill((side == .local ? Theme.local : Theme.remote).opacity(0.12)))
    }
}

/// I due pulsanti Pull/Push con il conteggio; quello consigliato è pieno.
struct SyncButtons: View {
    let pull: [String]
    let push: [String]
    var suggested: Side?
    var large = false
    var disabled = false
    let action: (Side, [String]) -> Void

    var body: some View {
        HStack(spacing: large ? 8 : 4) {
            button(.local, pull)
            button(.remote, push)
        }
    }

    @ViewBuilder
    private func button(_ side: Side, _ paths: [String]) -> some View {
        let color = side == .local ? Theme.local : Theme.remote
        let arrow = side == .local ? "arrow.down" : "arrow.up"
        let word = side == .local ? "Pull" : "Push"
        let help = side == .local ? L("Pull: copia dal server al Mac") : L("Push: copia dal Mac al server")
        if large {
            Button { action(side, paths) } label: {
                Label { Text(verbatim: "\(word) \(paths.count)") } icon: { Image(systemName: arrow) }
            }
            .buttonStyle(SyncButtonStyle(color: color, filled: suggested == side))
            .disabled(paths.isEmpty || disabled)
            .help(help)
        } else {
            Button { action(side, paths) } label: {
                HStack(spacing: 2) {
                    Image(systemName: arrow).font(.system(size: 10, weight: .bold))
                    if paths.count > 1 { Text(verbatim: "\(paths.count)").font(Theme.font(size: 10.5, .bold)).monospacedDigit() }
                }
                .foregroundStyle(paths.isEmpty ? Color.secondary.opacity(0.35) : color)
                .frame(minWidth: 30, minHeight: 20)
                .background(RoundedRectangle(cornerRadius: 6).fill(paths.isEmpty ? Color.clear : color.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .disabled(paths.isEmpty || disabled)
            .help(help)
        }
    }
}

struct SyncButtonStyle: ButtonStyle {
    let color: Color
    let filled: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(.callout, .bold))
            .lineLimit(1).fixedSize()
            .foregroundStyle(!enabled ? Color.secondary : (filled ? Color.white : color))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(!enabled ? Color.gray.opacity(0.12) : (filled ? color : color.opacity(0.10))))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(enabled && !filled ? color.opacity(0.4) : .clear))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// Una riga dell'albero: cartella (apribile) o file, con stato e pulsanti.
struct SyncRow: View {
    @ObservedObject var session: SiteSession
    let node: SyncNode
    let area: SyncArea
    let expanded: Bool
    let toggle: () -> Void
    let request: (Side, [String]) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if node.isFile {
                    Color.clear.frame(width: 12)
                    Image(systemName: "doc").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
                    Image(systemName: expanded ? "folder.fill" : "folder").foregroundStyle(Theme.amber)
                }
                Text(node.name).font(Theme.font(.callout, node.isFile ? .regular : .semibold)).lineLimit(1).truncationMode(.middle)
            }
            .padding(.leading, CGFloat(node.depth) * 18)
            .contentShape(Rectangle())
            .onTapGesture { if !node.isFile { toggle() } }
            Spacer(minLength: 8)
            if let f = node.file {
                statusText(f)
            }
            if area == .protected, let f = node.file, let reason = SyncRules.protectedReason(f.path) {
                Image(systemName: "info.circle").foregroundStyle(Theme.warn).help(reason)
            }
            if area.bulkAllowed || node.isFile {
                SyncButtons(pull: node.pull, push: node.push, disabled: session.busy != nil) { side, paths in request(side, paths) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    private func statusText(_ f: FileDiff) -> some View {
        let text: String
        let color: Color
        switch f.status {
        case .onlyLocal: text = L("solo sul Mac"); color = Theme.local
        case .onlyRemote: text = L("solo sul server"); color = Theme.remote
        case .changed:
            switch f.newerSide {
            case .local?: text = L("diverso · più recente sul Mac")
            case .remote?: text = L("diverso · più recente sul server")
            case nil: text = L("diverso")
            }
            color = Theme.amber
        case .unknown: text = L("da verificare"); color = .secondary
        case .same: text = L("uguale"); color = Theme.ok
        }
        return Text(text).font(Theme.font(.caption)).foregroundStyle(color).lineLimit(1)
    }

    @ViewBuilder
    private var menu: some View {
        let path = node.id
        Button("Mostra nel Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([session.localRoot.appendingPathComponent(path)])
        }
        if node.isFile, let base = URL(string: session.remoteURL), !session.remoteURL.isEmpty {
            Button("Apri sul server") { NSWorkspace.shared.open(base.appendingPathComponent(path)) }
        }
        let inside = session.files.filter { node.isFile ? $0.path == path : $0.path.hasPrefix(path) }
        let onlyRemote = inside.filter { $0.status == .onlyRemote }.map(\.path)
        let onlyLocal = inside.filter { $0.status == .onlyLocal }.map(\.path)
        if !onlyRemote.isEmpty || !onlyLocal.isEmpty { Divider() }
        if !onlyRemote.isEmpty {
            Button(L("Sposta i %d file solo sul server in _da_eliminare", onlyRemote.count)) { Task { await session.trashRemote(onlyRemote) } }
        }
        if !onlyLocal.isEmpty {
            Button(L("Sposta i %d file solo sul Mac nel Cestino", onlyLocal.count)) { Task { await session.trashLocal(onlyLocal) } }
        }
    }
}

/// Database: stato in una riga, cosa si rischia, Pull e Push.
struct DatabaseSyncCard: View {
    @ObservedObject var session: SiteSession
    let openDatabase: () -> Void
    let request: (Side) -> Void

    var body: some View {
        let diff = session.tables.filter { $0.status != .same }
        let serverOnlyRows = session.tables.reduce(0) { $0 + $1.rowsOnlyRemote }
        let localOnlyRows = session.tables.reduce(0) { $0 + $1.rowsOnlyLocal }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cylinder.split.1x2").font(.system(size: 20)).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Database").font(Theme.font(.headline, .bold))
                        if session.tables.isEmpty {
                            Text("non confrontato").font(Theme.font(.caption)).foregroundStyle(.secondary)
                        } else if diff.isEmpty {
                            Label("uguale", systemImage: "checkmark.circle.fill").font(Theme.font(.caption, .bold)).foregroundStyle(Theme.ok)
                        } else {
                            Text(verbatim: L("%d tabelle diverse su %d", diff.count, session.tables.count))
                                .font(Theme.font(.caption, .bold)).foregroundStyle(Theme.amber)
                        }
                    }
                    Text("Pagine, articoli, menu, impostazioni, utenti, ordini e moduli. Di solito il server è più aggiornato (i contenuti si inseriscono dal pannello): Pull ↓ per lavorare sul Mac con i dati veri; Push ↑ solo per un sito nuovo o se sul server non è cambiato niente.")
                        .font(Theme.font(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !session.tables.isEmpty {
                    HStack(spacing: 8) {
                        Button { request(.local) } label: { Label("Pull", systemImage: "arrow.down") }
                            .buttonStyle(SyncButtonStyle(color: Theme.local, filled: true))
                        Button { request(.remote) } label: { Label("Push", systemImage: "arrow.up") }
                            .buttonStyle(SyncButtonStyle(color: Theme.remote, filled: false))
                    }
                    .disabled(session.busy != nil || diff.isEmpty)
                }
            }
            if serverOnlyRows > 0 {
                Label(L("Sul server ci sono %d righe che sul Mac non esistono (contenuti, iscrizioni, ordini): un Push ↑ le cancellerebbe.", serverOnlyRows),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.font(.caption, .semibold)).foregroundStyle(Theme.warn)
            }
            if localOnlyRows > 0 {
                Label(L("Sul Mac ci sono %d righe che sul server non esistono: un Pull ↓ le cancellerebbe dal Mac.", localOnlyRows),
                      systemImage: "info.circle")
                    .font(Theme.font(.caption)).foregroundStyle(.secondary)
            }
            if !session.tables.isEmpty {
                Button("Scegli le tabelle una per una…", action: openDatabase).buttonStyle(.link).font(Theme.font(.caption))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Conferma in parole semplici: cosa viene copiato, cosa si sostituisce, cosa resta com'è.
struct SyncConfirmSheet: View {
    @ObservedObject var session: SiteSession
    let request: SyncRequest
    let close: () -> Void

    var body: some View {
        let toServer = request.side == .remote
        let set = Set(request.paths)
        let files = session.files.filter { set.contains($0.path) }
        let replaced = files.filter { toServer ? $0.remote != nil : $0.local != nil }
        let added = files.count - replaced.count
        let newerOnTarget = files.filter { $0.newerSide == request.side }
        let protectedFiles = files.filter { SyncRules.protectedReason($0.path) != nil }
        let color = toServer ? Theme.remote : Theme.local
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: toServer ? "arrow.up.circle.fill" : "arrow.down.circle.fill").font(.system(size: 26)).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(toServer ? L("Push di %d file sul server", files.count) : L("Pull di %d file sul Mac", files.count))
                        .font(Theme.font(.title3, .heavy))
                    Text(verbatim: request.scope).font(Theme.mono).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                bullet("plus.circle", L("%d nuovi", added))
                bullet("arrow.triangle.2.circlepath", toServer
                       ? L("%d sostituiti sul server (le versioni vecchie vanno in un backup ripristinabile)", replaced.count)
                       : L("%d sostituiti sul Mac (le versioni vecchie vanno in un backup nella cartella dell'app)", replaced.count))
                bullet("trash.slash", toServer ? L("Niente viene cancellato dal server.") : L("Niente viene cancellato dal Mac."))
            }
            if !newerOnTarget.isEmpty {
                warning(toServer
                        ? L("%d file sono più recenti sul server: forse qualcuno li ha modificati lì. Se fai Push perdi quelle modifiche.", newerOnTarget.count)
                        : L("%d file sono più recenti sul Mac: se fai Pull perdi le modifiche locali.", newerOnTarget.count))
            }
            if !protectedFiles.isEmpty {
                warning(L("Contiene file da non sincronizzare: %@", protectedFiles.map(\.path).prefix(4).joined(separator: ", ")))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files.prefix(200)) { f in
                        Text(verbatim: f.path).font(Theme.mono).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    if files.count > 200 { Text(verbatim: "… +\(files.count - 200)").font(Theme.mono).foregroundStyle(.tertiary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            HStack {
                Spacer()
                Button("Annulla", action: close).keyboardShortcut(.cancelAction)
                Button {
                    close()
                    Task {
                        if toServer { await session.pushFiles(request.paths) } else { await session.pullFiles(request.paths) }
                    }
                } label: { Label(toServer ? "Push ↑" : "Pull ↓", systemImage: toServer ? "arrow.up" : "arrow.down") }
                .buttonStyle(SyncButtonStyle(color: color, filled: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .font(Theme.font(.body))
        .padding(22)
        .frame(width: 560)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(Theme.font(.callout))
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(Theme.font(.callout, .semibold)).foregroundStyle(Theme.warn)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// La guida: cosa di WordPress non si sincronizza e perché.
struct SyncRulesSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let never: [(String, String)] = [
        ("wp-config.php", "wp-config.php"), (".htaccess", ".htaccess"), (".user.ini · php.ini", ".user.ini"),
        ("robots.txt", "robots.txt"), ("wp-content/advanced-cache.php · object-cache.php", "wp-content/advanced-cache.php"),
        ("wp-content/db.php", "wp-content/db.php"), ("wp-content/mu-plugins/ dell'hosting", "wp-content/mu-plugins/wpengine-common.php"),
        (".maintenance", ".maintenance"), ("*.sql · *.zip · *.wpress", "backup.sql"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cosa non sincronizzare con WordPress").font(Theme.font(.title3, .heavy))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(L("Mai, in nessuna direzione")) {
                        ForEach(never, id: \.0) { item in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: item.0).font(Theme.mono).bold()
                                Text(SyncRules.protectedReason(item.1) ?? "").font(Theme.font(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    section(L("Non serve: si rigenerano da soli")) {
                        Text("wp-content/cache, uploads/elementor/css, uploads/wc-logs, wflogs, litespeed, upgrade, file .log e le altre cache dei plugin. Mirrorpress li mostra a parte e non li include mai nei Push/Pull di gruppo.")
                            .font(Theme.font(.caption)).foregroundStyle(.secondary)
                    }
                    section(L("Di solito in una sola direzione")) {
                        ForEach([SyncArea.code, .media, .core], id: \.self) { a in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.title).font(Theme.font(.callout, .bold))
                                Text(a.rule).font(Theme.font(.caption)).foregroundStyle(.secondary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Database").font(Theme.font(.callout, .bold))
                            Text("Il server di solito ha i contenuti più recenti: Pull ↓. Push ↑ sovrascrive tutto quello inserito dal pannello (pagine, iscrizioni, ordini). Gli indirizzi (localhost ↔ dominio) vengono sostituiti in automatico.")
                                .font(Theme.font(.caption)).foregroundStyle(.secondary)
                        }
                    }
                    section(L("Esclusi già dall'analisi")) {
                        Text(".git, node_modules, .DS_Store, cartelle di backup dei plugin (updraft, ai1wm-backups…), _da_eliminare. Si cambiano nel profilo del sito, sezione Avanzate.")
                            .font(Theme.font(.caption)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Chiudi") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 600, height: 620)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.font(.headline, .bold))
            content()
        }
    }
}
