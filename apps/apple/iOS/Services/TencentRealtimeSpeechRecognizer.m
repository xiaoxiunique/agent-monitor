#import "TencentRealtimeSpeechRecognizer.h"

#import <AVFoundation/AVFoundation.h>
#import <QCloudRealTime/QCloudAudioDataSource.h>
#import <QCloudRealTime/QCloudConfig.h>
#import <QCloudRealTime/QCloudRealTimeRecognizer.h>
#import <QCloudRealTime/QCloudRealTimeResult.h>
#include <math.h>

@implementation TencentRealtimeSpeechConfig
@end

@interface AgentMonitorTencentAudioDataSource : NSObject <QCloudAudioDataSource>

@property(nonatomic, assign) BOOL running;
@property(nonatomic, copy, readonly) NSString *audioFilePath;
@property(nonatomic, assign, readonly) BOOL recording;
@property(nonatomic, assign, readonly) BOOL captureGraphPrepared;
@property(nonatomic, assign, readonly) BOOL microphoneWarm;
@property(nonatomic, assign, readonly) NSUInteger lastPrerollBytesSeeded;
@property(nonatomic, assign, readonly) BOOL lastPrerollWasPrimeSilence;
@property(nonatomic, assign, readonly) NSUInteger lastReadBytesProvided;

- (BOOL)prepareCaptureGraphWithError:(NSError **)error;
- (BOOL)warmCaptureGraphWithError:(NSError **)error;
- (BOOL)beginCaptureForRecognitionWithError:(NSError **)error;
- (void)shutdownCapture;

@end

@interface AgentMonitorTencentAudioDataSource ()

@property(nonatomic, strong) AVAudioEngine *engine;
@property(nonatomic, strong) AVAudioFormat *outputFormat;
@property(nonatomic, strong, nullable) AVAudioFormat *inputFormat;
@property(nonatomic, strong, nullable) AVAudioConverter *converter;
@property(nonatomic, strong) NSMutableData *pcmBuffer;
@property(nonatomic, strong) NSMutableData *prerollPCMBuffer;
@property(nonatomic, strong) NSCondition *condition;
@property(nonatomic, copy, nullable) void (^onFirstPCMData)(void);
@property(nonatomic, copy, nullable) void (^onFirstReadData)(void);
@property(nonatomic, assign) BOOL captureEnabled;
@property(nonatomic, assign) BOOL prerollEnabled;
@property(nonatomic, assign) BOOL hasInstalledTap;
@property(nonatomic, assign) BOOL didPrimeForRecognition;
@property(nonatomic, assign) BOOL didNotifyFirstPCMData;
@property(nonatomic, assign) BOOL didNotifyFirstReadData;
@property(nonatomic, assign) NSUInteger lastPrerollBytesSeededValue;
@property(nonatomic, assign) BOOL lastPrerollWasPrimeSilenceValue;
@property(nonatomic, assign) NSUInteger lastReadBytesProvidedValue;

@end

@implementation AgentMonitorTencentAudioDataSource

static const NSUInteger AgentMonitorTencentAudioMaxBufferBytes = 16000 * 2 * 5;
static const NSUInteger AgentMonitorTencentAudioPrerollBytes = 16000 * 2 * 6 / 10;
static const NSUInteger AgentMonitorTencentAudioPrimeSilenceBytes = 16000 * 2 / 20;

- (instancetype)init {
    self = [super init];
    if (self) {
        _engine = [[AVAudioEngine alloc] init];
        _outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                         sampleRate:16000
                                                           channels:1
                                                        interleaved:YES];
        _pcmBuffer = [NSMutableData data];
        _prerollPCMBuffer = [NSMutableData data];
        _condition = [[NSCondition alloc] init];
    }
    return self;
}

- (NSString *)audioFilePath {
    return @"";
}

- (BOOL)recording {
    return self.engine.isRunning;
}

- (BOOL)captureGraphPrepared {
    return self.hasInstalledTap && self.converter && self.inputFormat;
}

- (BOOL)microphoneWarm {
    return self.engine.isRunning;
}

- (NSUInteger)lastPrerollBytesSeeded {
    [self.condition lock];
    NSUInteger value = self.lastPrerollBytesSeededValue;
    [self.condition unlock];
    return value;
}

- (BOOL)lastPrerollWasPrimeSilence {
    [self.condition lock];
    BOOL value = self.lastPrerollWasPrimeSilenceValue;
    [self.condition unlock];
    return value;
}

- (NSUInteger)lastReadBytesProvided {
    [self.condition lock];
    NSUInteger value = self.lastReadBytesProvidedValue;
    [self.condition unlock];
    return value;
}

