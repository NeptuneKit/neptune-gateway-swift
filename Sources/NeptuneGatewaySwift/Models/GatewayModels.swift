import Foundation
import Vapor
import STJSON

public struct SourceInfo: Content, Sendable {
    public let sdkName: String?
    public let sdkVersion: String?
    public let file: String?
    public let function: String?
    public let line: Int?

    public init(
        sdkName: String? = nil,
        sdkVersion: String? = nil,
        file: String? = nil,
        function: String? = nil,
        line: Int? = nil
    ) {
        self.sdkName = sdkName
        self.sdkVersion = sdkVersion
        self.file = file
        self.function = function
        self.line = line
    }
}

public struct IngestLogRecord: Content, Sendable {
    public let timestamp: String
    public let level: String
    public let message: String
    public let platform: String
    public let appId: String
    public let sessionId: String
    public let deviceId: String
    public let category: String
    public let attributes: [String: String]?
    public let source: SourceInfo?

    public init(
        timestamp: String,
        level: String,
        message: String,
        platform: String,
        appId: String,
        sessionId: String,
        deviceId: String,
        category: String,
        attributes: [String: String]? = nil,
        source: SourceInfo? = nil
    ) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.platform = platform
        self.appId = appId
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.category = category
        self.attributes = attributes
        self.source = source
    }
}

public struct LogRecord: Content, Sendable {
    public let id: Int64
    public let timestamp: String
    public let level: String
    public let message: String
    public let platform: String
    public let appId: String
    public let sessionId: String
    public let deviceId: String
    public let category: String
    public let attributes: [String: String]?
    public let source: SourceInfo?

    public init(
        id: Int64,
        timestamp: String,
        level: String,
        message: String,
        platform: String,
        appId: String,
        sessionId: String,
        deviceId: String,
        category: String,
        attributes: [String: String]? = nil,
        source: SourceInfo? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.platform = platform
        self.appId = appId
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.category = category
        self.attributes = attributes
        self.source = source
    }
}

public struct QueryResponse: Content, Sendable {
    public let records: [LogRecord]
    public let hasMore: Bool
    public let meta: QueryResponseMeta?

    public init(records: [LogRecord], hasMore: Bool, meta: QueryResponseMeta? = nil) {
        self.records = records
        self.hasMore = hasMore
        self.meta = meta
    }
}

public struct QueryResponseMeta: Content, Sendable {
    public let partialFailures: [QueryPartialFailure]

    public init(partialFailures: [QueryPartialFailure]) {
        self.partialFailures = partialFailures
    }
}

public struct QueryPartialFailure: Content, Sendable {
    public let platform: String
    public let appId: String
    public let sessionId: String
    public let deviceId: String
    public let callbackEndpoint: String
    public let reason: String

    public init(
        platform: String,
        appId: String,
        sessionId: String,
        deviceId: String,
        callbackEndpoint: String,
        reason: String
    ) {
        self.platform = platform
        self.appId = appId
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.callbackEndpoint = callbackEndpoint
        self.reason = reason
    }
}

public struct IngestResponse: Content, Sendable {
    public let accepted: Int

    public init(accepted: Int) {
        self.accepted = accepted
    }
}

public struct MetricsResponse: Content, Sendable {
    public let ingestAcceptedTotal: Int
    public let sourceCount: Int
    public let retainedRecordCount: Int
    public let retentionMaxRecordCount: Int
    public let retentionMaxAgeSeconds: Int
    public let retentionDroppedTotal: Int

    public init(
        ingestAcceptedTotal: Int,
        sourceCount: Int,
        retainedRecordCount: Int = 0,
        retentionMaxRecordCount: Int = 200_000,
        retentionMaxAgeSeconds: Int = 60 * 60 * 24 * 14,
        retentionDroppedTotal: Int = 0
    ) {
        self.ingestAcceptedTotal = ingestAcceptedTotal
        self.sourceCount = sourceCount
        self.retainedRecordCount = retainedRecordCount
        self.retentionMaxRecordCount = retentionMaxRecordCount
        self.retentionMaxAgeSeconds = retentionMaxAgeSeconds
        self.retentionDroppedTotal = retentionDroppedTotal
    }
}

