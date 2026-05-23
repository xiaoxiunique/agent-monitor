#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TencentRealtimeSpeechConfig : NSObject

@property(nonatomic, copy) NSString *appID;
@property(nonatomic, copy) NSString *secretID;
@property(nonatomic, copy) NSString *secretKey;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, copy) NSString *engineType;
@property(nonatomic, assign) NSInteger projectID;

@end

@interface TencentRealtimeSpeechRecognizer : NSObject

@property(nonatomic, copy, nullable) void (^onTranscript)(NSString *text, BOOL isFinal);
@property(nonatomic, copy, nullable) void (^onError)(NSString *message);
@property(nonatomic, copy, nullable) void (^onFinished)(NSString *text);
@property(nonatomic, copy, nullable) void (^onVolume)(float volume);
@property(nonatomic, copy, nullable) void (^onRecordStarted)(void);
@property(nonatomic, copy, nullable) void (^onFlowStarted)(NSString *voiceID);

- (instancetype)initWithConfig:(TencentRealtimeSpeechConfig *)config;
- (void)prepare;
- (void)primeSDKObjects;
- (void)cancelPrepare;
- (void)start;
- (void)startWithDiagnosticStartTime:(NSTimeInterval)diagnosticStartTime;
- (void)stop;
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
