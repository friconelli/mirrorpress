import SwiftUI
import AppKit

/// Icona di un sito presa dalla sua favicon (apple-touch-icon se c'è, che è più grande), con cache su disco.
/// Finché non arriva, o se il sito non ne ha, resta l'iniziale colorata.
@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()
    @Published private(set) var images: [String: NSImage] = [:]
    private var loading: Set<String> = []

    private var cacheDir: URL {
        let u = AppPaths.support.appendingPathComponent("favicon", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func image(for siteURL: String) -> NSImage? {
        guard let host = URL(string: siteURL)?.host else { return nil }
        if let img = images[host] { return img }
        load(siteURL, host: host)
        return nil
    }

    private func load(_ siteURL: String, host: String) {
        guard !loading.contains(host), let base = URL(string: siteURL) else { return }
        loading.insert(host)
        let file = cacheDir.appendingPathComponent(host + ".png")
        // Cache valida 7 giorni.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < 7 * 86400,
           let img = NSImage(contentsOf: file) {
            Task { @MainActor in self.images[host] = img }   // mai durante il disegno della vista
            return
        }
        Task.detached(priority: .utility) {
            guard let data = await Self.fetch(base), let img = NSImage(data: data) else { return }
            if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: file)
            }
            await MainActor.run { self.images[host] = img }
        }
    }

    private nonisolated static func fetch(_ base: URL) async -> Data? {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: cfg)
        var candidates: [URL] = []
        if let (html, response) = try? await session.data(from: base), let page = response.url ?? Optional(base) {
            let text = String(decoding: html.prefix(200_000), as: UTF8.self)
            candidates = iconLinks(in: text, base: page)
        }
        candidates.append(URL(string: "/favicon.ico", relativeTo: base)!.absoluteURL)
        for url in candidates {
            guard let (data, resp) = try? await session.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 64, NSImage(data: data) != nil else { continue }
            return data
        }
        return nil
    }

    /// `<link rel="apple-touch-icon|icon|shortcut icon" href="…" sizes="…">`, le più grandi prima.
    nonisolated static func iconLinks(in html: String, base: URL) -> [URL] {
        guard let re = try? NSRegularExpression(pattern: "<link\\s[^>]*>", options: [.caseInsensitive]) else { return [] }
        func attr(_ tag: String, _ name: String) -> String? {
            guard let r = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive]),
                  let m = r.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let range = Range(m.range(at: 1), in: tag) else { return nil }
            return String(tag[range])
        }
        var found: [(URL, Int)] = []
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range, in: html) else { continue }
            let tag = String(html[r])
            guard let rel = attr(tag, "rel")?.lowercased(), rel.contains("icon"), !rel.contains("mask"),
                  let href = attr(tag, "href"), let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL
            else { continue }
            if url.pathExtension.lowercased() == "svg" { continue }   // NSImage su macOS 13 non è affidabile con gli SVG
            var score = Int(attr(tag, "sizes")?.split(separator: "x").first ?? "") ?? 32
            if rel.contains("apple-touch") { score = max(score, 180) }
            found.append((url, score))
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

/// Favicon del sito su un tassello bianco arrotondato; altrimenti l'iniziale colorata.
struct SiteIcon: View {
    let site: SiteProfile
    var size: CGFloat = 30
    @ObservedObject private var store = FaviconStore.shared

    var body: some View {
        if let img = store.image(for: site.remoteURL) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(size * 0.12)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        } else {
            SiteMonogram(name: site.name.isEmpty ? "?" : site.name, size: size)
        }
    }
}