- (BOOL)warmCaptureGraphWithError:(NSError **)error {
    if (![self prepareCaptureGraphWithError:error]) {
        return NO;
    }

    BOOL wasPrerolling = self.engine.isRunning && self.prerollEnabled && !self.captureEnabled;
    [self.condition lock];
    self.running = NO;
    self.captureEnabled = NO;
    self.prerollEnabled = YES;
    self.didPrimeForRecognition = NO;
    self.didNotifyFirstReadData = NO;
    self.lastPrerollBytesSeededValue = 0;
    self.lastPrerollWasPrimeSilenceValue = NO;
    self.lastReadBytesProvidedValue = 0;
    [self.pcmBuffer setLength:0];
    if (!wasPrerolling) {
        [self.prerollPCMBuffer setLength:0];
    }
    [self.condition broadcast];
    [self.condition unlock];

    if (self.engine.isRunning) {
        return YES;
    }

    return [self.engine startAndReturnError:error];
}

- (BOOL)beginCaptureForRecognitionWithError:(NSError **)error {
    if (![self prepareCaptureGraphWithError:error]) {
        return NO;
    }

    [self.condition lock];
    self.running = NO;
    self.captureEnabled = YES;
    self.prerollEnabled = NO;
    [self.pcmBuffer setLength:0];
    NSUInteger prerollLength = MIN(self.prerollPCMBuffer.length, AgentMonitorTencentAudioPrerollBytes);
    if (prerollLength > 0) {
        NSRange range = NSMakeRange(self.prerollPCMBuffer.length - prerollLength, prerollLength);
        [self.pcmBuffer appendData:[self.prerollPCMBuffer subdataWithRange:range]];
    } else {
        [self.pcmBuffer increaseLengthBy:AgentMonitorTencentAudioPrimeSilenceBytes];
        prerollLength = AgentMonitorTencentAudioPrimeSilenceBytes;
        self.lastPrerollWasPrimeSilenceValue = YES;
    }
    self.lastPrerollBytesSeededValue = prerollLength;
    [self.prerollPCMBuffer setLength:0];
    self.didPrimeForRecognition = YES;
    self.didNotifyFirstPCMData = NO;
    self.didNotifyFirstReadData = NO;
    [self.condition broadcast];
    [self.condition unlock];

    if (self.engine.isRunning) {
        return YES;
    }

    if (![self.engine startAndReturnError:error]) {
        [self.condition lock];
        self.captureEnabled = NO;
        self.didPrimeForRecognition = NO;
        [self.condition broadcast];
        [self.condition unlock];
        return NO;
    }

    return YES;
}

- (BOOL)prepareCaptureGraphWithError:(NSError **)error {
    if (self.captureGraphPrepared) {
        return YES;
    }

    AVAudioInputNode *inputNode = self.engine.inputNode;
    AVAudioFormat *inputFormat = [inputNode outputFormatForBus:0];
    if (inputFormat.channelCount == 0 || inputFormat.sampleRate <= 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"dev.hcg.AgentMonitor.tencent-audio-source"
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: @"No microphone input format is available."}];
        }
        return NO;
    }

    self.inputFormat = inputFormat;
    self.converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:self.outputFormat];
    if (!self.converter) {
        if (error) {
            *error = [NSError errorWithDomain:@"dev.hcg.AgentMonitor.tencent-audio-source"
                                         code:1002
                                     userInfo:@{NSLocalizedDescriptionKey: @"Microphone format converter could not be created."}];
        }
        return NO;
    }

    if (self.hasInstalledTap) {
        [inputNode removeTapOnBus:0];
        self.hasInstalledTap = NO;
    }

    __weak typeof(self) weakSelf = self;
    [inputNode installTapOnBus:0
                    bufferSize:512
                        format:inputFormat
                         block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        #pragma unused(when)
        [weakSelf consumeInputBuffer:buffer];
    }];
    self.hasInstalledTap = YES;

    [self.engine prepare];
    return YES;
}

- (void)start:(void (^)(BOOL didStart, NSError *error))completion {
    NSError *error = nil;
    [self.condition lock];
    BOOL alreadyPrimed = self.captureEnabled || self.didPrimeForRecognition || self.pcmBuffer.length > 0;
    [self.condition unlock];

    BOOL didStart = YES;
    if (!alreadyPrimed) {
        didStart = [self beginCaptureForRecognitionWithError:&error];
    }
    [self.condition lock];
    self.running = didStart;
    self.captureEnabled = didStart;
    self.didPrimeForRecognition = self.pcmBuffer.length == 0;
    [self.condition broadcast];
    [self.condition unlock];

    if (completion) {
        completion(didStart, error);
    }
}

- (void)stop {
    [self.condition lock];
    self.running = NO;
    self.captureEnabled = NO;
    self.prerollEnabled = self.engine.isRunning;
    [self.condition broadcast];
    [self.condition unlock];
}

