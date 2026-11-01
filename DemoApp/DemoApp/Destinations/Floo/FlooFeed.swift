//
//  FlooFeed.swift
//  DemoApp
//
//  The feed (floo docs/plugins.md §6 item 9) as WeChat's Moments shows it: your posts, your
//  agents' and those of the people you follow, newest first, each with its pictures, cards and
//  what it points at, then the likes and comments under it that you see. You like, comment and
//  post here in your own name; whom you follow and who follows you are on a sheet of their own.
//  Read when it opens and when pulled down: no stream tells of new posts yet.
//

import SwiftUI
import UniformTypeIdentifiers
import CardModel
import CardUI
import LocalStore
import Wire
import TransportKit

/// The feed as read from the server: all you see, or one person's or agent's posts.
@MainActor @Observable
final class FlooFeed {
    let live: FlooLive
    /// Whose posts alone; nil for all you see.
    let from: Participant?
    private(set) var posts: [FeedPost] = []
    private(set) var more = false
    private(set) var loaded = false
    var failure: String?
    /// The names of the people its pages came with.
    @ObservationIgnored private var names: [AccountID: String] = [:]
    @ObservationIgnored private var icons: [ServiceID: URL] = [:]
    @ObservationIgnored private var cards: [String: CardSession] = [:]
    @ObservationIgnored private var reading = false

    init(live: FlooLive, from: Participant? = nil) {
        self.live = live
        self.from = from
    }

    var me: AccountID { live.account }

    // MARK: Reading

    /// The newest page again, in place of what was read.
    func load() async {
        guard let client = live.server else { return }
        do {
            let page = try await client.feed(from: from?.description, limit: Self.page)
            await take(page)
            posts = page.posts
            more = page.more
            failure = nil
        } catch {
            failure = "没读到动态：\(error)"
        }
        loaded = true
    }

    /// The page after the last one read.
    func older() async {
        guard more, !reading, let client = live.server, let last = posts.last else { return }
        reading = true
        defer { reading = false }
        do {
            let page = try await client.feed(from: from?.description, before: last.number, limit: Self.page)
            await take(page)
            let have = Set(posts.map(\.number))
            posts += page.posts.filter { !have.contains($0.number) }
            more = page.more
        } catch {
            failure = "没读到更早的：\(error)"
        }
    }

    /// One post read again, after something was done under it.
    func reread(_ number: Int64) async {
        guard let client = live.server else { return }
        do {
            let page = try await client.feedPost(number)
            await take(page)
            guard let post = page.posts.first, let at = posts.firstIndex(where: { $0.number == number }) else { return }
            posts[at] = post
        } catch {
            failure = "没读到：\(error)"
        }
    }

    private static let page = 20

    /// The names of the people on a page, and the icons of your services' agents on it.
    private func take(_ page: FeedPage) async {
        for person in page.people {
            if let name = person.name { names[person.account] = name }
        }
        let authors = page.posts.flatMap { [$0.author] + $0.comments.map(\.author) + $0.likes.map(\.author) }
        for author in authors where author.account == me {
            guard case .agent(.service(let service)) = author.actor, icons[service] == nil else { continue }
            icons[service] = await live.icon(of: service)
        }
    }

    // MARK: Doing

    func liked(_ post: FeedPost) -> Bool { post.likes.contains { $0.author == .person(me) } }

    func like(_ post: FeedPost) async {
        let liked = liked(post)
        await act(post.number) { try await $0.like(post.number, !liked) }
    }

    func comment(_ text: String, on post: Int64, replyTo: Int64?) async {
        await act(post) { _ = try await $0.comment(FeedCommentNew(text: text, replyTo: replyTo), on: post) }
    }

    func remove(_ comment: FeedComment, on post: Int64) async {
        await act(post) { try await $0.removeComment(comment.number, on: post) }
    }

    func remove(_ post: FeedPost) async {
        guard let client = live.server else { return }
        do {
            try await client.removePost(post.number)
            posts.removeAll { $0.number == post.number }
        } catch {
            failure = "没删掉：\(error)"
        }
    }

    /// Posts your own: the words, and the pictures, uploaded first.
    func post(_ text: String, pictures: [Data]) async throws {
        guard let client = live.server else { return }
        var images: [ContentHash] = []
        for data in pictures {
            images.append(try await client.upload(data, type: "image/jpeg").hash)
        }
        _ = try await client.post(FeedPostNew(text: text, images: images))
        await load()
    }

