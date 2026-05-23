import AVFAudio
import Foundation
import Observation

private final class BackgroundNoiseGenerator {
    private var noiseState: UInt64 = 0x1234_5678_9abc_def0

    func nextSample() -> Float {
        noiseState = 6364136223846793005 &* noiseState &+ 1442695040888963407
        let value = UInt32(truncatingIfNeeded: noiseState >> 32)
        return (Float(value) / Float(UInt32.max)) * 2 - 1
    }
}

@MainActor
@Observable
final class BackgroundAudioKeepAlive {
    private let audioWorker = BackgroundAudioKeepAliveWorker()
    private var desiredEnabled = false
    private var isSuspendedForVoiceInput = false
    @ObservationIgnored private var suspendedSilentlyWithRunningAudio = false

    var isRunning = false
    var lastErrorMessage: String?

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        desiredEnabled = enabled
        guard !isSuspendedForVoiceInput else {
            if !enabled {
                stop()
            }
            return true
        }

        if enabled {
            return start()
        }

        stop()
        return true
    }

    func suspendForVoiceInput() {
        suspendForVoiceInput(publishStateChange: true, diagnosticStartedAt: nil)
    }

    func suspendForVoiceInputSilently(diagnosticStartedAt: CFAbsoluteTime? = nil) {
        suspendForVoiceInput(publishStateChange: false, diagnosticStartedAt: diagnosticStartedAt)
    }

    @discardableResult
    func suspendForVoiceInputAndWaitSilently(
        diagnosticStartedAt: CFAbsoluteTime? = nil,
        timeout: Duration? = nil
    ) async -> Bool {
        guard !isSuspendedForVoiceInput else { return true }

        isSuspendedForVoiceInput = true
        if isRunning {
            suspendedSilentlyWithRunningAudio = true
        }

        let didFinish = await audioWorker.stopForVoiceInput(timeout: timeout)
        guard let diagnosticStartedAt else { return didFinish }
        let elapsedMilliseconds = Int((CFAbsoluteTimeGetCurrent() - diagnosticStartedAt) * 1_000)
        VoiceInputDiagnostics.timing(
            didFinish ? "background-audio-suspend-finished" : "background-audio-suspend-timeout",
            elapsedMilliseconds: elapsedMilliseconds
        )
        return didFinish
    }

    private func suspendForVoiceInput(publishStateChange: Bool, diagnosticStartedAt: CFAbsoluteTime?) {
        guard !isSuspendedForVoiceInput else { return }

        isSuspendedForVoiceInput = true
        if publishStateChange {
            isRunning = false
        } else if isRunning {
            suspendedSilentlyWithRunningAudio = true
        }
        audioWorker.stopForVoiceInput { _ in
            guard let diagnosticStartedAt else { return }
            let elapsedMilliseconds = Int((CFAbsoluteTimeGetCurrent() - diagnosticStartedAt) * 1_000)
            VoiceInputDiagnostics.timing("background-audio-suspend-finished", elapsedMilliseconds: elapsedMilliseconds)
        }
    }

    func resumeAfterVoiceInput() {
        guard isSuspendedForVoiceInput else { return }

        let shouldRestartSilently = suspendedSilentlyWithRunningAudio
        suspendedSilentlyWithRunningAudio = false
        isSuspendedForVoiceInput = false
        if desiredEnabled {
            if shouldRestartSilently, isRunning {
                startWorker()
            } else {
                start()
            }
        }
    }

    @discardableResult
    func start() -> Bool {
        guard desiredEnabled, !isSuspendedForVoiceInput else { return true }
        guard !isRunning else { return true }

        isRunning = true
        lastErrorMessage = nil
        startWorker()
        return true
    }

    func stop() {
        guard isRunning else { return }

        suspendedSilentlyWithRunningAudio = false
        isRunning = false
        audioWorker.stop(deactivateSession: true) { _ in }
    }

    private func startWorker() {
        audioWorker.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.setRunning(self.desiredEnabled && !self.isSuspendedForVoiceInput)
                    if self.lastErrorMessage != nil {
                        self.lastErrorMessage = nil
                    }
                case .failure(let error):
                    let message = error.localizedDescription
                    if self.lastErrorMessage != message {
                        self.lastErrorMessage = message
                    }
                    self.desiredEnabled = false
                    self.setRunning(false)
                    self.suspendedSilentlyWithRunningAudio = false
                }
            }
        }
    }

    private func setRunning(_ running: Bool) {
        guard isRunning != running else { return }
        isRunning = running
    }
}

private final class SingleResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

private final class BackgroundAudioKeepAliveWorker: @unchecked Sendable {
    private static let queueKey = DispatchSpecificKey<Int>()

    private let queue = DispatchQueue(label: "dev.hcg.AgentMonitor.background-audio", qos: .utility)
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    init() {
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    func start(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            do {
                try startOnQueue()
                completion(.success(()))
            } catch {
                stopOnQueue(deactivateSession: true)
                completion(.failure(error))
            }
        }
    }

    func stop(deactivateSession: Bool, completion: @escaping @Sendable (Result<Void, Never>) -> Void) {
        queue.async { [self] in
            stopOnQueue(deactivateSession: deactivateSession)
            completion(.success(()))
        }
    }

    func stopForVoiceInput(completion: @escaping @Sendable (Result<Void, Never>) -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) == 1 {
            stopOnQueue(deactivateSession: false)
            completion(.success(()))
            return
        }

        queue.async { [self] in
            stopOnQueue(deactivateSession: false)
            completion(.success(()))
        }
    }

    func stopForVoiceInput(timeout: Duration? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = SingleResumeGate()
            let finish: @Sendable (Bool) -> Void = { didFinish in
                guard gate.claim() else { return }
                continuation.resume(returning: didFinish)
            }
            stopForVoiceInput { _ in
                finish(true)
            }

            if let timeout {
                Task {
                    try? await Task.sleep(for: timeout)
                    finish(false)
                }
            }
        }
    }

    private func startOnQueue() throws {
        guard !engine.isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) else {
            throw BackgroundAudioKeepAliveError.invalidAudioFormat
        }

        let generator = BackgroundNoiseGenerator()
        let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

            for frame in 0..<Int(frameCount) {
                let sample = generator.nextSample() * 0.0005
                for buffer in buffers {
                    let pointer = buffer.mData?.assumingMemoryBound(to: Float.self)
                    pointer?[frame] = sample
                }
            }

            return noErr
        }

        sourceNode = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        engine.prepare()
        try engine.start()
    }

    private func stopOnQueue(deactivateSession: Bool) {
        guard engine.isRunning || sourceNode != nil else { return }

        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
        }
        sourceNode = nil
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

private enum BackgroundAudioKeepAliveError: LocalizedError {
    case invalidAudioFormat

    var errorDescription: String? {
        switch self {
        case .invalidAudioFormat:
            return "Background audio format could not be created."
        }
    }
}