- (nullable NSData *)readData:(NSInteger)expectLength {
    if (expectLength <= 0) {
        return [NSData data];
    }

    void (^firstReadDataHandler)(void) = nil;

    [self.condition lock];
    if ((self.running || self.didPrimeForRecognition) && self.pcmBuffer.length == 0) {
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.08];
        while ((self.running || self.didPrimeForRecognition) && self.pcmBuffer.length == 0) {
            if (![self.condition waitUntilDate:deadline]) {
                break;
            }
        }
    }

    NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)expectLength];
    if (self.pcmBuffer.length > 0) {
        NSUInteger availableLength = MIN(self.pcmBuffer.length, (NSUInteger)expectLength);
        [data appendData:[self.pcmBuffer subdataWithRange:NSMakeRange(0, availableLength)]];
        [self.pcmBuffer replaceBytesInRange:NSMakeRange(0, availableLength) withBytes:NULL length:0];
        self.lastReadBytesProvidedValue = availableLength;
        self.didPrimeForRecognition = NO;
        if (!self.didNotifyFirstReadData) {
            self.didNotifyFirstReadData = YES;
            firstReadDataHandler = self.onFirstReadData;
        }
    }
    if (data.length < (NSUInteger)expectLength) {
        [data increaseLengthBy:(NSUInteger)expectLength - data.length];
    }
    [self.condition unlock];
    if (firstReadDataHandler) {
        firstReadDataHandler();
    }
    return data;
}

- (void)shutdownCapture {
    [self stop];

    if (self.hasInstalledTap) {
        [self.engine.inputNode removeTapOnBus:0];
        self.hasInstalledTap = NO;
    }
    [self.engine stop];
    self.converter = nil;
    self.inputFormat = nil;

    [self.condition lock];
    self.prerollEnabled = NO;
    [self.pcmBuffer setLength:0];
    [self.prerollPCMBuffer setLength:0];
    self.didPrimeForRecognition = NO;
    self.didNotifyFirstReadData = NO;
    self.lastPrerollBytesSeededValue = 0;
    self.lastPrerollWasPrimeSilenceValue = NO;
    self.lastReadBytesProvidedValue = 0;
    [self.condition broadcast];
    [self.condition unlock];
}

- (void)consumeInputBuffer:(AVAudioPCMBuffer *)inputBuffer {
    if (!inputBuffer || inputBuffer.frameLength == 0) {
        return;
    }

    [self.condition lock];
    BOOL shouldCapture = self.captureEnabled;
    BOOL shouldKeepPreroll = !shouldCapture && self.prerollEnabled;
    [self.condition unlock];
    if (!shouldCapture && !shouldKeepPreroll) {
        return;
    }

    AVAudioConverter *converter = self.converter;
    AVAudioFormat *outputFormat = self.outputFormat;
    if (!converter || !outputFormat) {
        return;
    }

    double ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate;
    AVAudioFrameCount outputCapacity = (AVAudioFrameCount)ceil((double)inputBuffer.frameLength * ratio) + 512;
    AVAudioPCMBuffer *outputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat frameCapacity:outputCapacity];
    if (!outputBuffer) {
        return;
    }

    __block BOOL didProvideInput = NO;
    AVAudioConverterInputBlock inputBlock = ^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus *outStatus) {
        #pragma unused(inNumberOfPackets)
        if (didProvideInput) {
            *outStatus = AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }

        didProvideInput = YES;
        *outStatus = AVAudioConverterInputStatus_HaveData;
        return inputBuffer;
    };

    NSError *conversionError = nil;
    AVAudioConverterOutputStatus status = [converter convertToBuffer:outputBuffer error:&conversionError withInputFromBlock:inputBlock];
    if (status == AVAudioConverterOutputStatus_Error || outputBuffer.frameLength == 0) {
        return;
    }

    const AudioBufferList *audioBufferList = outputBuffer.audioBufferList;
    if (!audioBufferList || audioBufferList->mNumberBuffers == 0) {
        return;
    }

    AudioBuffer audioBuffer = audioBufferList->mBuffers[0];
    if (!audioBuffer.mData || audioBuffer.mDataByteSize == 0) {
        return;
    }

    NSData *pcm = [NSData dataWithBytes:audioBuffer.mData length:audioBuffer.mDataByteSize];
    if (shouldCapture) {
        [self appendPCMData:pcm];
    } else {
        [self appendPrerollPCMData:pcm];
    }
}

- (void)appendPCMData:(NSData *)data {
    if (data.length == 0) {
        return;
    }

	    [self.condition lock];
	    void (^firstPCMDataHandler)(void) = nil;
	    if (self.captureEnabled) {
	        [self.pcmBuffer appendData:data];
	        if (!self.didNotifyFirstPCMData) {
	            self.didNotifyFirstPCMData = YES;
	            firstPCMDataHandler = self.onFirstPCMData;
	        }
	        if (self.pcmBuffer.length > AgentMonitorTencentAudioMaxBufferBytes) {
	            NSUInteger overflow = self.pcmBuffer.length - AgentMonitorTencentAudioMaxBufferBytes;
	            [self.pcmBuffer replaceBytesInRange:NSMakeRange(0, overflow) withBytes:NULL length:0];
	        }
	        [self.condition broadcast];
	    }
	    [self.condition unlock];
	    if (firstPCMDataHandler) {
	        firstPCMDataHandler();
	    }
	}

