//
//  FlooSignIn.swift
//  DemoApp
//
//  Signing in to the floo server (FlooLive's online backend) with an email and a password,
//  or making an account there first: the server makes it, its email taken as confirmed,
//  and you're signed in with it.
//

import SwiftUI
import Wire
import TransportKit

/// The sign-in the chat page shows until you're in: what you've typed, whether it's going,
/// and why it didn't.
@MainActor
@Observable
final class FlooSignIn {
    enum Mode { case signIn, signUp }

    var mode = Mode.signIn
    var email = UserDefaults.standard.string(forKey: FlooOnline.emailKey) ?? ""
    var password = ""
    private(set) var working = false
    private(set) var failure: String?

    @ObservationIgnored private let auth: SupabaseAuth
    @ObservationIgnored private let server: FlooClient
    @ObservationIgnored private var waiting: CheckedContinuation<AuthSession?, Never>?

    /// `failure`: why you're asked again, when a kept session no longer gets in.
    init(auth: SupabaseAuth, server: FlooClient, failure: String? = nil) {
        self.auth = auth
        self.server = server
        self.failure = failure
    }

    /// Whether the server lets the signed-in account in: it takes only the accounts it's
    /// told to (FLOO_ALLOWED_EMAILS), and turns the others away on every call. Signed out
    /// when it doesn't.
    static func admitted(_ server: FlooClient, _ auth: SupabaseAuth) async throws -> Bool {
        do {
            _ = try await server.devices()
            return true
        } catch ClientError.server(status: 403, _) {
            try? await auth.signOut()  // try?: the kept session may be gone already
            return false
        }
    }

    static let refused = "这个账号没有使用权限。"

    var canSubmit: Bool {
        !working && email.contains("@") && password.count >= FlooOnline.minimumPassword
    }

    /// The session once you're in; nil if the page went elsewhere first.
    func signedIn() async -> AuthSession? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiting = $0 }
        } onCancel: {
            Task { @MainActor in self.finish(nil) }
        }
    }

    func submit() {
        guard canSubmit else { return }
        let email = email.trimmingCharacters(in: .whitespaces)
        let password = password
        let mode = mode
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                if mode == .signUp { try await server.signUp(email: email, password: password) }
                let session = try await auth.signIn(email: email, password: password)
                guard try await Self.admitted(server, auth) else {
                    failure = Self.refused
                    return
                }
                UserDefaults.standard.set(email, forKey: FlooOnline.emailKey)
                #if targetEnvironment(macCatalyst)
                // This Mac's node comes in with you: Floo Helper signed in as you too. try?: if
                // it doesn't, the services sheet asks for the password again.
                Task { try? await FlooHelper.signIn(email: email, password: password) }
                #endif
                finish(session)
            } catch {
                failure = Self.reason(error, mode: mode)
            }
        }
    }

    private func finish(_ session: AuthSession?) {
        waiting?.resume(returning: session)
        waiting = nil
    }

    private static func reason(_ error: any Error, mode: Mode) -> String {
        switch error {
        case AuthError.rejected("invalid_credentials"): "邮箱或密码不正确。"
        case AuthError.rejected(let code): "无法登录（\(code)）。"
        case SignUpError.taken: "这个邮箱已经注册过了，请直接登录。"
        case SignUpError.rejected(let reason): "无法注册：\(reason)"
        case SignUpError.notAllowed: "这个邮箱不能在这里注册。"
        case SignUpError.tooMany: "注册次数过多，请稍后再试。"
        default: "无法连接服务器。"
        }
    }
}

/// The sign-in form, in the middle of the chat page.
struct FlooSignInView: View {
    @Bindable var model: FlooSignIn
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        let signingUp = model.mode == .signUp
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text(signingUp ? "创建 floo 账号" : "登录 floo")
                    .font(.title2.weight(.semibold))
                Text(signingUp ? "用邮箱和密码创建账号。" : "使用你的邮箱和密码登录。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                TextField("邮箱", text: $model.email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .modifier(FlooSignInField())
                SecureField("密码", text: $model.password)
                    .textContentType(signingUp ? .newPassword : .password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { model.submit() }
                    .modifier(FlooSignInField())
                if signingUp {
                    Text("密码至少 \(FlooOnline.minimumPassword) 位。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let failure = model.failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button {
                model.submit()
            } label: {
                ZStack {
                    Text(signingUp ? "注册" : "登录").opacity(model.working ? 0 : 1)
                    if model.working { ProgressView() }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canSubmit)
            Button(signingUp ? "已有账号？登录" : "没有账号？注册") {
                model.mode = signingUp ? .signIn : .signUp
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
            .disabled(model.working)
        }
        .frame(maxWidth: 340)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .onAppear { focus = model.email.isEmpty ? .email : .password }
    }
}

private struct FlooSignInField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 10))
    }
}
