import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct GatewayBusClient: Sendable, Equatable {
    let recipientID: String
    let platform: String
    let appId: String
    let sessionId: String
    let deviceId: String
    let callbackEndpoint: String
    let preferredTransports: [ClientTransport]
    let usbmuxdHint: USBMuxdHint?

    var transportOrder: [ClientTransport] {
        preferredTransports.isEmpty ? [.httpCallback] : preferredTransports
    }
}

struct GatewayMessageBusDispatchSummary: Sendable {
    let deliveredCount: Int
    let acks: [BusAck]

    var ackedCount: Int {
        acks.count
    }

    var timeoutCount: Int {
        max(0, deliveredCount - ackedCount)
    }
}

protocol ClientTransportAdapter: Sendable {
    var transport: ClientTransport { get }
    func send(_ envelope: BusEnvelope, to client: GatewayBusClient) async -> BusAck?
}

actor GatewayMessageBus {
    private let adapters: [ClientTransport: any ClientTransportAdapter]

    init(adapters: [any ClientTransportAdapter]) {
        var mapped: [ClientTransport: any ClientTransportAdapter] = [:]
        for adapter in adapters {
            mapped[adapter.transport] = adapter
        }
        self.adapters = mapped
    }

    func send(_ envelope: BusEnvelope, to client: GatewayBusClient) async -> BusAck? {
        for transport in client.transportOrder {
            guard let adapter = adapters[transport] else {
                continue
            }
            if let ack = await adapter.send(envelope, to: client) {
                return Self.normalizedAck(ack, client: client, transport: transport)
            }
        }
        return nil
    }

    func dispatch(
        _ envelope: BusEnvelope,
        to clients: [GatewayBusClient],
        onAck: @Sendable @escaping (GatewayBusClient, BusAck) -> Void = { _, _ in }
    ) async -> GatewayMessageBusDispatchSummary {
        let deliveredCount = clients.count
        let acks = await withTaskGroup(of: (GatewayBusClient, BusAck?).self, returning: [BusAck].self) { group in
            for client in clients {
                group.addTask { [self] in
                    let ack = await send(envelope, to: client)
                    return (client, ack)
                }
            }

            var results: [BusAck] = []
            for await (client, ack) in group {
                guard let ack else {
                    continue
                }
                onAck(client, ack)
                results.append(ack)
            }
            return results
        }

        return GatewayMessageBusDispatchSummary(deliveredCount: deliveredCount, acks: acks)
    }

    private static func normalizedAck(
        _ ack: BusAck,
        client: GatewayBusClient,
        transport: ClientTransport
    ) -> BusAck {
        BusAck(
            requestId: ack.requestId,
            command: ack.command,
            status: ack.status,
            message: ack.message,
            timestamp: ack.timestamp,
            recipientID: ack.recipientID ?? client.recipientID,
            transport: ack.transport ?? transport
        )
    }
}

struct HTTPCallbackAdapter: ClientTransportAdapter {
    let transport: ClientTransport = .httpCallback
    let timeout: TimeInterval

    init(timeout: TimeInterval = 3) {
        self.timeout = max(0.1, timeout)
    }

    func send(_ envelope: BusEnvelope, to client: GatewayBusClient) async -> BusAck? {
        guard let requestURL = Self.makeRequestURL(from: client.callbackEndpoint) else {
            return nil
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(envelope)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let ack = try JSONDecoder().decode(BusAck.self, from: data)
            return BusAck(
                requestId: ack.requestId,
                command: ack.command,
                status: ack.status,
                message: ack.message,
                timestamp: ack.timestamp,
                recipientID: ack.recipientID ?? client.recipientID,
                transport: ack.transport ?? transport
            )
        } catch {
            return nil
        }
    }

    fileprivate static func makeRequestURL(from endpoint: String) -> URL? {
        guard let endpointURL = URL(string: endpoint) else {
            return nil
        }
        let path = endpointURL.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasSuffix("/v2/client/command") {
            return endpointURL
        }
        return endpointURL
            .appending(path: "v2")
            .appending(path: "client")
            .appending(path: "command")
    }
}

struct WebSocketAdapter: ClientTransportAdapter {
    let transport: ClientTransport = .webSocket
    private let sender: (@Sendable (GatewayBusClient, BusEnvelope) async -> BusAck?)?

    init(sender: (@Sendable (GatewayBusClient, BusEnvelope) async -> BusAck?)? = nil) {
        self.sender = sender
    }

