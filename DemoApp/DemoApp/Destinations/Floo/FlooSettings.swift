//
//  FlooSettings.swift
//  DemoApp
//
//  A provider's settings, as floo docs/service-settings.md §3.2 has the App draw them: one
//  page for any service, from the format in the provider's own definition. Each key's control
//  and its limits follow from its data type; one that picks from something lists what the
//  operation its `choices` name gives (its output's properties for the label, color and
//  group). The format and the words are the real ones (FlooSettings.json, exported by
//  DemoApp/Scripts/floo-catalog.py); the calendars each device lists, and the files, are
//  scripted. `-flooContactsPath "service:calendar settings:calendar:iphone"` opens one.
//

import SwiftUI

// MARK: - JSON as the formats are written

/// A JSON value, read as it is written (the keys of a format are names, not Swift's).
enum FlooJSON: Decodable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([FlooJSON])
    case object([String: FlooJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }  // try?: another kind
        else if let value = try? container.decode(Double.self) { self = .number(value) }  // try?: as above
        else if let value = try? container.decode(String.self) { self = .string(value) }  // try?: as above
        else if let value = try? container.decode([FlooJSON].self) { self = .array(value) }  // try?: as above
        else { self = .object(try container.decode([String: FlooJSON].self)) }
    }

    subscript(key: String) -> FlooJSON? {
        if case .object(let fields) = self { fields[key] } else { nil }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var items: [FlooJSON] { if case .array(let values) = self { values } else { [] } }
    var fields: [String: FlooJSON] { if case .object(let fields) = self { fields } else { [:] } }
}

/// What a setting is called and a line on it, from the words layer.
struct FlooSettingWords: Decodable, Hashable {
    var title: String?
    var summary: String?
}

/// A service's settings format and its settings' words, by language.
struct FlooSettingsFormat: Decodable {
    let format: FlooJSON
    let words: [String: [String: FlooSettingWords]]

    static let all: [String: FlooSettingsFormat] = {
        guard let url = Bundle.main.url(forResource: "FlooSettings", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }  // try?: the demo shows none
        return (try? JSONDecoder().decode([String: FlooSettingsFormat].self, from: data)) ?? [:]  // try?: as above
    }()

    /// Its keys, as the format lists them.
    var keys: [String] { format["properties"]?.fields.keys.sorted() ?? [] }

    /// Chinese, then English, then the format's own words, then the key.
    func title(_ key: String) -> String {
        words["zh-Hans"]?[key]?.title ?? words["en"]?[key]?.title
            ?? format["properties"]?[key]?["title"]?.string ?? key
    }

    func summary(_ key: String) -> String? {
        words["zh-Hans"]?[key]?.summary ?? words["en"]?[key]?.summary
            ?? format["properties"]?[key]?["description"]?.string
    }
}

// MARK: - What the operations list (scripted)

enum FlooListed {
    /// What `operation` of `service` last answered on `device`: the calendars it has.
    static func answer(_ service: String, _ operation: String, on device: String) -> [FlooJSON] {
        guard service == "calendar", operation == "calendars" else { return [] }
        let calendars: [(String, String, String, String, Bool)] =
            switch device {
            case "iphone": [
                ("cal-work", "工作", "iCloud", "#1D7AF2", true),
                ("cal-home", "家", "iCloud", "#34C759", true),
                ("cal-therapy", "心理咨询", "iCloud", "#AF52DE", true),
                ("cal-team", "团队", "公司 Exchange", "#FF9500", true),
                ("cal-holidays", "中国节假日", "订阅的日历", "#FF3B30", false),
                ("cal-birthdays", "生日", "其他", "#8E8E93", false),
            ]
            default: [
                ("mac-work", "工作", "iCloud", "#1D7AF2", true),
                ("mac-home", "家", "iCloud", "#34C759", true),
                ("mac-local", "Mac 上的日历", "我的 Mac", "#FFCC00", true),
            ]
            }
        return calendars.map { id, title, account, color, writable in
            .object([
                "id": .string(id), "title": .string(title), "account": .string(account),
                "color": .string(color), "writable": .bool(writable),
            ])
        }
    }
}

// MARK: - The page

/// One provider's settings: each key drawn from its data type, changed by key.
struct FlooProviderSettingsPage: View {
    let demo: FlooContactsDemo
    let service: FlooService
    let device: FlooDevice
    let format: FlooSettingsFormat

    private var file: [String: FlooJSON] { demo.settings[service.id]?[device.id] ?? [:] }