    private func act(_ post: Int64, _ doing: (FlooClient) async throws -> Void) async {
        guard let client = live.server else { return }
        do {
            try await doing(client)
        } catch {
            failure = "没成：\(error)"
            return
        }
        await reread(post)
    }

    // MARK: Showing

    func face(_ author: Participant) -> FlooAgent { live.feedFace(author, name: names[author.account]) }

    func icon(_ author: Participant) -> URL? {
        guard author.account == me, case .agent(.service(let service)) = author.actor else { return nil }
        return icons[service]
    }

    /// Yours or one of your agents'.
    func mine(_ author: Participant) -> Bool { author.account == me }

    /// The cards its fences came to, each drawn once, in the order they stand.
    func cards(of post: FeedPost) -> [CardSession] {
        post.blocks.compactMap { block in
            guard case .card(let card) = block, let source = card.source else { return nil }
            let key = "\(post.number)-\(card.fence)-\(card.item)"
            if let session = cards[key] { return session }
            let session = CardSession(data: FlooLive.cardData(card.data))
            session.append(source)
            session.finish()
            cards[key] = session
            return session
        }
    }

    /// How a post's picture is reached when the device hasn't it: through the post (it may be
    /// someone else's, which the server gives by hash to its owner only), its link asked for
    /// each time it's needed; the bytes are kept by their hash (FlooMedia).
    func reach(_ index: Int, of post: Int64) -> FlooMedia.Reach {
        let client = live.server
        return FlooMedia.Reach(byHash: false) {
            guard let client else { throw CancellationError() }
            return try await client.feedImage(index, of: post)
        }
    }
}

/// A picture in a post: one it was posted with, or one its words show.
struct FlooFeedPicture: Hashable, Identifiable {
    enum Source: Hashable {
        /// The post's, its index, and the picture.
        case posted(Int64, Int, MediaRef)
        case web(URL)
    }

    let source: Source
    /// Its width over its height, when known.
    var aspect: CGFloat?

    var id: String {
        switch source {
        case .posted(let post, let index, _): "\(post)/\(index)"
        case .web(let url): url.absoluteString
        }
    }
}

/// What a post's words come to on the page.
enum FlooFeedText {
    /// Its words as shown: its fences out (their cards and what they point at show under
    /// them), its pictures out (in the grid).
    static func words(_ text: String) -> String {
        text.replacingOccurrences(of: fence, with: "", options: .regularExpression)
            .replacingOccurrences(of: image, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Its pictures: those it was posted with, then those its words show from the web.
    static func pictures(of post: FeedPost) -> [FlooFeedPicture] {
        let posted = post.images.enumerated().map { index, media in
            FlooFeedPicture(
                source: .posted(post.number, index, media),
                aspect: media.width.flatMap { width in media.height.map { CGFloat(width) / CGFloat(max(1, $0)) } }
            )
        }
        let shown = post.text.matches(of: /!\[[^\]\n]*\]\(\s*<?(https?:[^)\s>]+)>?[^)]*\)/).compactMap { match in
            URL(string: String(match.output.1)).map { FlooFeedPicture(source: .web($0)) }
        }
        return posted + shown
    }

    static func attributed(_ words: String) -> AttributedString {
        (try? AttributedString(markdown: words, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))  // try?: plain then
            ?? AttributedString(words)
    }

    /// More than Moments shows before 全文.
    static func long(_ words: String) -> Bool {
        words.count > 150 || words.split(separator: "\n", omittingEmptySubsequences: false).count > 6
    }

    /// When, as Moments says it: just now, minutes or hours ago, yesterday, then the day.
    static func when(_ date: Date) -> String {
        let minutes = Int(FlooClock.now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes)分钟前" }
        let day = FlooDay.label(date)
        if day == "今天" { return "\(minutes / 60)小时前" }
        return day
    }

    /// The symbol for what a mention points at, where a service's album shows it small.
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "contact": "person.crop.circle"
        case "mail": "envelope"
        case "message": "message"
        case "web": "safari"
        case "doc", "file": "doc.text"
        case "conversation": "bubble.left.and.bubble.right"
        case "event": "calendar"
        case "place": "mappin.and.ellipse"
        case "task": "checklist"
        case "code": "chevron.left.forwardslash.chevron.right"
        default: "note.text"
        }
    }

    private static let fence = "```floo\\.[\\s\\S]*?```"
    private static let image = #"!\[[^\]\n]*\]\(\s*<?[^)\s>]+>?(?:\s+"[^"\n]*")?\s*\)"#
}

