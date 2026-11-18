import SwiftUI

/// Mirroring guidato: direzione → cosa portare (per importanza) → riepilogo ed esecuzione.
/// Tema e dati del database vengono prima; plugin, media, utenti e tabelle dei plugin sono facoltativi.
enum GuidedItem: String, CaseIterable, Identifiable {
    case theme, content, settings, plugins, uploads, users, comments, pluginTables
    var id: String { rawValue }

    enum Importance: Int { case essential, recommended, optional }

    var importance: Importance {
        switch self {
        case .theme, .content: return .essential
        case .settings: return .recommended
        default: return .optional
        }
    }

    var isDatabase: Bool { [.content, .settings, .users, .comments, .pluginTables].contains(self) }

    var title: String {
        switch self {
        case .theme: return L("Tema attivo")
        case .content: return L("Contenuti")
        case .settings: return L("Impostazioni del sito")
        case .plugins: return L("File dei plugin")
        case .uploads: return L("Media (uploads)")
        case .users: return L("Utenti")
        case .comments: return L("Commenti")
        case .pluginTables: return L("Tabelle dei plugin")
        }
    }

    var detail: String {
        switch self {
        case .theme: return L("I file del tema (e del tema genitore): template, stili, script.")
        case .content: return L("Pagine, articoli, tipi di contenuto, campi personalizzati, categorie e tag, menu, voci della libreria media.")
        case .settings: return L("Tabella options: personalizzazioni del tema, widget, posizioni dei menu, plugin attivi, impostazioni dei plugin. Indirizzi sostituiti in automatico.")
        case .plugins: return L("Non serve che siano identici: conta che ci siano gli stessi plugin con versioni compatibili. Aggiornali dal pannello se preferisci.")
        case .uploads: return L("Immagini e documenti. Servono se i contenuti che porti usano media nuovi.")
        case .users: return L("Account e ruoli. Di solito restano diversi tra Mac e server (password, email di prova).")
        case .comments: return L("Commenti e relativi dati.")
        case .pluginTables: return L("Tabelle create dai plugin (moduli, ordini, log, cache): spesso contengono dati veri da non sovrascrivere.")
        }
    }

    /// Tabelle del gruppo (chiavi senza prefisso); pluginTables = tutte le altre.
    static let dbGroups: [GuidedItem: Set<String>] = [
        .content: ["posts", "postmeta", "terms", "termmeta", "term_taxonomy", "term_relationships", "links"],
        .settings: ["options"],
        .users: ["users", "usermeta"],
        .comments: ["comments", "commentmeta"],
    ]

    static func group(ofTable key: String) -> GuidedItem {
        for (g, keys) in dbGroups where keys.contains(key) { return g }
        return .pluginTables
    }
}

/// Cosa comporta ogni voce nella direzione scelta: file o tabelle da portare, righe che si perderebbero.
@MainActor
struct GuidedPlan {
    let session: SiteSession
    let target: Side          // lato che riceve (.remote = Push)

    private var source: SiteInfo? { target == .remote ? session.localInfo : session.remoteInfo }

    var themeFolders: [String] {
        guard let info = source, let slug = info.stylesheet, !slug.isEmpty else { return [] }
        var out = ["wp-content/themes/\(slug)/"]
        if let parent = info.themes.first(where: { $0.slug == slug })?.parent, !parent.isEmpty { out.append("wp-content/themes/\(parent)/") }
        return out
    }

    func files(_ item: GuidedItem) -> [String] {
        let candidates = session.files.filter { target == .remote ? SyncTree.pushable($0) : SyncTree.pullable($0) }
            .filter { let a = SyncRules.area($0.path); return a != .protected && a != .generated }
        switch item {
        case .theme:
            let folders = themeFolders
            return candidates.filter { f in folders.contains { f.path.hasPrefix($0) } }.map(\.path)
        case .plugins:
            return candidates.filter { $0.path.hasPrefix("wp-content/plugins/") || $0.path.hasPrefix("wp-content/mu-plugins/") }.map(\.path)
        case .uploads:
            return candidates.filter { $0.path.hasPrefix("wp-content/uploads/") }.map(\.path)
        default:
            return []
        }
    }

    func tables(_ item: GuidedItem) -> [TableDiff] {
        session.tables.filter { GuidedItem.group(ofTable: $0.key) == item && (target == .remote ? $0.local != nil : $0.remote != nil) }
    }

    func differingTables(_ item: GuidedItem) -> [TableDiff] { tables(item).filter { $0.status != .same } }

    /// Righe che esistono solo sul lato che verrà sovrascritto.
    func rowsLost(_ item: GuidedItem) -> Int {
        differingTables(item).reduce(0) { $0 + (target == .remote ? $1.rowsOnlyRemote : $1.rowsOnlyLocal) }
    }

