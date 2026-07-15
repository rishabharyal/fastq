import Foundation
import Combine

/// Persists Fastplay JWT credentials and exposes login state to the UI.
@MainActor
final class FastplayAuthStore: ObservableObject {
    static let shared = FastplayAuthStore()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var user: FastplayUser?
    @Published var lastError: String?
    @Published var isBusy = false

    private let defaultsKey = "fastq.fastplay.auth.v1"
    private var accessToken: String?
    private var refreshToken: String?

    private struct Persisted: Codable {
        var accessToken: String
        var refreshToken: String
        var user: FastplayUser?
    }

    private init() {
        load()
    }

    func login(email: String, password: String) async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            let pair = try await FastplayAPIClient.shared.login(email: email, password: password)
            accessToken = pair.accessToken
            refreshToken = pair.refreshToken
            await FastplayAPIClient.shared.setTokens(access: pair.accessToken, refresh: pair.refreshToken)
            let me = try await FastplayAPIClient.shared.me()
            user = me
            isLoggedIn = true
            save()
        } catch {
            lastError = error.localizedDescription
            isLoggedIn = false
            user = nil
        }
    }

    func register(name: String, email: String, password: String) async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            let pair = try await FastplayAPIClient.shared.register(name: name, email: email, password: password)
            accessToken = pair.accessToken
            refreshToken = pair.refreshToken
            await FastplayAPIClient.shared.setTokens(access: pair.accessToken, refresh: pair.refreshToken)
            let me = try await FastplayAPIClient.shared.me()
            user = me
            isLoggedIn = true
            save()
        } catch {
            lastError = error.localizedDescription
            isLoggedIn = false
            user = nil
        }
    }

    func logout() async {
        isBusy = true
        defer { isBusy = false }
        await FastplayAPIClient.shared.logout()
        accessToken = nil
        refreshToken = nil
        user = nil
        isLoggedIn = false
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    func restoreSession() async {
        guard isLoggedIn, accessToken != nil else { return }
        do {
            let me = try await FastplayAPIClient.shared.me()
            user = me
            save()
        } catch {
            // Try refresh once.
            do {
                let pair = try await FastplayAPIClient.shared.refreshTokens()
                accessToken = pair.accessToken
                refreshToken = pair.refreshToken
                let me = try await FastplayAPIClient.shared.me()
                user = me
                save()
            } catch {
                await logout()
            }
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return
        }
        accessToken = persisted.accessToken
        refreshToken = persisted.refreshToken
        user = persisted.user
        isLoggedIn = true
        Task {
            await FastplayAPIClient.shared.setTokens(access: persisted.accessToken, refresh: persisted.refreshToken)
        }
    }

    private func save() {
        guard let accessToken, let refreshToken else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        let persisted = Persisted(accessToken: accessToken, refreshToken: refreshToken, user: user)
        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