- (void)appendPrerollPCMData:(NSData *)data {
    if (data.length == 0) {
        return;
    }

    [self.condition lock];
    if (self.prerollEnabled && !self.captureEnabled) {
        [self.prerollPCMBuffer appendData:data];
        if (self.prerollPCMBuffer.length > AgentMonitorTencentAudioPrerollBytes) {
            NSUInteger overflow = self.prerollPCMBuffer.length - AgentMonitorTencentAudioPrerollBytes;
            [self.prerollPCMBuffer replaceBytesInRange:NSMakeRange(0, overflow) withBytes:NULL length:0];
        }
    }
    [self.condition unlock];
}

@end

@interface TencentRealtimeSpeechRecognizer () <QCloudRealTimeRecognizerDelegate>

@property(nonatomic, strong) TencentRealtimeSpeechConfig *speechConfig;
@property(nonatomic, strong, nullable) QCloudRealTimeRecognizer *recognizer;
@property(nonatomic, strong, nullable) AgentMonitorTencentAudioDataSource *audioSource;
@property(nonatomic, strong) dispatch_queue_t workQueue;
@property(nonatomic, assign) BOOL didNotifyRecordStarted;
@property(nonatomic, assign) CFAbsoluteTime lastVolumeCallbackTime;
@property(nonatomic, assign) float lastVolumeCallbackValue;
@property(nonatomic, strong, nullable) QCloudConfig *preparedConfig;
@property(nonatomic, strong, nullable) QCloudRealTimeRecognizer *preparedRecognizer;
@property(nonatomic, strong, nullable) AgentMonitorTencentAudioDataSource *preparedAudioSource;
@property(nonatomic, strong, nullable) QCloudRealTimeRecognizer *warmRecognizer;
@property(nonatomic, strong, nullable) AgentMonitorTencentAudioDataSource *warmAudioSource;
@property(nonatomic, strong, nullable) dispatch_block_t stopWarmMicrophoneBlock;
@property(atomic, assign) BOOL startPending;
@property(atomic, assign) BOOL startRequestedDuringPrepare;
@property(nonatomic, strong, nullable) dispatch_block_t pendingPrepareBlock;
@property(atomic, assign) BOOL prepareRunning;
@property(nonatomic, assign) BOOL didPrepareAudioSession;
@property(nonatomic, copy, nullable) NSString *preparedAudioSessionCategory;
@property(nonatomic, copy, nullable) NSString *preparedAudioSessionMode;
@property(nonatomic, assign) CFAbsoluteTime startRequestedAt;
@property(nonatomic, assign) CFAbsoluteTime diagnosticStartedAt;
@property(nonatomic, assign) CFAbsoluteTime prepareStartedAt;

@end

@implementation TencentRealtimeSpeechRecognizer

- (instancetype)initWithConfig:(TencentRealtimeSpeechConfig *)config {
    self = [super init];
    if (self) {
        _speechConfig = config;
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL,
            QOS_CLASS_USER_INITIATED,
            0
        );
        _workQueue = dispatch_queue_create("dev.hcg.AgentMonitor.tencent-realtime-speech", attributes);
    }
    return self;
}

- (void)start {
    [self startWithDiagnosticStartTime:0];
}

- (void)startWithDiagnosticStartTime:(NSTimeInterval)diagnosticStartTime {
    CFAbsoluteTime requestedAt = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime diagnosticStartedAt = diagnosticStartTime > 0 ? diagnosticStartTime : requestedAt;
    if (self.pendingPrepareBlock) {
        [self logTiming:@"start-requested-while-prepare-pending" baseTime:diagnosticStartedAt];
    }
    if (self.prepareRunning) {
        [self logTiming:@"start-requested-while-prepare-running" baseTime:diagnosticStartedAt];
    }
    self.startPending = YES;
    self.startRequestedAt = requestedAt;
    self.diagnosticStartedAt = diagnosticStartedAt;
    if (self.prepareRunning) {
        self.startRequestedDuringPrepare = YES;
        return;
    }
    if (self.pendingPrepareBlock && !self.prepareRunning) {
        dispatch_block_cancel(self.pendingPrepareBlock);
        self.pendingPrepareBlock = nil;
    }
    dispatch_async(self.workQueue, ^{
        [self logTiming:@"work-queue-entered"];
        self.pendingPrepareBlock = nil;
        if (self.recognizer || self.audioSource) {
            [self stopActiveRecognitionOnWorkQueueKeepingWarm:YES];
        }
        [self startOnWorkQueue];
        self.startPending = NO;
    });
}

- (void)cancelPrepare {
    if (self.pendingPrepareBlock && !self.prepareRunning) {
        dispatch_block_cancel(self.pendingPrepareBlock);
        self.pendingPrepareBlock = nil;
    }
}

- (void)clearStartPendingIfIdle {
    if (!self.recognizer && !self.prepareRunning) {
        self.startPending = NO;
        self.startRequestedDuringPrepare = NO;
    }
}

