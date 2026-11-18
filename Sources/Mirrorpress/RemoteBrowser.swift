import SwiftUI

/// Sfoglia le cartelle del server con le credenziali del profilo (anche non ancora salvate)
/// e restituisce quella scelta. Le cartelle con WordPress (wp-config.php) sono messe in evidenza.
struct RemoteFolderBrowser: View {
    let site: SiteProfile
    let password: String
    let onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var path = "/"
    @State private var entries: [RemoteEntry] = []
    @State private var loading = false
    @State private var error: MirrorpressError?
    @State private var wordpressDirs: Set<String> = []
    @State private var searching = false

    private var transport: Transport { Transport(site: site, password: password) }
    private var hereIsWordPress: Bool { entries.contains { $0.name == "wp-config.php" && !$0.isDir } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scegli la cartella del sito").font(Theme.font(.title3, .heavy))
                Spacer()
                if loading || searching { ProgressView().controlSize(.small) }
            }
            Text("Apri le cartelle del server fino a quella che contiene wp-config.php.")
                .font(Theme.font(.callout)).foregroundStyle(.secondary)

            breadcrumb

            if hereIsWordPress {
                Label("Qui c'è WordPress: è questa la cartella del sito.", systemImage: "checkmark.seal.fill")
                    .font(Theme.font(.callout, .semibold)).foregroundStyle(Theme.ok)
            }

            Group {
                if let error {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error.errorDescription ?? "", systemImage: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                            .font(Theme.font(.callout, .semibold))
                        if let hint = error.hint { Text(hint).font(Theme.font(.footnote)) }
                        if let d = error.detail {
                            ScrollView { Text(d).font(Theme.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(maxHeight: 160)
                        }
                        Button("Riprova") { Task { await load(path) } }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    List {
                        if path != "/" {
                            Button { Task { await load(parent(of: path)) } } label: {
                                Label("..", systemImage: "arrow.turn.left.up")
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(entries) { e in
                            row(e)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
            .frame(minHeight: 300)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))

            HStack {
                Button {
                    Task { await search() }
                } label: { Label("Cerca WordPress", systemImage: "magnifyingglass") }
                .disabled(searching)
                Spacer()
                Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Usa \(path)") { onChoose(path); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(error != nil)
            }
        }
        .font(Theme.font(.body))
        .padding(22)
        .frame(width: 560, height: 560)
        .task { await load(Transport.normalizeDir(site.remotePath.isEmpty ? "/" : site.remotePath), fallbackToRoot: true) }
    }

    private var breadcrumb: some View {
        let parts = path.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button { Task { await load("/") } } label: { Image(systemName: "externaldrive.connected.to.line.below") }
                    .buttonStyle(.plain)
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Button(part) { Task { await load("/" + parts[...i].joined(separator: "/") + "/") } }
                        .buttonStyle(.plain)
                        .font(Theme.font(.callout, i == parts.count - 1 ? .bold : .regular))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private func row(_ e: RemoteEntry) -> some View {
        let full = path + e.name + "/"
        if e.isDir {
            Button { Task { await load(full) } } label: {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.remote)
                    Text(e.name)
                    if wordpressDirs.contains(full) {
                        Text("WordPress").font(Theme.font(.caption, .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.ok))
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            HStack {
                Image(systemName: e.name == "wp-config.php" ? "gearshape.fill" : "doc").foregroundStyle(.secondary)
                Text(e.name).foregroundStyle(e.name == "wp-config.php" ? .primary : .secondary)
                Spacer()
                if let s = e.size { Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)).foregroundStyle(.tertiary) }
            }
            .font(Theme.font(.callout))
        }
    }

    private func parent(of p: String) -> String {
        var parts = p.split(separator: "/").map(String.init)
        _ = parts.popLast()
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/") + "/"
    }

    private func load(_ p: String, fallbackToRoot: Bool = false) async {
        loading = true
        defer { loading = false }
        do {
            entries = try await transport.entries(in: p)
            path = Transport.normalizeDir(p)
            error = nil
            await markWordPress()
        } catch let e {
            if fallbackToRoot && p != "/" { await load("/"); return }
            error = (e as? MirrorpressError) ?? describeNetworkError(e, url: nil)
        }
    }

    /// Controlla le sottocartelle visibili (al massimo 15) per segnare quelle con WordPress.
    private func markWordPress() async {
        let dirs = entries.filter { $0.isDir && !$0.name.hasPrefix(".") }.prefix(15).map { path + $0.name + "/" }
        let t = transport
        for d in dirs where !wordpressDirs.contains(d) {
            if let list = try? await t.entries(in: d), list.contains(where: { $0.name == "wp-config.php" }) {
                wordpressDirs.insert(d)
            }
        }
    }

    private func search() async {
        searching = true
        defer { searching = false }
        let found = await transport.findWordPress(from: "/", depth: 3, limit: 40)
        wordpressDirs.formUnion(found)
        if found.count == 1 { await load(found[0]) }
    }
}
