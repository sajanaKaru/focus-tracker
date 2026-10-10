import Foundation
@testable import FocusCore

final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: @Sendable (URLRequest) -> (Int, String)

    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) { self.handler = handler }

    private func record(_ request: URLRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let (code, body) = handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: [:])!)
    }

    func json(_ index: Int) -> [String: Any]? {
        requests[index].httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var isOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