- (QCloudConfig *)makeConfig {
    QCloudConfig *config = nil;
    if (self.speechConfig.token.length > 0) {
        config = [[QCloudConfig alloc] initWithAppId:self.speechConfig.appID
                                           secretId:self.speechConfig.secretID
                                          secretKey:self.speechConfig.secretKey
                                              token:self.speechConfig.token
                                          projectId:self.speechConfig.projectID];
    } else {
        config = [[QCloudConfig alloc] initWithAppId:self.speechConfig.appID
                                           secretId:self.speechConfig.secretID
                                          secretKey:self.speechConfig.secretKey
                                          projectId:self.speechConfig.projectID];
    }
    config.engineType = self.speechConfig.engineType.length > 0 ? self.speechConfig.engineType : @"16k_zh";
    config.filterDirty = 0;
    config.filterModal = 1;
    config.filterPunc = 0;
    config.convertNumMode = 1;
    config.needvad = 1;
    config.vadSilenceTime = 800;
    config.endRecognizeWhenDetectSilence = NO;
    config.endRecognizeWhenDetectSilenceAutoStop = NO;
    config.silenceDetectDuration = 1.2;
    config.enableDetectVolume = YES;
    config.keepMicrophoneRecording = YES;
    return config;
}

- (void)prepare {
    if (self.pendingPrepareBlock) {
        dispatch_block_cancel(self.pendingPrepareBlock);
    }

    __weak typeof(self) weakSelf = self;
    __block dispatch_block_t prepareBlock = nil;
    prepareBlock = dispatch_block_create(0, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        if (dispatch_block_testcancel(prepareBlock) || self.recognizer) {
            [self clearPendingPrepareBlock:prepareBlock];
            [self clearStartPendingIfIdle];
            return;
        }

        self.prepareRunning = YES;
        self.prepareStartedAt = CFAbsoluteTimeGetCurrent();
        [self logPrepareTiming:@"entered"];
        NSError *audioSessionError = nil;
        [self logPrepareTiming:@"audio-session-begin"];
        if ([self prepareAudioSessionWithError:&audioSessionError]) {
            [self logPrepareTiming:@"audio-session-ready"];
            if (dispatch_block_testcancel(prepareBlock) || self.recognizer) {
                [self logPrepareTiming:@"canceled-after-audio-session"];
                self.prepareRunning = NO;
                [self clearPendingPrepareBlock:prepareBlock];
                [self clearStartPendingIfIdle];
                return;
            }
            if (!self.preparedAudioSource) {
                self.preparedAudioSource = [[AgentMonitorTencentAudioDataSource alloc] init];
            }
            NSError *audioGraphError = nil;
            if ([self.preparedAudioSource warmCaptureGraphWithError:&audioGraphError]) {
                [self logPrepareTiming:@"microphone-warm-ready"];
            }
            [self prepareSDKObjectsIfNeeded];
            [self logPrepareTiming:@"sdk-objects-ready"];
            if (self.startPending || self.startRequestedDuringPrepare) {
                [self logPrepareTiming:@"pending-start-after-sdk-objects"];
                self.prepareRunning = NO;
                self.startRequestedDuringPrepare = YES;
                if ([self startOnWorkQueueForPendingStartIfNeededWithPrepareBlock:prepareBlock]) {
                    return;
                }
            }
            if (dispatch_block_testcancel(prepareBlock) || self.recognizer) {
                [self logPrepareTiming:@"canceled-after-warm-graph"];
                self.prepareRunning = NO;
                [self clearPendingPrepareBlock:prepareBlock];
                [self clearStartPendingIfIdle];
                return;
            }
            if (self.startPending) {
                [self logPrepareTiming:@"kept-warm-for-pending-start"];
            }
        }
        [self logPrepareTiming:@"finished"];
        self.prepareRunning = NO;
        if ([self startOnWorkQueueForPendingStartIfNeededWithPrepareBlock:prepareBlock]) {
            return;
        }
        [self clearPendingPrepareBlock:prepareBlock];
        [self clearStartPendingIfIdle];
    });
    self.pendingPrepareBlock = prepareBlock;
    dispatch_async(self.workQueue, prepareBlock);
}

- (void)primeSDKObjects {
    dispatch_async(self.workQueue, ^{
        if (self.recognizer || self.prepareRunning || self.pendingPrepareBlock) {
            return;
        }

        [self logPrepareTiming:@"standby-sdk-prime-begin"];
        [self prepareSDKObjectsIfNeeded];
        [self logPrepareTiming:@"standby-sdk-prime-ready"];
    });
}

- (BOOL)startOnWorkQueueForPendingStartIfNeededWithPrepareBlock:(dispatch_block_t)prepareBlock {
    if (!self.startRequestedDuringPrepare) {
        return NO;
    }

    [self logTiming:@"prepare-upgraded-to-start"];
    self.startRequestedDuringPrepare = NO;
    [self clearPendingPrepareBlock:prepareBlock];
    if (self.recognizer || self.audioSource) {
        [self stopActiveRecognitionOnWorkQueueKeepingWarm:YES];
    }
    [self startOnWorkQueue];
    self.startPending = NO;
    return YES;
}

