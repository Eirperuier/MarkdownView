//
//  FlooSettings.swift
//  DemoApp
//
//  A provider's settings, as floo docs/service-settings.md §3.2 has the App draw them: one
//  page for any service, from the format in the provider's own definition. Each key's control
//  and its limits follow from its data type; one that picks from something lists what the
//  operation its `choices` name gives (its output's properties for the label, color and
//  group). One that picks several from what another list picks from, held off it (`notIn`), is a
//  switch on each item's page instead of a list. Above or among them, read only, is what the
//  definition's `info` operation answers, drawn by that operation's output format. The words
//  layer lays the page out in sections and names the keys, their values, what leaving one
//  unset is, and the properties shown. A card on top shows the service's icon, its name and
//  the device; a percentage is a thick bar under its row, as Codex's usage page draws a
//  limit. The format,
//  the info's format and the words are the real ones (FlooSettings.json, exported by
//  DemoApp/Scripts/floo-catalog.py); what the operations answer on each device, and the
//  files, are scripted.
//  `-flooContactsPath "service:calendar settings:calendar:iphone"` opens one.
//

import SwiftUI
import FlooDesign

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
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var items: [FlooJSON] { if case .array(let values) = self { values } else { [] } }
    var fields: [String: FlooJSON] { if case .object(let fields) = self { fields } else { [:] } }

    /// The value as the words name values: its JSON text (`never`, `10080`).
    var text: String {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        default: ""
        }
    }
}

/// What a setting, or a property of what an operation answers, is called: a line on it, its
/// values' names, and what leaving it unset is called (`SettingWords`).
struct FlooFieldWords: Decodable, Hashable {
    var title: String?
    var summary: String?
    var values: [String: String]?
    var unset: String?
}

/// A section of the page: settings by key, what `info` answers by path (`SettingsSection`).
struct FlooSettingsSection: Decodable, Hashable {
    var title: String?
    var summary: String?
    var keys: [String]?
    var properties: [String]?
}

/// A settings page's words in one language.
struct FlooPageWords: Decodable {
    var settings: [String: FlooFieldWords]
    /// By operation, then by path.
    var properties: [String: [String: FlooFieldWords]]
    var sections: [FlooSettingsSection]
}

/// The operation the page shows above the settings, and its output format.
struct FlooInfoFormat: Decodable {
    let operation: String
    let output: FlooJSON
}

/// A service's settings format, its info, and the page's words by language.
struct FlooSettingsFormat: Decodable {
    let format: FlooJSON
    let info: FlooInfoFormat?
    let words: [String: FlooPageWords]

    static let all: [String: FlooSettingsFormat] = {
        guard let url = Bundle.main.url(forResource: "FlooSettings", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }  // try?: the demo shows none
        return (try? JSONDecoder().decode([String: FlooSettingsFormat].self, from: data)) ?? [:]  // try?: as above
    }()

    /// Chinese, then English.
    private var languages: [FlooPageWords] { ["zh-Hans", "en"].compactMap { words[$0] } }

    /// Its keys, as the format lists them.
    var keys: [String] { format["properties"]?.fields.keys.sorted() ?? [] }

    func schema(_ key: String) -> FlooJSON? { format["properties"]?[key] }

    /// The words' title, then the format's own, then the key.
    func title(_ key: String) -> String {
        languages.lazy.compactMap { $0.settings[key]?.title }.first
            ?? schema(key)?["title"]?.string ?? key
    }

    func summary(_ key: String) -> String? {
        languages.lazy.compactMap { $0.settings[key]?.summary }.first ?? schema(key)?["description"]?.string
    }

    /// What one of the key's values is called; the value itself when the words don't say.
    func name(_ key: String, value: String) -> String {
        languages.lazy.compactMap { $0.settings[key]?.values?[value] }.first ?? value
    }

    /// What leaving the key unset is called.
    func unset(_ key: String) -> String? {
        languages.lazy.compactMap { $0.settings[key]?.unset }.first
    }