    func send(_ envelope: BusEnvelope, to client: GatewayBusClient) async -> BusAck? {
        guard let sender else {
            return nil
        }

        let ack = await sender(client, envelope)
        return BusAck(
            requestId: ack?.requestId ?? envelope.requestId,
            command: ack?.command ?? envelope.command,
            status: ack?.status ?? "ok",
            message: ack?.message,
            timestamp: ack?.timestamp ?? envelope.timestamp,
            recipientID: ack?.recipientID ?? client.recipientID,
            transport: ack?.transport ?? transport
        )
    }
}

protocol USBMuxdConnectionFactory: Sendable {
    func connect(to path: String) throws -> USBMuxdConnection
}

protocol USBMuxdConnection: AnyObject, Sendable {
    func write(_ data: Data) throws
    func read(maxBytes: Int) throws -> Data
    func close()
}

struct USBMuxdHTTPAdapter: ClientTransportAdapter {
    let transport: ClientTransport = .usbmuxdHTTP
    private let connectionFactory: any USBMuxdConnectionFactory
    private let timeout: TimeInterval

    init(
        timeout: TimeInterval = 3,
        connectionFactory: any USBMuxdConnectionFactory = POSIXUSBMuxdConnectionFactory()
    ) {
        self.timeout = max(0.1, timeout)
        self.connectionFactory = connectionFactory
    }

    func send(_ envelope: BusEnvelope, to client: GatewayBusClient) async -> BusAck? {
        guard let hint = client.usbmuxdHint else {
            return nil
        }
        guard let requestURL = HTTPCallbackAdapter.makeRequestURL(from: client.callbackEndpoint) else {
            return nil
        }

        let socketPath = hint.socketPath ?? "/var/run/usbmuxd"
        let targetPort = requestURL.port ?? defaultPort(for: requestURL)

        let connection: USBMuxdConnection
        do {
            connection = try connectionFactory.connect(to: socketPath)
        } catch {
            return nil
        }
        defer { connection.close() }

        do {
            try connection.write(Self.makeConnectRequest(deviceID: hint.deviceID, port: targetPort))
            guard try Self.readConnectResult(from: connection) == 0 else {
                return nil
            }

            let body = try JSONEncoder().encode(envelope)
            try connection.write(
                Self.makeHTTPRequest(
                    url: requestURL,
                    body: body
                )
            )
            let response = try Self.readHTTPResponse(from: connection, timeout: timeout)
            guard (200..<300).contains(response.statusCode) else {
                return nil
            }

            let ack = try JSONDecoder().decode(BusAck.self, from: response.body)
            return BusAck(
                requestId: ack.requestId,
                command: ack.command,
                status: ack.status,
                message: ack.message,
                timestamp: ack.timestamp,
                recipientID: ack.recipientID ?? client.recipientID,
                transport: ack.transport ?? transport
            )
        } catch {
            return nil
        }
    }

    static func makeConnectRequest(deviceID: Int, port: Int) throws -> Data {
        guard deviceID > 0 else {
            throw USBMuxdAdapterError.invalidDeviceID
        }
        guard (1...Int(UInt16.max)).contains(port) else {
            throw USBMuxdAdapterError.invalidPort
        }

        let payload = [
            "BundleID": "dev.linhey.neptune-gateway-swift",
            "ClientVersionString": "neptune-gateway-swift",
            "DeviceID": deviceID,
            "MessageType": "Connect",
            "PortNumber": Int(UInt16(port).byteSwapped),
            "ProgName": "neptune-gateway-swift",
        ] as [String: Any]
        let plist = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)

