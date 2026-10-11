import Foundation
import Observation

public enum LicenseError: LocalizedError, Equatable, Sendable {
    case disabled
    case invalidCredentials
    case sessionExpired
    case tooManyAttempts
    case unreachable
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .disabled: "Your subscription is suspended."
        case .invalidCredentials: "Email or password is incorrect."
        case .sessionExpired: "Your session expired. Sign in again."
        case .tooManyAttempts: "Too many attempts. Try again later."
        case .unreachable: "Can't reach the license server."
        case .server(let message): message
        }
    }
}

public enum LicenseState: Equatable, Sendable {
    case signedOut, checking, active, suspended, unreachable
}

public struct LicenseSession: Equatable, Sendable {
    public var email: String
    public var refreshToken: String
}

/// Firebase Auth over REST. A disabled user fails sign-in and refresh with USER_DISABLED.
public struct LicenseClient: Sendable {
    private let apiKey: String
    private let transport: HTTPTransport

    public init(apiKey: String, transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.transport = transport
    }

    public var isConfigured: Bool { !apiKey.isEmpty }

    public func signIn(email: String, password: String) async throws -> LicenseSession {
        struct Response: Decodable { let email: String?; let refreshToken: String }
        let data = try await post(
            "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword",
            json: ["email": email, "password": password, "returnSecureToken": true]
        )
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw LicenseError.server("Unexpected response from the license server.")
        }
        return LicenseSession(email: response.email ?? email, refreshToken: response.refreshToken)
    }

    /// Returns the rotated refresh token.
    public func refresh(refreshToken: String) async throws -> String {
        struct Response: Decodable { let refresh_token: String }
        let data = try await post(
            "https://securetoken.googleapis.com/v1/token",
            form: "grant_type=refresh_token&refresh_token=\(Self.formEncoded(refreshToken))"
        )
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw LicenseError.server("Unexpected response from the license server.")
        }
        return response.refresh_token
    }

    public func sendPasswordReset(email: String) async throws {
        _ = try await post(
            "https://identitytoolkit.googleapis.com/v1/accounts:sendOobCode",
            json: ["requestType": "PASSWORD_RESET", "email": email]
        )
    }

    private func post(_ url: String, json: [String: Any]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await send(url, body: body, contentType: "application/json")
    }

    private func post(_ url: String, form: String) async throws -> Data {
        try await send(url, body: Data(form.utf8), contentType: "application/x-www-form-urlencoded")
    }

    private func send(_ url: String, body: Data, contentType: String) async throws -> Data {
        guard isConfigured, let endpoint = URL(string: "\(url)?key=\(apiKey)") else { throw LicenseError.unreachable }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw LicenseError.unreachable
        }
        guard !(200..<300).contains(response.statusCode) else { return data }
        throw Self.error(from: data, status: response.statusCode)
    }

    private static func error(from data: Data, status: Int) -> LicenseError {
        struct Envelope: Decodable { struct Inner: Decodable { let message: String? }; let error: Inner? }
        let message = (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message ?? ""
        func matches(_ codes: [String]) -> Bool { codes.contains { message.hasPrefix($0) } }
        if matches(["USER_DISABLED"]) { return .disabled }
        if matches(["EMAIL_NOT_FOUND", "INVALID_PASSWORD", "INVALID_LOGIN_CREDENTIALS", "INVALID_EMAIL", "MISSING_PASSWORD"]) { return .invalidCredentials }
        if matches(["TOKEN_EXPIRED", "USER_NOT_FOUND", "INVALID_REFRESH_TOKEN", "MISSING_REFRESH_TOKEN", "CREDENTIAL_TOO_OLD_LOGIN_AGAIN"]) { return .sessionExpired }
        if matches(["TOO_MANY_ATTEMPTS_TRY_LATER"]) { return .tooManyAttempts }
        if status >= 500 { return .unreachable }
        return .server(message.isEmpty ? "License server returned HTTP \(status)." : message)
    }

    private static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

@MainActor
@Observable
public final class LicenseStore {
    public private(set) var state: LicenseState
    public private(set) var email: String?
    public var isActive: Bool { state == .active }

    @ObservationIgnored private let client: LicenseClient
    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private let checkInterval: TimeInterval
    @ObservationIgnored private let bypass: Bool
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var isChecking = false
    @ObservationIgnored private var lastChecked: Date?

    /// `bypass` skips every check, for debug builds.
    public init(client: LicenseClient, secrets: SecretStore = KeychainSecretStore(), checkInterval: TimeInterval = 15 * 60, bypass: Bool = false) {
        self.client = client
        self.secrets = secrets
        self.checkInterval = checkInterval
        self.bypass = bypass
        email = secrets.get(account: Keychain.firebaseEmailAccount)
        let hasToken = !(secrets.get(account: Keychain.firebaseRefreshAccount) ?? "").isEmpty
        state = bypass ? .active : (hasToken ? .checking : .signedOut)
    }

    public var isConfigured: Bool { bypass || client.isConfigured }

    public func check() async {
        guard !bypass, !isChecking else { return }
        isChecking = true
        defer { isChecking = false; lastChecked = Date() }
        guard let token = secrets.get(account: Keychain.firebaseRefreshAccount), !token.isEmpty else {
            state = .signedOut
            return
        }
        // Keep the app mounted during a periodic re-check instead of flashing the spinner.
        if state != .active { state = .checking }
        do {
            let rotated = try await client.refresh(refreshToken: token)
            try? secrets.set(rotated, account: Keychain.firebaseRefreshAccount)
            state = .active
        } catch LicenseError.disabled {
            state = .suspended
        } catch LicenseError.sessionExpired {
            clearCredentials()
            state = .signedOut
        } catch {
            state = .unreachable
        }
    }

    /// Re-checks unless a check just ran; used when the app returns to the foreground.
    public func recheckIfStale(minimumAge: TimeInterval = 60) async {
        if let lastChecked, Date().timeIntervalSince(lastChecked) < minimumAge { return }
        await check()
    }

    /// Returns an error message to show, or nil on success (including a suspended account, which is a state).
    public func signIn(email: String, password: String) async -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        do {
            let session = try await client.signIn(email: trimmed, password: password)
            try secrets.set(session.refreshToken, account: Keychain.firebaseRefreshAccount)
            try? secrets.set(session.email, account: Keychain.firebaseEmailAccount)
            self.email = session.email
            state = .active
            return nil
        } catch LicenseError.disabled {
            state = .suspended
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public func signOut() {
        clearCredentials()
        state = .signedOut
    }

    /// Returns an error message to show, or nil on success. Unknown emails look like success so accounts aren't revealed.
    public func resetPassword(email: String) async -> String? {
        do {
            try await client.sendPasswordReset(email: email.trimmingCharacters(in: .whitespaces))
            return nil
        } catch LicenseError.invalidCredentials {
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public func startMonitoring() {
        guard !bypass, monitorTask == nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check()
                try? await Task.sleep(for: .seconds(self.checkInterval))
            }
        }
    }

    private func clearCredentials() {
        secrets.delete(account: Keychain.firebaseRefreshAccount)
        secrets.delete(account: Keychain.firebaseEmailAccount)
        email = nil
    }
}
