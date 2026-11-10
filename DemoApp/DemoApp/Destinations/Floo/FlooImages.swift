//
//  FlooImages.swift
//  DemoApp
//
//  Images in an agent's words, as flowith shows them (MarkdownRenderView,
//  MarkdownImageGroupView, SaveableImageView): out of the text, each run of
//  them a block of its own between the words; one alone a 250-high picture as
//  wide as it can be, several a row 200 high to scroll; the alt text a caption
//  under it; a tap opens it full screen.
//

import SwiftUI
import CardUI
import FlooUIKit
import Wire

/// An image an agent's words show: where it is, and what it shows.
struct FlooImage: Equatable, Identifiable {
    let url: URL
    let alt: String
    var id: String { url.absoluteString }

    /// The server's picture it is (`media:<hash>?…`, an image block of a message or a tool's
    /// result): its size and ThumbHash known before it comes, its bytes from the account's
    /// cache (FlooMedia).
    var media: MediaRef? { Self.media(url) }

    /// A ```floo.images fence of the server's pictures: an image block, a tool's images. Each
    /// line is its hash with what's known of it, as `media(_:)` reads it back.
    static func fence(_ images: [MediaRef], in conversation: ConversationID) -> String {
        let lines = images.map { image in
            var address = "media:\(image.hash)?type=\(image.type)&size=\(image.size)&conversation=\(conversation)"
            if let width = image.width, let height = image.height { address += "&width=\(width)&height=\(height)" }
            if let thumbhash = image.thumbhash {
                address += "&thumbhash=" + thumbhash.base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
            return address
        }
        return (["```floo.images"] + lines + ["```"]).joined(separator: "\n")
    }

    private static func media(_ url: URL) -> MediaRef? {
        guard url.scheme == "media", let parts = URLComponents(string: url.absoluteString),
              let hash = try? ContentHash(String(parts.path))  // try?: not a hash, not one
        else { return nil }
        var fields: [String: String] = [:]
        for item in parts.queryItems ?? [] { fields[item.name] = item.value }
        let thumbhash = fields["thumbhash"].flatMap { text -> Data? in
            let plain = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            return Data(base64Encoded: plain + String(repeating: "=", count: (4 - plain.count % 4) % 4))
        }
        return MediaRef(
            hash: hash, type: fields["type"] ?? "image/jpeg", size: fields["size"].flatMap { Int64($0) } ?? 0,
            width: fields["width"].flatMap { Int($0) }, height: fields["height"].flatMap { Int($0) }, thumbhash: thumbhash
        )
    }

    /// The conversation whose message or tool shows it: what reaches it when it isn't the
    /// account's own.
    var conversation: ConversationID? {
        guard url.scheme == "media" else { return nil }
        return URLComponents(string: url.absoluteString)?.queryItems?.first { $0.name == "conversation" }?.value
            .flatMap(ConversationID.init)
    }

    /// How its bytes are reached: by hash, then through its conversation.
    var reach: FlooMedia.Reach {
        guard let media, let conversation else { return FlooMedia.Reach() }
        return FlooMedia.reach(media.hash, in: conversation)
    }

    /// Its width over its height, where it says.
    var aspect: CGFloat? {
        guard let media, let width = media.width, let height = media.height, width > 0, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }
}

extension FlooDemo {
    /// `![alt](url)` written whole, an optional title after the URL.
    nonisolated private static let imagePattern = try! NSRegularExpression(  // try!: a literal pattern
        pattern: #"!\[([^\]\n]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"\n]*")?\s*\)"#
    )

    /// The words with their images taken out: each run of images (nothing but spaces between
    /// them, on a line or on lines one after another) becomes a ```floo.images fence of its
    /// own, a line per image, its URL then its alt text. Images in code stay as written, and
    /// so does one with a URL that isn't the web's; one still being written is left to the
    /// splitter, which holds a half-written link back.
    nonisolated static func imagesApart(_ text: String) -> String {
        guard text.contains("![") else { return text }
        var out: [String] = []
        var inCode = false
        // The images of the run being collected, and whether the last line ended in it.
        var run: [String] = []
        func close() {
            guard !run.isEmpty else { return }
            out += ["", "```floo.images"] + run + ["```", ""]
            run = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                close()
                inCode.toggle()
                out.append(line)
                continue
            }
            guard !inCode, line.contains("![") else {
                // A blank line ends a run; so do words.
                close()
                out.append(line)
                continue
            }
            let code = codeSpans(in: line)
            let whole = line as NSString
            var at = 0
            for match in imagePattern.matches(in: line, range: NSRange(location: 0, length: whole.length)) {
                let address = whole.substring(with: match.range(at: 2))
                guard !code.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                      let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                else { continue }
                let before = whole.substring(with: NSRange(location: at, length: match.range.location - at))
                if !before.trimmingCharacters(in: .whitespaces).isEmpty {
                    close()
                    out.append(before.trimmingCharacters(in: .whitespaces))
                }
                let alt = whole.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                run.append(alt.isEmpty ? address : "\(address) \(alt)")
                at = match.range.location + match.range.length
            }
            let after = whole.substring(from: at)
            if !after.trimmingCharacters(in: .whitespaces).isEmpty {
                close()
                out.append(at == 0 ? line : after.trimmingCharacters(in: .whitespaces))
            }
        }
        close()
        return out.joined(separator: "\n")
    }

