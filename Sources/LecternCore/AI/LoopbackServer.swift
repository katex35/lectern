import Foundation
import Network

/// A one-shot HTTP listener on the loopback interface that receives the browser's redirect after
/// sign-in. Only `GET <path>` with this attempt's `state` counts: other paths get a 404, another
/// state (an old tab, another program) a 400, and the wait goes on.
final class LoopbackServer: @unchecked Sendable {
    let path: String
    let state: String
    let page: String
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "lectern.loopback")
    private let lock = NSLock()
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var outcome: Result<[String: String], Error>?

    private init(listener: NWListener, path: String, state: String, page: String) {
        self.listener = listener
        self.path = path
        self.state = state
        self.page = page
    }

    /// Starts listening on a free port of 127.0.0.1, or on `port` of localhost (both address
    /// families) when the sign-in's redirect address is registered with a fixed port.
    static func start(path: String, state: String, page: String, port fixed: UInt16? = nil) async throws -> LoopbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        // a sign-in tried again right after one ended must get the same port back
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        if let fixed {
            guard let port = NWEndpoint.Port(rawValue: fixed) else { throw ChatGPTAuthError.portInUse(Int(fixed)) }
            listener = try NWListener(using: parameters, on: port)
        } else {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: parameters)
        }
        let server = LoopbackServer(listener: listener, path: path, state: state, page: page)
        listener.newConnectionHandler = { [weak server] connection in server?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // state updates arrive one at a time on the server's queue
            let started = Flag()
            listener.stateUpdateHandler = { [weak listener] state in
                guard !started.isSet else { return }
                switch state {
                case .ready:
                    started.isSet = true
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    // waiting would never end on its own for a loopback port
                    started.isSet = true
                    listener?.cancel()
                    if let fixed, case .posix(let code) = error, code == .EADDRINUSE {
                        continuation.resume(throwing: ChatGPTAuthError.portInUse(Int(fixed)))
                    } else {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    started.isSet = true
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: server.queue)
        }
        guard let port = listener.port?.rawValue, port != 0 else {
            listener.cancel()
            throw ChatGPTAuthError.failed("Could not open a local port for sign-in")
        }
        server.port = port
        return server
    }

    /// Waits for the redirect and returns its query parameters.
    func callback(timeout: TimeInterval) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: String], Error>) in
                let ready: Result<[String: String], Error>? = lock.withLock {
                    if let outcome { return outcome }
                    waiter = continuation
                    return nil
                }
                if let ready {
                    continuation.resume(with: ready)
                    return
                }
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(ChatGPTAuthError.timedOut)) }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    /// Closes the port and waits briefly until it is free, so the next sign-in can take it.
    func stop() {
        let closed = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .cancelled = state { closed.signal() }
        }
        listener.cancel()
        finish(.failure(CancellationError()))
        _ = closed.wait(timeout: .now() + 2)
    }

    private func finish(_ result: Result<[String: String], Error>) {
        let waiting: CheckedContinuation<[String: String], Error>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: buffer[..<end.lowerBound])
            } else if complete || error != nil || buffer.count > 65536 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: Data) {
        let requestLine = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: String(parts[1])),
              components.path == path else {
            send(connection, status: "404 Not Found", body: "")
            return
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        guard query["state"] == state else {
            send(connection, status: "400 Bad Request", body: "")
            return
        }
        send(connection, status: "200 OK", body: page)
        finish(.success(query))
    }

    private final class Flag: @unchecked Sendable {
        var isSet = false
    }

    private func send(_ connection: NWConnection, status: String, body: String) {
        let content = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(content.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + content, completion: .contentProcessed { _ in connection.cancel() })
    }
}
