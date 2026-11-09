//
//  CatalogDestination.swift
//  DemoApp
//
//  Every style MarkdownView draws, on one page, and the same list drawn to PNGs:
//
//      -openTab catalog -catalogShots <dir> [-catalogWidth 390] [-catalogDark YES]
//                       [-catalogOnly id,id] [-catalogRenderer swiftui|uikit]
//                       [-catalogRevealProbe YES]
//
//  With -catalogRevealProbe YES the list is frames in the middle of a reveal (CatalogReveal).
//
//  Scripts/markdown-catalog.sh runs it; Scripts/markdown-pixel-diff.swift compares two sets.
//

import MarkdownView
import SwiftUI
import UIKit

// MARK: - A fixture on screen

/// One fixture as its path draws it. This is the baseline: another renderer draws the same
/// fixture next to it.
struct CatalogFixtureView: View {
    let fixture: CatalogFixture

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .catalogKnobs(fixture.knobs[...])
    }

    @ViewBuilder
    private var content: some View {
        switch fixture.path {
        case .stream:
            // Split as chat splits; blocks sit against each other, chat's rows add no space.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.blocks(of: fixture.markdown), id: \.id) { block in
                    MarkdownStreamBlockView(block)
                        .markdownDisplayMathRendersSynchronously()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .selectableText:
            MarkdownSelectableText(fixture.markdown)
        case .document:
            MarkdownView(fixture.markdown)
                .markdownMathRenderingEnabled()
        }
    }

    private static func blocks(of markdown: String) -> [MarkdownStreamBlock] {
        var splitter = MarkdownBlockSplitter()
        return splitter.split(markdown)
    }
}

// MARK: - The page

struct CatalogDestination: View {
    @State private var groupID = UserDefaults.standard.string(forKey: "catalogGroup") ?? CatalogFixtures.groups[0].id

    private var group: CatalogGroup {
        CatalogFixtures.groups.first { $0.id == groupID } ?? CatalogFixtures.groups[0]
    }

