import SwiftUI
import AppKit

extension HealthReport.Level {
    var color: Color {
        switch self {
        case .ok: return Theme.ok
        case .notice: return Theme.local
        case .warning: return Theme.warn
        case .error: return Theme.danger
        }
    }
    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .notice: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "exclamationmark.octagon.fill"
        }
    }
}

/// Pallino nella barra laterale: il sito online ha un problema? (anche senza aprire il sito)
struct HealthDot: View {
    @EnvironmentObject var health: HealthMonitor
    let site: SiteProfile
    var body: some View {
        if let r = health.worst(site.id), r.level >= .notice {
            let side = r.side == .remote ? L("Server") : L("Locale")
            Image(systemName: r.level.symbol)
                .foregroundStyle(r.level.color)
                .font(.system(size: 12))
                .help(side + ": " + r.title)
        }
    }
}

/// Riquadro in cima al sito: cosa non va per i visitatori, perché e come risolvere.
struct HealthBanner: View {
    @EnvironmentObject var health: HealthMonitor
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: SiteSession
    @State private var expanded: [Side: Bool] = [:]

    var body: some View {
        let reports = [Side.remote, .local].compactMap { health.report(session.site.id, $0) }
            .filter { $0.level >= .notice || session.diagnosis[$0.side] != nil }
        if !reports.isEmpty {
            VStack(spacing: 0) {
                ForEach(reports, id: \.side) { r in
                    block(r)
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private func isExpanded(_ r: HealthReport) -> Bool { expanded[r.side] ?? (r.level >= .warning || session.diagnosis[r.side] != nil) }

    @ViewBuilder private func block(_ r: HealthReport) -> some View {
        let open = isExpanded(r)
        let sideName = r.side == .remote ? L("Sito online") : L("Sito in locale")
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: r.level.symbol).foregroundStyle(r.level.color).font(.system(size: 15))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: sideName.uppercased()).font(Theme.font(size: 10, .bold)).foregroundStyle(r.side == .remote ? Theme.remote : Theme.local)
                    Text(r.title).font(Theme.font(.callout, .semibold)).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                let checkedAt = r.checkedAt.formatted(date: .omitted, time: .shortened)
                Text("controllato alle \(checkedAt)").font(Theme.font(.caption)).foregroundStyle(.tertiary)
                if health.checking.contains(session.site.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await health.check(session.site) } } label: { Label("Ricontrolla", systemImage: "arrow.clockwise") }
                        .buttonStyle(ChipButtonStyle(color: r.level.color))
                }
                if let u = URL(string: r.url) {
                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "safari") }
                        .buttonStyle(ChipButtonStyle(color: r.level.color)).help("Apri nel browser")
                }
                Button { expanded[r.side] = !open } label: { Image(systemName: open ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if open {
                ScrollView { VStack(alignment: .leading, spacing: 8) { details(r) }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8) }
                    .frame(maxHeight: 330)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(r.level.color.opacity(r.level >= .warning ? 0.09 : 0.06))
    }

    @ViewBuilder private func details(_ r: HealthReport) -> some View {
                if !r.explanation.isEmpty {
                    Text(r.explanation).font(Theme.font(.callout)).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !r.steps.isEmpty { Steps(steps: r.steps) }
                if r.level >= .warning || r.kind == .comingSoon { diagnoseRow(r.side) }
                if let d = session.diagnosis[r.side] { DiagnosisCard(session: session, diagnosis: d) }
                DisclosureGroup("Dettagli tecnici") {
                    Text(r.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
                .font(Theme.font(.caption)).foregroundStyle(.secondary)
    }

    @ViewBuilder private func diagnoseRow(_ side: Side) -> some View {
        HStack(spacing: 10) {
            let can = side == .local || session.canReachRemoteBridge
            Button { Task { await session.diagnose(side) } } label: {
                Label(session.diagnosis[side] == nil ? L("Diagnosi") : L("Ripeti la diagnosi"), systemImage: "stethoscope")
            }
            .buttonStyle(ActionButtonStyle(color: side == .remote ? Theme.remote : Theme.local))
            .disabled(!can || session.busy != nil)
            if can {
                Text(side == .remote ? L("Installa per poco il ponte sul server, legge i log degli errori PHP e prova ad avviare WordPress per trovare il colpevole.")
                                     : L("Legge i log degli errori PHP e prova ad avviare WordPress in locale."))
                    .font(Theme.font(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Per la diagnosi sul server servono utente e password FTP nel profilo.").font(Theme.font(.caption)).foregroundStyle(.secondary)
                Button("Completa il profilo") { model.editing = session.site }.buttonStyle(ChipButtonStyle(color: Theme.remote))
            }
        }
    }
}

/// Passi numerati.
struct Steps: View {
    let steps: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(i + 1).").font(Theme.font(.callout, .bold)).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                    Text(LocalizedStringKey(s)).font(Theme.font(.callout)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Risultato della diagnosi con il ponte: colpevole, messaggio, correzioni con un clic.
struct DiagnosisCard: View {
    @EnvironmentObject var health: HealthMonitor
    @ObservedObject var session: SiteSession
    let diagnosis: Diagnosis
    @State private var confirmDisable: Diagnosis.Culprit?

    var body: some View {
        let v = diagnosis.verdict
        Card(padding: 12) {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope").foregroundStyle(Theme.amber)
                Text(v.title).font(Theme.font(.callout, .bold)).textSelection(.enabled)
                Spacer()
                let at = diagnosis.date.formatted(date: .omitted, time: .shortened)
                Text("diagnosi delle \(at)").font(Theme.font(.caption)).foregroundStyle(.tertiary)
            }
            if !v.text.isEmpty {
                Text(v.text).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            if !v.steps.isEmpty { Steps(steps: v.steps) }
            HStack(spacing: 8) {
                if let c = diagnosis.culprit, c.canDisable, !(session.disabledExtensions[diagnosis.side]?.contains(c) ?? false) {
                    Button { confirmDisable = c } label: { Label(L("Disattiva %@", c.slug), systemImage: "power") }
                        .buttonStyle(ActionButtonStyle(color: Theme.danger)).disabled(session.busy != nil)
                }
                if diagnosis.maintenance {
                    Button { Task { await session.removeMaintenance(diagnosis.side); await health.check(session.site) } } label: {
                        Label("Togli .maintenance", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(ActionButtonStyle(color: Theme.danger)).disabled(session.busy != nil)
                }
                ForEach(Array(session.disabledExtensions[diagnosis.side] ?? []), id: \.self) { c in
                    Button { Task { await session.enableExtension(c, side: diagnosis.side) } } label: { Label(L("Riattiva %@", c.slug), systemImage: "arrow.uturn.backward") }
                        .buttonStyle(ChipButtonStyle(color: Theme.ok)).disabled(session.busy != nil)
                }
            }
            let logs = diagnosis.logs.filter { $0.fatal > 0 }
            if !logs.isEmpty {
                DisclosureGroup(L("Ultimi errori fatali nei log (%d)", diagnosis.recentFatals.count)) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(logs, id: \.path) { l in
                            Text(verbatim: l.path).font(Theme.font(.caption, .bold)).foregroundStyle(.secondary)
                            Text(l.last.joined(separator: "\n")).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
                .font(Theme.font(.caption)).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(confirmDisable.map { L("Disattivare %@?", $0.slug) } ?? "", isPresented: Binding(get: { confirmDisable != nil }, set: { if !$0 { confirmDisable = nil } })) {
            Button(L("Disattiva")) {
                if let c = confirmDisable {
                    Task { await session.disableExtension(c, side: diagnosis.side); await health.check(session.site) }
                }
            }
            Button(L("Annulla"), role: .cancel) {}
        } message: {
            Text("La cartella viene rinominata con .off-mirrorpress: niente viene cancellato e si può riattivare da qui. Le impostazioni del plugin restano nel database.")
        }
    }
}
