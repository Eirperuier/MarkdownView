//
//  FlooLooking.swift
//  DemoApp
//
//  The cards that keep updating on this device's screen, as the server is told them (floo
//  docs/processing.md §1 正在看, §4): a card that only follows its tool is kept fresh only while
//  someone looks at it. The server keeps them wanted for five minutes after each beat of the
//  device's mailbox stream, written with that machine's other devices, so nothing is sent
//  again while they stay: only the set, as it changes.
//

import CardUI
import Foundation
import SwiftUI
import TransportKit
import Wire

@MainActor
final class FlooLooking {
    static let shared = FlooLooking()

    /// The client the account goes by now; nil before there is one.
    private var client: FlooClient?
    /// Each use's card drawn now (`AnswerCard.Live.id`), as many times as it's drawn.
    private var drawn: [String: Int] = [:]
    /// The app is in the background: none is looked at.
    private var away = false
    /// What the server was last told.
    private var told: Set<String> = []
    private var telling: Task<Void, Never>?
    /// The mailbox stream, open while any is looked at: its beat keeps them wanted.
    private var beating: Task<Void, Never>?

    /// The client the account goes by now: told again through it.
    func use(_ client: FlooClient) {
        self.client = client
        told = []
        beating?.cancel()
        beating = nil
        changed()
    }

    func appeared(_ use: String) {
        drawn[use, default: 0] += 1
        changed()
    }

    func disappeared(_ use: String) {
        guard let count = drawn[use] else { return }
        drawn[use] = count > 1 ? count - 1 : nil
        changed()
    }

    /// The app went to the background, or came back.
    func setAway(_ away: Bool) {
        guard away != self.away else { return }
        self.away = away
        changed()
    }

    private var looking: Set<String> { away ? [] : Set(drawn.keys) }

    /// Told a moment after the set changes, so a scroll past a card says it once.
    private func changed() {
        telling?.cancel()
        telling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))  // try?: a newer change cancels it
            guard !Task.isCancelled else { return }
            await self?.tell()
        }
    }

    private func tell() async {
        let now = looking
        follow(!now.isEmpty)
        guard let client, now != told else { return }
        var state = DeviceState()
        state.looking = now.sorted()
        do {
            try await client.report(state)
            told = now
        } catch {
            // Told again at the next change; meanwhile what was told lasts its five minutes.
        }
    }

    /// The device's mailbox stream, open while `open`: the stream reconnects by itself, and
    /// what it brings is for the device's services, which run elsewhere (the App, Floo Helper).
    private func follow(_ open: Bool) {
        guard open else {
            beating?.cancel()
            beating = nil
            return
        }
        guard beating == nil, let client else { return }
        beating = Task {
            while !Task.isCancelled {
                do { for try await _ in client.mailbox() {} } catch {}
                try? await Task.sleep(for: .seconds(5))  // try?: cancelled, it ends
            }
        }
    }
}

extension View {
    /// Says, while it's on the screen, that the card `session` shows is looked at
    /// (FlooLooking): one that keeps updating, once its first version came; nothing for one
    /// drawn once.
    func flooLooking(_ session: CardSession?) -> some View {
        modifier(FlooLooked(use: session?.use))
    }
}

private struct FlooLooked: ViewModifier {
    let use: String?
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                visible = true
                if let use { FlooLooking.shared.appeared(use) }
            }
            .onDisappear {
                visible = false
                if let use { FlooLooking.shared.disappeared(use) }
            }
            .onChange(of: use) { old, new in
                guard visible else { return }
                if let old { FlooLooking.shared.disappeared(old) }
                if let new { FlooLooking.shared.appeared(new) }
            }
    }
}