extension Color {
    /// The blue-grey of names and links in Moments.
    static let flooFeedName = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.49, green: 0.56, blue: 0.66, alpha: 1)
            : UIColor(red: 0.34, green: 0.42, blue: 0.58, alpha: 1)
    })
    /// The grey under a post's likes and comments, and behind a shared link.
    static let flooFeedBox = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.13, alpha: 1) : UIColor(white: 0.97, alpha: 1)
    })
}

// MARK: - The page

/// The feed in a sheet: the timeline, a person's or agent's own posts a tap on them away,
/// posting and following from its bar.
struct FlooFeedSheet: View {
    let live: FlooLive
    @State private var feed: FlooFeed
    @State private var writes = false
    @State private var showsFollows = false
    @Environment(\.dismiss) private var dismiss

    init(live: FlooLive) {
        self.live = live
        _feed = State(initialValue: FlooFeed(live: live))
    }

    var body: some View {
        NavigationStack {
            FlooFeedView(feed: feed)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("关注", systemImage: "person.2") { showsFollows = true }
                        Button("发表", systemImage: "camera") { writes = true }
                    }
                }
                .navigationDestination(for: Participant.self) { author in
                    FlooFeedView(feed: FlooFeed(live: live, from: author))
                }
        }
        .sheet(isPresented: $writes) { FlooFeedCompose(feed: feed) }
        .sheet(isPresented: $showsFollows, onDismiss: { Task { await feed.load() } }) {
            FlooFeedFollows(live: live)
        }
    }
}

/// Where a comment is being written: under which post, replying to whom.
struct FlooFeedReply: Equatable {
    let post: Int64
    var to: Int64?
    var name: String?
}

