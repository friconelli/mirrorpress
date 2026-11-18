import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var updater: Updater

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            if let site = model.selectedSite {
                SiteDetailView(session: model.session(for: site))
                    .id(site.id)
            } else {
                EmptyState()
            }
        }
        .sheet(item: $model.editing) { site in
            SiteEditorView(site: site)
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var updater: Updater

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LogoMark(size: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Mirrorpress").font(Theme.font(.title3, .heavy))
                    Text("locale ⇄ server").font(Theme.font(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)

            List(selection: $model.selection) {
                Section("Siti") {
                    ForEach(store.sites) { site in
                        SiteRow(site: site).tag(site.id)
                            .contextMenu {
                                Button("Modifica…") { model.editing = site }
                                Button("Mostra cartella locale") { NSWorkspace.shared.open(URL(fileURLWithPath: site.localPath)) }
                                if let u = URL(string: site.remoteURL), !site.remoteURL.isEmpty { Button("Apri il sito") { NSWorkspace.shared.open(u) } }
                            }
                    }
                }
            }
            .listStyle(.sidebar)

            VStack(spacing: 10) {
                Button { model.editing = SiteProfile() } label: {
                    Label("Aggiungi sito", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionButtonStyle(color: Theme.ink))
                UpdateFooter()
            }
            .padding(12)
        }
    }
}

/// Versione dell'app e aggiornamenti, sempre visibili in fondo alla barra laterale.
struct UpdateFooter: View {
    @EnvironmentObject var updater: Updater
    var body: some View {
        if updater.isUpdateAvailable, case let .available(version, _, _, _) = updater.state {
            Button { updater.showSheet = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Aggiornamento disponibile").font(Theme.font(.caption, .bold))
                        Text(verbatim: "v\(updater.currentVersion) → v\(version)").font(Theme.font(.caption))
                    }
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ok.gradient))
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 6) {
                Text(verbatim: "v\(updater.currentVersion)").font(Theme.font(.caption, .semibold)).foregroundStyle(.secondary)
                Spacer()
                if updater.state == .checking {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        updater.showSheet = true
                        Task { await updater.check() }
                    } label: { Label("Verifica aggiornamenti", systemImage: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .font(Theme.font(.caption))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

struct SiteRow: View {
    @EnvironmentObject var model: AppModel
    let site: SiteProfile
    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(site: site, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(site.name.isEmpty ? L("Senza nome") : site.name).font(Theme.font(.body, .semibold)).lineLimit(1)
                Text(URL(string: site.remoteURL)?.host ?? site.host)
                    .font(Theme.font(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let s = model.existingSession(site.id) { SiteRowStatus(session: s) }
        }
        .padding(.vertical, 3)
    }
}

/// Stato sintetico nella barra laterale: in corso, errori, ponte attivo.
struct SiteRowStatus: View {
    @ObservedObject var session: SiteSession
    var body: some View {
        if session.busy != nil {
            ProgressView().controlSize(.mini)
        } else if session.lastError != nil {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger).help(session.lastError ?? "")
        } else if session.analyzedAt != nil {
            let n = session.files.filter { $0.status != .same }.count + session.tables.filter { $0.status != .same }.count
            if n > 0 {
                Text(verbatim: "\(n)").font(Theme.font(size: 10.5, .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1.5).background(Capsule().fill(Theme.amber))
                    .help(L("Differenze tra locale e server"))
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).help(L("Locale e server allineati"))
            }
        }
    }
}

struct EmptyState: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            LogoMark(size: 84)
            Text("Sincronizza i siti dal Mac al server").font(Theme.font(.title2, .bold))
            Text("Mirrorpress confronta file e database tra la copia in locale (MAMP) e quella sull'hosting, mostra differenze e problemi e aggiorna il lato che vuoi, con backup automatici. Funziona con SFTP, FTPS, FTP o caricando a mano un piccolo file PHP: va bene per qualsiasi hosting con PHP.")
                .font(Theme.font(.body)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
            Text("Non serve per i progetti che si pubblicano con Vercel, Netlify o una pipeline: Mirrorpress li riconosce e li lascia stare.")
                .font(Theme.font(.callout)).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 520)
            Button { model.editing = SiteProfile() } label: { Label("Aggiungi il primo sito", systemImage: "plus") }
                .buttonStyle(ActionButtonStyle(color: Theme.remote))
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

// MARK: - Editor del profilo

struct SiteEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var site: SiteProfile
    @State private var password = ""
    @State private var httpPassword = ""
    @State private var localDBPassword = ""
    @State private var remoteDBPassword = ""
    @State private var excludesText = ""
    @State private var pipelineWarning: String?
    @State private var showAdvanced = false
    @State private var confirmDelete = false
    @State private var showBrowser = false

    private var isNew: Bool { !model.store.sites.contains { $0.id == site.id } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "Nuovo sito" : "Modifica sito").font(Theme.font(.title3, .heavy))
                Spacer()
            }
            .padding([.horizontal, .top], 22).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card {
                        SideTag(side: .local)
                        FieldRow("Cartella del sito") {
                            HStack {
                                TextField("", text: $site.localPath, prompt: Text("/Applications/MAMP/htdocs/sito"))
                                Button("Scegli…") { chooseFolder() }
                            }
                        }
                        if let pipelineWarning {
                            Label(pipelineWarning + " " + L("Mirrorpress non serve per questo progetto."), systemImage: "nosign")
                                .font(Theme.font(.callout, .semibold)).foregroundStyle(Theme.danger)
                        }
                        FieldRow("Nome") { TextField("", text: $site.name, prompt: Text("Villa Patrizia")) }
                        FieldRow("Indirizzo locale") {
                            TextField("", text: $site.localURL, prompt: Text("vuoto = siteurl del database locale"))
                        }
                    }

                    Card {
                        SideTag(side: .remote)
                        FieldRow("Indirizzo del sito") { TextField("", text: $site.remoteURL, prompt: Text("https://www.sito.it")) }
                        FieldRow("Connessione") {
                            Picker("", selection: $site.connection) {
                                ForEach(ConnectionKind.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .onChange(of: site.connection) { k in site.port = k.defaultPort }
                        }
                        if site.connection != .manual {
                            FieldRow("Server") {
                                HStack {
                                    TextField("", text: $site.host, prompt: Text("ftp.sito.it"))
                                    Text("porta").foregroundStyle(.secondary)
                                    TextField("", value: $site.port, format: .number.grouping(.never)).frame(width: 60)
                                }
                            }
                            FieldRow("Utente") { TextField("", text: $site.username) }
                            FieldRow("Password") {
                                SecureField("", text: $password, prompt: Text(site.connection == .sftp ? "vuota = chiave SSH" : ""))
                            }
                            FieldRow("Cartella remota") {
                                HStack {
                                    TextField("", text: $site.remotePath, prompt: Text("/www.sito.it  oppure  /public_html"))
                                    Button("Sfoglia…") { showBrowser = true }
                                        .disabled(site.host.isEmpty || site.username.isEmpty)
                                }
                            }
                            Text("La cartella che contiene wp-config.php, vista dall'FTP/SFTP: deve corrispondere all'indirizzo del sito.")
                                .font(Theme.font(.caption)).foregroundStyle(.secondary)
                            if site.connection != .sftp {
                                Toggle("Accetta certificati TLS non validi del server FTP (hosting condivisi)", isOn: $site.allowInvalidCertificates)
                                    .font(Theme.font(.callout))
                            }
                        } else {
                            Text("Mirrorpress preparerà un file PHP da caricare con il file manager dell'hosting nella cartella principale del sito. Si cancella da solo dopo 4 ore.")
                                .font(Theme.font(.callout)).foregroundStyle(.secondary)
                        }
                    }

                    DisclosureGroup(isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 12) {
                            Card {
                                Text("Protezione HTTP del sito (staging con password)").font(Theme.font(.callout, .bold))
                                FieldRow("Utente HTTP") { TextField("", text: $site.httpAuthUser) }
                                FieldRow("Password HTTP") { SecureField("", text: $httpPassword) }
                            }
                            Card {
                                Text("Database (solo se non è WordPress o il wp-config è particolare)").font(Theme.font(.callout, .bold))
                                dbFields(title: L("Locale"), o: $site.localDBOverride, password: $localDBPassword)
                                Divider()
                                dbFields(title: L("Server"), o: $site.remoteDBOverride, password: $remoteDBPassword)
                            }
                            Card {
                                Text("File esclusi dal confronto").font(Theme.font(.callout, .bold))
                                Text("Uno per riga. «nome» vale in ogni cartella, «cartella/sotto» parte dalla radice del sito. Si possono usare * e ?.")
                                    .font(Theme.font(.caption)).foregroundStyle(.secondary)
                                TextEditor(text: $excludesText).font(Theme.mono).frame(height: 140)
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                                HStack {
                                    Toggle("Confronta il contenuto dei file (MD5), non solo la dimensione", isOn: $site.compareContent)
                                    Spacer()
                                    Button("Ripristina predefinite") { excludesText = SiteProfile.defaultExcludes.joined(separator: "\n") }
                                        .buttonStyle(.link)
                                }.font(Theme.font(.callout))
                            }
                            Card {
                                Text("Note").font(Theme.font(.callout, .bold))
                                TextEditor(text: $site.notes).frame(height: 60)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Avanzate").font(Theme.font(.callout, .bold))
                    }
                }
                .padding(.horizontal, 22)
            }

            HStack {
                if !isNew {
                    Button("Elimina profilo", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salva") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(site.localPath.isEmpty || site.remoteURL.isEmpty || pipelineWarning != nil)
            }
            .padding(22)
        }
        .font(Theme.font(.body))
        .frame(width: 640, height: 720)
        .onAppear {
            password = Secret.connection.get(site)
            httpPassword = Secret.httpAuth.get(site)
            localDBPassword = Secret.localDB.get(site)
            remoteDBPassword = Secret.remoteDB.get(site)
            excludesText = site.excludes.joined(separator: "\n")
            checkPipeline()
        }
        .onChange(of: site.localPath) { _ in checkPipeline() }
        .sheet(isPresented: $showBrowser) {
            RemoteFolderBrowser(site: site, password: password) { site.remotePath = $0 }
        }
        .confirmationDialog("Eliminare il profilo «\(site.name)»?", isPresented: $confirmDelete) {
            Button("Elimina", role: .destructive) {
                let s = site
                dismiss()
                Task { await model.delete(s) }
            }
        } message: {
            Text("Si cancellano solo il profilo e le password salvate: i file e i database non vengono toccati.")
        }
    }

    @ViewBuilder
    private func dbFields(title: String, o: Binding<DBOverride>, password: Binding<String>) -> some View {
        Text(title).font(Theme.font(.caption, .bold)).foregroundStyle(.secondary)
        HStack {
            TextField("nome", text: o.name)
            TextField("utente", text: o.user)
            SecureField("password", text: password)
        }
        HStack {
            TextField("host (es. localhost:3306)", text: o.host)
            TextField("prefisso tabelle", text: o.prefix).frame(width: 140)
        }
    }

    private func checkPipeline() {
        guard !site.localPath.isEmpty else { pipelineWarning = nil; return }
        pipelineWarning = LocalEnv.pipelineReason(for: URL(fileURLWithPath: site.localPath))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = site.localPath.isEmpty ? LocalEnv.mampHtdocs : URL(fileURLWithPath: site.localPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        site.localPath = url.path
        if site.name.isEmpty { site.name = url.lastPathComponent.replacingOccurrences(of: "-", with: " ").capitalized }
        checkPipeline()
    }

    private func save() {
        site.excludes = excludesText.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        site.remoteURL = site.remoteURL.trimmingCharacters(in: .whitespaces)
        if !site.remoteURL.isEmpty && !site.remoteURL.contains("://") { site.remoteURL = "https://" + site.remoteURL }
        if site.name.isEmpty { site.name = URL(string: site.remoteURL)?.host ?? L("Sito") }
        Secret.connection.set(password, for: site)
        Secret.httpAuth.set(httpPassword, for: site)
        Secret.localDB.set(localDBPassword, for: site)
        Secret.remoteDB.set(remoteDBPassword, for: site)
        model.save(site)
        dismiss()
    }
}
