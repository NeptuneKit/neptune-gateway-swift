import Foundation
import STJSON
import NeptuneGatewaySwift

typealias JSONObject = [String: Any]

private func stringValue(_ value: InspectorPayloadValue?) -> String? {
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

private func boolValue(_ value: InspectorPayloadValue?) -> Bool? {
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

private func objectValue(_ value: InspectorPayloadValue?) -> [String: InspectorPayloadValue]? {
    value?.dictionary
}

private func arrayValue(_ value: InspectorPayloadValue?) -> [InspectorPayloadValue]? {
    value?.array
}

private func parseRect(_ rect: String?) -> ViewTreeNode.Frame? {
    guard let rect, !rect.isEmpty else { return nil }
    let pattern = #"-?\d+(?:\.\d+)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(rect.startIndex..<rect.endIndex, in: rect)
    let numbers = regex.matches(in: rect, range: range).compactMap { match -> Double? in
        guard let matchRange = Range(match.range, in: rect) else { return nil }
        return Double(rect[matchRange])
    }
    guard numbers.count >= 4 else { return nil }
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

private func normalizeObjectID(_ raw: String) -> String {
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

private func parseStyle(from object: [String: InspectorPayloadValue]) -> ViewTreeNode.Style? {
    if let style = decode(object["style"], as: ViewTreeNode.Style.self) {
        return style
    }
    if let style = decode(object["$style"], as: ViewTreeNode.Style.self) {
        return style
    }
    if let attrs = objectValue(object["$attrs"]) {
        let opacity = decodeNumber(attrs["opacity"])
        let backgroundColor = normalizeArkUIColor(stringValue(attrs["backgroundColor"]))
        let textColor = normalizeArkUIColor(stringValue(attrs["fontColor"]) ?? stringValue(attrs["textColor"]))
        let borderColor = normalizeArkUIColor(stringValue(attrs["borderColor"]))
        let borderWidth = decodeNumber(attrs["borderWidth"])
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
        if opacity != nil || backgroundColor != nil || textColor != nil || borderColor != nil || borderWidth != nil || borderRadius != nil
            || fontSize != nil || lineHeight != nil || letterSpacing != nil || fontWeightRaw != nil || fontFamily != nil
            || textAlign != nil || textContentAlign != nil || textOverflow != nil || wordBreak != nil
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

private func decodeNumber(_ value: InspectorPayloadValue?) -> Double? {
    guard let value else { return nil }
    switch value.type {
    case .number:
        return value.number?.doubleValue
    case .string:
        guard let string = value.string else { return nil }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        let regex = try? NSRegularExpression(pattern: "-?\\d+(\\.\\d+)?")
        guard let match = regex?.firstMatch(in: string, range: range),
              let swiftRange = Range(match.range, in: string)
        else { return nil }
        return Double(string[swiftRange])
    case .bool:
        let bool = value.bool ?? false
        return bool ? 1 : 0
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

private func parseInsets(_ value: InspectorPayloadValue?) -> Insets? {
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

private func normalizeArkUIColor(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("#") else { return trimmed }
    let hex = String(trimmed.dropFirst())
    let isHex = hex.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil
    guard isHex else { return trimmed }
    if hex.count == 8 {
        let alpha = hex.prefix(2)
        let rgb = hex.dropFirst(2)
        return "#\(rgb)\(alpha)".uppercased()
    }
    if hex.count == 4 {
        let chars = Array(hex)
        let a = String(repeating: String(chars[0]), count: 2)
        let r = String(repeating: String(chars[1]), count: 2)
        let g = String(repeating: String(chars[2]), count: 2)
        let b = String(repeating: String(chars[3]), count: 2)
        return "#\(r)\(g)\(b)\(a)".uppercased()
    }
    return trimmed.uppercased()
}

private func decode<T: Decodable>(_ value: InspectorPayloadValue?, as type: T.Type) -> T? {
    guard let value else { return nil }
    guard let data = try? JSONEncoder().encode(value),
          let json = try? JSON(data: data) else {
        return nil
    }
    return try? json.decode(to: type)
}

private func mapNode(
    _ value: InspectorPayloadValue,
    parentId: String?,
    fallbackId: String,
    resolutionScale: Double
) -> ViewTreeNode? {
    guard let object = objectValue(value) else { return nil }
    let attrs = objectValue(object["$attrs"])

    let nodeId = stringValue(object["id"])
        ?? stringValue(object["$id"])
        ?? stringValue(object["$ID"])
        ?? stringValue(attrs?["viewKey"])
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
    let style = normalizeStyleDefaults(parseStyle(from: object))
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
        mapNode(
            child,
            parentId: normalizedNodeId,
            fallbackId: "\(normalizedNodeId)-\(index)",
            resolutionScale: resolutionScale
        )
    }

    return ViewTreeNode(
        id: normalizedNodeId,
        parentId: parentId,
        name: nodeName,
        frame: normalizedFrame,
        style: style,
        text: text,
        visible: visible,
        children: children
    )
}

private func extractRoots(from payload: InspectorPayloadValue) -> [ViewTreeNode] {
    if let roots: [ViewTreeNode] = decode(payload, as: [ViewTreeNode].self) {
        return normalizeTree(roots, parentId: nil)
    }
    if let object = objectValue(payload),
       let rootsValue = object["roots"],
       let roots: [ViewTreeNode] = decode(rootsValue, as: [ViewTreeNode].self) {
        return normalizeTree(roots, parentId: nil)
    }
    if let object = objectValue(payload),
       let content = objectValue(object["content"]),
       let roots = arrayValue(content["$children"]) {
        let resolutionScale = decodeNumber(content["$resolution"]) ?? 1
        return roots.enumerated().compactMap { index, item in
            mapNode(item, parentId: nil, fallbackId: "root-\(index)", resolutionScale: resolutionScale)
        }
    }
    if let single = mapNode(payload, parentId: nil, fallbackId: "root-0", resolutionScale: 1) {
        return [single]
    }
    return []
}

private func scaleFrame(_ frame: ViewTreeNode.Frame?, by resolutionScale: Double) -> ViewTreeNode.Frame? {
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

private func normalizeTree(_ roots: [ViewTreeNode], parentId: String?) -> [ViewTreeNode] {
    roots.map { normalizeTreeNode($0, parentId: parentId) }
}

private func normalizeTreeNode(_ node: ViewTreeNode, parentId: String?) -> ViewTreeNode {
    let normalizedId = normalizeObjectID(node.id)
    let normalizedChildren = node.children.map { normalizeTreeNode($0, parentId: normalizedId) }
    return ViewTreeNode(
        id: normalizedId,
        parentId: parentId,
        name: node.name,
        frame: node.frame,
        style: normalizeStyleDefaults(node.style),
        text: node.text,
        visible: node.visible ?? true,
        children: normalizedChildren
    )
}

private func normalizeStyleDefaults(_ style: ViewTreeNode.Style?) -> ViewTreeNode.Style? {
    guard let style else { return nil }
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
        borderRadius: style.borderRadius ?? 0,
        borderWidth: style.borderWidth ?? 0,
        borderColor: style.borderColor,
        zIndex: style.zIndex ?? 0,
        textAlign: style.textAlign,
        textContentAlign: style.textContentAlign,
        textOverflow: style.textOverflow,
        wordBreak: style.wordBreak,
        paddingTop: style.paddingTop,
        paddingRight: style.paddingRight,
        paddingBottom: style.paddingBottom,
        paddingLeft: style.paddingLeft
    )
}

private func repoRoot() -> URL {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    return cwd
}

private func writePrettyJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try data.write(to: url)
    if let newline = "\n".data(using: .utf8) {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: newline)
        try handle.close()
    }
}

struct RawRequestFile: Decodable {
    let request: ViewTreeRawIngestRequest
    let path: URL
}

private func loadRawRequests(from mockDir: URL) throws -> [RawRequestFile] {
    let files = try FileManager.default.contentsOfDirectory(at: mockDir, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasSuffix("-raw-ingest-request.json") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return try files.map { url in
        let data = try Data(contentsOf: url)
        let json = try JSON(data: data)
        return RawRequestFile(
            request: try json.decode(to: ViewTreeRawIngestRequest.self),
            path: url
        )
    }
}

let root = repoRoot()
let mockDir = root.appendingPathComponent("mocks/ui-tree", isDirectory: true)
let requests = try loadRawRequests(from: mockDir)
guard !requests.isEmpty else {
    fputs("[neptune-ui-tree-mock-builder] no *-raw-ingest-request.json in \(mockDir.path)\n", stderr)
    exit(1)
}

var harmonySnapshot: ViewTreeSnapshot?

for item in requests {
    let request = item.request
    let snapshot = ViewTreeSnapshot(
        snapshotId: "snapshot-\(request.platform)-\(request.deviceId)-\(Int(Date().timeIntervalSince1970 * 1000))",
        capturedAt: request.capturedAt ?? ISO8601DateFormatter().string(from: Date()),
        platform: request.platform,
        roots: extractRoots(from: request.payload)
    )
    let platformFile = mockDir.appendingPathComponent("\(request.platform)-ui-tree-snapshot.json")
    try writePrettyJSON(snapshot, to: platformFile)
    print("[neptune-ui-tree-mock-builder] wrote \(platformFile.path)")
    if request.platform == "harmony" {
        harmonySnapshot = snapshot
    }
}

if let harmonySnapshot {
    let file = mockDir.appendingPathComponent("ui-tree-snapshot.json")
    try writePrettyJSON(harmonySnapshot, to: file)
    print("[neptune-ui-tree-mock-builder] wrote \(file.path)")
}
