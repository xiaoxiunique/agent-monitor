import AVFAudio
import CryptoKit
import Foundation
import Observation
import Speech
import UIKit

enum VoiceInputPermissions {
    static var hasMicrophonePermission: Bool {
        if case .granted = AVAudioApplication.shared.recordPermission {
            return true
        }
        return false
    }

    static var hasSpeechPermission: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static func requestMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            break
        @unknown default:
            return false
        }

        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static func request() async -> Bool {
        let speechAuthorized: Bool
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            speechAuthorized = true
        case .denied, .restricted:
            speechAuthorized = false
        case .notDetermined:
            speechAuthorized = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            speechAuthorized = false
        }

        guard speechAuthorized else { return false }

        return await requestMicrophone()
    }
}

enum VoiceInputError: LocalizedError {
    case speechUnavailable
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .speechUnavailable:
            return "Speech recognition is unavailable on this device."
        case .microphoneUnavailable:
            return "Microphone input is unavailable."
        }
    }
}

final class VoiceRecognitionSession: @unchecked Sendable {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Locale.preferredLanguages.first ?? "en-US"))
    private let audioEngine = AVAudioEngine()
    private let workQueue = DispatchQueue(label: "dev.hcg.AgentMonitor.apple-speech", qos: .userInitiated)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hasInputTap = false
    private var lastVolumeEmitTime: CFTimeInterval = 0
    private var lastVolumeEmitLevel: CGFloat = 0

    func prepare() {
        workQueue.async { [self] in
            do {
                try prepareOnWorkQueue()
            } catch {
                // Prewarming is best-effort; the normal start path still reports errors.
            }
        }
    }

    func start(
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onError: @escaping @MainActor (String) -> Void,
        onVolume: @escaping @MainActor (CGFloat) -> Void,
        onStarted: @escaping @MainActor () -> Void
    ) {
        workQueue.async { [self] in
            do {
                try startOnWorkQueue(
                    onTranscript: onTranscript,
                    onError: onError,
                    onVolume: onVolume
                )
                Task { @MainActor in
                    onStarted()
                }
            } catch {
                Task { @MainActor in
                    onError(error.localizedDescription)
                }
            }
        }
    }

    private func startOnWorkQueue(
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onError: @escaping @MainActor (String) -> Void,
        onVolume: @escaping @MainActor (CGFloat) -> Void
    ) throws {
        stopOnWorkQueue()
        guard let recognizer, recognizer.isAvailable else {
            throw VoiceInputError.speechUnavailable
        }

        try prepareOnWorkQueue()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw VoiceInputError.microphoneUnavailable
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
            let now = CACurrentMediaTime()
            guard now - self.lastVolumeEmitTime >= (1.0 / 12.0) else { return }
            let level = Self.normalizedAudioLevel(from: buffer)
            guard abs(level - self.lastVolumeEmitLevel) >= 0.06 || level == 0 && self.lastVolumeEmitLevel != 0 else { return }
            self.lastVolumeEmitTime = now
            self.lastVolumeEmitLevel = level
            Task { @MainActor in
                onVolume(level)
            }
        }
        hasInputTap = true

        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let transcript = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                Task { @MainActor in
                    onTranscript(transcript, isFinal)
                }
            }

            if let error {
                let message = error.localizedDescription
                Task { @MainActor in
                    onError(message)
                }
            }
        }
    }

    private func prepareOnWorkQueue() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw VoiceInputError.speechUnavailable
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        _ = audioEngine.inputNode
        audioEngine.prepare()
    }

    func stop() {
        workQueue.async { [self] in
            stopOnWorkQueue()
        }
    }

    private func stopOnWorkQueue() {
        guard audioEngine.isRunning || task != nil || request != nil else { return }

        audioEngine.stop()
        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        lastVolumeEmitTime = 0
        lastVolumeEmitLevel = 0

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func normalizedAudioLevel(from buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        let stride = max(frameCount / 128, 1)
        var squareSum: Float = 0
        var sampleCount = 0

        for channel in 0..<channelCount {
            let samples = channels[channel]
            var frame = 0
            while frame < frameCount {
                let sample = samples[frame]
                squareSum += sample * sample
                sampleCount += 1
                frame += stride
            }
        }

        let rms = sqrt(squareSum / Float(max(sampleCount, 1)))
        guard rms > 0.003 else { return 0 }

        let decibels = 20 * log10(rms)
        let normalized = (decibels + 48) / 42
        return CGFloat(min(max(normalized, 0), 1))
    }
}

struct TencentVoiceRecognitionConfig {
    let appID: String
    let secretID: String
    let secretKey: String
    let token: String

