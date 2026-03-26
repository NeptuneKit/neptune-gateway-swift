import Foundation

public struct GatewayMDNSConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var serviceType: String
    public var domain: String
    public var serviceName: String
    public var txtRecord: [String: String]

    public init(
        enabled: Bool = true,
        serviceType: String = "_neptune._tcp.",
        domain: String = "local.",
        serviceName: String = GatewayMDNSConfiguration.defaultServiceName,
        txtRecord: [String: String] = ["version": NeptuneGatewayVersion.current]
    ) {
        self.enabled = enabled
        self.serviceType = Self.normalizeWithTrailingDot(serviceType, fallback: "_neptune._tcp.")
        self.domain = Self.normalizeWithTrailingDot(domain, fallback: "local.")
        self.serviceName = Self.normalizeServiceName(serviceName, fallback: Self.defaultServiceName)
        self.txtRecord = txtRecord
    }

    public static func parseEnabled(from rawValue: String?) -> Bool {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawValue.isEmpty
        else {
            return true
        }

        switch rawValue {
        case "0", "false", "no", "off":
            return false
        case "1", "true", "yes", "on":
            return true
        default:
            return true
        }
    }

    public static var defaultServiceName: String {
        let host = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if host.isEmpty {
            return "neptune"
        }
        return host
    }

    private static func normalizeWithTrailingDot(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return fallback
        }
        if trimmed.hasSuffix(".") {
            return trimmed
        }
        return "\(trimmed)."
    }

    private static func normalizeServiceName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return fallback
        }
        return trimmed
    }
}

public final class GatewayMDNSPublisher: NSObject {
    private let configuration: GatewayMDNSConfiguration
    private let port: Int
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var service: NetService?
    private var startupSemaphore: DispatchSemaphore?

    public init(
        configuration: GatewayMDNSConfiguration,
        port: Int,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.configuration = configuration
        self.port = port
        self.log = log
        super.init()
    }

    public func startIfEnabled() {
        guard configuration.enabled else {
            log("mDNS publisher disabled.")
            return
        }
        start()
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard thread == nil else {
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        startupSemaphore = semaphore

        let publisherThread = Thread(target: self, selector: #selector(runPublisherThread), object: nil)
        publisherThread.name = "neptune-gateway-mdns"
        thread = publisherThread
        publisherThread.start()

        lock.unlock()
        _ = semaphore.wait(timeout: .now() + .seconds(3))
        lock.lock()
    }

    public func stop() {
        var currentRunLoop: CFRunLoop?
        lock.lock()
        currentRunLoop = runLoop
        lock.unlock()

        guard let currentRunLoop else {
            return
        }

        CFRunLoopPerformBlock(currentRunLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.service?.stop()
            CFRunLoopStop(currentRunLoop)
        }
        CFRunLoopWakeUp(currentRunLoop)
    }

    deinit {
        stop()
    }

    @objc
    private func runPublisherThread() {
        autoreleasepool {
            let runLoop = CFRunLoopGetCurrent()
            let service = NetService(
                domain: configuration.domain,
                type: configuration.serviceType,
                name: configuration.serviceName,
                port: Int32(port)
            )
            service.delegate = self
            service.schedule(in: .current, forMode: .default)

            if !configuration.txtRecord.isEmpty {
                let txtData = NetService.data(fromTXTRecord: configuration.txtRecord.mapValues { value in
                    Data(value.utf8)
                })
                service.setTXTRecord(txtData)
            }

            lock.lock()
            self.runLoop = runLoop
            self.service = service
            let semaphore = startupSemaphore
            startupSemaphore = nil
            lock.unlock()

            service.publish()
            semaphore?.signal()
            log(
                "mDNS publish requested type=\(configuration.serviceType) domain=\(configuration.domain) " +
                "name=\(configuration.serviceName) port=\(port)"
            )

            CFRunLoopRun()

            service.stop()
            service.remove(from: .current, forMode: .default)

            lock.lock()
            self.service = nil
            self.runLoop = nil
            self.thread = nil
            lock.unlock()
            log("mDNS publisher stopped.")
        }
    }
}

extension GatewayMDNSPublisher: NetServiceDelegate {
    public func netServiceDidPublish(_ sender: NetService) {
        log(
            "mDNS published name=\(sender.name) type=\(sender.type) domain=\(sender.domain) port=\(sender.port)"
        )
    }

    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        log("mDNS publish failed: \(errorDict)")
    }
}
