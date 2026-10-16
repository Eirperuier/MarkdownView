//
//  FlooSettings.swift
//  DemoApp
//
//  A provider's settings, as floo docs/service-settings.md §3.2 has the App draw them: one
//  page for any service, from the format in the provider's own definition. Each key's control
//  and its limits follow from its data type; one that picks from something lists what the
//  operation its `choices` name gives (its output's properties for the label, color and
//  group). One that picks several from what another list picks from, held off it (`notIn`), is a
//  switch on each item's page instead of a list. The format and the words are the real ones (FlooSettings.json, exported by
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

    /// The keys whose lists a key's values are held off (`notIn`: one name, or several).
    static func heldOff(_ property: FlooJSON) -> [String] {
        switch property["notIn"] {
        case .string(let one)?: [one]
        case .array(let several)?: several.compactMap(\.string)
        default: []
        }
    }

    /// The list a key that picks several is folded into: another that picks several from the
    /// same, which it is held off. It isn't a list of its own but a switch on each item's page
    /// (a calendar read-only or not, on the calendar's page; it can't be both kept out and read-only).
    func list(holding key: String) -> String? {
        let properties = format["properties"]?.fields ?? [:]
        guard let schema = properties[key], schema["type"]?.string == "array",
              let from = schema["items"]?["choices"]?["from"] else { return nil }
        return Self.heldOff(schema).first { other in
            properties[other]?["type"]?.string == "array" && properties[other]?["items"]?["choices"]?["from"] == from
        }
    }
}

// MARK: - What the operations list (scripted)

enum FlooListed {
    /// What `operation` of `service` last answered on `device`: the calendars it has, with
    /// the properties the calendar service's `calendars` gives each.
    static func answer(_ service: String, _ operation: String, on device: String) -> [FlooJSON] {
        guard service == "calendar", operation == "calendars" else { return [] }
        let calendars: [(String, String, String, String, String, Bool, Bool)] =
            switch device {
            case "iphone": [
                ("cal-work", "工作", "iCloud", "synced", "#1D7AF2", true, true),
                ("cal-home", "家", "iCloud", "synced", "#34C759", true, false),
                ("cal-therapy", "心理咨询", "iCloud", "synced", "#AF52DE", true, false),
                ("cal-team", "团队", "公司 Exchange", "exchange", "#FF9500", true, false),
                ("cal-holidays", "中国节假日", "订阅的日历", "subscription", "#FF3B30", false, false),
                ("cal-birthdays", "生日", "其他", "birthdays", "#8E8E93", false, false),
            ]
            default: [
                ("mac-work", "工作", "iCloud", "synced", "#1D7AF2", true, true),
                ("mac-home", "家", "iCloud", "synced", "#34C759", true, false),
                ("mac-local", "Mac 上的日历", "我的 Mac", "local", "#FFCC00", true, false),
            ]
            }
        return calendars.map { id, title, account, kind, color, writable, isDefault in
            .object([
                "id": .string(id), "title": .string(title), "account": .string(account), "kind": .string(kind),
                "color": .string(color), "writable": .bool(writable), "default": .bool(isDefault),
            ])
        }
    }

    /// What a service's listed things' properties are called, in the order shown. The
    /// definitions don't name their outputs' properties yet, so these stand in for the words
    /// layer; one not named here isn't shown.
    static func names(_ service: String) -> [(property: String, name: String)] {
        guard service == "calendar" else { return [] }
        // Whether floo may change one is the Allow Editing switch; one nobody can change has none.
        return [("account", "账户"), ("default", "系统默认日历")]
    }
}

// MARK: - The page