- (void)clearPendingPrepareBlock:(dispatch_block_t)prepareBlock {
    if (self.pendingPrepareBlock == prepareBlock) {
        self.pendingPrepareBlock = nil;
    }
}

- (void)startOnWorkQueue {
    if (self.stopWarmMicrophoneBlock) {
        dispatch_block_cancel(self.stopWarmMicrophoneBlock);
        self.stopWarmMicrophoneBlock = nil;
    }
    self.didNotifyRecordStarted = NO;
    self.lastVolumeCallbackTime = 0;
    self.lastVolumeCallbackValue = 0;

    QCloudRealTimeRecognizer *warmRecognizer = self.warmRecognizer;
    AgentMonitorTencentAudioDataSource *warmAudioSource = self.warmAudioSource;
    QCloudRealTimeRecognizer *preparedRecognizer = self.preparedRecognizer;
    AgentMonitorTencentAudioDataSource *preparedAudioSource = self.preparedAudioSource;
    QCloudConfig *config = (warmRecognizer || preparedRecognizer) ? nil : (self.preparedConfig ?: [self makeConfig]);
    self.warmRecognizer = nil;
    self.warmAudioSource = nil;
    self.preparedConfig = nil;
    self.preparedRecognizer = nil;
    self.preparedAudioSource = nil;

    NSError *audioSessionError = nil;
    [self logTiming:@"audio-session-begin"];
    if (![self prepareAudioSessionWithError:&audioSessionError]) {
        self.didPrepareAudioSession = NO;
        if (self.onError) {
            self.onError([NSString stringWithFormat:@"Microphone session setup failed (%ld): %@",
                          (long)audioSessionError.code,
                          audioSessionError.localizedDescription]);
        }
        return;
    }
    [self logTiming:@"audio-session-ready"];

    AgentMonitorTencentAudioDataSource *audioSource = warmAudioSource ?: preparedAudioSource ?: [[AgentMonitorTencentAudioDataSource alloc] init];
    __weak typeof(self) weakSelf = self;
    __weak AgentMonitorTencentAudioDataSource *weakAudioSource = audioSource;
    audioSource.onFirstPCMData = ^{
        [weakSelf logTiming:@"custom-audio-first-pcm"];
    };
    audioSource.onFirstReadData = ^{
        NSUInteger bytesProvided = weakAudioSource.lastReadBytesProvided;
        [weakSelf logTiming:[NSString stringWithFormat:@"custom-audio-first-read-%lubytes", (unsigned long)bytesProvided]];
    };
    BOOL hadPreparedCaptureGraph = audioSource.captureGraphPrepared;
    BOOL hadWarmMicrophone = audioSource.microphoneWarm;
    NSError *captureError = nil;
    [self logTiming:@"custom-audio-begin"];
    if (![audioSource beginCaptureForRecognitionWithError:&captureError]) {
        if (self.onError) {
            self.onError([NSString stringWithFormat:@"Microphone capture setup failed (%ld): %@",
                          (long)captureError.code,
                          captureError.localizedDescription]);
        }
        return;
    }
    if (hadPreparedCaptureGraph) {
        [self logTiming:@"custom-audio-reused-prepared-graph"];
    }
    if (hadWarmMicrophone) {
        [self logTiming:@"custom-audio-reused-warm-microphone"];
    }
    NSUInteger prerollBytesSeeded = audioSource.lastPrerollBytesSeeded;
    if (prerollBytesSeeded > 0) {
        NSString *kind = audioSource.lastPrerollWasPrimeSilence ? @"prime-silence" : @"preroll";
        [self logTiming:[NSString stringWithFormat:@"custom-audio-%@-%lubytes", kind, (unsigned long)prerollBytesSeeded]];
    }
    [self logTiming:@"custom-audio-ready"];

    if (!config && !warmRecognizer && !preparedRecognizer) {
        config = [self makeConfig];
    }
    QCloudRealTimeRecognizer *recognizer = warmRecognizer ?: preparedRecognizer ?: [[QCloudRealTimeRecognizer alloc] initWithConfig:config dataSource:audioSource];
    recognizer.delegate = self;
    self.recognizer = recognizer;
    self.audioSource = audioSource;
    [self logTiming:@"sdk-start-begin"];
    [recognizer start];
    [self logTiming:@"sdk-start-returned"];
    [self notifyRecordStartedIfNeeded];
}

- (void)stop {
    dispatch_async(self.workQueue, ^{
        [self stopActiveRecognitionOnWorkQueueKeepingWarm:YES];
    });
}

- (void)shutdown {
    dispatch_async(self.workQueue, ^{
        [self stopActiveRecognitionOnWorkQueueKeepingWarm:NO];
        [self clearWarmRecognizerOnWorkQueue];
        if (self.pendingPrepareBlock) {
            dispatch_block_cancel(self.pendingPrepareBlock);
            self.pendingPrepareBlock = nil;
        }
        self.preparedConfig = nil;
        self.preparedRecognizer = nil;
        [self.preparedAudioSource shutdownCapture];
        self.preparedAudioSource = nil;
        self.preparedAudioSessionCategory = nil;
        self.preparedAudioSessionMode = nil;
    });
}

