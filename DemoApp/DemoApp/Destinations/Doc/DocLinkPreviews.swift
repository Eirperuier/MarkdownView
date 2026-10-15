//
//  DocLinkPreviews.swift
//  DemoApp
//
//  What a bookmark doesn't say about its page, from the page itself (Craft's): its
//  title, summary and preview image, read from the page's Open Graph tags (else its
//  <title> and description). Each address is asked once; what comes back fills only
//  what the bookmark leaves empty. Remote images are kept once loaded (DocImageCache),
//  so a link redrawn (a transition's layers) shows its picture at once.
//

import UIKit
import DocKit

@MainActor
final class DocLinkPreviews {
    struct Preview: Equatable {
        var title = ""
        var summary = ""
        var image: String?

        /// `link` with what it leaves empty filled in.
        func filling(_ link: DocLink) -> DocLink {
            var link = link
            if link.title.isEmpty { link.title = title }
            if link.summary.isEmpty { link.summary = summary }
            if link.image == nil { link.image = image }
            return link
        }
    }

    /// Called with each address's preview as it comes.
    var onPreview: ((_ url: String, Preview) -> Void)?
    private(set) var previews: [String: Preview] = [:]
    private var asked: Set<String> = []

    /// Whether a link would show more with its page's preview.
    static func wants(_ link: DocLink) -> Bool {
        link.summary.isEmpty && link.image == nil
    }

    /// Asks for a web page's preview, once per address.
    func ask(_ url: String) {
        guard !asked.contains(url), let address = URL(string: url), ["http", "https"].contains(address.scheme?.lowercased()) else { return }
        asked.insert(url)
        Task {
            guard let preview = await Self.fetch(address) else { return }
            previews[url] = preview
            onPreview?(url, preview)
        }
    }

    private static func fetch(_ url: URL) async -> Preview? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        // Pages give a browser their tags; some give a bare client nothing.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        // The head is enough; a page can be large.
        let head = data.prefix(512 * 1024)
        guard let html = decode(head, contentType: http.value(forHTTPHeaderField: "Content-Type")) else { return nil }
        let preview = parse(html, base: http.url ?? url)
        return preview == Preview() ? nil : preview
    }

    /// The page's text, in the charset its header or <meta> names (UTF-8 if none).
    static func decode(_ data: Data, contentType: String?) -> String? {
        func charset(in text: String) -> String? {
            guard let match = text.firstMatch(of: /(?i)charset\s*=\s*["']?([A-Za-z0-9_\-]+)/) else { return nil }
            return String(match.1)
        }
        let named = contentType.flatMap(charset) ?? charset(in: String(decoding: data.prefix(2048), as: UTF8.self))
        if let named {
            let cf = CFStringConvertIANACharSetNameToEncoding(named as CFString)
            if cf != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return text
            }
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// The preview a page's tags give; images resolved against `base`.
    static func parse(_ html: String, base: URL) -> Preview {
        var tags: [String: String] = [:]
        for match in html.matches(of: /(?is)<meta\b[^>]*>/) {
            let tag = String(match.0)
            guard let key = attribute("property", in: tag) ?? attribute("name", in: tag),
                let content = attribute("content", in: tag)
            else { continue }
            let name = key.lowercased()
            if tags[name] == nil { tags[name] = unescaped(content).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        func first(_ names: String...) -> String? {
            names.lazy.compactMap { tags[$0] }.first { !$0.isEmpty }
        }
        let pageTitle = html.firstMatch(of: /(?is)<title[^>]*>(.*?)<\/title>/).map {
            unescaped(String($0.1)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let image = first("og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src")
            .flatMap { URL(string: $0, relativeTo: base)?.absoluteURL.absoluteString }
        return Preview(
            title: first("og:title", "twitter:title") ?? pageTitle ?? "",
            summary: first("og:description", "twitter:description", "description") ?? "",
            image: image
        )
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        for match in tag.matches(of: /(?i)([a-z:\-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/) where match.1.lowercased() == name {
            return String(match.2 ?? match.3 ?? match.4 ?? "")
        }
        return nil
    }

    private static func unescaped(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'", "nbsp": " "]
        return text.replacing(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/) { match in
            let entity = String(match.1)
            if let character = named[entity] { return character }
            let number = entity.hasPrefix("#x") || entity.hasPrefix("#X") ? UInt32(entity.dropFirst(2), radix: 16)
                : entity.hasPrefix("#") ? UInt32(entity.dropFirst()) : nil
            return number.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.0)
        }
    }
}

/// Remote images and kept ones (DocBlobs), kept once loaded.
@MainActor
@Observable
final class DocImageCache {
    static let shared = DocImageCache()
    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    /// The image at `url`, if it has come; asks for it if not.
    func image(_ url: URL) -> UIImage? {
        let key = url.absoluteString
        if let image = images[key] { return image }
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        Task {
            if let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) {
                images[key] = image
            }
        }
        return nil
    }
    /// Kept content's picture, if it's decoded; fetched (if it isn't here) and decoded if not.
    func image(_ ref: DocBlobRef) -> UIImage? {
        let key = ref.source
        if let image = images[key] { return image }
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        Task {
            guard let file = try? await DocBlobs.store.file(for: ref),
                  let image = await Task.detached(priority: .userInitiated, operation: { DocBlobImages.decode(file) }).value
            else { return }
            images[key] = image
        }
        return nil
    }
}