/// One provider's settings: each key drawn from its data type, changed by key.
struct FlooProviderSettingsPage: View {
    let demo: FlooContactsDemo
    let service: FlooService
    let device: FlooDevice
    let format: FlooSettingsFormat
    /// The one whose (i) was tapped: its page is open.
    @State private var shown: FlooSettingChoice?

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
            ForEach(format.keys.filter { format.list(holding: $0) == nil }, id: \.self) { key in
                if let schema = format.format["properties"]?[key] {
                    field(key, schema)
                }
            }
        }
        .navigationTitle("\(service.name) · \(device.name.replacingOccurrences(of: "这台 ", with: ""))")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $shown) { option in
            FlooSettingChoicePage(
                option: option, names: FlooListed.names(service.id),
                switches: { switches(on: option) },
                isOn: { key in checked(key, option.id) },
                set: { key, on in if checked(key, option.id) != on { toggle(key, option.id) } }
            )
        }
    }

    /// The switches on an item's page: each key folded into the list it is in, when the item
    /// is one that key picks from (its `where`) and the lists that key is held off don't hold it.
    private func switches(on option: FlooSettingChoice) -> [FlooSettingSwitch] {
        format.keys.compactMap { key in
            guard let schema = format.format["properties"]?[key], format.list(holding: key) != nil,
                  options(schema["items"]?["choices"] ?? .null).contains(where: { $0.id == option.id }),
                  !FlooSettingsFormat.heldOff(schema).contains(where: { file[$0]?.items.contains(.string(option.id)) == true })
            else { return nil }
            return FlooSettingSwitch(key: key, title: format.title(key), summary: format.summary(key))
        }
    }

    /// Whether `id` is checked in the list under `key`; `complement`: the file lists the ones
    /// left unchecked.
    private func checked(_ key: String, _ id: String) -> Bool {
        let complement = format.format["properties"]?[key]?["items"]?["choices"]?["complement"] == .bool(true)
        return (file[key]?.items.contains(.string(id)) == true) != complement
    }

    /// `id` in or out of the list under `key`.
    private func toggle(_ key: String, _ id: String) {
        var listed = file[key]?.items ?? []
        if let index = listed.firstIndex(of: .string(id)) { listed.remove(at: index) } else {
            listed.append(.string(id))
        }
        change(key, listed: listed)
    }

    /// The list under `key` set; a key held off it (`notIn`) loses what it now holds in the
    /// same change: one value unset, a list without them.
    private func change(_ key: String, listed: [FlooJSON]) {
        change(key, listed.isEmpty ? nil : .array(listed))
        for (other, property) in format.format["properties"]?.fields ?? [:]
        where FlooSettingsFormat.heldOff(property).contains(key) {
            switch file[other] {
            case .array(let values)?:
                let kept = values.filter { !listed.contains($0) }
                if kept.count != values.count { change(other, listed: kept) }
            case let value? where listed.contains(value): change(other, nil)
            default: break
            }
        }
    }

    /// Each key with its words under it: one that picks several is checked in place, a section
    /// for each group, each with an (i) to its page when its properties have names; one that picks one is a picker on its own page; the rest are their
    /// type's control.
    @ViewBuilder private func field(_ key: String, _ schema: FlooJSON) -> some View {
        if schema["type"]?.string == "array", let choices = schema["items"]?["choices"] {
            FlooChecklist(
                title: format.title(key), summary: format.summary(key), options: options(choices),
                checked: { checked(key, $0) },
                info: FlooListed.names(service.id).isEmpty ? nil : { shown = $0 }
            ) { toggle(key, $0) }
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
            // `notIn`: none the lists under those keys hold.
            let held = FlooSettingsFormat.heldOff(schema).flatMap { file[$0]?.items ?? [] }
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
                tint: keyed(item, "tint").flatMap(Color.init(hex:)), group: keyed(item, "group") ?? "",
                properties: item.fields
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
    /// All it was listed with.
    let properties: [String: FlooJSON]

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
/// heads them when there are none), its words under the last. A row is checked as the system's
/// Calendars list does it: a circle in its tint, filled and ticked when checked; the row
/// toggles, its (i) opens its page.
struct FlooChecklist: View {
    let title: String
    let summary: String?
    let options: [FlooSettingChoice]
    let checked: (String) -> Bool
    let info: ((FlooSettingChoice) -> Void)?
    let toggle: (String) -> Void

    var body: some View {
        let groups = FlooSettingChoice.groups(options)
        ForEach(groups, id: \.self) { group in
            Section {
                ForEach(options.filter { $0.group == group }) { option in
                    HStack(spacing: 12) {
                        Button { toggle(option.id) } label: {
                            HStack(spacing: 12) {
                                let on = checked(option.id), tint = option.tint ?? .accentColor
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(on ? .white : tint, tint)
                                    .accessibilityHidden(true)
                                Text(option.label).foregroundStyle(.primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(checked(option.id) ? .isSelected : [])
                        if let info {
                            Button { info(option) } label: { Image(systemName: "info.circle").font(.title3) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("\(option.label)的信息")
                        }
                    }
                }
            } header: {
                Text(group.isEmpty ? title : group)
            } footer: {
                if group == groups.last, let summary { Text(summary) }
            }
        }
    }
}

/// A switch on an item's page: a key folded into the list the item is in.
struct FlooSettingSwitch: Hashable {
    let key: String
    let title: String
    let summary: String?
}

/// One of what a setting picks from, as its operation listed it: each property that has a
/// name, in the order named; then a switch for each key folded into its list, its words under it.
struct FlooSettingChoicePage: View {
    let option: FlooSettingChoice
    let names: [(property: String, name: String)]
    let switches: () -> [FlooSettingSwitch]
    let isOn: (String) -> Bool
    let set: (String, Bool) -> Void

    var body: some View {
        List {
            Section {
                ForEach(names.filter { option.properties[$0.property] != nil }, id: \.property) { named in
                    LabeledContent(named.name, value: Self.text(option.properties[named.property]!))
                }
            }
            ForEach(switches(), id: \.self) { item in
                Section {
                    Toggle(item.title, isOn: Binding(get: { isOn(item.key) }, set: { set(item.key, $0) }))
                        .toggleStyle(.switch)
                } footer: {
                    item.summary.map(Text.init)
                }
            }
        }
        .navigationTitle(option.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func text(_ value: FlooJSON) -> String {
        switch value {
        case .bool(let yes): yes ? "是" : "否"
        case .string(let text): text
        case .number(let number): number.formatted()
        default: ""
        }
    }
}
