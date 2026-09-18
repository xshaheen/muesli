#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Result of reading AVAudioEngine's input node while inside the Objective-C
/// exception boundary. Swift cannot catch the NSExceptions AVFAudio may raise
/// while a hardware route is settling.
@interface ImlaAudioInputState : NSObject
@property(nonatomic, readonly, nullable) AVAudioFormat *outputFormat;
@property(nonatomic, readonly, nullable) NSError *error;
@end

FOUNDATION_EXPORT ImlaAudioInputState *ImlaAudioGraphReadInputState(
    AVAudioEngine *engine
);

FOUNDATION_EXPORT NSError * _Nullable ImlaAudioGraphSetInputDevice(
    AVAudioEngine *engine,
    AudioObjectID deviceID
);

/// The device the engine's input unit is currently bound to, or
/// kAudioObjectUnknown when it cannot be read.
FOUNDATION_EXPORT AudioObjectID ImlaAudioGraphCurrentInputDevice(
    AVAudioEngine *engine
);

FOUNDATION_EXPORT NSError * _Nullable ImlaAudioGraphInstallInputTap(
    AVAudioEngine *engine,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat * _Nullable format,
    AVAudioNodeTapBlock block
);
FOUNDATION_EXPORT NSError * _Nullable ImlaAudioGraphPrepareEngine(AVAudioEngine *engine);
FOUNDATION_EXPORT NSError * _Nullable ImlaAudioGraphStartEngine(AVAudioEngine *engine);
FOUNDATION_EXPORT NSError * _Nullable ImlaAudioGraphRemoveInputTap(AVAudioEngine *engine, AVAudioNodeBus bus);
FOUNDATION_EXPORT NSError * _Nullable ImlaAudioGraphStopEngine(AVAudioEngine *engine);

NS_ASSUME_NONNULL_END