public struct SourceSnapshot: Codable, Sendable, Equatable {
    public let platform: String
    public let appId: String
    public let sessionId: String
    public let deviceId: String
    public let lastSeenAt: String

    public init(platform: String, appId: String, sessionId: String, deviceId: String, lastSeenAt: String) {
        self.platform = platform
        self.appId = appId
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.lastSeenAt = lastSeenAt
    }
}

public struct SourceResponse: Content, Sendable {
    public let items: [SourceSnapshot]

    public init(items: [SourceSnapshot]) {
        self.items = items
    }
}

public struct ViewTreeNode: Content, Sendable, Equatable {
    public struct Frame: Content, Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Style: Content, Sendable, Equatable {
        public let opacity: Double?
        public let backgroundColor: String?
        public let textColor: String?
        public let typographyUnit: String?
        public let sourceTypographyUnit: String?
        public let platformFontScale: Double?
        public let fontSize: Double?
        public let lineHeight: Double?
        public let letterSpacing: Double?
        public let fontWeight: String?
        public let fontWeightRaw: String?
        public let fontFamily: String?
        public let borderRadius: Double?
        public let borderWidth: Double?
        public let borderColor: String?
        public let zIndex: Double?
        public let textAlign: String?
        public let textContentAlign: String?
        public let textOverflow: String?
        public let wordBreak: String?
        public let paddingTop: Double?
        public let paddingRight: Double?
        public let paddingBottom: Double?
        public let paddingLeft: Double?

        public init(
            opacity: Double? = nil,
            backgroundColor: String? = nil,
            textColor: String? = nil,
            typographyUnit: String? = nil,
            sourceTypographyUnit: String? = nil,
            platformFontScale: Double? = nil,
            fontSize: Double? = nil,
            lineHeight: Double? = nil,
            letterSpacing: Double? = nil,
            fontWeight: String? = nil,
            fontWeightRaw: String? = nil,
            fontFamily: String? = nil,
            borderRadius: Double? = nil,
            borderWidth: Double? = nil,
            borderColor: String? = nil,
            zIndex: Double? = nil,
            textAlign: String? = nil,
            textContentAlign: String? = nil,
            textOverflow: String? = nil,
            wordBreak: String? = nil,
            paddingTop: Double? = nil,
            paddingRight: Double? = nil,
            paddingBottom: Double? = nil,
            paddingLeft: Double? = nil
        ) {
            self.opacity = opacity
            self.backgroundColor = backgroundColor
            self.textColor = textColor
            self.typographyUnit = typographyUnit
            self.sourceTypographyUnit = sourceTypographyUnit
            self.platformFontScale = platformFontScale
            self.fontSize = fontSize
            self.lineHeight = lineHeight
            self.letterSpacing = letterSpacing
            self.fontWeight = fontWeight
            self.fontWeightRaw = fontWeightRaw
            self.fontFamily = fontFamily
            self.borderRadius = borderRadius
            self.borderWidth = borderWidth
            self.borderColor = borderColor
            self.zIndex = zIndex
            self.textAlign = textAlign
            self.textContentAlign = textContentAlign
            self.textOverflow = textOverflow
            self.wordBreak = wordBreak
            self.paddingTop = paddingTop
            self.paddingRight = paddingRight
            self.paddingBottom = paddingBottom
            self.paddingLeft = paddingLeft
        }
    }

    public struct Constraint: Content, Sendable, Equatable {
        public let id: String
        public let source: String
        public let relation: String
        public let firstAttribute: String
        public let secondAttribute: String?
        public let firstItem: String?
        public let secondItem: String?
        public let constant: Double
        public let multiplier: Double
        public let priority: Double
        public let isActive: Bool

