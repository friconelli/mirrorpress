import SwiftUI
import AppKit

enum DetailTab: String, CaseIterable, Identifiable {
    case sync, overview, database, backups, log
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .sync: return "Sincronizza"
        case .overview: return "Controlli"
        case .database: return "Database"
        case .backups: return "Backup"
        case .log: return "Log"
        }
    }
    var symbol: String {
        switch self {
        case .sync: return "arrow.up.arrow.down"
        case .overview: return "stethoscope"
        case .database: return "cylinder.split.1x2"
        case .backups: return "clock.arrow.circlepath"
        case .log: return "list.bullet.rectangle"
        }
    }
}

struct SiteDetailView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: SiteSession
    @State private var tab: DetailTab = .sync

    var body: some View {
        VStack(spacing: 0) {
            header
            if let busy = session.busy { BusyBar(text: busy, progress: session.progress) { session.cancel() } }
            if let file = session.manualBridgeFile { ManualBridgeBanner(session: session, file: file) }
            if let err = session.lastError, session.busy == nil, session.manualBridgeFile == nil {
                let last = session.log.last { $0.kind == .error }
                ErrorBanner(text: err, hint: last?.hint, showLog: tab == .log ? nil : { tab = .log }) { session.lastError = nil }
            }
            TabStrip(tab: $tab, session: session)
                .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 4)
            Divider().opacity(0.5)

            Group {
                switch tab {
                case .sync: SyncView(session: session) { tab = .database }
                case .overview: OverviewView(session: session)
                case .database: DatabaseView(session: session)
                case .backups: BackupsView(session: session)
                case .log: LogView(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
        .font(Theme.font(.body))
        .onAppear {
            if CommandLine.arguments.contains("--analyze"), session.analyzedAt == nil, session.busy == nil {
                Task { await session.analyze() }
            }
            if let i = CommandLine.arguments.firstIndex(of: "--tab"), i + 1 < CommandLine.arguments.count,
               let t = DetailTab(rawValue: CommandLine.arguments[i + 1]) { tab = t }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            SiteIcon(site: session.site, size: 44)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(session.site.name).font(Theme.font(.title2, .heavy)).lineLimit(1)
                    if session.bridgeInstalled { BridgePill(session: session) }
                }
                HStack(spacing: 8) {
                    endpoint(.local, session.localURL.isEmpty ? session.site.localPath : session.localURL)
                    PourArrow()
                    endpoint(.remote, session.site.remoteURL)
                    if let at = session.analyzedAt {
                        Text("·").foregroundStyle(.tertiary)
                        Text("Analizzato alle \(at.formatted(date: .omitted, time: .shortened))")
                            .font(Theme.font(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 12)
            Button { model.editing = session.site } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(IconButtonStyle())
                .help("Modifica il profilo del sito")
            Button { Task { await session.testConnection() } } label: { Label("Prova connessione", systemImage: "network") }
                .buttonStyle(ChipButtonStyle(color: Theme.local))
                .disabled(session.busy != nil)
            Button { Task { await session.analyze() } } label: { Label("Analizza", systemImage: "arrow.triangle.2.circlepath") }
                .buttonStyle(ActionButtonStyle(color: Theme.ink))
                .keyboardShortcut("r")
                .disabled(session.busy != nil)
        }
        .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 8)
    }

    private func endpoint(_ side: Side, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: side == .local ? "laptopcomputer" : "server.rack")
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(Theme.font(.callout, .medium))
        .foregroundStyle(side == .local ? Theme.local : Theme.remote)
    }
}

/// Freccia animata tra i due lati.
struct PourArrow: View {
    @State private var phase = false
    var body: some View {
        Image(systemName: "arrow.left.arrow.right")
            .font(Theme.font(size: 12, .bold))
            .foregroundStyle(Theme.amber)
            .scaleEffect(phase ? 1.1 : 0.9)
            .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever()) { phase = true } }
    }
}