    @MainActor
    init(settings: AppSettings) {
        appID = settings.tencentASRAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        secretID = settings.tencentASRSecretID.trimmingCharacters(in: .whitespacesAndNewlines)
        secretKey = settings.tencentASRSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        token = settings.tencentASRToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var missingFields: [String] {
        var fields: [String] = []
        if appID.isEmpty { fields.append("AppID") }
        if secretID.isEmpty { fields.append("SecretId") }
        if secretKey.isEmpty { fields.append("SecretKey") }
        return fields
    }

    var cacheKey: String {
        [appID, secretID, secretKey, token].joined(separator: "\u{1f}")
    }

    @MainActor
    static func settingsIdentity(settings: AppSettings) -> String {
        [
            settings.tencentASRAppID,
            settings.tencentASRSecretID,
            settings.tencentASRSecretKey,
            settings.tencentASRToken,
        ].joined(separator: "\u{1f}")
    }
}

final class TencentVoiceRecognitionSession {
    private var recognizer: TencentRealtimeSpeechRecognizer?

    func prepare(config: TencentVoiceRecognitionConfig) {
        guard recognizer == nil else { return }
        let nextRecognizer = TencentRealtimeSpeechRecognizer(config: Self.makeSDKConfig(from: config))
        nextRecognizer.prepare()
        recognizer = nextRecognizer
    }

    func prime(config: TencentVoiceRecognitionConfig) {
        guard recognizer == nil else { return }
        let nextRecognizer = TencentRealtimeSpeechRecognizer(config: Self.makeSDKConfig(from: config))
        nextRecognizer.primeSDKObjects()
        recognizer = nextRecognizer
    }

    func cancelPrepare() {
        recognizer?.cancelPrepare()
    }

    func start(
        config: TencentVoiceRecognitionConfig,
        diagnosticStartTime: CFTimeInterval = 0,
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onError: @escaping @MainActor (String) -> Void,
        onFinished: @escaping @MainActor (String) -> Void,
        onVolume: @escaping @MainActor (CGFloat) -> Void,
        onRecordStarted: (@MainActor () -> Void)? = nil,
        onFlowStarted: (@MainActor (String) -> Void)? = nil
    ) {
        let nextRecognizer: TencentRealtimeSpeechRecognizer
        if let preparedRecognizer = recognizer {
            nextRecognizer = preparedRecognizer
        } else {
            nextRecognizer = TencentRealtimeSpeechRecognizer(config: Self.makeSDKConfig(from: config))
        }
        nextRecognizer.onTranscript = { transcript, isFinal in
            Task { @MainActor in
                onTranscript(transcript, isFinal)
            }
        }
        nextRecognizer.onError = { message in
            Task { @MainActor in
                onError(message)
            }
        }
        nextRecognizer.onFinished = { text in
            Task { @MainActor in
                onFinished(text)
            }
        }
        nextRecognizer.onVolume = { volume in
            let level = Self.normalizedTencentVolume(volume)
            Task { @MainActor in
                onVolume(level)
            }
        }
        nextRecognizer.onRecordStarted = {
            Task { @MainActor in
                onRecordStarted?()
            }
        }
        nextRecognizer.onFlowStarted = { voiceID in
            Task { @MainActor in
                onFlowStarted?(voiceID)
            }
        }
        recognizer = nextRecognizer
        if diagnosticStartTime > 0 {
            nextRecognizer.start(withDiagnosticStartTime: diagnosticStartTime)
        } else {
            nextRecognizer.start()
        }
    }

    func stop(keepWarm: Bool = true) {
        let current = recognizer
        guard keepWarm else {
            recognizer = nil
            current?.shutdown()
            return
        }

        current?.stop()
    }

    private static func makeSDKConfig(from config: TencentVoiceRecognitionConfig) -> TencentRealtimeSpeechConfig {
        let sdkConfig = TencentRealtimeSpeechConfig()
        sdkConfig.appID = config.appID
        sdkConfig.secretID = config.secretID
        sdkConfig.secretKey = config.secretKey
        sdkConfig.token = config.token
        sdkConfig.engineType = "16k_zh"
        sdkConfig.projectID = 0
        return sdkConfig
    }

    private static func normalizedTencentVolume(_ volume: Float) -> CGFloat {
        guard volume > 1 else { return 0 }
        return CGFloat(min(max(volume / 45, 0), 1))
    }
}

enum TencentVoiceRecognitionConfigTester {
    enum TestResult {
        case success(String)
        case failure(String)
    }

    @MainActor
    static func test(settings: AppSettings) async -> TestResult {
        let config = TencentVoiceRecognitionConfig(settings: settings)
        let missingFields = config.missingFields
        guard missingFields.isEmpty else {
            return .failure("Missing \(missingFields.joined(separator: ", ")).")
        }

        return await TencentCloudASRCredentialProbe.test(config: config)
    }
}

private enum TencentCloudASRCredentialProbe {
    private static let service = "asr"
    private static let host = "asr.tencentcloudapi.com"
    private static let action = "DescribeTaskStatus"
    private static let version = "2019-06-14"
    private static let region = "ap-shanghai"
    private static let contentType = "application/json; charset=utf-8"
    private static let algorithm = "TC3-HMAC-SHA256"

