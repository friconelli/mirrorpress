import SwiftUI
import AppKit

struct FilesView: View {
    @ObservedObject var session: SiteSession
    @State private var filter: Set<FileStatus> = [.onlyLocal, .changed, .onlyRemote, .unknown]
    @State private var search = ""
    @State private var checked: Set<String> = []
    @State private var confirm: FileAction?
    @State private var sortOrder = [KeyPathComparator(\FileDiff.path)]
    @State private var tableSelection: Set<FileDiff.ID> = []

    enum FileAction: Identifiable {
        case push([String]), pull([String]), trashRemote([String]), trashLocal([String])
        var id: String { "\(self)" }
    }

    private var visible: [FileDiff] {
        let q = search.lowercased()
        return session.files.filter { filter.contains($0.status) && (q.isEmpty || $0.path.lowercased().contains(q)) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if session.analyzedAt == nil {
                Text("Nessuna analisi ancora.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
            actions
        }
        .onChange(of: session.analyzedAt) { _ in preselect() }
        .onAppear { if checked.isEmpty { preselect() } }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button(confirmButton, role: isDestructive ? .destructive : nil) { run() }
            Button("Annulla", role: .cancel) { confirm = nil }
        } message: {
            Text(confirmMessage)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ForEach([FileStatus.onlyLocal, .changed, .onlyRemote, .unknown, .same]) { s in
                let n = session.files.filter { $0.status == s }.count
                Toggle(isOn: Binding(get: { filter.contains(s) }, set: { if $0 { filter.insert(s) } else { filter.remove(s) } })) {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.color(s)).frame(width: 7, height: 7)
                        Text(verbatim: s.label)
                        Text(verbatim: "\(n)").font(Theme.font(.caption, .bold)).monospacedDigit().opacity(0.75)
                    }
                }
                .toggleStyle(FilterChipStyle(color: Theme.color(s)))
            }
            Spacer()
            TextField("Cerca percorso", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var table: some View {
        Table(visible, selection: $tableSelection, sortOrder: $sortOrder) {
            TableColumn("") { (f: FileDiff) in
                Toggle("", isOn: Binding(get: { checked.contains(f.path) }, set: { if $0 { checked.insert(f.path) } else { checked.remove(f.path) } }))
                    .labelsHidden()
            }
            .width(24)
            TableColumn("Stato") { (f: FileDiff) in
                HStack(spacing: 5) {
                    Circle().fill(Theme.color(f.status)).frame(width: 8, height: 8)
                    Text(f.status.label).font(Theme.font(.caption, .semibold))
                }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Percorso", value: \.path) { (f: FileDiff) in
                HStack(spacing: 4) {
                    if f.sensitive { Image(systemName: "lock.fill").foregroundStyle(Theme.warn).help("File sensibile: non viene mai selezionato in automatico") }
                    Text(f.folder.isEmpty ? "" : f.folder + "/").foregroundColor(.secondary) + Text(f.name).fontWeight(.semibold)
                }
                .font(Theme.font(.callout))
                .lineLimit(1).truncationMode(.head)
            }
            TableColumn("Locale") { (f: FileDiff) in sideCell(f.local, newer: f.newerSide == .local) }
                .width(min: 120, ideal: 150)
            TableColumn("Server") { (f: FileDiff) in sideCell(f.remote, newer: f.newerSide == .remote) }
                .width(min: 120, ideal: 150)
        }
        .contextMenu(forSelectionType: FileDiff.ID.self) { ids in
            Button("Seleziona") { checked.formUnion(ids) }
            Button("Deseleziona") { checked.subtract(ids) }
            if let first = ids.first {
                let folder = (first as NSString).deletingLastPathComponent
                let shown = folder.isEmpty ? "/" : folder
                Button("Seleziona tutta la cartella \(shown)") {
                    checked.formUnion(visible.filter { $0.folder == folder || $0.folder.hasPrefix(folder + "/") }.map(\.path))
                }
                Divider()
                Button("Mostra nel Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([session.localRoot.appendingPathComponent(first)])
                }
                if let base = URL(string: session.remoteURL), !session.remoteURL.isEmpty {
                    Button("Apri sul server") { NSWorkspace.shared.open(base.appendingPathComponent(first)) }
                }
            }
        }
    }

    private func sideCell(_ e: FileEntry?, newer: Bool) -> some View {
        Group {
            if let e {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Format.bytes(e.size)).font(Theme.font(.caption, .semibold))
                    Text(Format.date(TimeInterval(e.mtime)) + (newer ? " ●" : "")).font(Theme.font(size: 10))
                        .foregroundStyle(newer ? Theme.amber : .secondary)
                }
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    private var actions: some View {
        let sel = session.files.filter { checked.contains($0.path) }
        let push = sel.filter { $0.local != nil && $0.status != .same }.map(\.path)
        let pull = sel.filter { $0.remote != nil && $0.status != .same }.map(\.path)
        let onlyRemote = sel.filter { $0.status == .onlyRemote }.map(\.path)
        let onlyLocal = sel.filter { $0.status == .onlyLocal }.map(\.path)
        let sizeText = Format.bytes(sel.reduce(Int64(0)) { $0 + ($1.local?.size ?? 0) })
        return HStack(spacing: 10) {
            Text("\(checked.count) selezionati · \(sizeText)").font(Theme.font(.callout)).foregroundStyle(.secondary)
            Button("Seleziona i diversi") { preselect() }.buttonStyle(.link)
            Button("Nessuno") { checked = [] }.buttonStyle(.link)
            Spacer()
            Menu {
                Button("Sposta i \(onlyRemote.count) file solo sul server in _da_eliminare") { confirm = .trashRemote(onlyRemote) }
                    .disabled(onlyRemote.isEmpty)
                Button("Sposta i \(onlyLocal.count) file solo in locale nel Cestino") { confirm = .trashLocal(onlyLocal) }
                    .disabled(onlyLocal.isEmpty)
            } label: { Label("Elimina", systemImage: "trash") }
            .menuStyle(.borderlessButton).fixedSize()
            Button { confirm = .pull(pull) } label: { Label("Scarica in locale (\(pull.count))", systemImage: "arrow.down.to.line") }
                .buttonStyle(ActionButtonStyle(color: Theme.local))
                .disabled(pull.isEmpty || session.busy != nil)
            Button { confirm = .push(push) } label: { Label("Invia al server (\(push.count))", systemImage: "arrow.up.to.line") }
                .buttonStyle(ActionButtonStyle(color: Theme.remote))
                .disabled(push.isEmpty || session.busy != nil)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }

    /// Selezione predefinita: tutto ciò che va inviato, tranne i file sensibili.
    private func preselect() {
        checked = Set(session.files.filter { ($0.status == .onlyLocal || $0.status == .changed) && !$0.sensitive && !Compare.isJunk($0.path) }.map(\.path))
    }

    private var isDestructive: Bool {
        switch confirm { case .trashRemote, .trashLocal: return true; default: return false }
    }

    private var confirmTitle: String {
        switch confirm {
        case .push(let p): return L("Inviare %d file al server?", p.count)
        case .pull(let p): return L("Scaricare %d file in locale?", p.count)
        case .trashRemote(let p): return L("Spostare %d file del server in _da_eliminare?", p.count)
        case .trashLocal(let p): return L("Spostare %d file locali nel Cestino?", p.count)
        case nil: return ""
        }
    }

    private var confirmButton: String {
        switch confirm {
        case .push: return L("Invia")
        case .pull: return L("Scarica")
        default: return L("Sposta")
        }
    }

    private var confirmMessage: String {
        switch confirm {
        case .push(let p):
            let sens = p.filter(Compare.isSensitive)
            return L("I file vengono prima caricati in una cartella temporanea e messi in linea tutti insieme solo se l'invio è completo. Gli originali del server finiscono in un backup che puoi ripristinare.")
                + (sens.isEmpty ? "" : "\n\n" + L("Attenzione, file sensibili: %@", sens.joined(separator: ", ")))
        case .pull:
            return L("Le versioni locali sostituite vengono copiate in un backup nella cartella dell'app.")
        case .trashRemote:
            return L("Sul server niente viene cancellato: i file finiscono in _da_eliminare nella cartella di lavoro di Mirrorpress, da svuotare a mano.")
        case .trashLocal:
            return L("Si possono recuperare dal Cestino del Mac.")
        case nil: return ""
        }
    }

    private func run() {
        guard let action = confirm else { return }
        confirm = nil
        Task {
            switch action {
            case .push(let p): await session.pushFiles(p)
            case .pull(let p): await session.pullFiles(p)
            case .trashRemote(let p): await session.trashRemote(p)
            case .trashLocal(let p): await session.trashLocal(p)
            }
            checked.subtract(session.files.filter { $0.status == .same }.map(\.path))
        }
    }
}
