//
//  FlooPlaces.swift
//  DemoApp
//
//  Starting a group and connecting services, on the floo server (FlooLive): a group with your
//  butler, people found by their email and services you have; a service connected by signing
//  in to it in the browser, or, one this Mac runs, by Floo Helper getting what it needs here.
//

import SwiftUI
import Wire
import TransportKit

/// A new group: its name, the people in it (each found by email) and your services in it.
struct FlooNewGroupView: View {
    let live: FlooLive
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var email = ""
    @State private var people: [PersonFound] = []
    @State private var services: [FlooLiveService] = []
    @State private var picked: Set<String> = []
    @State private var finding = false
    @State private var opening = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("群名称", text: $title)
                }
                Section {
                    ForEach(people, id: \.account) { person in
                        Label(person.name ?? "没有名字的成员", systemImage: "person.crop.circle")
                    }
                    .onDelete { people.remove(atOffsets: $0) }
                    HStack {
                        TextField("对方的邮箱", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(find)
                        if finding {
                            ProgressView()
                        } else {
                            Button("添加", action: find)
                                .disabled(!email.contains("@"))
                        }
                    }
                } header: {
                    Text("成员")
                } footer: {
                    Text("你的管家会在群里；每个成员也带着自己的管家。")
                }
                if !services.isEmpty {
                    Section("服务") {
                        ForEach(services) { service in
                            Toggle(service.name, isOn: Binding(
                                get: { picked.contains(service.id) },
                                set: { on in if on { picked.insert(service.id) } else { picked.remove(service.id) } }
                            ))
                        }
                    }
                }
                if let failure {
                    Text(failure).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("新建群聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if opening {
                        ProgressView()
                    } else {
                        Button("建群", action: open)
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .task { services = await live.connectedServices() }
    }

    private func find() {
        let email = email.trimmingCharacters(in: .whitespaces)
        guard email.contains("@"), !finding else { return }
        finding = true
        failure = nil
        Task {
            defer { finding = false }
            do {
                guard let person = try await live.person(email: email) else {
                    failure = "没有用这个邮箱的账号。"
                    return
                }
                if !people.contains(where: { $0.account == person.account }) { people.append(person) }
                self.email = ""
            } catch ClientError.server(status: 429, _) {
                failure = "查得太频繁了，请稍后再试。"
            } catch {
                failure = "没查到：\(error)"
            }
        }
    }

    private func open() {
        opening = true
        failure = nil
        Task {
            defer { opening = false }
            do {
                try await live.openGroup(
                    title: title.trimmingCharacters(in: .whitespaces),
                    people: people.map(\.account),
                    services: Array(picked)
                )
                dismiss()
            } catch {
                failure = "群没建成：\(error)"
            }
        }
    }
}