    static func test(config: TencentVoiceRecognitionConfig) async -> TencentVoiceRecognitionConfigTester.TestResult {
        do {
            let response = try await sendProbe(config: config)
            guard let envelope = try? JSONDecoder().decode(TencentCloudAPIEnvelope.self, from: response.data) else {
                return .failure("Tencent Cloud returned an unreadable response.")
            }

            if let error = envelope.response.error {
                if isCredentialOrPermissionFailure(error.code, message: error.message) {
                    return .failure("\(error.code): \(error.message)")
                }

                if error.code == "FailedOperation.NoSuchTask" {
                    return .success("Credentials accepted. ASR API is reachable.")
                }

                return .success("Credentials accepted. Tencent returned \(error.code).")
            }

            if (200..<300).contains(response.statusCode) {
                return .success("Credentials accepted.")
            }

            return .failure("Tencent Cloud HTTP \(response.statusCode).")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func sendProbe(config: TencentVoiceRecognitionConfig) async throws -> (data: Data, statusCode: Int) {
        let payload = #"{"TaskId":1}"#
        let timestamp = Int(Date().timeIntervalSince1970)
        let date = utcDateString(for: timestamp)
        let credentialScope = "\(date)/\(service)/tc3_request"
        let signedHeaders = "content-type;host;x-tc-action"
        let canonicalHeaders = """
        content-type:\(contentType)
        host:\(host)
        x-tc-action:\(action.lowercased())

        """
        let canonicalRequest = [
            "POST",
            "/",
            "",
            canonicalHeaders,
            signedHeaders,
            sha256Hex(payload)
        ].joined(separator: "\n")
        let stringToSign = [
            algorithm,
            "\(timestamp)",
            credentialScope,
            sha256Hex(canonicalRequest)
        ].joined(separator: "\n")

        let secretDate = hmacSHA256(key: Data(("TC3" + config.secretKey).utf8), message: date)
        let secretService = hmacSHA256(key: secretDate, message: service)
        let secretSigning = hmacSHA256(key: secretService, message: "tc3_request")
        let signature = hmacSHA256(key: secretSigning, message: stringToSign).hexString
        let authorization = "\(algorithm) Credential=\(config.secretID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        guard let url = URL(string: "https://\(host)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(payload.utf8)
        request.timeoutInterval = 10
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(action, forHTTPHeaderField: "X-TC-Action")
        request.setValue("\(timestamp)", forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(region, forHTTPHeaderField: "X-TC-Region")
        if !config.token.isEmpty {
            request.setValue(config.token, forHTTPHeaderField: "X-TC-Token")
        }

        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        let statusCode = (urlResponse as? HTTPURLResponse)?.statusCode ?? -1
        return (data, statusCode)
    }

    private static func isCredentialOrPermissionFailure(_ code: String, message: String) -> Bool {
        let normalized = "\(code) \(message)".lowercased()
        let failures = [
            "authfailure",
            "invalidcredential",
            "requestexpired",
            "unauthorized",
            "signature",
            "secretid",
            "token",
            "permission",
            "denied",
            "notactivated",
            "not activated",
            "arrears"
        ]
        return failures.contains { normalized.contains($0) }
    }

    private static func utcDateString(for timestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    private static func sha256Hex(_ string: String) -> String {
        Data(SHA256.hash(data: Data(string.utf8))).hexString
    }

    private static func hmacSHA256(key: Data, message: String) -> Data {
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        )
        return Data(authenticationCode)
    }

    private struct TencentCloudAPIEnvelope: Decodable {
        let response: TencentCloudAPIResponse

        private enum CodingKeys: String, CodingKey {
            case response = "Response"
        }
    }

    private struct TencentCloudAPIResponse: Decodable {
        let error: TencentCloudAPIError?

        private enum CodingKeys: String, CodingKey {
            case error = "Error"
        }
    }

    private struct TencentCloudAPIError: Decodable {
        let code: String
        let message: String

        private enum CodingKeys: String, CodingKey {
            case code = "Code"
            case message = "Message"
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

enum VoiceInputPhase: Equatable {
    case idle
    case starting(VoiceRecognitionProvider)
    case listening(VoiceRecognitionProvider)

    var isActive: Bool {
        switch self {
        case .idle:
            false
        case .starting, .listening:
            true
        }
    }

    var isStarting: Bool {
        if case .starting = self { return true }
        return false
    }

    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }

    var statusText: String? {
        switch self {
        case .idle:
            nil
        case .starting(.tencent):
            "Starting Tencent voice input..."
        case .starting(.apple):
            "Starting Apple Speech..."
        case .listening(.tencent):
            "Tencent voice input is listening."
        case .listening(.apple):
            "Apple Speech is listening."
        }
    }
}

@MainActor
@Observable
final class VoiceInputController {
    private var appleSession: VoiceRecognitionSession?
    private var tencentSession: TencentVoiceRecognitionSession?
    @ObservationIgnored private var preparedAppleSession: VoiceRecognitionSession?
    @ObservationIgnored private var preparedTencentSession: TencentVoiceRecognitionSession?
    @ObservationIgnored private var lastPreparedProvider: VoiceRecognitionProvider?
    @ObservationIgnored private var lastPreparedTencentConfigKey: String?
    @ObservationIgnored private var warmTencentSession: TencentVoiceRecognitionSession?
    @ObservationIgnored private var warmTencentConfigKey: String?
    @ObservationIgnored private var warmTencentClearTask: Task<Void, Never>?
    @ObservationIgnored private var standbyTencentSession: TencentVoiceRecognitionSession?
    @ObservationIgnored private var standbyTencentConfigKey: String?
    @ObservationIgnored private var activeTencentConfigKey: String?
    @ObservationIgnored private var startID: UInt64 = 0
    private var lastTranscript = ""
    @ObservationIgnored private var lastPrepareRequestTime: CFTimeInterval = 0
    @ObservationIgnored private var lastTencentSettingsIdentity: String?
    @ObservationIgnored private var lastTencentConfigKey: String?
    @ObservationIgnored private var lastTencentConfig: TencentVoiceRecognitionConfig?
    @ObservationIgnored private var currentAudioLevel: CGFloat = 0
    @ObservationIgnored private var audioLevelObservers: [UUID: (CGFloat) -> Void] = [:]
    @ObservationIgnored private var stateObservers: [UUID: (VoiceInputPhase, String?) -> Void] = [:]
    private var lastAudioLevelUpdateTime: CFTimeInterval = 0
    @ObservationIgnored private var sessionStartTime: CFTimeInterval = 0
    @ObservationIgnored private var didLogFirstTranscriptTiming = false
    @ObservationIgnored private var suppressStartingStateNotification = false
    @ObservationIgnored private var suppressLifecycleStateNotifications = false

    @ObservationIgnored private(set) var phase: VoiceInputPhase = .idle
    @ObservationIgnored private var isSessionStarting = false
    @ObservationIgnored private(set) var latestTranscript = ""
    @ObservationIgnored var errorMessage: String?

    var isActive: Bool { isSessionStarting || phase.isActive }
    var isStarting: Bool { phase.isStarting }
    var isListening: Bool { phase.isListening }
    var statusText: String? { phase.statusText }

    func canStartImmediately(settings: AppSettings) -> Bool {
        switch settings.voiceRecognitionProvider {
        case .tencent:
            guard VoiceInputPermissions.hasMicrophonePermission else { return false }
            return cachedTencentConfig(settings: settings).missingFields.isEmpty
        case .apple:
            return VoiceInputPermissions.hasMicrophonePermission && VoiceInputPermissions.hasSpeechPermission
        }
    }

    func prepare(settings: AppSettings, force: Bool = false) {
        guard !isActive else {
            VoiceInputDiagnostics.event("prepare-skipped-active")
            return
        }
        let now = CACurrentMediaTime()
        if !force, now - lastPrepareRequestTime < 0.45 {
            VoiceInputDiagnostics.event("prepare-throttled")
            return
        }
        lastPrepareRequestTime = now

        let provider = settings.voiceRecognitionProvider
        VoiceInputDiagnostics.event("prepare-requested-\(provider.rawValue)")

        switch provider {
        case .tencent:
            guard VoiceInputPermissions.hasMicrophonePermission else {
                VoiceInputDiagnostics.event("prepare-skipped-microphone-permission")
                return
            }
            let config = cachedTencentConfig(settings: settings)
            guard config.missingFields.isEmpty else {
                VoiceInputDiagnostics.event("prepare-skipped-tencent-config")
                return
            }
            clearPreparedAppleSession()
            if lastPreparedProvider == .tencent,
               lastPreparedTencentConfigKey == config.cacheKey,
               preparedTencentSession != nil {
                VoiceInputDiagnostics.event("prepare-tencent-existing")
                return
            }
            clearPreparedTencentSession()
            if warmTencentConfigKey == config.cacheKey, warmTencentSession != nil {
                VoiceInputDiagnostics.event("prepare-tencent-warm-hit")
                return
            }
            preparedTencentSession = TencentVoiceRecognitionSession()
            preparedTencentSession?.prepare(config: config)
            standbyTencentSession = standbyTencentSession ?? TencentVoiceRecognitionSession()
            standbyTencentSession?.prime(config: config)
            standbyTencentConfigKey = config.cacheKey
            lastPreparedProvider = .tencent
            lastPreparedTencentConfigKey = config.cacheKey
            VoiceInputDiagnostics.event("prepare-tencent-dispatched")
        case .apple:
            guard VoiceInputPermissions.hasMicrophonePermission, VoiceInputPermissions.hasSpeechPermission else {
                VoiceInputDiagnostics.event("prepare-skipped-apple-permission")
                return
            }
            clearPreparedTencentSession()
            if lastPreparedProvider == .apple, preparedAppleSession != nil {
                VoiceInputDiagnostics.event("prepare-apple-existing")
                return
            }
            clearPreparedAppleSession()
            preparedAppleSession = VoiceRecognitionSession()
            preparedAppleSession?.prepare()
            lastPreparedProvider = .apple
            lastPreparedTencentConfigKey = nil
            VoiceInputDiagnostics.event("prepare-apple-dispatched")
        }
    }

    func cancelPrepareForImmediateStart(provider: VoiceRecognitionProvider) {
        switch provider {
        case .tencent:
            preparedTencentSession?.cancelPrepare()
        case .apple:
            break
        }
    }

    @discardableResult
    func start(
        settings: AppSettings,
        diagnosticStartTime: CFTimeInterval = 0,
        notifyStartingImmediately: Bool = true,
        notifyLifecycleState: Bool = true,
        onTranscript: @escaping @MainActor (String) -> Void,
        onListening: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        guard !isActive else { return false }
        let provider = settings.voiceRecognitionProvider
        let nowMonotonic = CACurrentMediaTime()
        let nowAbsolute = CFAbsoluteTimeGetCurrent()
        let sessionStartedAt = diagnosticStartTime > 0 ? diagnosticStartTime : nowMonotonic
        let diagnosticStartedAt = diagnosticStartTime > 0
            ? nowAbsolute - max(0, nowMonotonic - diagnosticStartTime)
            : nowAbsolute
        sessionStartTime = sessionStartedAt
        didLogFirstTranscriptTiming = false
        logStartTiming("start-entered")
        latestTranscript = ""
        if currentAudioLevel > 0 {
            setCurrentAudioLevel(0)
        }
        lastTranscript = ""
        lastAudioLevelUpdateTime = 0
        isSessionStarting = true
        errorMessage = nil
        suppressStartingStateNotification = !notifyStartingImmediately
        suppressLifecycleStateNotifications = !notifyLifecycleState
        setPhase(.starting(provider))
        suppressStartingStateNotification = false
        logStartTiming("phase-starting")

        switch provider {
        case .tencent:
            startTencent(
                settings: settings,
                diagnosticStartTime: diagnosticStartedAt,
                onTranscript: onTranscript,
                onListening: onListening
            )
        case .apple:
            cancelPrepareForImmediateStart(provider: provider)
            startApple(onTranscript: onTranscript, onListening: onListening)
        }

        logStartTiming("start-returning")
	        return isSessionStarting || phase.isActive
	    }

    private func startTencent(
        settings: AppSettings,
        diagnosticStartTime: CFTimeInterval,
        onTranscript: @escaping @MainActor (String) -> Void,
        onListening: @escaping @MainActor () -> Void
    ) {
        let config = cachedTencentConfig(settings: settings)
        let missingFields = config.missingFields
        guard missingFields.isEmpty else {
            setErrorMessage("Tencent ASR needs \(missingFields.joined(separator: ", ")).")
            isSessionStarting = false
            suppressStartingStateNotification = false
            setPhase(.idle)
            Haptics.sent(success: false)
            return
        }

        let requestID = nextStartID()
        startID = requestID

        if VoiceInputPermissions.hasMicrophonePermission {
            beginTencentSession(
                config: config,
                diagnosticStartTime: diagnosticStartTime,
                requestID: requestID,
                onTranscript: onTranscript,
                onListening: onListening
            )
            return
        }

        Task {
            let allowed = await VoiceInputPermissions.requestMicrophone()
            guard self.startID == requestID else { return }
            guard allowed else {
                setErrorMessage("Voice input needs microphone permission.")
                self.isSessionStarting = false
                self.suppressStartingStateNotification = false
                setPhase(.idle)
                Haptics.sent(success: false)
                return
            }

            await MainActor.run {
                self.beginTencentSession(
                    config: config,
                    diagnosticStartTime: diagnosticStartTime,
                    requestID: requestID,
                    onTranscript: onTranscript,
                    onListening: onListening
                )
            }
        }
    }

    private func beginTencentSession(
        config: TencentVoiceRecognitionConfig,
        diagnosticStartTime: CFTimeInterval,
        requestID: UInt64,
        onTranscript: @escaping @MainActor (String) -> Void,
        onListening: @escaping @MainActor () -> Void
    ) {
        guard startID == requestID, isActive else { return }
        logStartTiming("tencent-begin-session")
        let preparedMatchesCurrentConfig = lastPreparedTencentConfigKey == config.cacheKey
        let warmMatchesCurrentConfig = warmTencentConfigKey == config.cacheKey
        let standbyMatchesCurrentConfig = standbyTencentConfigKey == config.cacheKey
        let sessionSource: String
        let nextSession: TencentVoiceRecognitionSession
        if preparedMatchesCurrentConfig {
            sessionSource = preparedTencentSession == nil ? "prepared-miss-new" : "prepared"
            nextSession = preparedTencentSession ?? TencentVoiceRecognitionSession()
        } else if warmMatchesCurrentConfig {
            sessionSource = warmTencentSession == nil ? "warm-miss-new" : "warm"
            nextSession = warmTencentSession ?? TencentVoiceRecognitionSession()
        } else if standbyMatchesCurrentConfig {
            sessionSource = standbyTencentSession == nil ? "standby-miss-new" : "standby"
            nextSession = standbyTencentSession ?? TencentVoiceRecognitionSession()
        } else {
            sessionSource = "cold"
            nextSession = TencentVoiceRecognitionSession()
        }
        logStartTiming("tencent-session-\(sessionSource)")
        if !preparedMatchesCurrentConfig {
            preparedTencentSession?.cancelPrepare()
        }
        warmTencentClearTask?.cancel()
        warmTencentClearTask = nil
        warmTencentSession = nil
        warmTencentConfigKey = nil
        preparedTencentSession = nil
        lastPreparedTencentConfigKey = nil
        if standbyTencentSession === nextSession {
            standbyTencentSession = nil
            standbyTencentConfigKey = nil
        } else if !standbyMatchesCurrentConfig {
            standbyTencentSession?.stop(keepWarm: false)
            standbyTencentSession = nil
            standbyTencentConfigKey = nil
        }
        activeTencentConfigKey = config.cacheKey
        tencentSession = nextSession
        nextSession.start(
            config: config,
            diagnosticStartTime: diagnosticStartTime,
            onTranscript: { [weak nextSession] transcript, _ in
                guard self.tencentSession === nextSession, self.isActive else { return }
                onListening()
                self.markListening(.tencent)
                self.updateTranscript(transcript, onTranscript: onTranscript)
            },
            onError: { [weak nextSession] message in
                guard self.tencentSession === nextSession, self.isActive else { return }
                self.setErrorMessage(message)
                self.stop(clearError: false)
                Haptics.sent(success: false)
            },
            onFinished: { [weak nextSession] text in
                guard self.tencentSession === nextSession, self.isActive else { return }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.updateTranscript(text, force: true, onTranscript: onTranscript)
                }
                self.stop()
            },
            onVolume: { [weak nextSession] level in
                guard self.tencentSession === nextSession, self.isActive else { return }
                self.updateAudioLevel(level)
            },
            onRecordStarted: { [weak nextSession] in
                guard self.tencentSession === nextSession, self.isActive else { return }
                onListening()
                self.markListening(.tencent)
                self.logStartTiming("tencent-record-started")
            }
        )
    }

    private func startApple(
        onTranscript: @escaping @MainActor (String) -> Void,
        onListening: @escaping @MainActor () -> Void
    ) {
        let requestID = nextStartID()
        startID = requestID

        if VoiceInputPermissions.hasMicrophonePermission, VoiceInputPermissions.hasSpeechPermission {
            beginAppleSession(requestID: requestID, onTranscript: onTranscript, onListening: onListening)
            return
        }

        Task {
            let allowed = await VoiceInputPermissions.request()
            guard self.startID == requestID else { return }
            guard allowed else {
                setErrorMessage("Voice input needs microphone and speech recognition permission.")
                self.isSessionStarting = false
                self.suppressStartingStateNotification = false
                setPhase(.idle)
                Haptics.sent(success: false)
                return
            }

            self.beginAppleSession(requestID: requestID, onTranscript: onTranscript, onListening: onListening)
        }
    }

    private func beginAppleSession(
        requestID: UInt64,
        onTranscript: @escaping @MainActor (String) -> Void,
        onListening: @escaping @MainActor () -> Void
    ) {
        guard startID == requestID, isActive else { return }
        let nextSession = preparedAppleSession ?? VoiceRecognitionSession()
        preparedAppleSession = nil
        appleSession = nextSession
        nextSession.start(
            onTranscript: { [weak nextSession] transcript, isFinal in
                guard self.appleSession === nextSession, self.isActive else { return }
                onListening()
                self.markListening(.apple)
                self.updateTranscript(transcript, force: isFinal, onTranscript: onTranscript)
                if isFinal {
                    self.stop()
                }
            },
            onError: { [weak nextSession] message in
                guard self.appleSession === nextSession, self.isActive else { return }
                self.setErrorMessage(message)
                self.stop(clearError: false)
                Haptics.sent(success: false)
            },
            onVolume: { [weak nextSession] level in
                guard self.appleSession === nextSession, self.isActive else { return }
                self.updateAudioLevel(level)
            },
            onStarted: { [weak nextSession] in
                guard self.appleSession === nextSession, self.isActive else { return }
                onListening()
                self.markListening(.apple)
                self.logStartTiming("apple-record-started")
            }
        )
    }

    func stop(
        clearError: Bool = true,
        keepTencentWarm: Bool = true
    ) {
        if !keepTencentWarm {
            clearPreparedAppleSession()
            clearPreparedTencentSession()
        }

        if !keepTencentWarm, !isActive, appleSession == nil, tencentSession == nil, warmTencentSession != nil {
            warmTencentClearTask?.cancel()
            warmTencentClearTask = nil
            warmTencentSession?.stop(keepWarm: false)
            warmTencentSession = nil
            warmTencentConfigKey = nil
            return
        }

        guard isActive || appleSession != nil || tencentSession != nil else { return }

        invalidateStartID()
        let currentAppleSession = appleSession
        let currentTencentSession = tencentSession
        let currentTencentConfigKey = activeTencentConfigKey
        appleSession = nil
        tencentSession = nil
        activeTencentConfigKey = nil
        let shouldNotifyStopState = !suppressLifecycleStateNotifications
        isSessionStarting = false
        suppressStartingStateNotification = false
        if shouldNotifyStopState {
            setPhase(.idle)
        } else {
            phase = .idle
        }
        setCurrentAudioLevel(0)
        lastTranscript = ""
        lastAudioLevelUpdateTime = 0
        sessionStartTime = 0
        didLogFirstTranscriptTiming = false
        if clearError {
            setErrorMessage(nil)
        }
        currentAppleSession?.stop()
        if let currentTencentSession {
            currentTencentSession.stop(keepWarm: clearError && keepTencentWarm)
            if clearError && keepTencentWarm {
                warmTencentSession = currentTencentSession
                warmTencentConfigKey = currentTencentConfigKey
                scheduleWarmTencentSessionClear()
            }
        }
        suppressLifecycleStateNotifications = false
    }

    private func clearPreparedTencentSession() {
        preparedTencentSession?.stop(keepWarm: false)
        preparedTencentSession = nil
        standbyTencentSession?.stop(keepWarm: false)
        standbyTencentSession = nil
        standbyTencentConfigKey = nil
        if lastPreparedProvider == .tencent {
            lastPreparedProvider = nil
        }
        lastPreparedTencentConfigKey = nil
        lastPrepareRequestTime = 0
    }

    private func clearPreparedAppleSession() {
        preparedAppleSession?.stop()
        preparedAppleSession = nil
        if lastPreparedProvider == .apple {
            lastPreparedProvider = nil
        }
        lastPrepareRequestTime = 0
    }

    private func scheduleWarmTencentSessionClear() {
        warmTencentClearTask?.cancel()
        warmTencentClearTask = Task {
            try? await Task.sleep(for: .milliseconds(12000))
            await MainActor.run {
                self.warmTencentSession?.stop(keepWarm: false)
                self.warmTencentSession = nil
                self.warmTencentConfigKey = nil
                self.warmTencentClearTask = nil
            }
        }
    }

    private func updateAudioLevel(_ nextLevel: CGFloat) {
        let now = CACurrentMediaTime()
        let clamped = min(max(nextLevel, 0), 1)
        let smoothing: CGFloat = clamped > currentAudioLevel ? 0.42 : 0.18
        var smoothedLevel = currentAudioLevel + (clamped - currentAudioLevel) * smoothing
        if smoothedLevel < 0.015 {
            smoothedLevel = 0
        }

        guard now - lastAudioLevelUpdateTime >= (1.0 / 15.0) ||
            abs(smoothedLevel - currentAudioLevel) >= 0.035 ||
            (smoothedLevel == 0 && currentAudioLevel != 0)
        else { return }

        lastAudioLevelUpdateTime = now
        setCurrentAudioLevel(smoothedLevel)
    }

    @discardableResult
    func addAudioLevelObserver(_ observer: @escaping (CGFloat) -> Void) -> UUID {
        let id = UUID()
        audioLevelObservers[id] = observer
        observer(currentAudioLevel)
        return id
    }

    func removeAudioLevelObserver(_ id: UUID) {
        audioLevelObservers[id] = nil
    }

    @discardableResult
    func addStateObserver(_ observer: @escaping (VoiceInputPhase, String?) -> Void) -> UUID {
        let id = UUID()
        stateObservers[id] = observer
        observer(phase, errorMessage)
        return id
    }

    func removeStateObserver(_ id: UUID) {
        stateObservers[id] = nil
    }

    private func notifyStateObservers() {
        for observer in stateObservers.values {
            observer(phase, errorMessage)
        }
    }

    private func setPhase(_ nextPhase: VoiceInputPhase) {
        guard phase != nextPhase else { return }
        phase = nextPhase
        if suppressLifecycleStateNotifications, nextPhase.isActive || nextPhase == .idle {
            return
        }
        if suppressStartingStateNotification, nextPhase.isStarting {
            return
        }
        notifyStateObservers()
    }

    private func setErrorMessage(_ nextMessage: String?) {
        guard errorMessage != nextMessage else { return }
        errorMessage = nextMessage
        notifyStateObservers()
    }

    private func setCurrentAudioLevel(_ level: CGFloat) {
        guard abs(currentAudioLevel - level) > 0.001 else { return }
        currentAudioLevel = level
        for observer in audioLevelObservers.values {
            observer(level)
        }
    }

    private func markListening(_ provider: VoiceRecognitionProvider) {
        let nextPhase: VoiceInputPhase = .listening(provider)
        let phaseChanged = phase != nextPhase
        let startingChanged = isSessionStarting
        let errorChanged = errorMessage != nil
        guard phaseChanged || startingChanged || errorChanged else { return }

        phase = nextPhase
        isSessionStarting = false
        errorMessage = nil
        if suppressLifecycleStateNotifications {
            return
        }
        notifyStateObservers()
    }

    private func updateTranscript(
        _ transcript: String,
        force: Bool = false,
        onTranscript: @escaping @MainActor (String) -> Void
    ) {
        guard force || transcript != lastTranscript else { return }

        lastTranscript = transcript
        latestTranscript = transcript
        if !didLogFirstTranscriptTiming, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            didLogFirstTranscriptTiming = true
            logStartTiming("first-transcript")
        }
        onTranscript(transcript)
    }

    private func logStartTiming(_ event: String) {
        guard sessionStartTime > 0 else { return }
        let elapsedMilliseconds = Int((CACurrentMediaTime() - sessionStartTime) * 1_000)
        VoiceInputDiagnostics.timing(event, elapsedMilliseconds: elapsedMilliseconds)
    }

    private func cachedTencentConfig(settings: AppSettings) -> TencentVoiceRecognitionConfig {
        let settingsIdentity = TencentVoiceRecognitionConfig.settingsIdentity(settings: settings)
        if lastTencentSettingsIdentity == settingsIdentity, let lastTencentConfig {
            return lastTencentConfig
        }
        let config = TencentVoiceRecognitionConfig(settings: settings)
        lastTencentSettingsIdentity = settingsIdentity
        lastTencentConfigKey = config.cacheKey
        lastTencentConfig = config
        return config
    }

    private func nextStartID() -> UInt64 {
        startID &+= 1
        return startID
    }

    private func invalidateStartID() {
        startID &+= 1
    }
}

enum VoiceInputDiagnostics {
    private static let queue = DispatchQueue(label: "dev.hcg.AgentMonitor.voice-input-diagnostics", qos: .utility)

    static func timing(_ event: String, elapsedMilliseconds: Int) {
        #if DEBUG
        queue.async {
            NSLog("[VoiceInputTiming] %@ %ldms", event, elapsedMilliseconds)
        }
        #endif
    }

    static func event(_ event: String) {
        #if DEBUG
        queue.async {
            NSLog("[VoiceInputTiming] %@", event)
        }
        #endif
    }
}

@MainActor
enum Haptics {
    private static let successImpact = UIImpactFeedbackGenerator(style: .light)
    private static let voicePressImpact = UIImpactFeedbackGenerator(style: .soft)
    private static let cancelImpact = UIImpactFeedbackGenerator(style: .light)
    private static let errorNotification = UINotificationFeedbackGenerator()

    static func prepareVoicePress() {
        voicePressImpact.prepare()
        cancelImpact.prepare()
    }

    static func voicePress() {
        voicePressImpact.impactOccurred(intensity: 0.75)
        voicePressImpact.prepare()
    }

    static func cancelZoneEntered() {
        cancelImpact.impactOccurred(intensity: 0.7)
        cancelImpact.prepare()
    }

    static func voiceCanceled() {
        cancelImpact.impactOccurred(intensity: 0.45)
        cancelImpact.prepare()
    }

    static func sent(success: Bool) {
        if success {
            successImpact.impactOccurred()
            successImpact.prepare()
        } else {
            errorNotification.notificationOccurred(.error)
            errorNotification.prepare()
        }
    }
}