    /// The `inline code` spans of a line.
    private nonisolated static func codeSpans(in line: String) -> [NSRange] {
        guard line.contains("`") else { return [] }
        let pattern = try! NSRegularExpression(pattern: "`[^`]*`")  // try!: a literal pattern
        return pattern.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)).map(\.range)
    }

    /// A ```floo.images fence's images.
    nonisolated static func images(_ source: String) -> [FlooImage] {
        fenceBody(source).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let address = parts.first, let url = URL(string: address) else { return nil }
            return FlooImage(url: url, alt: parts.count > 1 ? parts[1] : "")
        }
    }
}

/// A run of images: one alone as wide as it can be, several in a row to scroll.
struct FlooImagesView: View {
    let images: [FlooImage]
    @State private var open: FlooImage?

    /// flowith's: one alone, several in a row, and the widest one in a row may be.
    static let aloneHeight: CGFloat = 250
    static let rowHeight: CGFloat = 200
    static let rowWidest: CGFloat = 300
    static let radius: CGFloat = 15

    var body: some View {
        Group {
            if images.count == 1, let image = images.first {
                VStack(alignment: .leading, spacing: 6) {
                    FlooImageBox(image: image, height: Self.aloneHeight, widest: nil) { open = image }
                    caption(image.alt).padding(.leading, 5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top) {
                        ForEach(images) { image in
                            VStack(alignment: .leading, spacing: 6) {
                                FlooImageBox(image: image, height: Self.rowHeight, widest: Self.rowWidest) { open = image }
                                caption(image.alt).lineLimit(1).frame(maxWidth: Self.rowWidest, alignment: .leading)
                            }
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .fullScreenCover(item: $open) { image in
            FlooImageViewer(images: images, start: image)
        }
    }

    @ViewBuilder
    private func caption(_ alt: String) -> some View {
        if !alt.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(alt).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// One image in its box: the box's height is set before the picture comes, so nothing below
/// it moves; its width is the picture's at that height, up to what there is. A picture wider
/// than the box covers it; a narrower one shows whole at its left.
private struct FlooImageBox: View {
    let image: FlooImage
    let height: CGFloat
    /// The widest it may be; nil, as wide as it's given.
    let widest: CGFloat?
    let tap: () -> Void

    var body: some View {
        let picture = image.media == nil ? DocImageCache.shared.image(image.url) : nil
        let aspect = image.aspect ?? picture.map { $0.size.width / max($0.size.height, 1) } ?? 1
        let natural = height * aspect
        Group {
            if let widest {
                box(picture, width: min(natural, widest))
            } else {
                GeometryReader { proxy in
                    box(picture, width: min(natural, proxy.size.width))
                }
                .frame(height: height)
            }
        }
        .accessibilityLabel(image.alt)
    }

    private func box(_ picture: UIImage?, width: CGFloat) -> some View {
        ZStack {
            Color(uiColor: .floo(.rowFill))
            if let media = image.media {
                // Its ThumbHash, then the picture, decoded at this size.
                FlooMediaImage(media: media, reach: image.reach).frame(width: width, height: height)
            } else if let picture {
                Image(uiImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: FlooImagesView.radius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
        .animation(.easeOut(duration: 0.25), value: picture != nil)
    }
}

/// The images full screen, from the one tapped; swipe for the others, tap to close.
private struct FlooImageViewer: View {
    let images: [FlooImage]
    let start: FlooImage
    @State private var shown: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView(selection: Binding(get: { shown ?? start.id }, set: { shown = $0 })) {
            ForEach(images) { image in
                Group {
                    if let media = image.media {
                        FlooMediaImage(media: media, reach: image.reach, contentMode: .fit)
                    } else if let picture = DocImageCache.shared.image(image.url) {
                        Image(uiImage: picture).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tag(image.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
        .background(Color.black.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .preferredColorScheme(.dark)
    }
}
