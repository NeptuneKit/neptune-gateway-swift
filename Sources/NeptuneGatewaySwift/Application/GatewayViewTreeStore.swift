import Foundation
import STJSON

actor GatewayViewTreeStore {
    private struct Key: Hashable {
        let platform: String
        let appId: String
        let sessionId: String
        let deviceId: String
    }

    private struct Entry {
        let key: Key
        let snapshotId: String
        let capturedAt: String
        let payload: InspectorPayloadValue
        let storedAt: Date
    }

    private var entriesByKey: [Key: Entry] = [:]
    private var latestByDeviceId: [String: Entry] = [:]

    func ingest(_ request: ViewTreeRawIngestRequest) {
        let key = Key(
            platform: request.platform,
            appId: request.appId,
            sessionId: request.sessionId,
            deviceId: request.deviceId
        )
        let now = Date()
        let entry = Entry(
            key: key,
            snapshotId: request.snapshotId ?? "raw-\(request.platform)-\(request.deviceId)-\(Int(now.timeIntervalSince1970 * 1000))",
            capturedAt: request.capturedAt ?? Self.rfc3339(now),
            payload: request.payload,
            storedAt: now
        )
        entriesByKey[key] = entry
        latestByDeviceId[request.deviceId] = entry
    }

    func inspectorSnapshot(deviceId: String) -> InspectorSnapshot? {
        guard let entry = latestByDeviceId[deviceId] else {
            return nil
        }
        return InspectorSnapshot(
            snapshotId: entry.snapshotId,
            capturedAt: entry.capturedAt,
            platform: entry.key.platform,
            available: true,
            payload: entry.payload
        )
    }

    func removeInspectorSnapshot(deviceId: String) {
        guard let entry = latestByDeviceId.removeValue(forKey: deviceId) else {
            return
        }
        entriesByKey.removeValue(forKey: entry.key)
    }

    func snapshot(
        platform: String,
        appId: String,
        sessionId: String,
        deviceId: String?
    ) -> ViewTreeSnapshot? {
        let candidate: Entry?
        if let deviceId {
            candidate = entriesByKey[Key(platform: platform, appId: appId, sessionId: sessionId, deviceId: deviceId)]
        } else {
            candidate = entriesByKey.values
                .filter { $0.key.platform == platform && $0.key.appId == appId && $0.key.sessionId == sessionId }
                .sorted(by: { $0.storedAt > $1.storedAt })
                .first
        }

        guard let entry = candidate,
              let roots = Self.extractRoots(from: entry.payload, platform: entry.key.platform)
        else {
            return nil
        }

        return ViewTreeSnapshot(
            snapshotId: "snapshot-\(entry.key.platform)-\(entry.key.deviceId)-\(Int(entry.storedAt.timeIntervalSince1970 * 1000))",
            capturedAt: entry.capturedAt,
            platform: entry.key.platform,
            roots: roots
        )
    }

    func removeSnapshot(
        platform: String,
        appId: String,
        sessionId: String,
        deviceId: String?
    ) {
        if let deviceId {
            let key = Key(platform: platform, appId: appId, sessionId: sessionId, deviceId: deviceId)
            if let entry = entriesByKey.removeValue(forKey: key),
               latestByDeviceId[deviceId]?.key == entry.key {
                latestByDeviceId.removeValue(forKey: deviceId)
            }
            return
        }

        let keysToRemove = entriesByKey.keys.filter {
            $0.platform == platform && $0.appId == appId && $0.sessionId == sessionId
        }
        for key in keysToRemove {
            if let removed = entriesByKey.removeValue(forKey: key),
               latestByDeviceId[removed.key.deviceId]?.key == removed.key {
                latestByDeviceId.removeValue(forKey: removed.key.deviceId)
            }
        }
    }

    private static func extractRoots(from payload: InspectorPayloadValue, platform: String) -> [ViewTreeNode]? {
        if let roots: [ViewTreeNode] = decode(payload, as: [ViewTreeNode].self) {
            return normalizeTree(roots, parentId: nil, platform: platform)
        }

        if let object = objectValue(payload),
           let rootsValue = object["roots"],
           let roots: [ViewTreeNode] = decode(rootsValue, as: [ViewTreeNode].self) {
            return normalizeTree(roots, parentId: nil, platform: platform)
        }

        if let object = objectValue(payload),
           let rootsValue = object["roots"],
           let rootsArray = arrayValue(rootsValue) {
            let mapped = rootsArray.enumerated().compactMap { index, item in
                mapInspectorNode(
                    item,
                    parentId: nil,
                    fallbackId: "root-\(index)",
                    resolutionScale: 1,
                    platform: platform
                )
            }
            if !mapped.isEmpty {
                return mapped
            }
        }

        if let object = objectValue(payload),
           let content = objectValue(object["content"]),
           let roots = arrayValue(content["$children"]) {
            let resolutionScale = decodeNumber(content["$resolution"]) ?? 1
            let mapped = roots.enumerated().compactMap { index, item in
                mapInspectorNode(
                    item,
                    parentId: nil,
                    fallbackId: "root-\(index)",
                    resolutionScale: resolutionScale,
                    platform: platform
                )
            }
            if !mapped.isEmpty {
                return mapped
            }
        }

        if let single = mapInspectorNode(
            payload,
            parentId: nil,
            fallbackId: "root-0",
            resolutionScale: 1,
            platform: platform
        ) {
            return [single]
        }
        return nil
    }

    private static func normalizeTree(_ roots: [ViewTreeNode], parentId: String?, platform: String) -> [ViewTreeNode] {
        roots.map { normalizeTreeNode($0, parentId: parentId, platform: platform) }
    }

    private static func normalizeTreeNode(_ node: ViewTreeNode, parentId: String?, platform: String) -> ViewTreeNode {
        let normalizedId = normalizeObjectID(node.id)
        let normalizedChildren = node.children.map { normalizeTreeNode($0, parentId: normalizedId, platform: platform) }
        let normalizedStyle = normalizeStyleDefaults(node.style, nodeName: node.name, frame: node.frame, platform: platform)
        let normalizedRawNode = normalizedRawNode(node, normalizedId: normalizedId, normalizedStyle: normalizedStyle)
        return ViewTreeNode(
            id: normalizedId,
            parentId: parentId,
            name: node.name,
            frame: node.frame,
            style: normalizedStyle,
            rawNode: normalizedRawNode,
            text: node.text,
            visible: node.visible ?? true,
            children: normalizedChildren
        )
    }

    private static func normalizedRawNode(
        _ node: ViewTreeNode,
        normalizedId: String,
        normalizedStyle: ViewTreeNode.Style?
    ) -> InspectorPayloadValue? {
        if let rawNode = node.rawNode, rawNode.type != .null {
            return rawNode
        }
        guard let normalizedStyle else {
            return nil
        }
        return normalizedNodeAsRawPayload(
            node,
            normalizedId: normalizedId,
            normalizedStyle: normalizedStyle
        )
    }

    private static func normalizedNodeAsRawPayload(
        _ node: ViewTreeNode,
        normalizedId: String,
        normalizedStyle: ViewTreeNode.Style
    ) -> InspectorPayloadValue? {
        var object: [String: InspectorPayloadValue] = [:]
        func assign(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            object[key] = InspectorPayloadValue(value)
        }
        func assign(_ key: String, _ value: Double?) {
            guard let value else { return }
            object[key] = InspectorPayloadValue(value)
        }

        object["id"] = InspectorPayloadValue(normalizedId)
        if let parentId = node.parentId {
            object["parentId"] = InspectorPayloadValue(parentId)
        }
        object["name"] = InspectorPayloadValue(node.name)
        if let text = node.text {
            object["text"] = InspectorPayloadValue(text)
        }
        if let visible = node.visible {
            object["visible"] = InspectorPayloadValue(visible)
        }
        if let frame = node.frame,
           let frameValue = encodeAsJSON(frame) {
            object["frame"] = frameValue
        }
        if let styleValue = encodeAsJSON(normalizedStyle) {
            object["style"] = styleValue
        }
        object["childCount"] = InspectorPayloadValue(node.children.count)

        guard !object.isEmpty else {
            return nil
        }
        return InspectorPayloadValue(object)
    }

    private static func mapInspectorNode(
        _ value: InspectorPayloadValue,
        parentId: String?,
        fallbackId: String,
        resolutionScale: Double,
        platform: String
    ) -> ViewTreeNode? {
        guard let object = objectValue(value) else {
            return nil
        }

        let nodeId = stringValue(object["id"])
            ?? stringValue(object["$id"])
            ?? stringValue(object["$ID"])
            ?? fallbackId
        let normalizedNodeId = normalizeObjectID(nodeId)

        let nodeName = stringValue(object["name"])
            ?? stringValue(object["className"])
            ?? stringValue(object["$type"])
            ?? stringValue(object["type"])
            ?? "ViewNode"

        let frame = decode(object["frame"], as: ViewTreeNode.Frame.self)
            ?? parseRect(stringValue(object["$rect"]))
        let normalizedFrame = scaleFrame(frame, by: resolutionScale)

        let attrs = objectValue(object["$attrs"])
        let rawNode = extractRawNode(from: object, attrs: attrs)
        let style = normalizeStyleDefaults(
            parseStyle(from: object),
            nodeName: nodeName,
            frame: normalizedFrame,
            platform: platform
        )
        let text = stringValue(object["text"])
            ?? stringValue(object["content"])
            ?? stringValue(attrs?["text"])
            ?? stringValue(attrs?["content"])
            ?? stringValue(attrs?["value"])
            ?? stringValue(attrs?["label"])

        let visible = boolValue(object["visible"])
            ?? boolValue(object["isVisible"])
            ?? boolValue(attrs?["visible"])
            ?? true

        let rawChildren = arrayValue(object["children"])
            ?? arrayValue(object["$children"])
            ?? []

        let children = rawChildren.enumerated().compactMap { index, child in
            mapInspectorNode(
                child,
                parentId: normalizedNodeId,
                fallbackId: "\(normalizedNodeId)-\(index)",
                resolutionScale: resolutionScale,
                platform: platform
            )
        }

        return ViewTreeNode(
            id: normalizedNodeId,
            parentId: parentId,
            name: nodeName,
            frame: normalizedFrame,
            style: style,
            rawNode: rawNode,
            text: text,
            visible: visible,
            children: children
        )
    }

    private static func extractRawNode(
        from object: [String: InspectorPayloadValue],
        attrs: [String: InspectorPayloadValue]?
    ) -> InspectorPayloadValue? {
        var payload = object
        payload.removeValue(forKey: "children")
        payload.removeValue(forKey: "$children")
        if let attrs, !attrs.isEmpty, payload["$attrs"] == nil {
            payload["$attrs"] = InspectorPayloadValue(attrs)
        }
        if payload.isEmpty {
            return nil
        }
        return InspectorPayloadValue(payload)
    }

    private static func encodeAsJSON<T: Encodable>(_ value: T) -> InspectorPayloadValue? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value),
              let decoded = try? JSONDecoder().decode(InspectorPayloadValue.self, from: data) else {
            return nil
        }
        return decoded
    }

    private static func normalizeStyleDefaults(
        _ style: ViewTreeNode.Style?,
        nodeName: String,
        frame: ViewTreeNode.Frame?,
        platform: String
    ) -> ViewTreeNode.Style? {
        guard let style else { return nil }
        var textAlign = style.textAlign
        var borderRadius = style.borderRadius ?? 0

        if platform == "harmony", nodeName == "Button" {
            textAlign = "Alignment.Center"
            if borderRadius <= 0, let height = frame?.height, height > 0 {
                borderRadius = height / 2
            }
        }
        if platform == "harmony", nodeName == "Circle" {
            if borderRadius <= 0 {
                if let width = frame?.width, let height = frame?.height, width > 0, height > 0 {
                    borderRadius = min(width, height) / 2
                } else if let width = frame?.width, width > 0 {
                    borderRadius = width / 2
                } else if let height = frame?.height, height > 0 {
                    borderRadius = height / 2
                }
            }
        }

        return ViewTreeNode.Style(
            opacity: style.opacity,
            backgroundColor: style.backgroundColor,
            textColor: style.textColor,
            typographyUnit: style.typographyUnit,
            sourceTypographyUnit: style.sourceTypographyUnit,
            platformFontScale: style.platformFontScale ?? 0,
            fontSize: style.fontSize ?? 0,
            lineHeight: style.lineHeight ?? 0,
            letterSpacing: style.letterSpacing ?? 0,
            fontWeight: style.fontWeight,
            fontWeightRaw: style.fontWeightRaw,
            fontFamily: style.fontFamily,
            borderRadius: borderRadius,
            borderWidth: style.borderWidth ?? 0,
            borderColor: style.borderColor,
            zIndex: style.zIndex ?? 0,
            textAlign: textAlign,
            textContentAlign: style.textContentAlign,
            textOverflow: style.textOverflow,
            wordBreak: style.wordBreak,
            paddingTop: style.paddingTop,
            paddingRight: style.paddingRight,
            paddingBottom: style.paddingBottom,
            paddingLeft: style.paddingLeft
        )
    }

    private static func parseStyle(from object: [String: InspectorPayloadValue]) -> ViewTreeNode.Style? {
        if let style = decode(object["style"], as: ViewTreeNode.Style.self) {
            return style
        }
        if let style = decode(object["$style"], as: ViewTreeNode.Style.self) {
            return style
        }
        if let attrs = objectValue(object["$attrs"]) {
            let opacity = decodeNumber(attrs["opacity"])
            let rawBackgroundColor = normalizeArkUIColor(
                stringValue(attrs["backgroundColor"]) ?? stringValue(attrs["background"]) ?? stringValue(attrs["bgColor"])
            )
            let fillColor = normalizeArkUIColor(stringValue(attrs["fill"]))
            let backgroundColor = preferVisibleColor(primary: rawBackgroundColor, fallback: fillColor)
            let textColor = normalizeArkUIColor(stringValue(attrs["fontColor"]) ?? stringValue(attrs["textColor"]))
            let borderColor = normalizeArkUIColor(stringValue(attrs["borderColor"]) ?? stringValue(attrs["stroke"]))
            let borderWidth = decodeNumber(attrs["borderWidth"]) ?? decodeNumber(attrs["strokeWidth"])
            let borderRadius = decodeNumber(attrs["borderRadius"])
            let platformFontScale = decodeNumber(attrs["platformFontScale"])
            let fontSizeToken = stringValue(attrs["fontSize"])?.lowercased()
            let fontSize: Double? = {
                if let explicit = decodeNumber(attrs["fontSize"]) {
                    return explicit
                }
                if fontSizeToken == "auto" {
                    return nil
                }
                return decodeNumber(attrs["actualFontSize"])
                    ?? decodeNumber(attrs["font"]?.dictionary?["size"])
            }()
            let lineHeight = decodeNumber(attrs["lineHeight"])
            let letterSpacing = decodeNumber(attrs["letterSpacing"])
            let fontWeightRaw = stringValue(attrs["fontWeightRaw"]) ?? stringValue(attrs["fontWeight"])
            let fontFamily = stringValue(attrs["fontFamily"]) ?? stringValue(attrs["font"]?.dictionary?["family"])
            let localizedAlignment = stringValue(attrs["localizedAlignment"])
            let layoutGravity = stringValue(attrs["layoutGravity"])
            let prefersCenteredText =
                (localizedAlignment?.lowercased().contains("center") ?? false)
                || (layoutGravity?.lowercased().contains("center") ?? false)
            var textAlign = stringValue(attrs["textAlign"])
            if prefersCenteredText {
                let normalized = textAlign?.lowercased() ?? ""
                if normalized.isEmpty || normalized.contains("start") || normalized == "left" {
                    textAlign = "TextAlign.Center"
                }
            }
            let textContentAlign = stringValue(attrs["textContentAlign"])
            let textOverflow = stringValue(attrs["textOverflow"])
            let wordBreak = stringValue(attrs["wordBreak"])
            let zIndex = decodeNumber(attrs["zIndex"])
            let padding = parseInsets(attrs["padding"])

            if opacity != nil || backgroundColor != nil || textColor != nil || borderColor != nil || borderWidth != nil
                || borderRadius != nil || fontSize != nil || lineHeight != nil || letterSpacing != nil || fontWeightRaw != nil
                || fontFamily != nil || textAlign != nil || textContentAlign != nil || textOverflow != nil || wordBreak != nil
                || zIndex != nil || platformFontScale != nil || padding != nil {
                return ViewTreeNode.Style(
                    opacity: opacity,
                    backgroundColor: backgroundColor,
                    textColor: textColor,
                    typographyUnit: "dp",
                    sourceTypographyUnit: "fp",
                    platformFontScale: platformFontScale,
                    fontSize: fontSize,
                    lineHeight: lineHeight,
                    letterSpacing: letterSpacing,
                    fontWeight: fontWeightRaw,
                    fontWeightRaw: fontWeightRaw,
                    fontFamily: fontFamily,
                    borderRadius: borderRadius,
                    borderWidth: borderWidth,
                    borderColor: borderColor,
                    zIndex: zIndex,
                    textAlign: textAlign,
                    textContentAlign: textContentAlign,
                    textOverflow: textOverflow,
                    wordBreak: wordBreak,
                    paddingTop: padding?.top,
                    paddingRight: padding?.right,
                    paddingBottom: padding?.bottom,
                    paddingLeft: padding?.left
                )
            }
        }
        return nil
    }

    private static func parseRect(_ rect: String?) -> ViewTreeNode.Frame? {
        guard let rect, !rect.isEmpty else {
            return nil
        }
        let pattern = #"-?\d+(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(rect.startIndex..<rect.endIndex, in: rect)
        let numbers = regex.matches(in: rect, range: range).compactMap { match -> Double? in
            guard let matchRange = Range(match.range, in: rect) else { return nil }
            return Double(rect[matchRange])
        }
        guard numbers.count >= 4 else {
            return nil
        }
        let minX = numbers[0]
        let minY = numbers[1]
        let maxX = numbers[2]
        let maxY = numbers[3]
        return ViewTreeNode.Frame(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private static func scaleFrame(_ frame: ViewTreeNode.Frame?, by resolutionScale: Double) -> ViewTreeNode.Frame? {
        guard let frame else { return nil }
        guard resolutionScale.isFinite, resolutionScale > 0, abs(resolutionScale - 1) > 0.0001 else {
            return frame
        }
        return ViewTreeNode.Frame(
            x: frame.x / resolutionScale,
            y: frame.y / resolutionScale,
            width: frame.width / resolutionScale,
            height: frame.height / resolutionScale
        )
    }

    private static func normalizeObjectID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            return "0x" + trimmed.dropFirst(2)
        }
        let parts = trimmed.split(separator: "|")
        if parts.count >= 2,
           let tail = parts.last,
           String(tail).range(of: #"^[0-9a-fA-F]{6,}$"#, options: .regularExpression) != nil {
            return "0x\(tail)"
        }
        return trimmed
    }

    private static func decode<T: Decodable>(_ value: InspectorPayloadValue?, as type: T.Type) -> T? {
        guard let value else { return nil }
        guard let data = try? JSONEncoder().encode(value),
              let json = try? JSON(data: data) else {
            return nil
        }
        return try? json.decode(to: type)
    }

    private static func objectValue(_ value: InspectorPayloadValue?) -> [String: InspectorPayloadValue]? {
        value?.dictionary
    }

    private static func arrayValue(_ value: InspectorPayloadValue?) -> [InspectorPayloadValue]? {
        value?.array
    }

    private static func stringValue(_ value: InspectorPayloadValue?) -> String? {
        guard let value else { return nil }
        switch value.type {
        case .string:
            guard let string = value.string else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .number:
            return value.number?.stringValue
        case .bool:
            return value.bool == true ? "true" : "false"
        default:
            return nil
        }
    }

    private static func boolValue(_ value: InspectorPayloadValue?) -> Bool? {
        guard let value else { return nil }
        switch value.type {
        case .bool:
            guard let bool = value.bool else { return nil }
            return bool
        case .string:
            guard let string = value.string else { return nil }
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "true" { return true }
            if normalized == "false" { return false }
            return nil
        case .number:
            return (value.number?.doubleValue ?? 0) != 0
        default:
            return nil
        }
    }

    private static func decodeNumber(_ value: InspectorPayloadValue?) -> Double? {
        guard let value else { return nil }
        switch value.type {
        case .number:
            return value.number?.doubleValue
        case .string:
            guard let string = value.string else { return nil }
            let pattern = #"-?\d+(?:\.\d+)?"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            guard let match = regex.firstMatch(in: string, range: range),
                  let numberRange = Range(match.range, in: string)
            else { return nil }
            return Double(string[numberRange])
        case .bool:
            return (value.bool ?? false) ? 1 : 0
        default:
            return nil
        }
    }

    private struct Insets {
        let top: Double
        let right: Double
        let bottom: Double
        let left: Double
    }

    private static func parseInsets(_ value: InspectorPayloadValue?) -> Insets? {
        guard let value else { return nil }
        if let object = objectValue(value) {
            guard let top = decodeNumber(object["top"]),
                  let right = decodeNumber(object["right"]),
                  let bottom = decodeNumber(object["bottom"]),
                  let left = decodeNumber(object["left"]) else {
                return nil
            }
            return Insets(top: top, right: right, bottom: bottom, left: left)
        }
        if let uniform = decodeNumber(value) {
            return Insets(top: uniform, right: uniform, bottom: uniform, left: uniform)
        }
        return nil
    }

    private static func normalizeArkUIColor(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return trimmed }
        let hex = String(trimmed.dropFirst())
        let isHex = hex.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil
        guard isHex else { return trimmed }
        if hex.count == 8 {
            // ArkUI uses #AARRGGBB, convert to CSS #RRGGBBAA.
            let alpha = hex.prefix(2)
            let rgb = hex.dropFirst(2)
            return "#\(rgb)\(alpha)".uppercased()
        }
        if hex.count == 4 {
            // #ARGB -> #RRGGBBAA
            let chars = Array(hex)
            let a = String(repeating: String(chars[0]), count: 2)
            let r = String(repeating: String(chars[1]), count: 2)
            let g = String(repeating: String(chars[2]), count: 2)
            let b = String(repeating: String(chars[3]), count: 2)
            return "#\(r)\(g)\(b)\(a)".uppercased()
        }
        return trimmed.uppercased()
    }

    private static func preferVisibleColor(primary: String?, fallback: String?) -> String? {
        if let primary, !isFullyTransparent(primary) {
            return primary
        }
        if let fallback, !isFullyTransparent(fallback) {
            return fallback
        }
        return primary ?? fallback
    }

    private static func isFullyTransparent(_ color: String) -> Bool {
        let normalized = color.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.hasPrefix("#") else { return false }
        let hex = String(normalized.dropFirst())
        if hex.count == 8 {
            // CSS #RRGGBBAA
            return hex.suffix(2) == "00"
        }
        if hex.count == 4 {
            // CSS #RGBA
            return hex.suffix(1) == "0"
        }
        return false
    }

    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