    /// `-catalogOnly id,id` narrows the page too, to look at a fixture where it really lays out.
    private var fixtures: [CatalogFixture] {
        guard let only = UserDefaults.standard.string(forKey: "catalogOnly") else { return group.fixtures }
        let ids = Set(only.split(separator: ",").map(String.init))
        return CatalogFixtures.all.filter { ids.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(CatalogFixtures.groups) { group in
                        Button(group.title) { groupID = group.id }
                            .buttonStyle(.bordered)
                            .tint(group.id == groupID ? .accentColor : .secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(fixtures) { fixture in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(fixture.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(fixture.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            CatalogFixtureView(fixture: fixture)
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: 752)
                .padding()
                .id(groupID)
            }
        }
        .task {
            CatalogImages.install()
            await CatalogThemeProbe.runIfAsked()
            await CatalogShots.runIfAsked()
        }
    }
}

// MARK: - Pictures with no network

/// Serves the fixtures' images, so a shot is the same every time. `never` doesn't answer (a
/// loading state), anything it doesn't know is a 404.
final class CatalogImages: URLProtocol {
    static let host = "catalog.test"

    @MainActor private static var installed = false

    @MainActor static func install() {
        guard !installed else { return }
        installed = true
        URLProtocol.registerClass(CatalogImages.self)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let name = url.lastPathComponent
        if name == "never.png" { return }
        guard let (data, type) = Self.body(named: name) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(named name: String) -> (Data, String)? {
        switch name {
        case "wide.png": picture(CGSize(width: 800, height: 400)).map { ($0, "image/png") }
        case "tall.png": picture(CGSize(width: 300, height: 600)).map { ($0, "image/png") }
        case "square.png": picture(CGSize(width: 120, height: 120)).map { ($0, "image/png") }
        case "drawing.svg":
            (Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="240" height="120" viewBox="0 0 240 120"><rect width="240" height="120" rx="12" fill="#3a7bd5"/><circle cx="60" cy="60" r="36" fill="#ffd166"/><path d="M110 90 L160 30 L210 90 Z" fill="#06d6a0"/></svg>"##.utf8), "image/svg+xml")
        default: nil
        }
    }

    /// A fixed picture: a gradient with a diagonal, so scaling and cropping show.
    private static func picture(_ size: CGSize) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            let colors = [UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1).cgColor, UIColor(red: 0.9, green: 0.5, blue: 0.3, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            UIColor.white.setStroke()
            context.cgContext.setLineWidth(4)
            context.cgContext.move(to: .zero)
            context.cgContext.addLine(to: CGPoint(x: size.width, y: size.height))
            context.cgContext.strokePath()
        }
    }
}

// MARK: - Shots

@MainActor
private final class CatalogMeasuredHeight {
    var height: CGFloat = 0
}

/// Draws fixtures to PNGs at a fixed width, each in a window of its own height, once its
/// picture has stopped changing (highlighting, maths and images arrive late).
@MainActor
enum CatalogShots {
    private struct Entry: Codable {
        let id: String
        let group: String
        let width: CGFloat
        let height: CGFloat
        let scale: CGFloat
        let settled: Bool
        let milliseconds: Int
    }

    static func runIfAsked() async {
        let defaults = UserDefaults.standard
        guard let directory = defaults.string(forKey: "catalogShots") else { return }
        let width = CGFloat(defaults.double(forKey: "catalogWidth") == 0 ? 390 : defaults.double(forKey: "catalogWidth"))
        let dark = defaults.bool(forKey: "catalogDark")
        let only = defaults.string(forKey: "catalogOnly").map { Set($0.split(separator: ",").map(String.init)) }
        let folder = URL(fileURLWithPath: directory)
        // Icons with no network: one fixed picture, or none for the host that shows the fallback.
        MarkdownLinkChips.prefetchIcon = nil
        MarkdownLinkChips.iconImage = { host in
            host == "noicon.test" ? nil : Image(systemName: "seal.fill")
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            print("CATALOG no scene")
            return
        }
        var entries: [Entry] = []
        let groups = defaults.bool(forKey: "catalogRevealProbe") ? [CatalogReveal.group] : CatalogFixtures.groups
        for group in groups {
            for fixture in group.fixtures where only?.contains(fixture.id) ?? true {
                entries.append(await shoot(fixture, group: group, width: width, dark: dark, scene: scene, folder: folder))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(entries).write(to: folder.appending(path: "manifest.json"))
        print("CATALOG done \(entries.count) fixtures, \(entries.filter { !$0.settled }.count) unsettled")
        if defaults.bool(forKey: "catalogQuit") { exit(0) }
    }

    private static func shoot(
        _ fixture: CatalogFixture,
        group: CatalogGroup,
        width: CGFloat,
        dark: Bool,
        scene: UIWindowScene,
        folder: URL
    ) async -> Entry {
        let started = Date()
        let style: UIUserInterfaceStyle = dark ? .dark : .light
        // A window that never changes size, with the fixture well below its top: a text view
        // in the top safe area gets the system's scroll edge blur, and a window resized under
        // a text view leaves its attachments where they were. The shot is cropped to the fixture.
        let top: CGFloat = 160
        let windowHeight: CGFloat = 2400
        let measured = CatalogMeasuredHeight()
        let root: UIViewController
        // Held still until the shot's taken; nil out of the reveal probe.
        let revealed = CatalogReveal.prepare(fixture)
        defer { CatalogReveal.finish() }
        if UserDefaults.standard.string(forKey: "catalogRenderer") == "uikit" {
            let host = UIViewController()
            let view = CatalogUIKitFixtureView(fixture: fixture, scale: scene.screen.scale, revealed: revealed)
            host.view.addSubview(view)
            // Off-window, as a list cell asks before it's shown.
            measured.height = view.height(forWidth: width)
            view.frame = CGRect(x: 0, y: top, width: width, height: measured.height)
            view.onHeightChange = { [weak view] in
                guard let view else { return }
                measured.height = view.height(forWidth: width)
                view.frame = CGRect(x: 0, y: top, width: width, height: measured.height)
            }
            root = host
        } else {
            let host = UIHostingController(rootView: AnyView(
                Group {
                    if let revealed {
                        CatalogRevealView(revealed: revealed)
                    } else {
                        CatalogFixtureView(fixture: fixture)
                    }
                }
                    .frame(width: width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { measured.height = $0 }
                    .padding(.top, top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea()
            ))
            host.safeAreaRegions = []
            root = host
        }
        root.overrideUserInterfaceStyle = style
        root.view.backgroundColor = .systemBackground

        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        window.frame = CGRect(x: 0, y: 0, width: width, height: windowHeight)
        window.rootViewController = root
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        var last: Data?
        var settled = false
        var height: CGFloat = 0
        // At least half a second; then until two pictures in a row, 250 ms apart, are the same.
        for attempt in 0..<(fixture.waitsForImages ? 40 : 24) {
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? (fixture.waitsForImages ? 1500 : 500) : 250))
            height = max(1, measured.height.rounded(.up))
            let format = UIGraphicsImageRendererFormat()
            format.scale = scene.screen.scale
            format.opaque = true
            let bounds = window.bounds
            var drawn = false
            let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { _ in
                drawn = window.drawHierarchy(in: bounds.offsetBy(dx: 0, dy: -top), afterScreenUpdates: true)
            }
            // A failed draw is a black picture, the same every time: not settled.
            guard drawn else {
                last = nil
                continue
            }
            if image == last {
                settled = true
                break
            }
            last = image
        }
        if let last {
            try? last.write(to: folder.appending(path: "\(fixture.id).png"))
        }
        return Entry(
            id: fixture.id,
            group: group.id,
            width: width,
            height: height,
            scale: scene.screen.scale,
            settled: settled,
            milliseconds: Int(Date().timeIntervalSince(started) * 1000)
        )
    }
}