        public init(
            id: String,
            source: String,
            relation: String,
            firstAttribute: String,
            secondAttribute: String? = nil,
            firstItem: String? = nil,
            secondItem: String? = nil,
            constant: Double,
            multiplier: Double,
            priority: Double,
            isActive: Bool
        ) {
            self.id = id
            self.source = source
            self.relation = relation
            self.firstAttribute = firstAttribute
            self.secondAttribute = secondAttribute
            self.firstItem = firstItem
            self.secondItem = secondItem
            self.constant = constant
            self.multiplier = multiplier
            self.priority = priority
            self.isActive = isActive
        }
    }

    public let id: String
    public let parentId: String?
    public let name: String
    public let frame: Frame?
    public let style: Style?
    public let constraints: [Constraint]?
    public let rawNode: InspectorPayloadValue?
    public let text: String?
    public let visible: Bool?
    public let children: [ViewTreeNode]

    public init(
        id: String,
        parentId: String?,
        name: String,
        frame: Frame? = nil,
        style: Style? = nil,
        constraints: [Constraint]? = nil,
        rawNode: InspectorPayloadValue? = nil,
        text: String? = nil,
        visible: Bool? = nil,
        children: [ViewTreeNode]
    ) {
        self.id = id
        self.parentId = parentId
        self.name = name
        self.frame = frame
        self.style = style
        self.constraints = constraints
        self.rawNode = rawNode
        self.text = text
        self.visible = visible
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case parentId
        case name
        case frame
        case style
        case constraints
        case rawNode
        case text
        case visible
        case children
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        name = try container.decode(String.self, forKey: .name)
        frame = try container.decodeIfPresent(Frame.self, forKey: .frame)
        style = try container.decodeIfPresent(Style.self, forKey: .style)
        constraints = try container.decodeIfPresent([Constraint].self, forKey: .constraints)
        rawNode = try container.decodeIfPresent(InspectorPayloadValue.self, forKey: .rawNode)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        visible = try container.decodeIfPresent(Bool.self, forKey: .visible)
        children = try container.decodeIfPresent([ViewTreeNode].self, forKey: .children) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if let parentId {
            try container.encode(parentId, forKey: .parentId)
        } else {
            try container.encodeNil(forKey: .parentId)
        }
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(frame, forKey: .frame)
        try container.encodeIfPresent(style, forKey: .style)
        try container.encodeIfPresent(constraints, forKey: .constraints)
        try container.encodeIfPresent(rawNode, forKey: .rawNode)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(visible, forKey: .visible)
        try container.encode(children, forKey: .children)
    }
}

public struct ViewTreeSnapshot: Content, Sendable, Equatable {
    public let snapshotId: String
    public let capturedAt: String
    public let platform: String
    public let roots: [ViewTreeNode]

    public init(snapshotId: String, capturedAt: String, platform: String, roots: [ViewTreeNode]) {
        self.snapshotId = snapshotId
        self.capturedAt = capturedAt
        self.platform = platform
        self.roots = roots
    }
}

public typealias InspectorPayloadValue = JSON

extension JSON: @unchecked @retroactive Sendable {}

public struct InspectorSnapshot: Content, Sendable, Equatable {
    public let snapshotId: String
    public let capturedAt: String
    public let platform: String
    public let available: Bool
    public let payload: InspectorPayloadValue?
    public let reason: String?

    public init(
        snapshotId: String,
        capturedAt: String,
        platform: String,
        available: Bool,
        payload: InspectorPayloadValue?,
        reason: String? = nil
    ) {
        self.snapshotId = snapshotId
        self.capturedAt = capturedAt
        self.platform = platform
        self.available = available
        self.payload = payload
        self.reason = reason
    }
}

