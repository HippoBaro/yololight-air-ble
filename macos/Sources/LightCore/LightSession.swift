import Foundation

/// Implementations deliver notifications/disconnections on the main actor.
@MainActor
public protocol LightTransport: AnyObject {
    var isConnected: Bool { get }
    var onNotification: ((Data) -> Void)? { get set }
    var onDisconnect: ((Error) -> Void)? { get set }
    /// Connect on demand and obtain the advertised or announced protocol identity.
    func connect() async throws -> DeviceIdentity
    func write(_ data: Data) async throws
    func disconnect()
}

/// Serializes queries because the light replies with FFFF, not the request sequence.
@MainActor
public final class LightSession {
    private struct PendingReply {
        let id = UUID()
        let command: UInt8
        let size: Int
        let continuation: CheckedContinuation<[UInt8], Error>
        var payload: [UInt8]?
        var writeAcknowledged = false
    }

    public private(set) var device: DeviceIdentity?
    private let transport: any LightTransport
    private let replyTimeout: Duration
    private let settlingDelay: Duration
    private var sequence: UInt16 = 0
    private var busy = false
    private var pending: PendingReply?
    private var timeoutTask: Task<Void, Never>?
    public var onDisconnect: ((Error) -> Void)?

    public var isConnected: Bool { transport.isConnected && device != nil }

    public init(transport: any LightTransport,
                replyTimeout: Duration = .seconds(4), settlingDelay: Duration = .milliseconds(250)) {
        self.transport = transport
        self.replyTimeout = replyTimeout
        self.settlingDelay = settlingDelay
        transport.onNotification = { [weak self] data in self?.receive(data) }
        transport.onDisconnect = { [weak self] error in
            self?.device = nil
            self?.finishReply(.failure(error))
            self?.onDisconnect?(error)
        }
    }

    public func connect() async throws {
        guard !busy else { throw LightError.busy }
        busy = true
        defer { busy = false }
        do {
            let identity = try await transport.connect()
            try Task.checkCancellation()
            guard transport.isConnected else { throw LightError.notConnected }
            device = identity
        } catch {
            disconnect()
            throw error
        }
    }

    public func disconnect() {
        device = nil
        finishReply(.failure(LightError.notConnected))
        transport.disconnect()
    }

    public func status() async throws -> LightState {
        try await perform {
            let power = try await self.query(0xa1, size: 1)[0]
            let brightness = Int(try await self.query(0xa2, size: 1)[0])
            let temperature = Self.integer(try await self.query(0xa3, size: 2))
            let range = try await self.temperatureLimits()
            guard power <= 1, brightness <= 100, range.contains(temperature), temperature % 100 == 0 else {
                throw LightError.invalidValue("The light returned invalid settings.")
            }
            return LightState(isOn: power == 1, brightness: brightness,
                              temperature: temperature, temperatureRange: range)
        }
    }

    @discardableResult
    public func set(_ setting: LightSetting, to value: Int) async throws -> Int {
        try await perform {
            switch setting {
            case .power:
                guard (0...1).contains(value) else { throw LightError.invalidValue("Power must be off or on.") }
            case .brightness:
                guard (0...100).contains(value) else { throw LightError.invalidValue("Brightness must be 0–100%.") }
            case .temperature:
                let range = try await self.temperatureLimits()
                guard range.contains(value), value % 100 == 0 else {
                    throw LightError.invalidValue("Temperature must be \(range.lowerBound)–\(range.upperBound) K, in 100 K steps.")
                }
            }
            let payload: [UInt8] = setting.size == 2
                ? [UInt8(value >> 8), UInt8(value & 0xff)] : [UInt8(value)]
            try await self.transport.write(self.frame(setting.rawValue, kind: 1, payload: payload))
            try await Task.sleep(for: self.settlingDelay)
            let actual = Self.integer(try await self.query(setting.query, size: setting.size))
            guard actual == value else { throw LightError.readbackMismatch(expected: value, actual: actual) }
            return actual
        }
    }

    private func perform<T>(_ operation: () async throws -> T) async throws -> T {
        guard !busy else { throw LightError.busy }
        guard isConnected else { throw LightError.notConnected }
        busy = true
        defer { busy = false }
        do {
            return try await operation()
        } catch {
            // A timed-out reply has no usable request sequence. Start a new
            // connection before any further operation rather than reuse it.
            disconnect()
            throw error
        }
    }

    private func temperatureLimits() async throws -> ClosedRange<Int> {
        let bytes = try await query(0xa5, size: 4)
        let low = Self.integer(Array(bytes.prefix(2)))
        let high = Self.integer(Array(bytes.suffix(2)))
        guard low >= 100, low < high, low % 100 == 0, high % 100 == 0 else {
            throw LightError.invalidValue("The light returned invalid temperature limits.")
        }
        return low...high
    }

    private static func integer(_ bytes: [UInt8]) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    private func frame(_ command: UInt8, kind: UInt8, payload: [UInt8] = []) throws -> Data {
        guard let device else { throw LightError.notConnected }
        sequence &+= 1
        return try LightFrame.encode(mac: device.mac, command: command, kind: kind,
                                     sequence: sequence, payload: payload)
    }

    private func query(_ command: UInt8, size: Int) async throws -> [UInt8] {
        let packet = try frame(command, kind: 2)
        return try await withCheckedThrowingContinuation { continuation in
            let request = PendingReply(command: command, size: size, continuation: continuation)
            pending = request
            timeoutTask = Task { [weak self, replyTimeout] in
                do { try await Task.sleep(for: replyTimeout) } catch { return }
                guard self?.pending?.id == request.id else { return }
                self?.finishReply(.failure(LightError.timeout))
            }
            Task { [weak self, transport] in
                do {
                    try await transport.write(packet)
                    guard self?.pending?.id == request.id else { return }
                    self?.pending?.writeAcknowledged = true
                    self?.completeIfReady()
                } catch {
                    guard self?.pending?.id == request.id else { return }
                    self?.finishReply(.failure(error))
                }
            }
        }
    }

    private func receive(_ data: Data) {
        // Invalid/A4 announcements and foreign identities must not satisfy a query.
        guard let device, let frame = try? LightFrame.decode(data), frame.mac == device.mac,
              let request = pending, frame.command == request.command, frame.kind == 2 else { return }
        guard frame.payload.count == request.size else {
            finishReply(.failure(LightError.invalidPacket("Unexpected reply payload length.")))
            return
        }
        pending?.payload = frame.payload
        completeIfReady()
    }

    private func completeIfReady() {
        // A notification may arrive before the GATT write acknowledgement.
        guard let request = pending, request.writeAcknowledged, let payload = request.payload else { return }
        finishReply(.success(payload))
    }

    private func finishReply(_ result: Result<[UInt8], Error>) {
        guard let request = pending else { return }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        request.continuation.resume(with: result)
    }
}
