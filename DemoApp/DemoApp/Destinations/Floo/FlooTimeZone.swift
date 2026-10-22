//
//  FlooTimeZone.swift
//  DemoApp
//
//  The person's usual time zone (floo docs/time.md §6.1): asked once after signing in, when
//  the account has none, and changed from the account menu. The agents say times and lay
//  reminders by it; away from home, by where the phone is. Only these two screens set it.
//

import Synchronization
import SwiftUI
import Wire

/// The zone asked for after signing in: the one picked so far, until it's confirmed.
@MainActor
@Observable
final class FlooZoneChoice {
    var zone: ZoneName
    @ObservationIgnored private var waiting: CheckedContinuation<ZoneName, Never>?

    /// `zone`: where their phone says they are, else this device's.
    init(zone: ZoneName) {
        self.zone = zone
    }

    /// The zone once it's confirmed.
    func chosen() async -> ZoneName {
        await withCheckedContinuation { waiting = $0 }
    }

    func confirm() {
        waiting?.resume(returning: zone)
        waiting = nil
    }
}

/// The step after signing in, in the middle of the chat page.
struct FlooZoneChoiceView: View {
    @Bindable var model: FlooZoneChoice
    @State private var picking = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("你的时区")
                    .font(.title2.weight(.semibold))
                Text("floo 按这个时区和你说时间、安排提醒。带着手机出门时，按手机所在地的时间。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                picking = true
            } label: {
                HStack {
                    FlooZoneLabel(zone: model.zone)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            Button {
                model.confirm()
            } label: {
                Text("继续").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: 340)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $picking) {
            FlooZonePicker(selected: model.zone) { model.zone = $0 }
        }
    }
}

/// A zone as a row says it: what it's called here, and its city and offset now.
struct FlooZoneLabel: View {
    let zone: ZoneName

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(FlooZones.name(of: zone))
            Text(FlooZones.detail(of: zone))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Every zone the system knows, to search and pick one.
struct FlooZonePicker: View {
    let selected: ZoneName?
    let pick: (ZoneName) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(FlooZones.matching(query), id: \.identifier) { zone in
                Button {
                    pick(zone)
                    dismiss()
                } label: {
                    HStack {
                        FlooZoneLabel(zone: zone)
                        Spacer()
                        if zone == selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "城市或时区")
            .navigationTitle("时区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }
}

/// What time it is for the person, where the demo says "today" or "3 minutes ago": this
/// device's clock, or on a lab stage the lab's, which a scene moves (floo docs/time.md §8).
enum FlooClock {
    /// The lab's clock ahead of this device's, as last asked.
    private static let offset = Mutex<TimeInterval>(0)

    static var now: Date { Date().addingTimeInterval(offset.withLock { $0 }) }

    /// Keeps up with a lab stage's clock at `base`, every few seconds as a scene moves it.
    static func follow(lab base: URL) async {
        struct Info: Decodable { let epochMilliseconds: Int64 }
        while !Task.isCancelled {
            if let (data, _) = try? await URLSession.shared.data(from: base.appending(path: "lab/info")),  // try?: asked again soon
                let info = try? JSONDecoder().decode(Info.self, from: data)  // try?: an older stage says no time
            {
                offset.withLock { $0 = Double(info.epochMilliseconds) / 1000 - Date().timeIntervalSince1970 }
            }
            try? await Task.sleep(for: .seconds(5))  // try?: cancelled, the loop ends
        }
    }
}

/// A day as people are shown it, from this device's calendar when it's shown: 今天, 昨天,
/// 10月6日, or with its year when it isn't this one's.
enum FlooDay {
    static func label(_ date: Date) -> String {
        let calendar = Calendar.current  // time: shown on this device, by its calendar
        let today = calendar.startOfDay(for: FlooClock.now)
        let day = calendar.startOfDay(for: date)
        if day == today { return "今天" }
        if calendar.date(byAdding: .day, value: 1, to: day) == today { return "昨天" }
        let month = calendar.component(.month, from: date)
        let number = calendar.component(.day, from: date)
        let year = calendar.component(.year, from: date)
        return year == calendar.component(.year, from: today) ? "\(month)月\(number)日" : "\(year)年\(month)月\(number)日"
    }
}

enum FlooZones {
    /// The system's zones of places (not `Etc/…` offsets), by their offset now, then city.
    static let all: [ZoneName] = TimeZone.knownTimeZoneIdentifiers
        .filter { $0.contains("/") && !$0.hasPrefix("Etc/") }
        .compactMap(ZoneName.init)
        .sorted { (offset(of: $0), city(of: $0)) < (offset(of: $1), city(of: $1)) }

    static func matching(_ query: String) -> [ZoneName] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { zone in
            [zone.identifier, city(of: zone), name(of: zone)].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// "中国标准时间", as the system names it in Chinese; its city when it has no name.
    static func name(of zone: ZoneName) -> String {
        TimeZone(identifier: zone.identifier)?.localizedName(for: .generic, locale: Locale(identifier: "zh_CN"))
            ?? city(of: zone)
    }

    /// "Shanghai · GMT+8".
    static func detail(of zone: ZoneName) -> String {
        "\(city(of: zone)) · \(ZoneName.offsetName(offset(of: zone)).replacingOccurrences(of: "UTC", with: "GMT"))"
    }

    /// "Los Angeles" of America/Los_Angeles.
    static func city(of zone: ZoneName) -> String {
        (zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier)
            .replacingOccurrences(of: "_", with: " ")
    }

    static func offset(of zone: ZoneName) -> Int {
        zone.offset(at: .now)
    }
}
