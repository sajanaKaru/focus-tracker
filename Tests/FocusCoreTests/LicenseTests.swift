import XCTest
@testable import FocusCore

final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func get(account: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func set(_ value: String, account: String) throws { lock.lock(); values[account] = value; lock.unlock() }
    func delete(account: String) { lock.lock(); values[account] = nil; lock.unlock() }
}

private struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}

private func firebaseError(_ message: String) -> (Int, String) {
    (400, #"{"error":{"code":400,"message":"\#(message)"}}"#)
}

private let signInOK = (200, #"{"email":"qa@team.dev","refreshToken":"refresh-1","idToken":"id-1"}"#)
private let refreshOK = (200, #"{"id_token":"id-2","refresh_token":"refresh-2","user_id":"u1"}"#)

@MainActor
final class LicenseTests: XCTestCase {
    private func makeStore(
        secrets: MemorySecretStore = MemorySecretStore(),
        _ handler: @escaping @Sendable (URLRequest) -> (Int, String)
    ) -> (LicenseStore, RecordingTransport, MemorySecretStore) {
        let transport = RecordingTransport(handler)
        let store = LicenseStore(client: LicenseClient(apiKey: "KEY", transport: transport), secrets: secrets)
        return (store, transport, secrets)
    }

    func testSignInStoresRefreshTokenAndActivates() async {
        let (store, transport, secrets) = makeStore { _ in signInOK }
        let error = await store.signIn(email: "qa@team.dev", password: "pw")
        XCTAssertNil(error)
        XCTAssertEqual(store.state, .active)
        XCTAssertEqual(store.email, "qa@team.dev")
        XCTAssertEqual(secrets.get(account: Keychain.firebaseRefreshAccount), "refresh-1")
        XCTAssertEqual(transport.requests[0].url?.absoluteString, "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=KEY")
        let body = transport.json(0)
        XCTAssertEqual(body?["email"] as? String, "qa@team.dev")
        XCTAssertEqual(body?["password"] as? String, "pw")
        XCTAssertEqual(body?["returnSecureToken"] as? Bool, true)
    }

    func testWrongPasswordReportsErrorAndStoresNothing() async {
        let (store, _, secrets) = makeStore { _ in firebaseError("INVALID_LOGIN_CREDENTIALS") }
        let error = await store.signIn(email: "qa@team.dev", password: "bad")
        XCTAssertNotNil(error)
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertNil(secrets.get(account: Keychain.firebaseRefreshAccount))
    }

    func testSignInOfDisabledUserIsSuspended() async {
        let (store, _, secrets) = makeStore { _ in firebaseError("USER_DISABLED") }
        _ = await store.signIn(email: "qa@team.dev", password: "pw")
        XCTAssertEqual(store.state, .suspended)
        XCTAssertNil(secrets.get(account: Keychain.firebaseRefreshAccount))
    }

    func testCheckWithoutTokenIsSignedOut() async {
        let (store, transport, _) = makeStore { _ in refreshOK }
        await store.check()
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCheckRefreshesAndRotatesToken() async throws {
        let secrets = MemorySecretStore()
        try secrets.set("refresh-1", account: Keychain.firebaseRefreshAccount)
        try secrets.set("qa@team.dev", account: Keychain.firebaseEmailAccount)
        let (store, transport, _) = makeStore(secrets: secrets) { _ in refreshOK }
        await store.check()
        XCTAssertEqual(store.state, .active)
        XCTAssertEqual(store.email, "qa@team.dev")
        XCTAssertEqual(secrets.get(account: Keychain.firebaseRefreshAccount), "refresh-2")
        XCTAssertEqual(transport.requests[0].url?.absoluteString, "https://securetoken.googleapis.com/v1/token?key=KEY")
        XCTAssertEqual(String(data: transport.requests[0].httpBody ?? Data(), encoding: .utf8), "grant_type=refresh_token&refresh_token=refresh-1")
    }

    func testDisabledUserIsSuspendedAndKeepsToken() async throws {
        let secrets = MemorySecretStore()
        try secrets.set("refresh-1", account: Keychain.firebaseRefreshAccount)
        let (store, _, _) = makeStore(secrets: secrets) { _ in firebaseError("USER_DISABLED") }
        await store.check()
        XCTAssertEqual(store.state, .suspended)
        XCTAssertEqual(secrets.get(account: Keychain.firebaseRefreshAccount), "refresh-1")
    }

    func testExpiredSessionClearsTokenAndSignsOut() async throws {
        for message in ["TOKEN_EXPIRED", "USER_NOT_FOUND", "INVALID_REFRESH_TOKEN"] {
            let secrets = MemorySecretStore()
            try secrets.set("refresh-1", account: Keychain.firebaseRefreshAccount)
            let (store, _, _) = makeStore(secrets: secrets) { _ in firebaseError(message) }
            await store.check()
            XCTAssertEqual(store.state, .signedOut, message)
            XCTAssertNil(secrets.get(account: Keychain.firebaseRefreshAccount), message)
        }
    }

    func testNetworkFailureIsUnreachableAndKeepsToken() async throws {
        let secrets = MemorySecretStore()
        try secrets.set("refresh-1", account: Keychain.firebaseRefreshAccount)
        let store = LicenseStore(client: LicenseClient(apiKey: "KEY", transport: OfflineTransport()), secrets: secrets)
        await store.check()
        XCTAssertEqual(store.state, .unreachable)
        XCTAssertEqual(secrets.get(account: Keychain.firebaseRefreshAccount), "refresh-1")
    }

    func testServerErrorIsUnreachable() async throws {
        let secrets = MemorySecretStore()
        try secrets.set("refresh-1", account: Keychain.firebaseRefreshAccount)
        let (store, _, _) = makeStore(secrets: secrets) { _ in (503, "Service Unavailable") }
        await store.check()
        XCTAssertEqual(store.state, .unreachable)
    }

    func testSuspendAndReenableFlipsState() async throws {
        let secrets = MemorySecretStore()
        try secrets.set("refresh-1", account: Keychain.firebaseRefreshAccount)
        let suspended = Switch(false)
        let (store, _, _) = makeStore(secrets: secrets) { _ in suspended.isOn ? firebaseError("USER_DISABLED") : refreshOK }
        await store.check()
        XCTAssertEqual(store.state, .active)
        suspended.isOn = true
        await store.check()
        XCTAssertEqual(store.state, .suspended)
        suspended.isOn = false
        await store.check()
        XCTAssertEqual(store.state, .active)
    }

    func testSignOutRemovesCredentialsOnly() async throws {
        let (store, _, secrets) = makeStore { _ in signInOK }
        _ = await store.signIn(email: "qa@team.dev", password: "pw")
        store.signOut()
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertNil(store.email)
        XCTAssertNil(secrets.get(account: Keychain.firebaseRefreshAccount))
        XCTAssertNil(secrets.get(account: Keychain.firebaseEmailAccount))
    }

    func testPasswordResetRequest() async {
        let (store, transport, _) = makeStore { _ in (200, #"{"email":"qa@team.dev"}"#) }
        let error = await store.resetPassword(email: "qa@team.dev")
        XCTAssertNil(error)
        XCTAssertEqual(transport.requests[0].url?.absoluteString, "https://identitytoolkit.googleapis.com/v1/accounts:sendOobCode?key=KEY")
        XCTAssertEqual(transport.json(0)?["requestType"] as? String, "PASSWORD_RESET")
        XCTAssertEqual(transport.json(0)?["email"] as? String, "qa@team.dev")
    }

    func testMissingApiKeyNeverCallsNetwork() async throws {
        let secrets = MemorySecretStore()
        try secrets.set("refresh-1", account: Keychain.firebaseRefreshAccount)
        let transport = RecordingTransport { _ in refreshOK }
        let store = LicenseStore(client: LicenseClient(apiKey: "", transport: transport), secrets: secrets)
        await store.check()
        XCTAssertEqual(store.state, .unreachable)
        XCTAssertTrue(transport.requests.isEmpty)
    }
}