    var body: some View {
        List {
            if !device.online {
                Section {
                    Label(
                        "\(device.name)\(device.lastSeen ?? "")在线。改好的设置存着，等它上线后照着做；下面的列表是它那时报的。",
                        systemImage: "moon.zzz"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            ForEach(format.keys, id: \.self) { key in
                if let schema = format.format["properties"]?[key] {
                    field(key, schema)
                }
            }
        }
        .navigationTitle("\(service.name) · \(device.name.replacingOccurrences(of: "这台 ", with: ""))")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func field(_ key: String, _ schema: FlooJSON) -> some View {
        if schema["type"]?.string == "array", let choices = schema["items"]?["choices"] {
            choiceSections(key, choices) { id in file[key]?.items.contains(.string(id)) == true } tap: { id in
                var picked = file[key]?.items ?? []
                if let index = picked.firstIndex(of: .string(id)) { picked.remove(at: index) } else {
                    picked.append(.string(id))
                }
                change(key, picked.isEmpty ? nil : .array(picked))
            }
        } else if let choices = schema["choices"] {
            choiceSections(key, choices, none: true) { id in file[key]?.string == id } tap: { id in
                change(key, .string(id))
            }
        } else {
            Section {
                plain(key, schema)
            } footer: {
                format.summary(key).map(Text.init)
            }
        }
    }

    /// What `choices.from` lists, filtered by `where`: a section for each `group`, the
    /// key's title over the first (over "none" when one may be left unpicked) and its words
    /// under the last.
    @ViewBuilder private func choiceSections(
        _ key: String,
        _ choices: FlooJSON,
        none: Bool = false,
        picked: @escaping (String) -> Bool,
        tap: @escaping (String) -> Void
    ) -> some View {
        let listed = FlooListed.answer(service.id, choices["from"]?.string ?? "", on: device.id).filter { item in
            (choices["where"]?.fields ?? [:]).allSatisfy { item[$0.key] == $0.value }
        }
        let keyed = { (item: FlooJSON, role: String) in choices[role]?.string.flatMap { item[$0]?.string } }
        let groups = listed.reduce(into: [String]()) { order, item in
            let group = keyed(item, "group") ?? ""
            if !order.contains(group) { order.append(group) }
        }
        if none {
            Section {
                row(title: "不选", tint: nil, picked: file[key] == nil) { change(key, nil) }
            } header: {
                Text(format.title(key)).font(.headline).foregroundStyle(.primary).textCase(nil)
            }
        }
        ForEach(Array(groups.enumerated()), id: \.element) { index, group in
            Section {
                ForEach(listed.filter { (keyed($0, "group") ?? "") == group }, id: \.self) { item in
                    if let id = keyed(item, "key") {
                        row(
                            title: keyed(item, "label") ?? id,
                            tint: keyed(item, "tint").flatMap(Color.init(hex:)),
                            picked: picked(id)
                        ) { tap(id) }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 10) {
                    if index == 0 && !none {
                        Text(format.title(key)).font(.headline).foregroundStyle(.primary).textCase(nil)
                    }
                    if !group.isEmpty { Text(group) }
                }
            } footer: {
                if index == groups.count - 1, let summary = format.summary(key) { Text(summary) }
            }
        }
    }

    private func row(title: String, tint: Color?, picked: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let tint { Circle().fill(tint).frame(width: 12, height: 12) }
                Text(title).foregroundStyle(.primary)
                Spacer()
                if picked { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A key that picks from nothing: its control is its type's.
    @ViewBuilder private func plain(_ key: String, _ schema: FlooJSON) -> some View {
        let title = format.title(key)
        switch schema["type"]?.string {
        case "boolean":
            Toggle(title, isOn: Binding(
                get: { file[key] == .bool(true) },
                set: { change(key, .bool($0)) }
            ))
        case "string" where !(schema["enum"]?.items.isEmpty ?? true):
            Picker(title, selection: Binding(
                get: { file[key]?.string ?? "" },
                set: { change(key, $0.isEmpty ? nil : .string($0)) }
            )) {
                ForEach(schema["enum"]?.items.compactMap(\.string) ?? [], id: \.self) { Text($0).tag($0) }
            }
        case "integer", "number":
            let low = schema["minimum"].flatMap { if case .number(let n) = $0 { Int(n) } else { nil } } ?? 0
            let high = schema["maximum"].flatMap { if case .number(let n) = $0 { Int(n) } else { nil } } ?? 1_000
            let value = { if case .number(let n)? = file[key] { Int(n) } else { low } }()
            Stepper("\(title)：\(value)", value: Binding(
                get: { value },
                set: { change(key, .number(Double($0))) }
            ), in: low...high)
        default:
            TextField(title, text: Binding(
                get: { file[key]?.string ?? "" },
                set: { change(key, $0.isEmpty ? nil : .string($0)) }
            ))
        }
    }

    /// One key set or removed; the others stay (`ProviderSettingsChange`'s `set` / `remove`).
    private func change(_ key: String, _ value: FlooJSON?) {
        demo.settings[service.id, default: [:]][device.id, default: [:]][key] = value
    }
}