- (void)stopActiveRecognitionOnWorkQueueKeepingWarm:(BOOL)keepWarm {
    if (keepWarm) {
        if (self.stopWarmMicrophoneBlock) {
            dispatch_block_cancel(self.stopWarmMicrophoneBlock);
            self.stopWarmMicrophoneBlock = nil;
        }
    } else {
        [self clearWarmRecognizerOnWorkQueue];
    }

    QCloudRealTimeRecognizer *recognizer = self.recognizer;
    AgentMonitorTencentAudioDataSource *audioSource = self.audioSource;
    BOOL hadActiveSession = recognizer != nil;
    self.recognizer = nil;
    self.audioSource = nil;
    self.didNotifyRecordStarted = NO;
    recognizer.delegate = nil;
    [recognizer stop];
    [audioSource stop];
    if (hadActiveSession) {
        if (keepWarm) {
            [self keepMicrophoneWarmBriefly:recognizer audioSource:audioSource];
        } else {
            [recognizer stopMicrophone];
            [audioSource shutdownCapture];
            self.didPrepareAudioSession = NO;
            self.preparedAudioSessionCategory = nil;
            self.preparedAudioSessionMode = nil;
        }
    }
}

- (void)clearWarmRecognizerOnWorkQueue {
    if (self.stopWarmMicrophoneBlock) {
        dispatch_block_cancel(self.stopWarmMicrophoneBlock);
        self.stopWarmMicrophoneBlock = nil;
    }
    QCloudRealTimeRecognizer *previousWarmRecognizer = self.warmRecognizer;
    AgentMonitorTencentAudioDataSource *previousWarmAudioSource = self.warmAudioSource;
    self.warmRecognizer = nil;
    self.warmAudioSource = nil;
    [previousWarmRecognizer stopMicrophone];
    [previousWarmAudioSource shutdownCapture];
    self.didPrepareAudioSession = NO;
    self.preparedAudioSessionCategory = nil;
    self.preparedAudioSessionMode = nil;
}

- (void)keepMicrophoneWarmBriefly:(QCloudRealTimeRecognizer *)recognizer audioSource:(AgentMonitorTencentAudioDataSource *)audioSource {
    if (!audioSource) {
        return;
    }

    recognizer.delegate = nil;
    self.warmRecognizer = nil;
    self.warmAudioSource = audioSource;
    dispatch_block_t block = dispatch_block_create(0, ^{
        QCloudRealTimeRecognizer *warmRecognizer = self.warmRecognizer;
        AgentMonitorTencentAudioDataSource *warmAudioSource = self.warmAudioSource;
        self.warmRecognizer = nil;
        self.warmAudioSource = nil;
        self.stopWarmMicrophoneBlock = nil;
        [warmRecognizer stopMicrophone];
        [warmAudioSource shutdownCapture];
        self.didPrepareAudioSession = NO;
        self.preparedAudioSessionCategory = nil;
        self.preparedAudioSessionMode = nil;
    });
    self.stopWarmMicrophoneBlock = block;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)), self.workQueue, block);
}

- (void)prepareSDKObjectsIfNeeded {
    if (!self.preparedConfig) {
        self.preparedConfig = [self makeConfig];
    }

    if (!self.preparedAudioSource) {
        self.preparedAudioSource = [[AgentMonitorTencentAudioDataSource alloc] init];
    }

    if (!self.preparedRecognizer) {
        self.preparedRecognizer = [[QCloudRealTimeRecognizer alloc] initWithConfig:self.preparedConfig dataSource:self.preparedAudioSource];
        self.preparedRecognizer.delegate = self;
    }
}

- (BOOL)prepareAudioSessionWithError:(NSError **)error {
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    BOOL categoryMatches = self.preparedAudioSessionCategory != nil &&
        [audioSession.category isEqualToString:self.preparedAudioSessionCategory] &&
        [audioSession.mode isEqualToString:(self.preparedAudioSessionMode ?: AVAudioSessionModeDefault)];

    if (!categoryMatches) {
        BOOL didSetCategory = [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                                                   mode:AVAudioSessionModeMeasurement
                                                options:AVAudioSessionCategoryOptionDuckOthers | AVAudioSessionCategoryOptionAllowBluetoothHFP | AVAudioSessionCategoryOptionDefaultToSpeaker
                                                  error:error];
        if (!didSetCategory) {
            return NO;
        }
        [audioSession setPreferredSampleRate:16000 error:nil];
        [audioSession setPreferredIOBufferDuration:0.02 error:nil];
        self.preparedAudioSessionCategory = AVAudioSessionCategoryPlayAndRecord;
        self.preparedAudioSessionMode = AVAudioSessionModeMeasurement;
    }

    if (self.didPrepareAudioSession) {
        return YES;
    }

    BOOL didActivate = [audioSession setActive:YES
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:error];
    if (didActivate) {
        self.didPrepareAudioSession = YES;
    }
    return didActivate;
}