struct BusyBar: View {
    let text: String
    let progress: Double?
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            if let progress {
                ProgressView(value: progress).frame(width: 160).tint(Theme.amber)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).font(Theme.font(.callout, .medium)).lineLimit(1)
            Spacer()
            Button("Annulla", action: cancel).buttonStyle(.link)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Theme.amber.opacity(0.12))
    }
}

struct ErrorBanner: View {
    let text: String
    var hint: String? = nil
    var showLog: (() -> Void)? = nil
    let close: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(Theme.font(.callout, .semibold)).textSelection(.enabled)
                if let hint, !hint.isEmpty {
                    Text(hint).font(Theme.font(.footnote)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            if let showLog {
                Button("Dettagli nel log", action: showLog).buttonStyle(ChipButtonStyle(color: Theme.danger))
            }
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Theme.danger.opacity(0.09))
    }
}

/// Schede del sito con contatori: quante differenze ci sono, senza doverle aprire.
struct TabStrip: View {
    @Binding var tab: DetailTab
    @ObservedObject var session: SiteSession
    @Namespace private var ns

    private func count(_ t: DetailTab) -> (Int, Color)? {
        guard session.analyzedAt != nil || t == .log else { return nil }
        switch t {
        case .overview:
            let n = session.issues.count
            let worst = session.issues.contains { $0.severity == .error } ? Theme.danger : Theme.warn
            return n > 0 ? (n, worst) : nil
        case .sync:
            let n = session.files.filter { $0.status != .same }.count + session.tables.filter { $0.status != .same }.count
            return n > 0 ? (n, Theme.amber) : nil
        case .database:
            let n = session.tables.filter { $0.status != .same }.count
            return n > 0 ? (n, Theme.amber) : nil
        case .backups: return nil
        case .log:
            let n = session.log.filter { $0.kind == .error }.count
            return n > 0 ? (n, Theme.danger) : nil
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DetailTab.allCases) { t in
                let selected = t == tab
                Button {
                    withAnimation(Theme.spring) { tab = t }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.symbol).font(.system(size: 12, weight: .semibold))
                        Text(t.label).font(Theme.font(.callout, selected ? .bold : .medium))
                        if let (n, c) = count(t) {
                            Text(verbatim: n > 999 ? "999+" : "\(n)")
                                .font(Theme.font(size: 10.5, .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Capsule().fill(c))
                        }
                    }
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card)
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// «Ponte attivo» con il menu per toglierlo.
struct BridgePill: View {
    @ObservedObject var session: SiteSession
    @State private var confirm = false
    var body: some View {
        Button { confirm = true } label: {
            HStack(spacing: 5) {
                Circle().fill(Theme.ok).frame(width: 7, height: 7)
                Text("Ponte attivo").font(Theme.font(.caption, .bold))
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(Theme.ok)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Theme.ok.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Il ponte PHP è attivo sul server: si cancella da solo dopo 4 ore o alla chiusura dell'app. Clic per toglierlo subito.")
        .confirmationDialog("Togliere il ponte dal server?", isPresented: $confirm) {
            Button("Togli il ponte") { Task { await session.removeBridge() } }
        }
    }
}

struct ManualBridgeBanner: View {
    @ObservedObject var session: SiteSession
    let file: URL
    private var folder: String { session.site.remotePath.isEmpty ? "/" : session.site.remotePath }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill").foregroundStyle(Theme.amber).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text("Carica il ponte a mano").font(Theme.font(.callout, .bold))
                Text("1. Con il file manager dell'hosting apri la cartella del sito, quella con wp-config.php (\(folder)).")
                Text("2. Carica \(file.lastPathComponent) così com'è, senza rinominarlo né modificarlo.")
                Text("3. Torna qui e premi «Ho caricato il ponte».")
                if let exp = session.manualBridgeExpires {
                    Label("Sicuro: risponde solo alle richieste firmate da questa app (HMAC con un token unico), solo in HTTPS, e alle \(exp.formatted(date: .omitted, time: .shortened)) si disattiva e si cancella da solo.", systemImage: "lock.shield")
                        .foregroundStyle(Theme.ok)
                }
            }
            .font(Theme.font(.caption))
            .foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button("Mostra il file") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    .buttonStyle(ChipButtonStyle(color: Theme.amber))
                Button("Ho caricato il ponte") { Task { await session.confirmManualBridge(); await session.analyze() } }
                    .buttonStyle(ActionButtonStyle(color: Theme.remote))
                Button("Annulla") { session.discardManualFile() }.buttonStyle(.link).font(Theme.font(.caption))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Theme.amber.opacity(0.12))
    }
}

// MARK: - Panoramica

struct OverviewView: View {
    @ObservedObject var session: SiteSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if session.analyzedAt == nil {
                    Card {
                        Text("Premi «Analizza» per confrontare locale e server").font(Theme.font(.headline, .bold))
                        Text("Mirrorpress installa per qualche minuto un piccolo file PHP firmato sul server (il «ponte»), legge file e database dei due lati e ti mostra cosa è diverso e cosa potrebbe andare storto. Niente viene modificato finché non lo chiedi tu.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    summary
                    sideBySide
                    issuesList
                }
            }
            .padding(20)
        }
    }