    func isEmpty(_ item: GuidedItem) -> Bool {
        item.isDatabase ? differingTables(item).isEmpty : files(item).isEmpty
    }

    func summary(_ item: GuidedItem) -> String {
        if item.isDatabase {
            let d = differingTables(item)
            if d.isEmpty { return L("già uguale") }
            return d.count == 1 ? L("1 tabella diversa (%@)", d[0].key) : L("%d tabelle diverse", d.count)
        }
        if item == .theme && themeFolders.isEmpty { return L("tema attivo non trovato") }
        let n = files(item).count
        return n == 0 ? L("già uguale") : L("%d file", n)
    }

    /// Plugin con versioni diverse o presenti da un solo lato (dalle intestazioni dei plugin).
    var pluginMismatches: [String] {
        guard let l = session.localInfo, let r = session.remoteInfo else { return [] }
        let lp = Dictionary(l.plugins.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        let rp = Dictionary(r.plugins.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        for slug in Set(lp.keys).union(rp.keys).sorted() {
            switch (lp[slug], rp[slug]) {
            case let (a?, b?) where a.version != b.version: out.append("\(a.name.isEmpty ? slug : a.name) \(a.version) ↔ \(b.version)")
            case let (a?, nil): out.append(L("%@: solo sul Mac", a.name.isEmpty ? slug : a.name))
            case let (nil, b?): out.append(L("%@: solo sul server", b.name.isEmpty ? slug : b.name))
            default: break
            }
        }
        return out
    }
}

struct GuidedMirrorSheet: View {
    @ObservedObject var session: SiteSession
    let close: () -> Void

    enum Step { case direction, choose, review, running, done }
    @State private var step: Step = .direction
    @State private var target: Side = .remote
    @State private var selected: Set<GuidedItem> = []
    @State private var acceptLoss = false
    @State private var progress: [GuidedItem: StepState] = [:]
    @State private var runItems: [GuidedItem] = []   // fissati alla partenza: i passi finiti non spariscono
    enum StepState { case waiting, running, done, failed(String), skipped }

    private var plan: GuidedPlan { GuidedPlan(session: session, target: target) }
    private var toServer: Bool { target == .remote }
    private var color: Color { toServer ? Theme.remote : Theme.local }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch step {
                    case .direction: directionStep
                    case .choose: chooseStep
                    case .review: reviewStep
                    case .running, .done: runStep
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .font(Theme.font(.body))
        .frame(width: 720, height: 660)
        .onAppear {
            // Solo per prove e schermate: `--guided push|pull [review]` apre direttamente un passo.
            let a = CommandLine.arguments
            if let i = a.firstIndex(of: "--guided"), i + 1 < a.count {
                target = a[i + 1] == "pull" ? .local : .remote
                selected = defaults(for: target)
                step = a.contains("review") ? .review : .choose
                if a.contains("run") { acceptLoss = true; run() }
            }
        }
    }

    // MARK: Intestazione e piede

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars").font(.system(size: 20)).foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mirroring guidato").font(Theme.font(.title3, .heavy))
                Text(session.site.name).font(Theme.font(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Array([L("Direzione"), L("Cosa portare"), L("Riepilogo"), L("Esecuzione")].enumerated()), id: \.offset) { i, name in
                    let current = stepIndex == i
                    Text(verbatim: "\(i + 1). \(name)")
                        .font(Theme.font(.caption, current ? .bold : .regular))
                        .foregroundStyle(current ? Color.primary : (i < stepIndex ? Theme.ok : Color.secondary))
                }
            }
        }
        .padding(18)
    }

    private var stepIndex: Int {
        switch step { case .direction: return 0; case .choose: return 1; case .review: return 2; case .running, .done: return 3 }
    }

    private var footer: some View {
        HStack {
            if step == .choose || step == .review {
                Button("Indietro") { step = step == .review ? .choose : .direction }
            }
            Spacer()
            switch step {
            case .direction:
                Button("Annulla", action: close).keyboardShortcut(.cancelAction)
            case .choose:
                Button("Annulla", action: close).keyboardShortcut(.cancelAction)
                Button("Continua") { acceptLoss = false; step = .review }
                    .buttonStyle(SyncButtonStyle(color: color, filled: true))
                    .disabled(selected.isEmpty)
                    .keyboardShortcut(.defaultAction)
            case .review:
                Button("Annulla", action: close).keyboardShortcut(.cancelAction)
                Button { run() } label: { Label(toServer ? L("Esegui il Push") : L("Esegui il Pull"), systemImage: toServer ? "arrow.up" : "arrow.down") }
                    .buttonStyle(SyncButtonStyle(color: color, filled: true))
                    .disabled(totalLoss > 0 && !acceptLoss || session.busy != nil)
                    .keyboardShortcut(.defaultAction)
            case .running:
                ProgressView().controlSize(.small)
                Text(session.busy ?? "").font(Theme.font(.caption)).foregroundStyle(.secondary).lineLimit(1)
            case .done:
                Button("Chiudi", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: 1. Direzione

    private var directionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Da che parte vuoi copiare?").font(Theme.font(.headline, .bold))
            directionCard(.remote, title: L("Pubblica sul server"), subtitle: L("Push ↑ · porta online il lavoro fatto sul Mac: di solito il tema, a volte nuove pagine o impostazioni."))
            directionCard(.local, title: L("Aggiorna il Mac"), subtitle: L("Pull ↓ · porta sul Mac i contenuti veri del sito online, per lavorare con dati aggiornati."))
            Text("Nella pagina successiva scegli cosa portare: tema e contenuti sono già selezionati, il resto è facoltativo.")
                .font(Theme.font(.caption)).foregroundStyle(.secondary)
        }
    }

    private func directionCard(_ side: Side, title: String, subtitle: String) -> some View {
        let c = side == .remote ? Theme.remote : Theme.local
        return Button {
            target = side
            selected = defaults(for: side)
            step = .choose
        } label: {
            HStack(spacing: 14) {
                Image(systemName: side == .remote ? "arrow.up.circle.fill" : "arrow.down.circle.fill").font(.system(size: 30)).foregroundStyle(c)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.font(.headline, .bold))
                    Text(subtitle).font(Theme.font(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c.opacity(0.3)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Preselezione: le voci essenziali e consigliate che hanno qualcosa da portare; per il Pull anche i media.
    private func defaults(for side: Side) -> Set<GuidedItem> {
        let p = GuidedPlan(session: session, target: side)
        var s = Set(GuidedItem.allCases.filter { $0.importance != .optional && !p.isEmpty($0) })
        if side == .local, !p.isEmpty(.uploads) { s.insert(.uploads) }
        return s
    }

    // MARK: 2. Cosa portare

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            section(L("Essenziale"), items: GuidedItem.allCases.filter { $0.importance == .essential })
            section(L("Consigliato"), items: GuidedItem.allCases.filter { $0.importance == .recommended })
            section(L("Facoltativo"), items: GuidedItem.allCases.filter { $0.importance == .optional })
        }
    }

    private func section(_ title: String, items: [GuidedItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(Theme.font(.caption, .bold)).foregroundStyle(.secondary)
            ForEach(items) { item in itemRow(item) }
        }
    }

    private func itemRow(_ item: GuidedItem) -> some View {
        let empty = plan.isEmpty(item)
        let on = Binding(get: { selected.contains(item) }, set: { if $0 { selected.insert(item) } else { selected.remove(item) } })
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: on).labelsHidden().disabled(empty).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(item.title).font(Theme.font(.callout, .bold))
                        Text(plan.summary(item)).font(Theme.font(.caption, .semibold)).foregroundStyle(empty ? Theme.ok : Theme.amber)
                    }
                    Text(item.detail).font(Theme.font(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(warnings(for: item), id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle.fill").font(Theme.font(.caption, .semibold)).foregroundStyle(Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected.contains(item) ? color.opacity(0.06) : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .opacity(empty ? 0.6 : 1)
    }

    private func warnings(for item: GuidedItem) -> [String] {
        var w: [String] = []
        if item.isDatabase {
            let lost = plan.rowsLost(item)
            if lost > 0 {
                w.append(toServer ? L("Sul server ci sono %d righe che sul Mac non esistono: verrebbero cancellate.", lost)
                                  : L("Sul Mac ci sono %d righe che sul server non esistono: verrebbero cancellate.", lost))
            }
        }
        if item == .content && selected.contains(.content) && !selected.contains(.uploads) {
            let missing = plan.files(.uploads).count
            if missing > 0 {
                w.append(toServer ? L("%d media sono solo sul Mac: se i contenuti li usano, sul server le immagini mancheranno.", missing)
                                  : L("%d media sono solo sul server: se i contenuti li usano, sul Mac le immagini mancheranno.", missing))
            }
        }
        if item == .plugins {
            let mm = plan.pluginMismatches
            if !mm.isEmpty { w.append(L("Plugin diversi: %@", mm.prefix(5).joined(separator: " · ") + (mm.count > 5 ? " …" : ""))) }
        }
        if item == .theme && plan.themeFolders.isEmpty { w.append(L("Non trovo il tema attivo: fai prima l'analisi.")) }
        return w
    }

    // MARK: 3. Riepilogo

    private var ordered: [GuidedItem] {
        // Prima i file (tema, plugin, media), poi il database: così il sito trova il codice prima dei dati.
        [.theme, .plugins, .uploads, .content, .settings, .users, .comments, .pluginTables].filter { selected.contains($0) && !plan.isEmpty($0) }
    }

    private var totalLoss: Int { ordered.filter(\.isDatabase).reduce(0) { $0 + plan.rowsLost($1) } }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(toServer ? L("Ecco cosa verrà portato sul server") : L("Ecco cosa verrà portato sul Mac")).font(Theme.font(.headline, .bold))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(ordered.enumerated()), id: \.element) { i, item in
                    HStack(spacing: 10) {
                        Text(verbatim: "\(i + 1)").font(Theme.font(.caption, .bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(Circle().fill(color))
                        Text(item.title).font(Theme.font(.callout, .semibold))
                        Text(plan.summary(item)).font(Theme.font(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Label(toServer ? L("Prima di ogni passo: backup dei file e del database del server.") : L("Prima di ogni passo: backup dei file e del database del Mac."),
                      systemImage: "lifepreserver")
                Label(L("Indirizzi e percorsi nel database vengono sostituiti in automatico."), systemImage: "link")
                Label(L("Niente viene cancellato: i file presenti solo dall'altra parte restano dove sono."), systemImage: "trash.slash")
                Label(L("Restano fuori sempre: wp-config.php, .htaccess, cache e gli altri file da non sincronizzare."), systemImage: "lock")
            }
            .font(Theme.font(.caption)).foregroundStyle(.secondary)
            if totalLoss > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Label(toServer ? L("Sul server si perderanno %d righe del database che sul Mac non esistono (contenuti, iscrizioni, ordini inseriti online).", totalLoss)
                                   : L("Sul Mac si perderanno %d righe del database che sul server non esistono.", totalLoss),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.font(.callout, .semibold)).foregroundStyle(Theme.warn)
                    Toggle("Ho capito, procedi lo stesso", isOn: $acceptLoss).font(Theme.font(.callout))
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warn.opacity(0.1)))
            }
        }
    }

    // MARK: 4. Esecuzione

    private var runStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(runItems) { item in
                HStack(spacing: 10) {
                    switch progress[item] ?? .waiting {
                    case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                    case .running: ProgressView().controlSize(.small)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                    case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                    case .skipped: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
                    }
                    Text(item.title).font(Theme.font(.callout, .semibold))
                    if case .failed(let msg) = progress[item] ?? .waiting {
                        Text(msg).font(Theme.font(.caption)).foregroundStyle(Theme.danger).lineLimit(2)
                    }
                }
            }
            if step == .done {
                let failed = runItems.contains { if case .failed = progress[$0] ?? .waiting { return true }; return false }
                Label(failed ? L("Mirroring interrotto: i dettagli sono nel Log. I passi già fatti restano, con i loro backup.")
                             : L("Mirroring completato. L'analisi è stata aggiornata."),
                      systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(Theme.font(.callout, .semibold)).foregroundStyle(failed ? Theme.warn : Theme.ok)
                    .padding(.top, 8)
            }
        }
    }

    private func run() {
        let items = ordered
        let p = plan
        // File e tabelle calcolati ora, prima che i passi cambino lo stato dell'analisi.
        let fileSets = Dictionary(uniqueKeysWithValues: items.filter { !$0.isDatabase }.map { ($0, p.files($0)) })
        let dbKeys = items.filter(\.isDatabase).flatMap { p.tables($0).map(\.key) }
        let dbItems = items.filter(\.isDatabase)
        progress = Dictionary(uniqueKeysWithValues: items.map { ($0, StepState.waiting) })
        runItems = items
        step = .running
        Task {
            var failed = false
            for item in items where !item.isDatabase {
                if failed { progress[item] = .skipped; continue }
                progress[item] = .running
                session.lastError = nil
                if toServer { await session.pushFiles(fileSets[item] ?? []) } else { await session.pullFiles(fileSets[item] ?? []) }
                if let e = session.lastError { progress[item] = .failed(e); failed = true } else { progress[item] = .done }
            }
            if !dbItems.isEmpty {
                if failed {
                    for i in dbItems { progress[i] = .skipped }
                } else {
                    for i in dbItems { progress[i] = .running }
                    session.lastError = nil
                    // Un solo passaggio per tutte le tabelle scelte: un backup, uno scambio atomico.
                    if toServer { await session.pushDatabase(keys: dbKeys) } else { await session.pullDatabase(keys: dbKeys) }
                    let e = session.lastError
                    for i in dbItems { progress[i] = e.map { .failed($0) } ?? .done }
                    failed = e != nil
                }
            }
            if !failed { await session.analyze() }
            step = .done
        }
    }
}
