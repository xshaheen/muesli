#import "AudioGraphExceptionBridge.h"

static NSString *const ImlaAudioGraphErrorDomain = @"ImlaAudioGraph";

static NSError *ImlaAudioGraphExceptionError(NSException *exception, NSString *operation) {
    return [NSError errorWithDomain:ImlaAudioGraphErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey:
                                          [NSString stringWithFormat:@"%@ failed: %@", operation,
                                           exception.reason ?: exception.name]}];
}

@interface ImlaAudioInputState ()
@property(nonatomic, readwrite, nullable) AVAudioFormat *outputFormat;
@property(nonatomic, readwrite, nullable) NSError *error;
@end

@implementation ImlaAudioInputState
@end

ImlaAudioInputState *ImlaAudioGraphReadInputState(AVAudioEngine *engine) {
    ImlaAudioInputState *state = [[ImlaAudioInputState alloc] init];
    @try {
        AVAudioFormat *format = [engine.inputNode outputFormatForBus:0];
        if (format.streamDescription == NULL) {
            state.error = [NSError errorWithDomain:ImlaAudioGraphErrorDomain
                                              code:3
                                          userInfo:@{NSLocalizedDescriptionKey:
                                                         @"The microphone input format is unavailable"}];
        } else {
            state.outputFormat = format;
        }
    } @catch (NSException *exception) {
        state.error = ImlaAudioGraphExceptionError(exception, @"Read microphone input state");
    }
    return state;
}

NSError *ImlaAudioGraphSetInputDevice(AVAudioEngine *engine, AudioObjectID deviceID) {
    @try {
        AudioUnit audioUnit = engine.inputNode.audioUnit;
        if (audioUnit == NULL) {
            return [NSError errorWithDomain:ImlaAudioGraphErrorDomain
                                       code:4
                                   userInfo:@{NSLocalizedDescriptionKey:
                                                  @"No audio unit is available for preferred input routing"}];
        }
        OSStatus status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            sizeof(deviceID)
        );
        if (status != noErr) {
            return [NSError errorWithDomain:NSOSStatusErrorDomain
                                       code:status
                                   userInfo:@{NSLocalizedDescriptionKey:
                                                  @"Could not select the requested microphone"}];
        }
        return nil;
    } @catch (NSException *exception) {
        return ImlaAudioGraphExceptionError(exception, @"Select microphone input device");
    }
}

AudioObjectID ImlaAudioGraphCurrentInputDevice(AVAudioEngine *engine) {
    @try {
        AudioUnit audioUnit = engine.inputNode.audioUnit;
        if (audioUnit == NULL) {
            return kAudioObjectUnknown;
        }
        AudioObjectID deviceID = kAudioObjectUnknown;
        UInt32 size = sizeof(deviceID);
        OSStatus status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        );
        if (status != noErr) {
            return kAudioObjectUnknown;
        }
        return deviceID;
    } @catch (NSException *exception) {
        return kAudioObjectUnknown;
    }
}

NSError *ImlaAudioGraphInstallInputTap(
    AVAudioEngine *engine,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat *format,
    AVAudioNodeTapBlock block
) {
    @try {
        [engine.inputNode installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return nil;
    } @catch (NSException *exception) {
        return ImlaAudioGraphExceptionError(exception, @"Install microphone tap");
    }
}

NSError *ImlaAudioGraphPrepareEngine(AVAudioEngine *engine) {
    @try {
        [engine prepare];
        return nil;
    } @catch (NSException *exception) {
        return ImlaAudioGraphExceptionError(exception, @"Prepare audio engine");
    }
}

NSError *ImlaAudioGraphStartEngine(AVAudioEngine *engine) {
    @try {
        NSError *error = nil;
        if (![engine startAndReturnError:&error]) {
            return error ?: [NSError errorWithDomain:ImlaAudioGraphErrorDomain
                                                 code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"Start audio engine failed"}];
        }
        return nil;
    } @catch (NSException *exception) {
        return ImlaAudioGraphExceptionError(exception, @"Start audio engine");
    }
}

NSError *ImlaAudioGraphRemoveInputTap(AVAudioEngine *engine, AVAudioNodeBus bus) {
    @try {
        [engine.inputNode removeTapOnBus:bus];
        return nil;
    } @catch (NSException *exception) {
        return ImlaAudioGraphExceptionError(exception, @"Remove microphone tap");
    }
}

NSError *ImlaAudioGraphStopEngine(AVAudioEngine *engine) {
    @try {
        [engine stop];
        return nil;
    } @catch (NSException *exception) {
        return ImlaAudioGraphExceptionError(exception, @"Stop audio engine");
    }
}