- (void)notifyRecordStartedIfNeeded {
    if (self.didNotifyRecordStarted) {
        return;
    }

    self.didNotifyRecordStarted = YES;
    [self logTiming:@"record-started"];
    if (self.onRecordStarted) {
        self.onRecordStarted();
    }
}

- (void)logTiming:(NSString *)event {
    CFAbsoluteTime baseTime = self.diagnosticStartedAt > 0 ? self.diagnosticStartedAt : self.startRequestedAt;
    [self logTiming:event baseTime:baseTime];
}

- (void)logTiming:(NSString *)event baseTime:(CFAbsoluteTime)baseTime {
    if (baseTime <= 0) {
        return;
    }

    NSInteger elapsedMilliseconds = (NSInteger)((CFAbsoluteTimeGetCurrent() - baseTime) * 1000);
#if DEBUG
    NSLog(@"[VoiceInputTiming] tencent-%@ %ldms", event, (long)elapsedMilliseconds);
#endif
}

- (void)logPrepareTiming:(NSString *)event {
    CFAbsoluteTime baseTime = self.prepareStartedAt > 0 ? self.prepareStartedAt : CFAbsoluteTimeGetCurrent();
    NSInteger elapsedMilliseconds = (NSInteger)((CFAbsoluteTimeGetCurrent() - baseTime) * 1000);
#if DEBUG
    NSLog(@"[VoiceInputTiming] tencent-prepare-%@ %ldms", event, (long)elapsedMilliseconds);
#endif
}

- (void)realTimeRecognizerOnSliceRecognize:(QCloudRealTimeRecognizer *)recognizer result:(QCloudRealTimeResult *)result {
    NSString *text = [self preferredTextFromResult:result];
    if (text.length > 0 && self.onTranscript) {
        self.onTranscript(text, NO);
    }
}

- (void)realTimeRecognizerOnSegmentSuccessRecognize:(QCloudRealTimeRecognizer *)recognizer result:(QCloudRealTimeResult *)result {
    NSString *text = [self preferredTextFromResult:result];
    if (text.length > 0 && self.onTranscript) {
        self.onTranscript(text, YES);
    }
}

- (void)realTimeRecognizerDidFinish:(QCloudRealTimeRecognizer *)recognizer result:(NSString *)result {
    if (result.length > 0 && self.onFinished) {
        self.onFinished(result);
    }
}

- (void)realTimeRecognizerDidError:(QCloudRealTimeRecognizer *)recognizer result:(QCloudRealTimeResult *)result {
    NSString *message = result.clientErrMessage.length > 0 ? result.clientErrMessage : result.message;
    if (message.length == 0) {
        message = [NSString stringWithFormat:@"Tencent ASR failed (%ld)", (long)result.code];
    }
    NSString *lowercaseMessage = [message lowercaseString];
    if ([lowercaseMessage containsString:@"audiorecord init failed"] ||
        [lowercaseMessage containsString:@"audio record init failed"]) {
        message = @"Microphone recorder initialization failed. Tencent credentials are not the problem; try a real device or check microphone input.";
    }
    if (self.onError) {
        self.onError(message);
    }
}

- (void)realTimeRecognizerDidStartRecord:(QCloudRealTimeRecognizer *)recognizer error:(NSError *)error {
    if (error && self.onError) {
        self.onError([NSString stringWithFormat:@"Microphone recorder initialization failed (%ld): %@",
                      (long)error.code,
                      error.localizedDescription]);
    } else if (!error) {
        [self notifyRecordStartedIfNeeded];
    }
}

- (void)realTimeRecognizerOnFlowRecognizeStart:(QCloudRealTimeRecognizer *)recognizer voiceId:(NSString *)voiceId seq:(NSInteger)seq {
    if (self.onFlowStarted) {
        self.onFlowStarted(voiceId ?: @"");
    }
}

- (void)realTimeRecognizerDidUpdateVolumeDB:(QCloudRealTimeRecognizer *)recognizer volume:(float)volume {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (self.lastVolumeCallbackTime > 0 &&
        now - self.lastVolumeCallbackTime < (1.0 / 15.0) &&
        fabsf(volume - self.lastVolumeCallbackValue) < 4.0) {
        return;
    }

    self.lastVolumeCallbackTime = now;
    self.lastVolumeCallbackValue = volume;

    if (self.onVolume) {
        self.onVolume(volume);
    }
}

- (void)realTimeRecognizerOnSliceDetectTimeOut {
    [self stop];
}

- (NSString *)preferredTextFromResult:(QCloudRealTimeResult *)result {
    if (result.recognizedText.length > 0) {
        return result.recognizedText;
    }
    if (result.text.length > 0) {
        return result.text;
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (id item in result.resultList) {
        if ([item respondsToSelector:@selector(voiceTextStr)]) {
            NSString *text = [item valueForKey:@"voiceTextStr"];
            if (text.length > 0) {
                [parts addObject:text];
            }
        }
    }
    return [parts componentsJoinedByString:@""];
}

@end
