import ArgumentParser
import Foundation
import Vapor

public struct NeptuneGatewayCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "neptune-gateway",
        abstract: "Neptune v2 gateway server and log proxy tools.",
        subcommands: [
            ServeCommand.self,
            LogsCommand.self,
        ],
        defaultSubcommand: ServeCommand.self
    )

    public init() {}
}

public struct ServeCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the Neptune v2 gateway server."
    )

    @ArgumentParser.Option(name: .long, help: "Gateway host.")
    var host: String = ProcessInfo.processInfo.environment["NEPTUNE_HOST"] ?? "127.0.0.1"

    @ArgumentParser.Option(name: .long, help: "Gateway port.")
    var port: Int = Int(ProcessInfo.processInfo.environment["NEPTUNE_PORT"] ?? "18765") ?? 18765

    @ArgumentParser.Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Enable mDNS publish for gateway discovery."
    )
    var mdns: Bool = GatewayMDNSConfiguration.parseEnabled(
        from: ProcessInfo.processInfo.environment["NEPTUNE_MDNS_ENABLED"]
    )

    @ArgumentParser.Option(name: .long, help: "mDNS service name.")
    var mdnsServiceName: String = ProcessInfo.processInfo.environment["NEPTUNE_MDNS_SERVICE_NAME"]
        ?? GatewayMDNSConfiguration.defaultServiceName

    @ArgumentParser.Option(name: .long, help: "mDNS service type.")
    var mdnsServiceType: String = ProcessInfo.processInfo.environment["NEPTUNE_MDNS_SERVICE_TYPE"]
        ?? "_neptune._tcp."

    @ArgumentParser.Option(name: .long, help: "mDNS service domain.")
    var mdnsDomain: String = ProcessInfo.processInfo.environment["NEPTUNE_MDNS_DOMAIN"] ?? "local."

    @ArgumentParser.Option(
        name: .long,
        help: "Advertised host returned by /v2/gateway/discovery."
    )
    var advertiseHost: String = ProcessInfo.processInfo.environment["NEPTUNE_ADVERTISE_HOST"] ?? ""

    public init() {}

    public mutating func validate() throws {
        guard (1...65535).contains(port) else {
            throw ValidationError("--port must be between 1 and 65535")
        }
    }

    public mutating func run() throws {
        let executable = CommandLine.arguments.first ?? "neptune-gateway"
        let environmentName = ProcessInfo.processInfo.environment["VAPOR_ENV"] ?? "development"
        let environment = Environment(name: environmentName, arguments: [executable, "serve"])
        let app = try NeptuneGatewaySwift.makeApplication(
            environment: environment,
            hostname: host,
            port: port,
            advertiseHost: normalizeAdvertiseHost(advertiseHost)
        )
        let mdnsPublisher = GatewayMDNSPublisher(
            configuration: GatewayMDNSConfiguration(
                enabled: mdns,
                serviceType: mdnsServiceType,
                domain: mdnsDomain,
                serviceName: mdnsServiceName
            ),
            port: port,
            log: { message in
                app.logger.info("\(message)")
            }
        )
        mdnsPublisher.startIfEnabled()
        defer { mdnsPublisher.stop() }
        try app.run()
    }

    private func normalizeAdvertiseHost(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

public struct LogsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Gateway log utilities.",
        subcommands: [ProxyCommand.self]
    )

    public init() {}
}

public struct ProxyCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "proxy",
        abstract: "Proxy system logs into the Neptune gateway.",
        subcommands: [
            IOSProxyCommand.self,
            AndroidProxyCommand.self,
            HarmonyProxyCommand.self,
        ]
    )

    public init() {}
}

public struct IOSProxyCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ios",
        abstract: "Proxy Apple unified logging commands.",
        subcommands: [
            IOSStreamProxyCommand.self,
            IOSShowProxyCommand.self,
        ]
    )

    public init() {}
}

public struct AndroidProxyCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "android",
        abstract: "Proxy Android logcat.",
        subcommands: [AndroidLogcatProxyCommand.self]
    )

    public init() {}
}

public struct HarmonyProxyCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "harmony",
        abstract: "Proxy Harmony hdc hilog.",
        subcommands: [HarmonyHiLogProxyCommand.self]
    )

    public init() {}
}

public struct ProxyCommonOptions: ParsableArguments, Sendable {
    @ArgumentParser.Flag(name: .long, help: "Print raw proxied lines without reporting to the gateway.")
    public var raw = false

    @ArgumentParser.Option(name: .long, help: "Gateway base URL.")
    public var gateway: String = "http://127.0.0.1:18765"

    @ArgumentParser.Option(name: .long, help: "Override appId for normalized records.")
    public var appID: String?

    @ArgumentParser.Option(name: .long, help: "Override sessionId for normalized records.")
    public var sessionID: String?

    @ArgumentParser.Option(name: .long, help: "Override deviceId for normalized records.")
    public var deviceID: String?

    public init() {}
}

public struct IOSStreamProxyCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "stream", abstract: "Run `log stream` and proxy lines.")

    @OptionGroup var options: ProxyCommonOptions
    @ArgumentParser.Argument(parsing: .captureForPassthrough) var passthrough: [String] = []

    public init() {}

    public mutating func run() throws {
        try GatewayProxyRunner.run(
            configuration: .init(
                platform: .ios,
                command: ["/usr/bin/log", "stream"] + passthrough,
                options: options
            )
        )
    }
}

public struct IOSShowProxyCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "show", abstract: "Run `log show` and proxy lines.")

    @OptionGroup var options: ProxyCommonOptions
    @ArgumentParser.Argument(parsing: .captureForPassthrough) var passthrough: [String] = []

    public init() {}

    public mutating func run() throws {
        try GatewayProxyRunner.run(
            configuration: .init(
                platform: .ios,
                command: ["/usr/bin/log", "show"] + passthrough,
                options: options
            )
        )
    }
}

public struct AndroidLogcatProxyCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "logcat", abstract: "Run `adb logcat` and proxy lines.")

    @OptionGroup var options: ProxyCommonOptions
    @ArgumentParser.Argument(parsing: .captureForPassthrough) var passthrough: [String] = []

    public init() {}

    public mutating func run() throws {
        try GatewayProxyRunner.run(
            configuration: .init(
                platform: .android,
                command: ["/usr/bin/env", "adb", "logcat"] + passthrough,
                options: options
            )
        )
    }
}

public struct HarmonyHiLogProxyCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "hilog", abstract: "Run `hdc hilog` and proxy lines.")

    @OptionGroup var options: ProxyCommonOptions
    @ArgumentParser.Argument(parsing: .captureForPassthrough) var passthrough: [String] = []

    public init() {}

    public mutating func run() throws {
        try GatewayProxyRunner.run(
            configuration: .init(
                platform: .harmony,
                command: ["/usr/bin/env", "hdc", "hilog"] + passthrough,
                options: options
            )
        )
    }
}
