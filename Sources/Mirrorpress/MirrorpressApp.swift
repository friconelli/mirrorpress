import SwiftUI
import AppKit

@MainActor
final class AppModel: ObservableObject {
    let store = SiteStore()
    let health = HealthMonitor()
    @Published var selection: UUID?
    @Published var editing: SiteProfile?
    private var sessions: [UUID: SiteSession] = [:]

    init() {
        selection = store.sites.first?.id
        if let i = CommandLine.arguments.firstIndex(of: "--site"), i + 1 < CommandLine.arguments.count {
            let name = CommandLine.arguments[i + 1].lowercased()
            selection = store.sites.first { $0.name.lowercased() == name }?.id ?? selection
        }
    }

    func session(for site: SiteProfile) -> SiteSession {
        if let s = sessions[site.id] { return s }
        let s = SiteSession(site: site)
        // Solo per prove e demo: `--bridge-dir <cartella>` installa il ponte copiandolo lì invece che via FTP/SFTP.
        if let i = CommandLine.arguments.firstIndex(of: "--bridge-dir"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            s.installHook = { file, name in try FileManager.default.copyItem(at: file, to: dir.appendingPathComponent(name)) }
        }
        sessions[site.id] = s
        return s
    }

    func existingSession(_ id: UUID) -> SiteSession? { sessions[id] }

    func detachBridgesForQuit() -> [RemoteBridge] { sessions.values.compactMap { $0.detachBridgeForQuit() } }

    func save(_ site: SiteProfile) {
        store.upsert(site)
        sessions[site.id]?.profileChanged(site)
        selection = site.id
        Task { await health.check(site) }
        objectWillChange.send()
    }

    func delete(_ site: SiteProfile) async {
        await sessions[site.id]?.removeBridge()
        sessions[site.id] = nil
        store.remove(site)
        selection = store.sites.first?.id
        objectWillChange.send()
    }

    var selectedSite: SiteProfile? { store.sites.first { $0.id == selection } }

    /// Alla chiusura: toglie i ponti rimasti sui server.
    func removeAllBridges() async {
        for s in sessions.values { await s.removeBridge() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        // I ponti si cancellano da soli su richiesta firmata. Le richieste partono fuori dal thread principale
        // e si aspettano al massimo 6 secondi: la chiusura non resta mai appesa (il ponte comunque scade).
        let bridges = MainActor.assumeIsolated { model.detachBridgesForQuit() }
        guard !bridges.isEmpty else { return .terminateNow }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for b in bridges { group.addTask { _ = try? await b.call("selfdestruct", [:]) } }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 6)
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MirrorpressApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = Updater()

    init() {
        ProfileImport.runIfRequested()
        Theme.registerFonts()
    }

    var body: some Scene {
        WindowGroup("Mirrorpress") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(updater)
                .environmentObject(model.health)
                .frame(minWidth: 1020, minHeight: 680)
                .onAppear {
                    delegate.model = model
                    let store = model.store
                    model.health.start { store.sites }
                    Snapshot.scheduleIfRequested()
                    Snapshot.prepareIfRequested()
                    if !CommandLine.arguments.contains("--snapshot") { updater.startAutomaticChecks() }
                }
                .sheet(isPresented: $updater.showSheet) { UpdateSheet(updater: updater) }
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Verifica aggiornamenti…") {
                    updater.showSheet = true
                    Task { await updater.check() }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Nuovo sito…") { model.editing = SiteProfile() }.keyboardShortcut("n")
            }
        }
        Settings { SettingsView().environmentObject(updater) }
    }
}

struct SettingsView: View {
    @AppStorage("phpPath") private var phpPath = ""
    @AppStorage("autoUpdateCheck") private var autoUpdateCheck = true
    @EnvironmentObject var updater: Updater
    var body: some View {
        Form {
            Section {
                Toggle("Controlla gli aggiornamenti automaticamente", isOn: $autoUpdateCheck)
                HStack {
                    Text("Versione \(updater.currentVersion)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Verifica ora") { updater.showSheet = true; Task { await updater.check() } }
                }
            }
            Section {
                TextField("Percorso di PHP", text: $phpPath, prompt: Text(LocalEnv.phpBinary ?? "/Applications/MAMP/bin/php/…/bin/php"))
                Text("Vuoto = il PHP più recente di MAMP (o di Homebrew). Serve per leggere e scrivere il database locale.")
                    .font(Theme.font(.caption)).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