public struct ViewTreeRawIngestRequest: Content, Sendable, Equatable {
    public let platform: String
    public let appId: String
    public let sessionId: String
    public let deviceId: String
    public let snapshotId: String?
    public let capturedAt: String?
    public let payload: InspectorPayloadValue

    public init(
        platform: String,
        appId: String,
        sessionId: String,
        deviceId: String,
        snapshotId: String? = nil,
        capturedAt: String? = nil,
        payload: InspectorPayloadValue
    ) {
        self.platform = platform
        self.appId = appId
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.snapshotId = snapshotId
        self.capturedAt = capturedAt
        self.payload = payload
    }
}

public struct HealthResponse: Content, Sendable {
    public let status: String
    public let version: String

    public init(status: String, version: String) {
        self.status = status
        self.version = version
    }
}

public struct DiscoveryResponse: Content, Sendable {
    public let host: String
    public let port: Int
    public let version: String

    public init(host: String, port: Int, version: String) {
        self.host = host
        self.port = port
        self.version = version
    }
}

public struct ClientRegisterRequest: Content, Sendable {
    public let platform: String
    public let appId: String
    public let sessionId: String?
    public let deviceId: String
    public let callbackEndpoint: String
    public let preferredTransports: [ClientTransport]?
    public let usbmuxdHint: USBMuxdHint?
    public let expiresAt: String?

    public init(
        platform: String,
        appId: String,
        sessionId: String? = nil,
        deviceId: String,
        callbackEndpoint: String,
        preferredTransports: [ClientTransport]? = nil,
        usbmuxdHint: USBMuxdHint? = nil,
        expiresAt: String? = nil
    ) {
        self.platform = platform
        self.appId = appId
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.callbackEndpoint = callbackEndpoint
        self.preferredTransports = preferredTransports
        self.usbmuxdHint = usbmuxdHint
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case platform
        case appId
        case sessionId
        case deviceId
        case callbackEndpoint
        case preferredTransports
        case usbmuxdHint
        case expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let platform = try container.decode(String.self, forKey: .platform)
        let appId = try container.decode(String.self, forKey: .appId)
        let sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        let deviceId = try container.decode(String.self, forKey: .deviceId)
        let callbackEndpointRaw = try container.decodeIfPresent(String.self, forKey: .callbackEndpoint)
        guard let callbackEndpoint = callbackEndpointRaw else {
            throw DecodingError.keyNotFound(
                CodingKeys.callbackEndpoint,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing callback endpoint fields."
                )
            )
        }
        let preferredTransports = try container.decodeIfPresent([ClientTransport].self, forKey: .preferredTransports)
        let usbmuxdHint = try container.decodeIfPresent(USBMuxdHint.self, forKey: .usbmuxdHint)
        let expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)

        self.init(
            platform: platform,
            appId: appId,
            sessionId: sessionId,
            deviceId: deviceId,
            callbackEndpoint: callbackEndpoint,
            preferredTransports: preferredTransports,
            usbmuxdHint: usbmuxdHint,
            expiresAt: expiresAt
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(platform, forKey: .platform)
        try container.encode(appId, forKey: .appId)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(callbackEndpoint, forKey: .callbackEndpoint)
        try container.encodeIfPresent(preferredTransports, forKey: .preferredTransports)
        try container.encodeIfPresent(usbmuxdHint, forKey: .usbmuxdHint)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
    }
}

public struct ClientSnapshot: Content, Sendable, Equatable {
    public let platform: String
    public let appId: String
    public let sessionId: String
    public let deviceId: String
    public let callbackEndpoint: String
    public let preferredTransports: [ClientTransport]
    public let usbmuxdHint: USBMuxdHint?
    public let lastSeenAt: String
    public let expiresAt: String
    public let ttlSeconds: Int
    public let selected: Bool

