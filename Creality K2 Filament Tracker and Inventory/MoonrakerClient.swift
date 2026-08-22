//
//  MoonrakerClient.swift
//  Creality K2 Filament Tracker and Inventory
//
//  A minimal JSON-RPC-over-websocket client for Moonraker (the API surface
//  the K2 Plus's Fluidd-style dashboard runs on). Replaces the old Python
//  app's HTTP polling with a persistent subscription: once connected, the
//  printer pushes `notify_status_update` messages the instant CFS slots,
//  the external holder, or print status change — no polling interval to
//  tune, no missed-window gap between polls.
//
//  Deliberately dependency-free (Foundation's URLSessionWebSocketTask only)
//  and deliberately simple: fixed 5s reconnect delay, no exponential
//  backoff, no request queuing beyond what's needed for
//  printer.objects.subscribe. This is a single-printer personal tool, not
//  a general Moonraker SDK.
//

import Foundation

@MainActor
final class MoonrakerClient {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    enum MoonrakerError: Error, LocalizedError {
        case notConnected
        case invalidAddress
        case rpc(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to printer."
            case .invalidAddress: return "Invalid printer address."
            case .rpc(let message): return message
            }
        }
    }

    private(set) var state: ConnectionState = .disconnected {
        didSet { onStateChange?(state) }
    }

    /// Fired whenever a `notify_status_update` push arrives, with the raw
    /// status payload (e.g. {"box": {...}, "filament_rack": {...}}).
    var onStatusUpdate: (([String: Any]) -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?

    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var baseURL: String = ""
    private var shouldReconnect = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var nextRequestId = 1
    private var pendingContinuations: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    func connect(to baseURL: String) {
        self.baseURL = baseURL
        shouldReconnect = true
        openSocket()
    }

    func disconnect() {
        shouldReconnect = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session = nil
        state = .disconnected
    }

    private func openSocket() {
        guard let url = Self.websocketURL(from: baseURL) else {
            state = .failed("Invalid printer address")
            return
        }
        state = .connecting
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.webSocketTask = task
        task.resume()
        receiveNext()
        Task { [weak self] in
            await self?.subscribeToPrinterObjects()
        }
    }

    private func receiveNext() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.handleFailure(error)
                case .success(let message):
                    self.handle(message: message)
                    self.receiveNext()
                }
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let raw): data = raw
        case .string(let text): data = Data(text.utf8)
        @unknown default: return
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }

        if let id = json["id"] as? Int, let continuation = pendingContinuations.removeValue(forKey: id) {
            if let error = json["error"] as? [String: Any] {
                continuation.resume(throwing: MoonrakerError.rpc(error["message"] as? String ?? "Unknown printer error"))
            } else {
                continuation.resume(returning: (json["result"] as? [String: Any]) ?? [:])
            }
            return
        }

        if json["method"] as? String == "notify_status_update",
           let params = json["params"] as? [Any],
           let status = params.first as? [String: Any] {
            onStatusUpdate?(status)
        }
    }

    private func handleFailure(_ error: Error) {
        state = .failed(error.localizedDescription)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        reconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.openSocket() }
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    @discardableResult
    private func send(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard let task = webSocketTask else { throw MoonrakerError.notConnected }
        let id = nextRequestId
        nextRequestId += 1
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params, "id": id]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw MoonrakerError.rpc("Could not encode request: \(error.localizedDescription)")
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuations[id] = continuation
            task.send(.data(data)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.pendingContinuations.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        }
    }

    private func subscribeToPrinterObjects() async {
        do {
            let result = try await send(
                method: "printer.objects.subscribe",
                params: [
                    "objects": [
                        "box": NSNull(),
                        "filament_rack": NSNull(),
                        "print_stats": NSNull(),
                        "virtual_sdcard": NSNull(),
                    ]
                ]
            )
            state = .connected
            if let status = result["status"] as? [String: Any] {
                onStatusUpdate?(status)
            }
        } catch {
            state = .failed(error.localizedDescription)
            scheduleReconnect()
        }
    }

    private static func websocketURL(from httpBaseURL: String) -> URL? {
        var text = httpBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text), components.host != nil else { return nil }
        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        components.path = "/websocket"
        return components.url
    }
}
