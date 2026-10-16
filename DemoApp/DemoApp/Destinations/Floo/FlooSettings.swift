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
                        "\(device.name)上次在线时间为\(device.lastSeen ?? "")。更改将在设备重新上线后生效。",
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

    /// Each key with its words under it: one that picks several is checked in place, a section
    /// for each group; one that picks one is a picker on its own page; the rest are their
    /// type's control.
    @ViewBuilder private func field(_ key: String, _ schema: FlooJSON) -> some View {
        if schema["type"]?.string == "array", let choices = schema["items"]?["choices"] {
            // `complement`: the file lists the ones left unchecked.
            let complement = choices["complement"] == .bool(true)
            FlooChecklist(
                title: format.title(key), summary: format.summary(key), options: options(choices),
                checked: { id in (file[key]?.items.contains(.string(id)) == true) != complement }
            ) { id in
                var listed = file[key]?.items ?? []
                if let index = listed.firstIndex(of: .string(id)) { listed.remove(at: index) } else {
                    listed.append(.string(id))
                }
                change(key, listed.isEmpty ? nil : .array(listed))
                // A key held off this list (`notIn`) whose value it now lists is unset in the same change.
                for (other, property) in format.format["properties"]?.fields ?? [:]
                where property["notIn"] == .string(key) {
                    if let value = file[other], listed.contains(value) { change(other, nil) }
                }
            }
        } else {
            Section {
                single(key, schema)
            } footer: {
                format.summary(key).map(Text.init)
            }
        }
    }

    @ViewBuilder private func single(_ key: String, _ schema: FlooJSON) -> some View {
        if let choices = schema["choices"] {
            // `notIn`: none the list under that key holds.
            let held = schema["notIn"]?.string.flatMap { file[$0]?.items } ?? []
            let options = options(choices).filter { !held.contains(.string($0.id)) }
            Picker(format.title(key), selection: Binding(
                get: { file[key]?.string ?? "" },
                set: { change(key, $0.isEmpty ? nil : .string($0)) }
            )) {
                Text("系统默认").tag("")
                ForEach(FlooSettingChoice.groups(options), id: \.self) { group in
                    Section(group) {
                        ForEach(options.filter { $0.group == group }) { FlooSettingChoiceLabel(option: $0).tag($0.id) }
                    }
                }
            }
            .pickerStyle(.navigationLink)
        } else {
            plain(key, schema)
        }
    }

    /// What `choices.from` lists, filtered by `where`, with the properties its roles name.
    private func options(_ choices: FlooJSON) -> [FlooSettingChoice] {
        let keyed = { (item: FlooJSON, role: String) in choices[role]?.string.flatMap { item[$0]?.string } }
        return FlooListed.answer(service.id, choices["from"]?.string ?? "", on: device.id).compactMap { item in
            guard (choices["where"]?.fields ?? [:]).allSatisfy({ item[$0.key] == $0.value }),
                  let id = keyed(item, "key") else { return nil }
            return FlooSettingChoice(
                id: id, label: keyed(item, "label") ?? id,
                tint: keyed(item, "tint").flatMap(Color.init(hex:)), group: keyed(item, "group") ?? ""
            )
        }
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

/// One of what a setting picks from.
struct FlooSettingChoice: Identifiable, Hashable {
    let id: String
    let label: String
    let tint: Color?
    let group: String

    /// Their groups, in the order listed.
    static func groups(_ options: [FlooSettingChoice]) -> [String] {
        options.reduce(into: [String]()) { order, option in
            if !order.contains(option.group) { order.append(option.group) }
        }
    }
}

struct FlooSettingChoiceLabel: View {
    let option: FlooSettingChoice

    var body: some View {
        HStack(spacing: 12) {
            if let tint = option.tint { Circle().fill(tint).frame(width: 12, height: 12) }
            Text(option.label)
        }
    }
}

/// A setting that picks several: each checked or not, a section for each group (its title
/// heads them when there are none), its words under the last.
struct FlooChecklist: View {
    let title: String
    let summary: String?
    let options: [FlooSettingChoice]
    let checked: (String) -> Bool
    let toggle: (String) -> Void

    var body: some View {
        let groups = FlooSettingChoice.groups(options)
        ForEach(groups, id: \.self) { group in
            Section {
                ForEach(options.filter { $0.group == group }) { option in
                    Button { toggle(option.id) } label: {
                        HStack {
                            FlooSettingChoiceLabel(option: option).foregroundStyle(.primary)
                            Spacer()
                            if checked(option.id) {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(group.isEmpty ? title : group)
            } footer: {
                if group == groups.last, let summary { Text(summary) }
            }
        }
    }
}