    public init(
        platform: String,
        appId: String,
        sessionId: String,
        deviceId: String,
        callbackEndpoint: String,
        preferredTransports: [ClientTransport],
        usbmuxdHint: USBMuxdHint?,
        lastSeenAt: String,
        expiresAt: String,
        ttlSeconds: Int,
        selected: Bool
    ) {
        self.platform = platform
        self.appId = appId
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.callbackEndpoint = callbackEndpoint
        self.preferredTransports = preferredTransports
        self.usbmuxdHint = usbmuxdHint
        self.lastSeenAt = lastSeenAt
        self.expiresAt = expiresAt
        self.ttlSeconds = ttlSeconds
        self.selected = selected
    }
}

public struct ClientRegisterResponse: Content, Sendable {
    public let client: ClientSnapshot

    public init(client: ClientSnapshot) {
        self.client = client
    }
}

public struct ClientListResponse: Content, Sendable {
    public let items: [ClientSnapshot]

    public init(items: [ClientSnapshot]) {
        self.items = items
    }
}

public struct ClientSelector: Content, Sendable, Hashable {
    public let platform: String
    public let appId: String
    public let deviceId: String

    public init(platform: String, appId: String, deviceId: String) {
        self.platform = platform
        self.appId = appId
        self.deviceId = deviceId
    }
}

public struct ClientsSelectedRequest: Content, Sendable {
    public let items: [ClientSelector]

    public init(items: [ClientSelector]) {
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case selected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let items = try container.decodeIfPresent([ClientSelector].self, forKey: .items) {
            self.items = items
            return
        }
        if let selected = try container.decodeIfPresent([ClientSelector].self, forKey: .selected) {
            self.items = selected
            return
        }
        self.items = []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
    }
}

public struct ClientsSelectedResponse: Content, Sendable {
    public let items: [ClientSelector]
    public let selectedCount: Int
    public let updatedAt: String

    public init(items: [ClientSelector], selectedCount: Int, updatedAt: String) {
        self.items = items
        self.selectedCount = selectedCount
        self.updatedAt = updatedAt
    }
}

public enum ClientTransport: String, Codable, CaseIterable, Sendable {
    case httpCallback
    case webSocket
    case usbmuxdHTTP
}

public struct USBMuxdHint: Content, Sendable, Equatable {
    public let deviceID: Int
    public let socketPath: String?

    public init(deviceID: Int, socketPath: String? = nil) {
        self.deviceID = deviceID
        self.socketPath = socketPath
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case deviceId
        case socketPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.deviceID =
            try container.decodeIfPresent(Int.self, forKey: .deviceID)
            ?? container.decode(Int.self, forKey: .deviceId)
        self.socketPath = try container.decodeIfPresent(String.self, forKey: .socketPath)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encodeIfPresent(socketPath, forKey: .socketPath)
    }
}

public struct BusEnvelope: Content, Sendable {
    public let requestId: String
    public let direction: String
    public let kind: String
    public let command: String
    public let payload: [String: String]?
    public let timestamp: String

    public init(
        requestId: String,
        direction: String = "cli_to_client",
        kind: String = "command",
        command: String,
        payload: [String: String]? = nil,
        timestamp: String
    ) {
        self.requestId = requestId
        self.direction = direction
        self.kind = kind
        self.command = command
        self.payload = payload
        self.timestamp = timestamp
    }
}

public struct BusAck: Content, Sendable {
    public let requestId: String
    public let command: String
    public let status: String
    public let message: String?
    public let timestamp: String
    public let recipientID: String?
    public let transport: ClientTransport?

    public init(
        requestId: String,
        command: String,
        status: String,
        message: String? = nil,
        timestamp: String,
        recipientID: String? = nil,
        transport: ClientTransport? = nil
    ) {
        self.requestId = requestId
        self.command = command
        self.status = status
        self.message = message
        self.timestamp = timestamp
        self.recipientID = recipientID
        self.transport = transport
    }
}

public typealias GatewayCommandRequest = BusEnvelope
public typealias GatewayCommandAck = BusAck
