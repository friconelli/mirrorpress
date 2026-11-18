import SwiftUI

/// Mirrorpress: il vino passa da un vaso all'altro. Locale = acqua (blu), server = vino, accento ambra.
enum Theme {
    static let local = Color(red: 0.11, green: 0.50, blue: 0.86)       // #1C80DB
    static let remote = Color(red: 0.55, green: 0.13, blue: 0.30)      // #8C214D
    static let amber = Color(red: 0.96, green: 0.65, blue: 0.20)       // #F5A633
    static let ink = Color(red: 0.09, green: 0.08, blue: 0.09)
    static let ok = Color(red: 0.16, green: 0.62, blue: 0.38)
    static let warn = Color(red: 0.93, green: 0.55, blue: 0.10)
    static let danger = Color(red: 0.84, green: 0.20, blue: 0.20)

    static let canvas = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.11, green: 0.10, blue: 0.11, alpha: 1)
            : NSColor(red: 0.975, green: 0.965, blue: 0.955, alpha: 1)
    })
    static let card = Color(nsColor: .controlBackgroundColor)

    static let pour = LinearGradient(colors: [local, Color(red: 0.42, green: 0.22, blue: 0.62), remote],
                                     startPoint: .leading, endPoint: .trailing)
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.8)

    // Tipografia: Bricolage Grotesque (OFL), inclusa nell'app in Resources/Fonts.
    static let fontFamily = "Bricolage Grotesque"

    static func font(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 28
        case .title: size = 24
        case .title2: size = 20
        case .title3: size = 17
        case .headline: size = 14
        case .body: size = 14
        case .callout: size = 13
        case .subheadline: size = 12.5
        case .footnote: size = 11.5
        default: size = 11
        }
        return .custom(fontFamily, size: size, relativeTo: style).weight(weight)
    }

    static func font(size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(fontFamily, size: size).weight(weight)
    }

    static let mono = Font.system(size: 11.5, design: .monospaced)

    static func registerFonts() {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Fonts")) }
        dirs.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Fonts"))
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where ["ttf", "otf"].contains(f.pathExtension.lowercased()) {
                CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            }
            return
        }
    }

    static func color(_ s: Severity) -> Color {
        switch s {
        case .error: return danger
        case .warning: return warn
        case .info: return local
        }
    }

    static func symbol(_ s: Severity) -> String {
        switch s {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    static func color(_ s: FileStatus) -> Color {
        switch s {
        case .onlyLocal: return local
        case .onlyRemote: return remote
        case .changed: return warn
        case .same: return ok
        case .unknown: return .secondary
        }
    }

    static func color(_ s: TableStatus) -> Color {
        switch s {
        case .onlyLocal: return local
        case .onlyRemote: return remote
        case .changed: return warn
        case .same: return ok
        case .unknown: return .secondary
        }
    }
}

// MARK: - Marchio

/// Due pagine speculari (locale e server) e l'asse ambra dello specchio che si accende all'apertura.
struct LogoMark: View {
    var size: CGFloat = 40
    @State private var lit = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Theme.ink)
            Canvas { ctx, sz in
                let w = sz.width, h = sz.height
                let pw = w * 0.30, ph = h * 0.56, py = h * 0.22
                let left = CGRect(x: w * 0.5 - w * 0.07 - pw, y: py, width: pw, height: ph)
                let right = CGRect(x: w * 0.5 + w * 0.07, y: py, width: pw, height: ph)
                ctx.fill(Path(roundedRect: left, cornerRadius: w * 0.05), with: .color(Theme.local))
                ctx.fill(Path(roundedRect: right, cornerRadius: w * 0.05), with: .color(Theme.remote))
                for (i, f) in [0.7, 0.5, 0.6].enumerated() {
                    let lw = pw * f, lh = max(1.2, h * 0.04), ly = py + h * 0.09 + CGFloat(i) * h * 0.13
                    ctx.fill(Path(roundedRect: CGRect(x: left.maxX - w * 0.05 - lw, y: ly, width: lw, height: lh), cornerRadius: lh / 2),
                             with: .color(.white.opacity(0.8)))
                    ctx.fill(Path(roundedRect: CGRect(x: right.minX + w * 0.05, y: ly, width: lw, height: lh), cornerRadius: lh / 2),
                             with: .color(.white.opacity(0.8)))
                }
                let axisH = h * (lit ? 0.76 : 0.1)
                ctx.fill(Path(roundedRect: CGRect(x: w * 0.5 - w * 0.025, y: h * 0.5 - axisH / 2, width: w * 0.05, height: axisH),
                              cornerRadius: w * 0.025), with: .color(Theme.amber))
            }
            .padding(size * 0.06)
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.15)) { lit = true } }
    }
}

// MARK: - Componenti

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Pulsante d'azione pieno: verso il server (vino) o verso il locale (blu).
struct ActionButtonStyle: ButtonStyle {
    var color: Color = Theme.remote
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return configuration.label
            .font(Theme.font(.callout, .bold))
            .lineLimit(1).fixedSize()
            .foregroundStyle(enabled ? Color.white : Color.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(shape.fill(enabled ? color.opacity(hovering ? 1 : 0.9) : Color.gray.opacity(0.22)))
            .overlay(shape.strokeBorder(Color.black.opacity(enabled ? 0.25 : 0), lineWidth: 1))
            .shadow(color: enabled ? color.opacity(hovering ? 0.35 : 0.18) : .clear, radius: hovering ? 6 : 3, y: 2)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

struct ChipButtonStyle: ButtonStyle {
    var color: Color = Theme.amber
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(.callout, .semibold))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(hovering ? 0.26 : 0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(hovering ? 0.8 : 0), lineWidth: 1.2))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Pallino + testo, per stati e contatori.
struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(Theme.font(size: 11, .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}

/// Etichetta "Locale" / "Server" con il colore del lato.
struct SideTag: View {
    let side: Side
    var body: some View {
        Label(side.label, systemImage: side == .local ? "laptopcomputer" : "server.rack")
            .font(Theme.font(.caption, .bold))
            .foregroundStyle(side == .local ? Theme.local : Theme.remote)
    }
}

struct FieldRow<Control: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let control: Control
    init(_ label: LocalizedStringKey, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Theme.font(.callout)).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            control
        }
    }
}

/// Pulsante quadrato con sola icona (azioni secondarie nell'intestazione).
struct IconButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(hovering ? 0.1 : 0.05)))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Filtro a pillola: pieno quando attivo, solo contorno quando spento.
struct FilterChipStyle: ToggleStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(Theme.font(.callout, .semibold))
                .foregroundStyle(configuration.isOn ? color : Color.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(configuration.isOn ? color.opacity(0.14) : Color.clear))
                .overlay(Capsule().strokeBorder(configuration.isOn ? color.opacity(0.45) : Color.primary.opacity(0.15), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: configuration.isOn)
    }
}

/// Iniziale del sito su un tassello colorato (colore stabile ricavato dal nome).
struct SiteMonogram: View {
    let name: String
    var size: CGFloat = 30
    private var color: Color {
        let palette = [Theme.local, Theme.remote, Theme.amber, Theme.ok, Color(red: 0.42, green: 0.36, blue: 0.80), Color(red: 0.10, green: 0.55, blue: 0.60)]
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return palette[h % palette.count]
    }
    var body: some View {
        let initial = name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
        Text(initial)
            .font(Theme.font(size: size * 0.48, .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(color.gradient))
    }
}