    private var summary: some View {
        let files = session.files
        let tables = session.tables
        return HStack(spacing: 12) {
            stat(L("File da inviare"), files.filter { $0.status == .onlyLocal || $0.status == .changed }.count, Theme.local)
            stat(L("Solo sul server"), files.filter { $0.status == .onlyRemote }.count, Theme.remote)
            stat(L("Tabelle diverse"), tables.filter { $0.status != .same }.count, Theme.warn)
            stat(L("Problemi"), session.issues.filter { $0.severity == .error }.count, Theme.danger)
            stat(L("Avvisi"), session.issues.filter { $0.severity == .warning }.count, Theme.warn)
        }
    }

    private func stat(_ label: String, _ n: Int, _ color: Color) -> some View {
        Card(padding: 12) {
            Text(verbatim: "\(n)").font(Theme.font(size: 26, .heavy)).foregroundStyle(n == 0 ? Color.secondary : color)
                .contentTransition(.numericText())
            Text(label).font(Theme.font(.caption, .semibold)).foregroundStyle(.secondary)
        }
    }

    private var sideBySide: some View {
        let l = session.localInfo, r = session.remoteInfo
        let rows: [(String, String, String)] = [
            (L("WordPress"), l?.wpVersion ?? "—", r?.wpVersion ?? "—"),
            ("PHP", l?.php ?? "—", r?.php ?? "—"),
            (L("Database"), l?.dbServer ?? (l?.dbError ?? "—"), r?.dbServer ?? (r?.dbError ?? "—")),
            (L("Prefisso"), l?.dbPrefix ?? "—", r?.dbPrefix ?? "—"),
            (L("Peso database"), l.map { Format.bytes($0.dbSize) } ?? "—", r.map { Format.bytes($0.dbSize) } ?? "—"),
            ("siteurl", l?.siteURL ?? "—", r?.siteURL ?? "—"),
            (L("Tema attivo"), l?.stylesheet ?? "—", r?.stylesheet ?? "—"),
            (L("Plugin (attivi)"), l.map { "\($0.plugins.count) (\($0.activePlugins.count))" } ?? "—", r.map { "\($0.plugins.count) (\($0.activePlugins.count))" } ?? "—"),
            (L("Cartella"), l?.root ?? "—", r?.root ?? "—"),
            (L("Web server"), "MAMP", r?.server ?? "—"),
            (L("Limiti"), "", r.map { "memory \($0.memoryLimit) · post \(Format.bytes($0.postMaxSize)) · " + L("spazio libero %@", Format.bytes($0.diskFree)) } ?? "—"),
        ]
        return Card {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    Text("")
                    SideTag(side: .local)
                    SideTag(side: .remote)
                }
                Divider().gridCellColumns(3)
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0).font(Theme.font(.callout, .semibold)).foregroundStyle(.secondary)
                        Text(row.1).font(Theme.font(.callout)).textSelection(.enabled).lineLimit(2)
                        let differs = row.1 != row.2 && !row.1.isEmpty && ![L("Cartella"), L("Web server"), "siteurl"].contains(row.0)
                        Text(row.2).font(Theme.font(.callout, differs ? .bold : .regular))
                            .foregroundStyle(differs ? Theme.warn : .primary)
                            .textSelection(.enabled).lineLimit(2)
                    }
                }
            }
        }
    }

    private var issuesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Problemi e incongruenze").font(Theme.font(.headline, .bold))
            if session.issues.isEmpty {
                Label("Nessun problema trovato.", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.ok)
            }
            ForEach(session.issues) { issue in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: Theme.symbol(issue.severity)).foregroundStyle(Theme.color(issue.severity)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(issue.title).font(Theme.font(.callout, .semibold))
                            Badge(text: issue.area, color: .secondary)
                        }
                        if !issue.detail.isEmpty {
                            Text(issue.detail).font(Theme.font(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Spacer()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.color(issue.severity).opacity(0.07)))
            }
        }
    }
}

