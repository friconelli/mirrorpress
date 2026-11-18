import SwiftUI
import AppKit

/// Scheda Controlli → Codice: lancia il controllo e mostra le criticità divise per lato e per gravità.
struct CodeCheckSection: View {
    @ObservedObject var session: SiteSession
    @State private var side: Side? = nil          // nil = tutti
    @State private var showWarnings = true

    private var shown: [CodeFinding] {
        session.codeFindings.filter { (side == nil || $0.side == side) && (showWarnings || $0.severity == .error) }
    }

    var body: some View {
        let errors = session.codeFindings.filter { $0.severity == .error }
        let warnings = session.codeFindings.filter { $0.severity == .warning }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 18)).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Codice").font(Theme.font(.headline, .bold))
                        if session.codeCheckedAt != nil {
                            if errors.isEmpty && warnings.isEmpty {
                                Label("nessuna criticità", systemImage: "checkmark.circle.fill").font(Theme.font(.caption, .bold)).foregroundStyle(Theme.ok)
                            } else {
                                if !errors.isEmpty { Badge(text: L("%d gravi", errors.count), color: Theme.danger) }
                                if !warnings.isEmpty { Badge(text: L("%d avvisi", warnings.count), color: Theme.warn) }
                            }
                        }
                    }
                    Text("Cerca malware e backdoor, file di WordPress e dei plugin diversi dagli originali ufficiali, PHP nella cartella dei media, funzioni che non esistono più nel PHP del server, errori di sintassi del tema con la versione di PHP del server, residui di debug e indirizzi del Mac scritti nel codice. Sul Mac e sul server.")
                        .font(Theme.font(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let at = session.codeCheckedAt {
                        Text("Ultimo controllo alle \(at.formatted(date: .omitted, time: .shortened))").font(Theme.font(.caption)).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                Button { Task { await session.checkCode() } } label: {
                    Label(session.codeCheckedAt == nil ? L("Controlla il codice") : L("Ricontrolla"), systemImage: "checkmark.shield")
                }
                .buttonStyle(ActionButtonStyle(color: Theme.ink))
                .disabled(session.busy != nil)
            }
            if session.codeCheckedAt != nil && !session.codeFindings.isEmpty {
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { side == nil }, set: { if $0 { side = nil } })) { Text("Tutti") }
                        .toggleStyle(FilterChipStyle(color: Theme.ink))
                    Toggle(isOn: Binding(get: { side == .local }, set: { side = $0 ? .local : nil })) { Text("Sul Mac") }
                        .toggleStyle(FilterChipStyle(color: Theme.local))
                    Toggle(isOn: Binding(get: { side == .remote }, set: { side = $0 ? .remote : nil })) { Text("Sul server") }
                        .toggleStyle(FilterChipStyle(color: Theme.remote))
                    Spacer()
                    Toggle("Mostra gli avvisi", isOn: $showWarnings).toggleStyle(.switch).controlSize(.small).font(Theme.font(.caption))
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(shown.prefix(300)) { f in CodeFindingRow(session: session, finding: f) }
                    if shown.count > 300 {
                        Text(verbatim: "… +\(shown.count - 300)").font(Theme.font(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(errors.isEmpty ? Color.primary.opacity(0.08) : Theme.danger.opacity(0.4)))
    }
}

struct CodeFindingRow: View {
    @ObservedObject var session: SiteSession
    let finding: CodeFinding

    var body: some View {
        let info = finding.info
        let color = finding.severity == .error ? Theme.danger : Theme.warn
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill").foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(info.title).font(Theme.font(.callout, .semibold))
                    Badge(text: info.category, color: .secondary)
                    SideTag(side: finding.side)
                    if !finding.extra.isEmpty { Text(finding.extra).font(Theme.font(.caption)).foregroundStyle(.secondary) }
                }
                Text(verbatim: finding.line > 0 ? "\(finding.path):\(finding.line)" : finding.path)
                    .font(Theme.mono).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                if !finding.snippet.isEmpty {
                    Text(verbatim: finding.snippet).font(Theme.mono).foregroundStyle(.primary.opacity(0.75)).lineLimit(2)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
                }
                Text(info.explanation).font(Theme.font(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.06)))
        .contextMenu {
            if finding.side == .local {
                Button("Apri il file") { NSWorkspace.shared.open(session.localRoot.appendingPathComponent(finding.path)) }
                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.localRoot.appendingPathComponent(finding.path)]) }
            }
            Button("Copia il percorso") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(finding.path, forType: .string)
            }
        }
    }
}