/// Moments: a cover with your name, then the posts, newest first; one person's or agent's
/// alone under their name.
struct FlooFeedView: View {
    @State var feed: FlooFeed
    @State private var acting: Int64?
    @State private var replying: FlooFeedReply?
    @State private var reply = ""
    @State private var removing: FeedPost?
    @FocusState private var typing: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if feed.from == nil { cover }
                ForEach(feed.posts, id: \.number) { post in
                    FlooFeedRow(feed: feed, post: post, acting: $acting, replying: $replying, removing: $removing)
                        .onAppear {
                            if post.number == feed.posts.last?.number { Task { await feed.older() } }
                        }
                    Divider()
                }
                if feed.loaded, feed.posts.isEmpty {
                    Text("还没有动态")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                }
                if let failure = feed.failure {
                    Text(failure).font(.footnote).foregroundStyle(.red).padding(16)
                }
            }
            .padding(.bottom, 40)
        }
        .onScrollPhaseChange { _, phase in
            if phase != .idle { acting = nil }
        }
        .refreshable { await feed.load() }
        .task { await feed.load() }
        .safeAreaInset(edge: .bottom) {
            if let replying { replyBar(replying) }
        }
        .onChange(of: replying) { _, now in
            reply = ""
            typing = now != nil
        }
        .onChange(of: typing) { _, now in
            if !now, reply.isEmpty { replying = nil }
        }
        .confirmationDialog("删除这条动态？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let removing { Task { await feed.remove(removing) } }
            }
        }
        .navigationTitle(feed.from.map { feed.face($0).name } ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var cover: some View {
        let me = feed.face(.person(feed.me))
        return ZStack(alignment: .bottomTrailing) {
            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.5)], startPoint: .top, endPoint: .bottom)
                .frame(height: 260)
            HStack(alignment: .bottom, spacing: 14) {
                Text(me.name)
                    .font(.title3.weight(.bold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                    .padding(.bottom, 26)
                FlooServiceIcon(url: nil, name: me.name, tint: me.tint, size: 68)
                    .overlay(FlooIconShape().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
            }
            .padding(.trailing, 14)
            .offset(y: 20)
        }
        .padding(.bottom, 44)
    }

    private func replyBar(_ replying: FlooFeedReply) -> some View {
        HStack(spacing: 8) {
            TextField(replying.name.map { "回复\($0)" } ?? "评论", text: $reply, axis: .vertical)
                .lineLimit(1...4)
                .focused($typing)
                .onSubmit(send)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Button("发送", action: send)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let replying, !text.isEmpty else { return }
        reply = ""
        self.replying = nil
        Task { await feed.comment(text, on: replying.post, replyTo: replying.to) }
    }
}

/// One post as Moments lays it out: the face, name, words, pictures, cards and links; when and
/// the ·· that likes or comments; the likes and comments under it.
struct FlooFeedRow: View {
    let feed: FlooFeed
    let post: FeedPost
    @Binding var acting: Int64?
    @Binding var replying: FlooFeedReply?
    @Binding var removing: FeedPost?
    @State private var whole = false
    @State private var removingComment: FeedComment?
    @Environment(\.openURL) private var openURL

    var body: some View {
        let face = feed.face(post.author)
        HStack(alignment: .top, spacing: 10) {
            toAlbum { FlooServiceIcon(url: feed.icon(post.author), name: face.name, tint: face.tint, size: 42) }
            VStack(alignment: .leading, spacing: 6) {
                toAlbum {
                    Text(face.name).font(.body.weight(.semibold)).foregroundStyle(Color.flooFeedName)
                }
                words
                pictures
                ForEach(Array(feed.cards(of: post).enumerated()), id: \.offset) { _, session in
                    CardView(tree: session.tree)
                        .frame(width: 232, alignment: .topLeading)
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                mentions
                footer
                under
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .confirmationDialog("删除这条评论？", isPresented: Binding(get: { removingComment != nil }, set: { if !$0 { removingComment = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let removingComment { Task { await feed.remove(removingComment, on: post.number) } }
            }
        }
    }

    /// A tap on the face or name opens their posts, except on their own page.
    @ViewBuilder private func toAlbum<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        if feed.from == nil {
            NavigationLink(value: post.author, label: label).buttonStyle(.plain)
        } else {
            label()
        }
    }

    @ViewBuilder private var words: some View {
        let words = FlooFeedText.words(post.text)
        if !words.isEmpty {
            Text(FlooFeedText.attributed(words))
                .font(.body)
                .lineLimit(whole ? nil : 6)
                .textSelection(.enabled)
            if FlooFeedText.long(words) {
                Button(whole ? "收起" : "全文") { whole.toggle() }
                    .font(.body).foregroundStyle(Color.flooFeedName).buttonStyle(.plain)
            }
        }
    }

    /// One picture as large as it is, within a square; four as two by two; others three across.
    @ViewBuilder private var pictures: some View {
        let pictures = FlooFeedText.pictures(of: post)
        if pictures.count == 1, let picture = pictures.first {
            FlooFeedPictureView(feed: feed, picture: picture)
        } else if !pictures.isEmpty {
            let across = pictures.count == 4 ? 2 : 3
            Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(Array(stride(from: 0, to: pictures.count, by: across)), id: \.self) { start in
                    GridRow {
                        ForEach(pictures[start..<min(start + across, pictures.count)]) { picture in
                            FlooFeedPictureView(feed: feed, picture: picture, side: 82)
                        }
                    }
                }
            }
        }
    }

    /// What its fences point at, as the chat shows them: one card of them all, a view
    /// mention's rows as its view draws them. A tap opens a mention's link, if it has one.
    @ViewBuilder private var mentions: some View {
        let mentions = post.blocks.compactMap { block -> Mention? in
            if case .mention(let mention) = block { feed.live.mention(mention) } else { nil }
        }
        if !mentions.isEmpty {
            MentionList(mentions, now: FlooClock.now) { mention in
                guard let url = mention.url else { return }
                if url.scheme == "floo" { feed.live.open(link: url.absoluteString) } else if url.scheme != nil { openURL(url) }
            }
            .frame(width: 256, alignment: .topLeading)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(FlooFeedText.when(post.at.date)).font(.caption).foregroundStyle(.secondary)
            if feed.mine(post.author) {
                Button("删除") { removing = post }
                    .font(.caption).foregroundStyle(Color.flooFeedName).buttonStyle(.plain)
            }
            Spacer()
            Button {
                withAnimation(.snappy(duration: 0.2)) { acting = acting == post.number ? nil : post.number }
            } label: {
                HStack(spacing: 3) {
                    Circle().frame(width: 4, height: 4)
                    Circle().frame(width: 4, height: 4)
                }
                .foregroundStyle(Color.flooFeedName)
                .frame(width: 32, height: 20)
                .background(Color.flooFeedBox, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
        // On the row, not the button: a tap lands only within what it's on.
        .overlay(alignment: .trailing) {
            if acting == post.number {
                menu
                    .padding(.trailing, 40)
                    .transition(.opacity.combined(with: .scale(scale: 0.5, anchor: .trailing)))
            }
        }
    }

    /// The dark strip ·· slides out: like (or take it back) and comment.
    private var menu: some View {
        let liked = feed.liked(post)
        return HStack(spacing: 0) {
            Button {
                acting = nil
                Task { await feed.like(post) }
            } label: {
                Label(liked ? "取消" : "赞", systemImage: liked ? "heart.fill" : "heart").frame(width: 86, height: 38)
            }
            Rectangle().fill(.black.opacity(0.3)).frame(width: 0.5, height: 20)
            Button {
                acting = nil
                replying = FlooFeedReply(post: post.number)
            } label: {
                Label("评论", systemImage: "bubble.left").frame(width: 86, height: 38)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .labelStyle(.titleAndIcon)
        .buttonStyle(.plain)
        .background(Color(white: 0.3), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .fixedSize()
    }

    /// The likes, a heart before their names, then the comments, on grey under a small tip.
    @ViewBuilder private var under: some View {
        if !post.likes.isEmpty || !post.comments.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if !post.likes.isEmpty {
                    (Text(Image(systemName: "heart")) + Text(" " + post.likes.map { feed.face($0.author).name }.joined(separator: ", ")))
                        .font(.subheadline)
                        .foregroundStyle(Color.flooFeedName)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                }
                if !post.likes.isEmpty, !post.comments.isEmpty {
                    Divider()
                }
                if !post.comments.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(post.comments, id: \.number) { comment in
                            commentLine(comment)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.flooFeedBox)
            .overlay(alignment: .topLeading) {
                FlooFeedTip().fill(Color.flooFeedBox).frame(width: 12, height: 6).offset(x: 12, y: -6)
            }
            .padding(.top, 6)
        }
    }

    /// A comment: its writer, whom it replies to, what it says. A tap on yours takes it
    /// back; on another's, replies.
    private func commentLine(_ comment: FeedComment) -> some View {
        let name = feed.face(comment.author).name
        let to = comment.replyTo.flatMap { number in post.comments.first { $0.number == number } }
        var line = Text(name).foregroundStyle(Color.flooFeedName).fontWeight(.medium)
        if let to {
            line = line + Text(" 回复 ") + Text(feed.face(to.author).name).foregroundStyle(Color.flooFeedName).fontWeight(.medium)
        }
        let mine = feed.mine(comment.author)
        return Button {
            if mine {
                removingComment = comment
            } else {
                replying = FlooFeedReply(post: post.number, to: comment.number, name: name)
            }
        } label: {
            (line + Text("：" + comment.text))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !mine {
                Button("回复", systemImage: "arrowshape.turn.up.left") {
                    replying = FlooFeedReply(post: post.number, to: comment.number, name: name)
                }
            }
            // Yours, or under your side's post.
            if mine || feed.mine(post.author) {
                Button("删除", systemImage: "trash", role: .destructive) { removingComment = comment }
            }
        }
    }
}

/// The small tip above the likes and comments, pointing up at the post.
struct FlooFeedTip: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

struct FlooFeedPictureView: View {
    let feed: FlooFeed
    let picture: FlooFeedPicture
    /// Its side in a grid; nil alone, as wide or high as Moments shows one, in its own shape
    /// (a square when the post didn't say).
    var side: CGFloat?

    private var size: CGSize {
        if let side { return CGSize(width: side, height: side) }
        guard let aspect = picture.aspect else { return CGSize(width: 160, height: 160) }
        return aspect >= 1
            ? CGSize(width: 180, height: max(80, 180 / aspect))
            : CGSize(width: max(80, 180 * aspect), height: 180)
    }

    var body: some View {
        ZStack {
            Color.primary.opacity(0.06)
            // Its ThumbHash, then the picture decoded at this size, from the account's cache;
            // one from the web through the same decoded images, fetched when not among them.
            switch picture.source {
            case .posted(let post, let index, let media):
                FlooMediaImage(media: media, use: ContentUse(.image, keep: .others), reach: feed.reach(index, of: post))
            case .web(let url):
                CardAsyncImage(url: url.absoluteString, thumbhash: nil) {
                    try? await URLSession.shared.data(from: url).0  // try?: the placeholder stays
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

// MARK: - Posting

/// A post of your own: words and up to nine pictures.
struct FlooFeedCompose: View {
    let feed: FlooFeed
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var picking = false
    @State private var images: [UIImage] = []
    @State private var sending = false
    @State private var failure: String?

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("这一刻的想法…", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 6), count: 3), alignment: .leading, spacing: 6) {
                        ForEach(images.indices, id: \.self) { index in
                            Image(uiImage: images[index]).resizable().scaledToFill()
                                .frame(width: 96, height: 96).clipped()
                                .overlay(alignment: .topTrailing) {
                                    Button("移除", systemImage: "xmark.circle.fill") { images.remove(at: index) }
                                        .labelStyle(.iconOnly)
                                        .foregroundStyle(.white, .black.opacity(0.5))
                                        .buttonStyle(.plain)
                                        .padding(4)
                                }
                        }
                        if images.count < 9 {
                            Button { picking = true } label: {
                                Image(systemName: "plus")
                                    .font(.title).foregroundStyle(.secondary)
                                    .frame(width: 96, height: 96)
                                    .background(Color.flooFeedBox)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let failure {
                        Text(failure).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("发表", action: send).disabled(empty)
                    }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                for url in (try? result.get()) ?? [] where images.count < 9 {  // try?: none picked
                    let open = url.startAccessingSecurityScopedResource()
                    defer { if open { url.stopAccessingSecurityScopedResource() } }
                    // try?: a picture that can't be read is left out
                    if let data = try? Data(contentsOf: url), let image = UIImage(data: data) { images.append(image) }
                }
            }
        }
    }

    private func send() {
        sending = true
        failure = nil
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pictures = images.compactMap { $0.jpegData(compressionQuality: 0.85) }
        Task {
            do {
                try await feed.post(text, pictures: pictures)
                dismiss()
            } catch {
                failure = "没发出去：\(error)"
            }
            sending = false
        }
    }
}

// MARK: - Following

/// Whom you follow and who follows you: asks to let in, people to follow by their email.
struct FlooFeedFollows: View {
    let live: FlooLive
    @Environment(\.dismiss) private var dismiss
    @State private var follows: FeedFollows?
    @State private var email = ""
    @State private var finding = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                if let follows {
                    if !follows.asking.isEmpty {
                        Section("请求关注你") {
                            ForEach(follows.asking, id: \.self) { account in
                                HStack {
                                    Text(name(account))
                                    Spacer()
                                    Button("拒绝") { Task { await act { try await $0.letFollow(account, false) } } }
                                        .buttonStyle(.bordered)
                                    Button("同意") { Task { await act { try await $0.letFollow(account) } } }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }
                    Section("关注") {
                        ForEach(follows.following, id: \.self) { account in
                            Text(name(account))
                                .swipeActions {
                                    Button("取消关注", role: .destructive) { Task { await act { try await $0.follow(account, false) } } }
                                }
                        }
                        ForEach(follows.asked, id: \.self) { account in
                            HStack {
                                Text(name(account))
                                Spacer()
                                Text("等待同意").foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                Button("撤回", role: .destructive) { Task { await act { try await $0.follow(account, false) } } }
                            }
                        }
                        HStack {
                            TextField("对方的邮箱", text: $email)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onSubmit(follow)
                            if finding {
                                ProgressView()
                            } else {
                                Button("关注", action: follow).disabled(!email.contains("@"))
                            }
                        }
                    }
                    if !follows.followers.isEmpty {
                        Section("关注你的") {
                            ForEach(follows.followers, id: \.self) { account in
                                Text(name(account))
                                    .swipeActions {
                                        Button("移除", role: .destructive) { Task { await act { try await $0.letFollow(account, false) } } }
                                    }
                            }
                        }
                    }
                }
                if let failure {
                    Text(failure).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("关注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func name(_ account: AccountID) -> String {
        follows?.people.first { $0.account == account }?.name ?? "没有名字的成员"
    }

    private func load() async {
        guard let client = live.server else { return }
        do {
            follows = try await client.follows()
        } catch {
            failure = "没读到：\(error)"
        }
    }

    private func act(_ doing: (FlooClient) async throws -> Void) async {
        guard let client = live.server else { return }
        do {
            try await doing(client)
            failure = nil
        } catch {
            failure = "没成：\(error)"
        }
        await load()
    }

    private func follow() {
        let email = email.trimmingCharacters(in: .whitespaces)
        guard email.contains("@"), !finding else { return }
        finding = true
        Task {
            await act { client in
                guard let found = try await live.person(email: email) else { throw FlooFeedNotFound() }
                try await client.follow(found.account)
            }
            if failure == nil { self.email = "" }
            finding = false
        }
    }
}

struct FlooFeedNotFound: Error, CustomStringConvertible {
    var description: String { "没有用这个邮箱的人" }
}