// MARK: - Log

struct LogView: View {
    @ObservedObject var session: SiteSession
    @State private var onlyProblems = false

    private var lines: [LogLine] {
        onlyProblems ? session.log.filter { $0.kind == .error || $0.kind == .warning } : session.log
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("Solo errori e avvisi", isOn: $onlyProblems).toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button {
                    let text = session.log.map(\.plain).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Label("Copia log", systemImage: "doc.on.clipboard") }
                .disabled(session.log.isEmpty)
                Button { session.clearLog() } label: { Label("Svuota", systemImage: "trash") }
                    .disabled(session.log.isEmpty || session.busy != nil)
            }
            .font(Theme.font(.callout))
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if lines.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.alignleft").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("Ancora niente nel log.").font(Theme.font(.callout)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(lines) { line in
                                LogRow(line: line).id(line.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: session.log.count) { _ in
                        if let last = lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }
        }
    }
}

struct LogRow: View {
    let line: LogLine
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(line.date, style: .time).font(Theme.mono).foregroundStyle(.tertiary).frame(width: 46, alignment: .leading)
            Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 5) {
                Text(line.text)
                    .font(Theme.font(.callout, line.kind == .error ? .semibold : .regular))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = line.hint, !hint.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lightbulb").foregroundStyle(Theme.amber)
                        Text(hint).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Theme.font(.footnote))
                    .foregroundStyle(.primary.opacity(0.8))
                }
                if let detail = line.detail, !detail.isEmpty {
                    Button {
                        withAnimation(Theme.spring) { expanded.toggle() }
                    } label: {
                        Label(expanded ? "Nascondi dettagli tecnici" : "Mostra dettagli tecnici",
                              systemImage: expanded ? "chevron.down" : "chevron.right")
                            .font(Theme.font(.caption, .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    if expanded {
                        Text(detail)
                            .font(Theme.mono)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(background))
        .onAppear { if line.kind == .error && line.detail != nil && line.hint == nil { expanded = true } }
    }

    private var symbol: String {
        switch line.kind { case .info: return "circle.fill"; case .success: return "checkmark.circle.fill"; case .warning: return "exclamationmark.triangle.fill"; case .error: return "xmark.octagon.fill" }
    }
    private var color: Color {
        switch line.kind { case .info: return .secondary.opacity(0.6); case .success: return Theme.ok; case .warning: return Theme.warn; case .error: return Theme.danger }
    }
    private var background: Color {
        switch line.kind { case .error: return Theme.danger.opacity(0.08); case .warning: return Theme.warn.opacity(0.08); default: return .clear }
    }
}