        var data = Data()
        data.append(littleEndian: UInt32(16 + plist.count))
        data.append(littleEndian: 1)
        data.append(littleEndian: 8)
        data.append(littleEndian: 1)
        data.append(plist)
        return data
    }

    static func makeResultResponse(number: Int) throws -> Data {
        let payload: [String: Any] = ["MessageType": "Result", "Number": number]
        let plist = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        var data = Data()
        data.append(littleEndian: UInt32(16 + plist.count))
        data.append(littleEndian: 1)
        data.append(littleEndian: 8)
        data.append(littleEndian: 1)
        data.append(plist)
        return data
    }

    private static func readConnectResult(from connection: USBMuxdConnection) throws -> Int {
        let header = try readExact(from: connection, count: 16)
        let messageLength = Int(header.readLittleEndianUInt32(at: 0))
        guard messageLength >= 16 else {
            throw USBMuxdAdapterError.invalidResponse
        }

        let payload = try readExact(from: connection, count: messageLength - 16)
        guard
            let plist = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil) as? [String: Any],
            let number = plist["Number"] as? Int
        else {
            throw USBMuxdAdapterError.invalidResponse
        }
        return number
    }

    private static func makeHTTPRequest(url: URL, body: Data) -> Data {
        let pathWithQuery: String = {
            let path = url.path.isEmpty ? "/v2/client/command" : url.path
            if let query = url.query, !query.isEmpty {
                return path + "?" + query
            }
            return path
        }()
        let host = url.host ?? "localhost"
        let request = """
        POST \(pathWithQuery) HTTP/1.1\r
        Host: \(host)\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r
        """

        var data = Data(request.utf8)
        data.append(body)
        return data
    }

    private static func readHTTPResponse(
        from connection: USBMuxdConnection,
        timeout: TimeInterval
    ) throws -> (statusCode: Int, body: Data) {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(max(0.1, timeout))

        while Date() < deadline {
            let chunk = try connection.read(maxBytes: 4096)
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)
        }

        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            throw USBMuxdAdapterError.invalidHTTPResponse
        }

        let headerData = buffer.prefix(upTo: headerRange.lowerBound)
        let body = buffer.suffix(from: headerRange.upperBound)
        let lines = String(decoding: headerData, as: UTF8.self)
            .split(separator: "\r\n", omittingEmptySubsequences: false)
        guard
            let statusLine = lines.first,
            let statusCode = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) })
        else {
            throw USBMuxdAdapterError.invalidHTTPResponse
        }
        return (statusCode, Data(body))
    }

    private static func readExact(from connection: USBMuxdConnection, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            let chunk = try connection.read(maxBytes: count - data.count)
            guard !chunk.isEmpty else {
                throw USBMuxdAdapterError.unexpectedEOF
            }
            data.append(chunk)
        }
        return data
    }

    private func defaultPort(for url: URL) -> Int {
        url.scheme?.lowercased() == "https" ? 443 : 80
    }
}

private enum USBMuxdAdapterError: Error {
    case invalidDeviceID
    case invalidPort
    case invalidResponse
    case invalidHTTPResponse
    case unexpectedEOF
    case socketCreationFailed
    case connectFailed
    case pathTooLong
    case writeFailed
    case readFailed
}

private struct POSIXUSBMuxdConnectionFactory: USBMuxdConnectionFactory {
    func connect(to path: String) throws -> USBMuxdConnection {
        try POSIXUSBMuxdConnection(path: path)
    }
}

private final class POSIXUSBMuxdConnection: USBMuxdConnection, @unchecked Sendable {
    private var fileDescriptor: Int32

    init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw USBMuxdAdapterError.socketCreationFailed
        }
        self.fileDescriptor = fd

        do {
            try Self.connect(fd: fd, path: path)
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var remaining = data.count
            var current = baseAddress
            while remaining > 0 {
                let written = Darwin.write(fileDescriptor, current, remaining)
                guard written >= 0 else {
                    throw USBMuxdAdapterError.writeFailed
                }
                remaining -= written
                current = current.advanced(by: written)
            }
        }
    }

    func read(maxBytes: Int) throws -> Data {
        guard maxBytes > 0 else {
            return Data()
        }

        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let count = Darwin.read(fileDescriptor, &buffer, maxBytes)
        guard count >= 0 else {
            throw USBMuxdAdapterError.readFailed
        }
        return Data(buffer.prefix(Int(count)))
    }

    func close() {
        guard fileDescriptor >= 0 else {
            return
        }
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    private static func connect(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes: [CChar] = Array(path.utf8CString)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxLength else {
            throw USBMuxdAdapterError.pathTooLong
        }

        pathBytes.withUnsafeBufferPointer { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                destination.initialize(from: source.baseAddress!, count: source.count)
            }
        }

        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(
                    fd,
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            throw USBMuxdAdapterError.connectFailed
        }
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { buffer in
            append(buffer.bindMemory(to: UInt8.self))
        }
    }

    func readLittleEndianUInt32(at offset: Int) -> UInt32 {
        subdata(in: offset..<(offset + 4)).withUnsafeBytes { rawBuffer in
            UInt32(littleEndian: rawBuffer.load(as: UInt32.self))
        }
    }
}