    /// The words for a property of what `operation` answers, at `path`, each field from the
    /// first language that has it.
    func property(_ operation: String, _ path: String) -> FlooFieldWords? {
        let found = languages.compactMap { $0.properties[operation]?[path] }
        guard !found.isEmpty else { return nil }
        return FlooFieldWords(
            title: found.lazy.compactMap(\.title).first, summary: found.lazy.compactMap(\.summary).first,
            values: found.lazy.compactMap(\.values).first, unset: nil
        )
    }

    /// The properties of what `operation` lists that have names, by path in path order: what
    /// an item's page shows.
    func named(_ operation: String) -> [FlooNamedProperty] {
        let paths = Set(languages.flatMap { ($0.properties[operation] ?? [:]).keys })
        return paths.sorted().compactMap { path in
            return property(operation, path)?.title.map { FlooNamedProperty(property: path, name: $0) }
        }
    }

    /// How the page is laid out; none when the words don't say.
    var sections: [FlooSettingsSection] { languages.first { !$0.sections.isEmpty }?.sections ?? [] }

    /// The keys whose lists a key's values are held off (`notIn`: one name, or several).
    static func heldOff(_ property: FlooJSON) -> [String] {
        switch property["notIn"] {
        case .string(let one)?: [one]
        case .array(let several)?: several.compactMap(\.string)
        default: []
        }
    }

