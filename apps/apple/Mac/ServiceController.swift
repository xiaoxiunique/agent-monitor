import AppKit
import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class ServiceController {
    enum State {
        case idle
        case starting
        case runningOwned
        case runningExternal
        case failed

        var title: String {
            switch self {
            case .idle: "Stopped"
            case .starting: "Starting"
            case .runningOwned: "Running"
            case .runningExternal: "Running (external)"
            case .failed: "Failed"
            }
        }

        var icon: String {
            switch self {
            case .idle: "terminal"
            case .starting: "arrow.triangle.2.circlepath"
            case .runningOwned, .runningExternal: "terminal.fill"
            case .failed: "exclamationmark.triangle"
            }
        }
    }

    var state: State = .idle
    var lastMessage = ""
    var isReachable = false
    var tailscaleHost: String?
    var lanHost: String?

    private static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let monorepoRoot = projectRoot
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private let bundledServiceExecutable = Bundle.main.resourceURL?.appendingPathComponent("agent-monitor-service")
    private let bundledPublicDirectory = Bundle.main.resourceURL?.appendingPathComponent("public")
    private let developmentServiceExecutable = ServiceController.projectRoot.appendingPathComponent("AgentMonitorService/target/release/agent-monitor-service")
    private let developmentPublicDirectory = ServiceController.monorepoRoot.appendingPathComponent("public")
    private let port = 8787
    private var process: Process?
    private var monitorTask: Task<Void, Never>?

    init() {
        tailscaleHost = Self.currentTailscaleAddress()
        lanHost = Self.currentLANAddress()
        Task { @MainActor [weak self] in
            await self?.startIfNeeded()
        }
    }

    var dashboardURL: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }

    var phoneDashboardURL: URL {
        let host = tailscaleHost ?? lanHost ?? Self.currentTailscaleAddress() ?? Self.currentLANAddress() ?? "127.0.0.1"
        return URL(string: "http://\(host):\(port)/")!
    }

    var lanDashboardURL: URL? {
        guard let lanHost else { return nil }
        return URL(string: "http://\(lanHost):\(port)/")
    }

    var phoneURLKind: String {
        tailscaleHost != nil ? "Tailscale" : "LAN"
    }

    var statusTitle: String {
        "Agent Monitor: \(state.title)"
    }

    var menuIcon: String {
        state.icon
    }

    var ownsProcess: Bool {
        process?.isRunning == true
    }

    private var serviceExecutable: URL {
        if let bundledServiceExecutable,
           FileManager.default.isExecutableFile(atPath: bundledServiceExecutable.path) {
            return bundledServiceExecutable
        }

        return developmentServiceExecutable
    }

    private var publicDirectory: URL {
        if let bundledPublicDirectory,
           FileManager.default.fileExists(atPath: bundledPublicDirectory.appendingPathComponent("index.html").path) {
            return bundledPublicDirectory
        }

        return developmentPublicDirectory
    }

    func startIfNeeded() async {
        await refreshStatus()
        guard !isReachable else {
            state = .runningExternal
            return
        }
        await startOwnedService()
    }

    func refreshStatus() async {
        tailscaleHost = Self.currentTailscaleAddress()
        lanHost = Self.currentLANAddress()
        isReachable = await checkHealth()
        if isReachable {
            state = ownsProcess ? .runningOwned : .runningExternal
            lastMessage = "Service is reachable."
        } else if ownsProcess {
            state = .starting
            lastMessage = "Process is running; waiting for HTTP service."
        } else if state != .failed {
            state = .idle
            lastMessage = "Service is not running."
        }
    }

    func startOwnedService() async {
        guard process?.isRunning != true else {
            await refreshStatus()
            return
        }

        if await checkHealth() {
            isReachable = true
            state = .runningExternal
            lastMessage = "Existing service detected on port \(port)."
            return
        }

        state = .starting
        lastMessage = "Starting Rust service..."

        guard FileManager.default.isExecutableFile(atPath: serviceExecutable.path) else {
            state = .failed
            lastMessage = "Missing agent-monitor-service at \(serviceExecutable.path)."
            return
        }

        guard FileManager.default.fileExists(atPath: publicDirectory.appendingPathComponent("index.html").path) else {
            state = .failed
            lastMessage = "Missing web assets at \(publicDirectory.path)."
            return
        }

        let process = Process()
        process.currentDirectoryURL = serviceExecutable.deletingLastPathComponent()
        process.executableURL = serviceExecutable

        var environment = ProcessInfo.processInfo.environment
        let defaultPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let inheritedPath = environment["PATH"], !inheritedPath.isEmpty {
            environment["PATH"] = "\(defaultPath):\(inheritedPath)"
        } else {
            environment["PATH"] = defaultPath
        }
        environment["AGENT_MONITOR_HOST"] = "0.0.0.0"
        environment["AGENT_MONITOR_PORT"] = String(port)
        environment["AGENT_MONITOR_PUBLIC_DIR"] = publicDirectory.path
        environment.removeValue(forKey: "AGENT_MONITOR_TOKEN")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.lastMessage = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                guard self?.process === terminated else { return }
                self?.process = nil
                self?.isReachable = false
                self?.state = terminated.terminationStatus == 0 ? .idle : .failed
                self?.lastMessage = "Service process exited with \(terminated.terminationStatus)."
            }
        }

        do {
            try process.run()
            self.process = process
            startMonitorLoop()
        } catch {
            state = .failed
            lastMessage = error.localizedDescription
        }
    }

    func restartOwnedService() async {
        stopOwnedService()
        try? await Task.sleep(for: .milliseconds(400))
        await startOwnedService()
    }

    func stopOwnedService() {
        monitorTask?.cancel()
        monitorTask = nil
        if let pipe = process?.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        process?.terminate()
        process = nil
        isReachable = false
        state = .idle
        lastMessage = "Owned service stopped."
    }

    func openDashboard() {
        NSWorkspace.shared.open(dashboardURL)
    }

    func copyPhoneDashboardURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(phoneDashboardURL.absoluteString, forType: .string)
        lastMessage = "Copied \(phoneURLKind) URL: \(phoneDashboardURL.absoluteString)"
    }

    func revealServiceFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([serviceExecutable, publicDirectory])
    }

    private func startMonitorLoop() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func checkHealth() async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/api/snapshot")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private static func currentLANAddress() -> String? {
        currentIPv4Address { name, ip in
            if isTailscaleIPv4(ip) { return false }
            return name.hasPrefix("en")
        } ?? currentIPv4Address { _, ip in
            !isTailscaleIPv4(ip)
        }
    }

    private static func currentTailscaleAddress() -> String? {
        currentIPv4Address { _, ip in
            isTailscaleIPv4(ip)
        }
    }

    private static func currentIPv4Address(where matches: (String, String) -> Bool) -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }

        var cursor = interfaces

        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next

            guard let address = interface.ifa_addr else { continue }
            guard address.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0 else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let ip = host.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!)
            }
            guard !ip.hasPrefix("169.254.") else { continue }

            let name = String(cString: interface.ifa_name)
            if matches(name, ip) {
                return ip
            }
        }

        return nil
    }

    private static func isTailscaleIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }
}