    /// Whether the file lists what is left unchecked (`complement`, on the list or in its
    /// items' choices).
    func complement(_ key: String) -> Bool {
        schema(key)?["complement"] == .bool(true) || schema(key)?["items"]?["choices"]?["complement"] == .bool(true)
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

// MARK: - What the operations answer (scripted)

enum FlooListed {
    /// When the answers were last had from the device.
    static let updated = Date.now.addingTimeInterval(-4 * 60)

    /// What `operation` of `service` last answered on `device`: the calendars it has, with the
    /// properties the calendar service's `calendars` gives each; Codex's account, models and
    /// folders on the Mac.
    static func answer(_ service: String, _ operation: String, on device: String) -> FlooJSON {
        switch (service, operation) {
        case ("calendar", "calendars"): calendars(on: device)
        case ("codex", "account"): codexAccount
        case ("codex", "models"): codexModels
        case ("codex", "folders"): codexFolders
        default: .null
        }
    }

    /// Three models, two of them with a fast speed.
    private static var codexModels: FlooJSON {
        let models: [(String, String, [String], String, Bool)] = [
            ("gpt-5.5-codex", "GPT-5.5-Codex", ["low", "medium", "high", "xhigh"], "medium", true),
            ("gpt-5.5", "GPT-5.5", ["minimal", "low", "medium", "high", "xhigh"], "medium", true),
            ("gpt-5.5-mini", "GPT-5.5 mini", ["low", "medium", "high"], "medium", false),
        ]
        return .array(models.map { id, name, efforts, effort, fast in
            .object([
                "id": .string(id), "name": .string(name), "efforts": .array(efforts.map(FlooJSON.string)),
                "default_effort": .string(effort),
                "speeds": .array((fast ? ["standard", "fast"] : ["standard"]).map(FlooJSON.string)),
            ])
        })
    }

    /// Two projects' folders and one a recent session was in.
    private static var codexFolders: FlooJSON {
        let folders: [(String, String?)] = [
            ("~/Developer/floo", "floo"), ("~/Developer/floo-MarkdownView", "floo"),
            ("~/Developer/FlooDesign", "floo"), ("~/Developer/tidemark", "tidemark"),
            ("~/Developer/tidemark-site", "tidemark"), ("~/Downloads/scratch", nil),
        ]
        return .array(folders.map { path, project in
            var entry: [String: FlooJSON] = ["path": .string(path), "name": .string((path as NSString).lastPathComponent)]
            entry["project"] = project.map(FlooJSON.string)
            return .object(entry)
        })
    }

    private static func calendars(on device: String) -> FlooJSON {
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
        return .array(calendars.map { id, title, account, kind, color, writable, isDefault in
            .object([
                "id": .string(id), "title": .string(title), "account": .string(account), "kind": .string(kind),
                "color": .string(color), "writable": .bool(writable), "default": .bool(isDefault),
            ])
        })
    }

    /// A Pro account, a tenth of its week used; the model and effort are Codex's fallback
    /// (`model/list`), the rest from its config file.
    private static var codexAccount: FlooJSON {
        let when = { (seconds: TimeInterval) in FlooJSON.string(ISO8601DateFormatter().string(from: updated.addingTimeInterval(seconds))) }
        let config = FlooJSON.string("~/.codex/config.toml")
        return .object([
            "version": .string("0.162.0"),
            "account": .object(["kind": .string("chatgpt"), "email": .string("linxiao@hey.com"), "plan": .string("pro")]),
            "limits": .array([
                .object([
                    "window_minutes": .number(10_080), "used_percent": .number(12),
                    "resets_at": when((6 * 24 + 1) * 3600 + 20 * 60),
                ]),
            ]),
            "limit_reached": .bool(false),
            "credits": .object(["balance": .number(62_500), "unlimited": .bool(false)]),
            "saved_resets": .object(["available": .number(3), "next_expires_at": when(23 * 24 * 3600 + 3600)]),
            "defaults": .object([
                "model": .object(["value": .string("gpt-5.5")]),
                "effort": .object(["value": .string("medium")]),
                "approval": .object(["value": .string("on_request"), "file": config]),
                "mode": .object(["value": .string("workspace"), "file": config]),
                "web_search": .object(["value": .string("cached"), "file": config]),
            ]),
        ])
    }
}

// MARK: - The page

/// One provider's settings: the sections the words lay out, each key drawn from its data type
/// and changed by key, what `info` answers among them. Without sections, each key is a
/// section of its own and a list that picks several is checked in place.
struct FlooProviderSettingsPage: View {
    let demo: FlooContactsDemo
    let service: FlooService
    let device: FlooDevice
    let format: FlooSettingsFormat
    /// The one whose (i) was tapped: its page is open.
    @State private var shown: FlooSettingChoice?
    /// The list whose page is open.
    @State private var listing: FlooSettingKey?
    /// The text whose page is open.
    @State private var editing: FlooSettingKey?

    private var file: [String: FlooJSON] { demo.settings[service.id]?[device.id] ?? [:] }
    private var info: FlooJSON {
        format.info.map { FlooListed.answer(service.id, $0.operation, on: device.id) } ?? .null
    }

    /// The sections, then the keys none of them holds; keys folded into a list aren't drawn.
    private var layout: [FlooSettingsSection] {
        let drawn = format.keys.filter { format.list(holding: $0) == nil }
        let sections = format.sections.map { section in
            var section = section
            section.keys = section.keys?.filter(drawn.contains)
            return section
        }
        let placed = Set(sections.flatMap { $0.keys ?? [] })
        let rest = drawn.filter { !placed.contains($0) }
        return sections + (rest.isEmpty ? [] : [FlooSettingsSection(keys: rest)])
    }

    var body: some View {
        List {
            Section {
                FlooDesignSettingsHeader(service.name, subtitle: device.name) {
                    FlooServiceIcon(
                        url: service.icon, name: service.name, tint: service.tint,
                        size: FlooDesignTokens.Component.Settings.headerIcon
                    )
                }
            }
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
            if format.sections.isEmpty {
                ForEach(layout.flatMap { $0.keys ?? [] }, id: \.self) { key in
                    if let schema = format.schema(key) { field(key, schema) }
                }
            } else {
                let sections = layout
                ForEach(sections.indices, id: \.self) { index in
                    section(sections[index], updated: index == updatedIndex(sections))
                }
            }
        }
        // The same room above every section's title, whether the one before has words under it or not.
        .listSectionSpacing(FlooDesignTokens.Component.Settings.sectionSpacing)
        .navigationTitle(service.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $shown) { option in
            FlooSettingChoicePage(
                option: option, names: names(of: option.from),
                switches: { switches(on: option) },
                isOn: { key in checked(key, option.id) },
                set: { key, on in if checked(key, option.id) != on { toggle(key, option.id) } }
            )
        }
        .navigationDestination(item: $listing) { item in
            let key = item.key
            List {
                // Unset isn't none checked (no folders limit, not no folders): it is a choice of its own.
                if let unset = format.unset(key), !format.complement(key) {
                    Section {
                        Button { change(key, nil) } label: {
                            HStack {
                                Text(unset).foregroundStyle(.primary)
                                Spacer()
                                if file[key] == nil { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let choices = format.schema(key)?["items"]?["choices"] {
                    FlooChecklist(
                        title: format.title(key), summary: format.summary(key), options: options(choices),
                        checked: { checked(key, $0) }, info: nil
                    ) { toggle(key, $0) }
                }
            }
            .navigationTitle(format.title(key))
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationDestination(item: $editing) { item in
            FlooSettingTextPage(
                title: format.title(item.key), summary: format.summary(item.key),
                limit: format.schema(item.key)?["maxLength"]?.number.map(Int.init),
                text: Binding(
                    get: { file[item.key]?.string ?? "" },
                    set: { change(item.key, $0.isEmpty ? nil : .string($0)) }
                )
            )
        }
    }

    // MARK: Sections

    /// The section the time the info was had goes under: the last of those at the top that
    /// show only what `info` answers, or the last that shows any.
    private func updatedIndex(_ sections: [FlooSettingsSection]) -> Int? {
        let showing = { (section: FlooSettingsSection) in !(section.properties ?? []).isEmpty }
        let top = sections.prefix { showing($0) && ($0.keys ?? []).isEmpty }
        return top.isEmpty ? sections.lastIndex(where: showing) : top.count - 1
    }

    @ViewBuilder private func section(_ section: FlooSettingsSection, updated: Bool) -> some View {
        let keys = section.keys ?? []
        let properties = (section.properties ?? []).filter { value(at: $0) != nil }
        if !keys.isEmpty || !properties.isEmpty {
            Section {
                ForEach(said(properties), id: \.path) { row in shown(row.path, under: row.under) }
                ForEach(keys, id: \.self) { key in
                    if let schema = format.schema(key) { row(key, schema) }
                }
            } header: {
                section.title.map(Text.init)
            } footer: {
                // A key alone says what it is under it; several are said on their own pages.
                let said = section.summary ?? (keys.count == 1 && properties.isEmpty ? format.summary(keys[0]) : nil)
                if said != nil || updated {
                    VStack(alignment: .leading, spacing: 6) {
                        if let said { Text(said) }
                        if updated { Text("更新于 \(FlooListed.updated.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))") }
                    }
                }
            }
        }
    }

    /// A key as a row among others: a list that picks from choices opens its own page, a list
    /// of values is a switch for each, a text opens its own page; the rest are their type's control.
    @ViewBuilder private func row(_ key: String, _ schema: FlooJSON) -> some View {
        if schema["type"]?.string == "array", schema["items"]?["choices"] != nil {
            Button { listing = FlooSettingKey(key: key) } label: {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text(file[key] == nil ? (format.unset(key) ?? "") : "\(chosen(key))")
                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold))
                    }
                } label: {
                    label(key)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if schema["type"]?.string == "array", let values = schema["items"]?["enum"]?.items.compactMap(\.string) {
            ForEach(values, id: \.self) { value in
                Toggle(format.name(key, value: value), isOn: Binding(
                    get: { checked(key, value) },
                    set: { on in if checked(key, value) != on { toggle(key, value) } }
                ))
                .toggleStyle(.switch)
                .tint(FlooDesignTokens.Component.Settings.switchTint)
                .disabled(!canToggle(key, value))
            }
        } else if schema["type"]?.string == "string", schema["choices"] == nil, schema["enum"] == nil {
            Button { editing = FlooSettingKey(key: key) } label: {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text(file[key]?.string ?? format.unset(key) ?? "").lineLimit(1).frame(maxWidth: 240, alignment: .trailing)
                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold))
                    }
                } label: {
                    label(key)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            single(key, schema)
        }
    }

    /// A key's row's label: its title.
    private func label(_ key: String) -> some View {
        FlooDesignSettingsLabel(format.title(key))
    }

    /// How many a list that picks from choices has checked.
    private func chosen(_ key: String) -> Int {
        guard let choices = format.schema(key)?["items"]?["choices"] else { return 0 }
        return options(choices).filter { checked(key, $0.id) }.count
    }

    // MARK: What info answers

    /// What `info` answers at `path`: through objects by name.
    private func value(at path: String) -> FlooJSON? {
        path.split(separator: ".").reduce(info as FlooJSON?) { found, name in found?[String(name)] }
            .flatMap { $0 == .null ? nil : $0 }
    }

    /// The output format at `path`: through objects, past a list's index and an entry's key.
    private func outputSchema(at path: String) -> FlooJSON? {
        path.split(separator: ".").reduce(format.info?.output) { found, name in
            let inside = found?["items"] ?? found?["additionalProperties"] ?? found
            return inside?["properties"]?[String(name)]
        }
    }

    private func words(_ path: String) -> FlooFieldWords? {
        format.info.flatMap { format.property($0.operation, path) }
    }

    /// The rows of what a section shows of `info`: a time listed right after another property
    /// of the same object is said under that one's row (when a saved reset expires, under how
    /// many there are), not on a row of its own.
    private func said(_ paths: [String]) -> [(path: String, under: [String])] {
        let parent = { (path: String) in path.split(separator: ".").dropLast().joined(separator: ".") }
        return paths.reduce(into: []) { rows, path in
            if let last = rows.last, !parent(path).isEmpty, parent(path) == parent(last.path),
               outputSchema(at: path)?["format"]?.string == "date-time" {
                rows[rows.count - 1].under.append(path)
            } else {
                rows.append((path, []))
            }
        }
    }

    /// A time said under a row: how long until it, then what happens then ("6 天 1 小时后重置").
    private func when(_ value: FlooJSON?, _ path: String) -> String? {
        value?.string.flatMap(Self.date).map { "\(Self.relative($0))后\(words(path)?.title ?? "")" }
    }

    /// A row of what `info` answers: its name, a line under it, its value.
    private func infoRow(_ title: String, value: String, subtitle: String? = nil) -> some View {
        LabeledContent {
            Text(value)
        } label: {
            FlooDesignSettingsLabel(title, subtitle: subtitle)
        }
    }

    /// What `info` answers at `path`, read only: a value is a row of its name, the times
    /// `under` it said under it; an object is its named properties; a list is a row for each
    /// item; a table a row for each entry.
    @ViewBuilder private func shown(_ path: String, under: [String] = []) -> some View {
        let schema = outputSchema(at: path)
        if let value = value(at: path) {
            if schema?["type"]?.string == "array", schema?["items"]?["type"]?.string == "object" {
                ForEach(value.items.indices, id: \.self) { index in item(path, value.items[index]) }
            } else if schema?["additionalProperties"] != nil {
                ForEach(entries(value), id: \.self) { key in entry(path, key, value[key] ?? .null) }
            } else if schema?["type"]?.string == "object" {
                ForEach(value.fields.keys.sorted().filter { words("\(path).\($0)")?.title != nil }, id: \.self) { name in
                    let words = words("\(path).\(name)")
                    infoRow(words?.title ?? name, value: text(value[name] ?? .null, at: "\(path).\(name)"))
                }
            } else {
                let subtitle = under.compactMap { when(self.value(at: $0), $0) }.joined(separator: "\n")
                infoRow(
                    words(path)?.title ?? path, value: text(value, at: path),
                    subtitle: subtitle.isEmpty ? nil : subtitle
                )
            }
        }
    }

    /// An item of a list: named by the value of the property whose values have names (the
    /// week of a weekly limit), when it comes next under the name; a percentage how much of it
    /// is used, beside the name and as a thick bar under them (Codex's usage page).
    @ViewBuilder private func item(_ path: String, _ item: FlooJSON) -> some View {
        let fields = item.fields.keys.sorted()
        let label = fields.lazy.compactMap { name in self.words("\(path).\(name)")?.values?[item[name]?.text ?? ""] }.first
        let percent = fields.first { outputSchema(at: "\(path).\($0)")?["format"]?.string == "percent" }
        let time = fields.first { outputSchema(at: "\(path).\($0)")?["format"]?.string == "date-time" }
        let used = percent.flatMap { item[$0]?.number }
        let settings = FlooDesignTokens.Component.Settings.self
        VStack(alignment: .leading, spacing: settings.meterGap) {
            LabeledContent {
                if let percent, let used {
                    Text([words("\(path).\(percent)")?.title, (used / 100).formatted(.percent.precision(.fractionLength(0)))]
                        .compactMap(\.self).joined(separator: " "))
                }
            } label: {
                FlooDesignSettingsLabel(
                    label ?? words(path)?.title ?? path,
                    subtitle: time.flatMap { when(item[$0], "\(path).\($0)") }
                )
            }
            if let used {
                // Under the row's words, to its end.
                FlooDesignMeter(value: used / 100)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, settings.meterGap)
    }

    /// The keys of a table, as the settings are laid out when they are settings' keys.
    private func entries(_ value: FlooJSON) -> [String] {
        let order = format.sections.flatMap { $0.keys ?? [] }
        return value.fields.keys.sorted { (order.firstIndex(of: $0) ?? .max, $0) < (order.firstIndex(of: $1) ?? .max, $1) }
    }

    /// An entry of a table: called as its key is (a setting's key is the setting's title), its value what its unnamed properties hold, its named ones under it.
    @ViewBuilder private func entry(_ path: String, _ key: String, _ value: FlooJSON) -> some View {
        let title = words("\(path).\(key)")?.title ?? (format.schema(key) != nil ? format.title(key) : key)
        let named = value.fields.keys.sorted().filter { words("\(path).\($0)")?.title != nil }
        let plain = value.fields.keys.sorted().filter { !named.contains($0) }.compactMap { value[$0] }
        let under = named.map { "\(words("\(path).\($0)")?.title ?? $0) \(value[$0]?.text ?? "")" }.joined(separator: "\n")
        infoRow(
            title, value: (plain.isEmpty ? [value] : plain).map { setting(key, $0) }.joined(separator: " "),
            subtitle: under.isEmpty ? nil : under
        )
    }

    /// A value as a setting `key` would show it: its value's name, or the label of the choice it is.
    private func setting(_ key: String, _ value: FlooJSON) -> String {
        if let choices = format.schema(key)?["choices"],
           let option = options(choices).first(where: { $0.id == value.text }) { return option.label }
        return format.schema(key) != nil ? format.name(key, value: value.text) : value.text
    }

    /// A value of what `info` answers, as its format and words say.
    private func text(_ value: FlooJSON, at path: String) -> String {
        let schema = outputSchema(at: path)
        if let name = words(path)?.values?[value.text] { return name }
        switch (value, schema?["format"]?.string) {
        case (.number(let used), "percent"): return (used / 100).formatted(.percent.precision(.fractionLength(0)))
        case (.string(let when), "date-time"): return Self.date(when).map { "\(Self.relative($0))后" } ?? when
        case (.number(let number), _): return number.formatted()
        case (.bool(let yes), _): return yes ? "是" : "否"
        default: return value.text
        }
    }

    static func date(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }

    /// How long until `date`, in its two largest units ("6 天 1 小时").
    static func relative(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.day, .hour, .minute], from: .now, to: date)
        let said = [(parts.day ?? 0, "天"), (parts.hour ?? 0, "小时"), (parts.minute ?? 0, "分钟")]
            .drop { $0.0 <= 0 }.prefix(2).filter { $0.0 > 0 }
        return said.isEmpty ? "1 分钟" : said.map { "\($0.0) \($0.1)" }.joined(separator: " ")
    }

    // MARK: Lists

    /// The properties named for what `operation` lists: what an item's page shows.
    private func names(of operation: String) -> [FlooNamedProperty] {
        format.named(operation)
    }

    /// The switches on an item's page: each key folded into the list it is in, when the item
    /// is one that key picks from (its `where`) and the lists that key is held off don't hold it.
    private func switches(on option: FlooSettingChoice) -> [FlooSettingSwitch] {
        format.keys.compactMap { key in
            guard let schema = format.schema(key), format.list(holding: key) != nil,
                  options(schema["items"]?["choices"] ?? .null).contains(where: { $0.id == option.id }),
                  !FlooSettingsFormat.heldOff(schema).contains(where: { file[$0]?.items.contains(.string(option.id)) == true })
            else { return nil }
            return FlooSettingSwitch(key: key, title: format.title(key), summary: format.summary(key))
        }
    }

    /// Whether `id` is checked in the list under `key`; `complement`: the file lists the ones
    /// left unchecked.
    private func checked(_ key: String, _ id: String) -> Bool {
        (file[key]?.items.contains(.string(id)) == true) != format.complement(key)
    }

    /// Whether `id` can go in or out of the list under `key`: its `maxItems` and `minItems` hold.
    private func canToggle(_ key: String, _ id: String) -> Bool {
        let listed = file[key]?.items ?? []
        let schema = format.schema(key)
        if listed.contains(.string(id)) {
            return listed.count > Int(schema?["minItems"]?.number ?? 0)
        }
        return schema?["maxItems"]?.number.map { listed.count < Int($0) } ?? true
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
        change(key, listed.isEmpty && format.complement(key) ? nil : .array(listed))
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

    // MARK: Keys

    /// A key as a section of its own, its words under it: one that picks several is checked in
    /// place, a section for each group, each with an (i) to its page when its properties have
    /// names; the rest are rows.
    @ViewBuilder private func field(_ key: String, _ schema: FlooJSON) -> some View {
        if schema["type"]?.string == "array", let choices = schema["items"]?["choices"] {
            let from = choices["from"]?.string ?? ""
            FlooChecklist(
                title: format.title(key), summary: format.summary(key), options: options(choices),
                checked: { checked(key, $0) },
                info: names(of: from).isEmpty ? nil : { shown = $0 }
            ) { toggle(key, $0) }
        } else {
            Section {
                row(key, schema)
            } footer: {
                format.summary(key).map(Text.init)
            }
        }
    }

    /// One value: picked on its own page from the choices or the values not held off
    /// (`notIn`), or leaving it unset; a switch, or a number.
    @ViewBuilder private func single(_ key: String, _ schema: FlooJSON) -> some View {
        let title = format.title(key)
        let held = FlooSettingsFormat.heldOff(schema).flatMap { file[$0]?.items ?? [] }
        if let choices = schema["choices"] {
            let options = options(choices).filter { !held.contains(.string($0.id)) }
            Picker(selection: selection(key)) {
                Text(format.unset(key) ?? "默认").tag("")
                ForEach(FlooSettingChoice.groups(options), id: \.self) { group in
                    Section(group) {
                        ForEach(options.filter { $0.group == group }) { FlooSettingChoiceLabel(option: $0).tag($0.id) }
                    }
                }
            } label: {
                label(key)
            }
            .pickerStyle(.navigationLink)
        } else if let values = schema["enum"]?.items.filter({ !held.contains($0) }).compactMap(\.string), !values.isEmpty {
            Picker(selection: selection(key)) {
                Text(format.unset(key) ?? "默认").tag("")
                Section {
                    ForEach(values, id: \.self) { Text(format.name(key, value: $0)).tag($0) }
                }
            } label: {
                label(key)
            }
            .pickerStyle(.navigationLink)
        } else {
            switch schema["type"]?.string {
            case "boolean":
                Toggle(isOn: Binding(
                    get: { file[key] == .bool(true) },
                    set: { change(key, .bool($0)) }
                )) {
                    label(key)
                }
                .toggleStyle(.switch)
                .tint(FlooDesignTokens.Component.Settings.switchTint)
            case "integer", "number":
                let low = Int(schema["minimum"]?.number ?? 0)
                let high = Int(schema["maximum"]?.number ?? 1_000)
                let value = Int(file[key]?.number ?? Double(low))
                Stepper("\(title)：\(value)", value: Binding(
                    get: { value },
                    set: { change(key, .number(Double($0))) }
                ), in: low...high)
            default:
                EmptyView()
            }
        }
    }

    private func selection(_ key: String) -> Binding<String> {
        Binding(get: { file[key]?.string ?? "" }, set: { change(key, $0.isEmpty ? nil : .string($0)) })
    }

    /// What `choices.from` lists, filtered by `where`, with the properties its roles name.
    private func options(_ choices: FlooJSON) -> [FlooSettingChoice] {
        let keyed = { (item: FlooJSON, role: String) in choices[role]?.string.flatMap { item[$0]?.string } }
        let from = choices["from"]?.string ?? ""
        return FlooListed.answer(service.id, from, on: device.id).items.compactMap { item in
            guard (choices["where"]?.fields ?? [:]).allSatisfy({ item[$0.key] == $0.value }),
                  let id = keyed(item, "key") else { return nil }
            return FlooSettingChoice(
                id: id, label: keyed(item, "label") ?? id,
                tint: keyed(item, "tint").flatMap(Color.init(hex:)), group: keyed(item, "group") ?? "",
                from: from, properties: item.fields
            )
        }
    }

    /// One key set or removed; the others stay (`ProviderSettingsChange`'s `set` / `remove`).
    private func change(_ key: String, _ value: FlooJSON?) {
        demo.settings[service.id, default: [:]][device.id, default: [:]][key] = value
    }
}

/// A property of what an operation lists, as an item's page shows it.
struct FlooNamedProperty: Hashable {
    let property: String
    let name: String
}

/// A key whose own page is open.
struct FlooSettingKey: Identifiable, Hashable {
    let key: String
    var id: String { key }
}

/// One of what a setting picks from.
struct FlooSettingChoice: Identifiable, Hashable {
    let id: String
    let label: String
    let tint: Color?
    let group: String
    /// The operation that listed it.
    let from: String
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
/// Calendars list does it: a circle in its tint, filled and ticked when checked (one without a
/// tint, a plain checkmark circle); the row toggles, its (i) opens its page.
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
                                let on = checked(option.id)
                                if let tint = option.tint {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.title2)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(on ? .white : tint, tint)
                                        .accessibilityHidden(true)
                                } else {
                                    // No color of its own: the plain checkmark circle, ticked in the accent color.
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.title2)
                                        .symbolRenderingMode(.monochrome)
                                        .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                        .accessibilityHidden(true)
                                }
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

/// A text setting on its own page: the text, its words and how much of its `maxLength` it uses under it.
struct FlooSettingTextPage: View {
    let title: String
    let summary: String?
    let limit: Int?
    @Binding var text: String

    var body: some View {
        List {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 180)
                    .onChange(of: text) { _, new in
                        if let limit, new.count > limit { text = String(new.prefix(limit)) }
                    }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let summary { Text(summary) }
                    if let limit { Text("\(text.count) / \(limit)").monospacedDigit() }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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
    let names: [FlooNamedProperty]
    let switches: () -> [FlooSettingSwitch]
    let isOn: (String) -> Bool
    let set: (String, Bool) -> Void

    var body: some View {
        List {
            Section {
                ForEach(names.filter { option.properties[$0.property] != nil }, id: \.property) { named in
                    LabeledContent {
                        Text(Self.text(option.properties[named.property]!))
                    } label: {
                        Text(named.name)
                    }
                }
            }
            ForEach(switches(), id: \.self) { item in
                Section {
                    Toggle(item.title, isOn: Binding(get: { isOn(item.key) }, set: { set(item.key, $0) }))
                    .toggleStyle(.switch)
                    .tint(FlooDesignTokens.Component.Settings.switchTint)
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
