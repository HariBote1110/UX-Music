// Spike: Core Audio process tap helpers (manual reference counting — no ARC,
// so this file compiles safely alongside cgo-generated C sources).
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>

#include "tap.h"

// Implemented in Go (main.go, //export goTapSamples).
extern void goTapSamples(float *samples, int frames, int channels);

static AudioDeviceIOProcID gIOProcID = NULL;

OSStatus spikeTranslatePID(int pid, AudioObjectID *outObject) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyTranslatePIDToProcessObject,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    pid_t qualifier = (pid_t)pid;
    UInt32 size = sizeof(AudioObjectID);
    return AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr,
                                      sizeof(qualifier), &qualifier,
                                      &size, outObject);
}

OSStatus spikeCreateTap(AudioObjectID processObject, int mute, AudioObjectID *outTap) {
    OSStatus err = noErr;
    @autoreleasepool {
        CATapDescription *desc = [[[CATapDescription alloc]
            initStereoMixdownOfProcesses:@[ @(processObject) ]] autorelease];
        desc.name = @"UX-Music spike tap";
        desc.privateTap = YES;
        desc.muteBehavior = mute ? CATapMutedWhenTapped : CATapUnmuted;
        err = AudioHardwareCreateProcessTap(desc, outTap);
    }
    return err;
}

OSStatus spikeGetTapFormat(AudioObjectID tap, double *sampleRate,
                           unsigned int *channels, unsigned int *formatFlags,
                           unsigned int *bitsPerChannel, unsigned int *formatID) {
    AudioObjectPropertyAddress addr = {
        kAudioTapPropertyFormat,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioStreamBasicDescription asbd = {0};
    UInt32 size = sizeof(asbd);
    OSStatus err = AudioObjectGetPropertyData(tap, &addr, 0, NULL, &size, &asbd);
    if (err == noErr) {
        *sampleRate = asbd.mSampleRate;
        *channels = asbd.mChannelsPerFrame;
        *formatFlags = asbd.mFormatFlags;
        *bitsPerChannel = asbd.mBitsPerChannel;
        *formatID = asbd.mFormatID;
    }
    return err;
}

// Copies the tap's UID string (kAudioTapPropertyUID). Autoreleased NSString.
static NSString *spikeTapUID(AudioObjectID tap, OSStatus *outErr) {
    AudioObjectPropertyAddress addr = {
        kAudioTapPropertyUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    CFStringRef uid = NULL;
    UInt32 size = sizeof(uid);
    *outErr = AudioObjectGetPropertyData(tap, &addr, 0, NULL, &size, &uid);
    if (*outErr != noErr || uid == NULL) {
        return nil;
    }
    return [(NSString *)uid autorelease];
}

// Copies the default output device UID. Autoreleased NSString (nil on error).
static NSString *spikeDefaultOutputUID(void) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioDeviceID device = 0;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL,
                                   &size, &device) != noErr || device == 0) {
        return nil;
    }
    AudioObjectPropertyAddress uidAddr = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    CFStringRef uid = NULL;
    size = sizeof(uid);
    if (AudioObjectGetPropertyData(device, &uidAddr, 0, NULL, &size, &uid) != noErr ||
        uid == NULL) {
        return nil;
    }
    return [(NSString *)uid autorelease];
}

OSStatus spikeCreateAggregate(AudioObjectID tap, const char *uidSuffix,
                              AudioObjectID *outAggregate) {
    OSStatus err = noErr;
    @autoreleasepool {
        NSString *tapUID = spikeTapUID(tap, &err);
        if (err != noErr || tapUID == nil) {
            return err != noErr ? err : kAudioHardwareUnspecifiedError;
        }
        NSString *suffix = [NSString stringWithUTF8String:uidSuffix];
        NSMutableDictionary *desc = [NSMutableDictionary dictionary];
        desc[@(kAudioAggregateDeviceNameKey)] =
            [NSString stringWithFormat:@"uxmusic-spike-agg-%@", suffix];
        desc[@(kAudioAggregateDeviceUIDKey)] =
            [NSString stringWithFormat:@"uxmusic-spike-agg-uid-%@", suffix];
        desc[@(kAudioAggregateDeviceIsPrivateKey)] = @YES;
        desc[@(kAudioAggregateDeviceIsStackedKey)] = @NO;
        desc[@(kAudioAggregateDeviceTapAutoStartKey)] = @YES;
        desc[@(kAudioAggregateDeviceTapListKey)] = @[ @{
            @(kAudioSubTapUIDKey) : tapUID,
            @(kAudioSubTapDriftCompensationKey) : @YES,
        } ];
        NSString *outputUID = spikeDefaultOutputUID();
        if (outputUID != nil) {
            desc[@(kAudioAggregateDeviceMainSubDeviceKey)] = outputUID;
            desc[@(kAudioAggregateDeviceSubDeviceListKey)] =
                @[ @{@(kAudioSubDeviceUIDKey) : outputUID} ];
        }
        err = AudioHardwareCreateAggregateDevice((CFDictionaryRef)desc, outAggregate);
    }
    return err;
}

static OSStatus spikeIOProc(AudioObjectID inDevice, const AudioTimeStamp *inNow,
                            const AudioBufferList *inInputData,
                            const AudioTimeStamp *inInputTime,
                            AudioBufferList *outOutputData,
                            const AudioTimeStamp *inOutputTime,
                            void *inClientData) {
    (void)inDevice; (void)inNow; (void)inInputTime;
    (void)inOutputTime; (void)inClientData;
    if (inInputData != NULL && inInputData->mNumberBuffers > 0) {
        const AudioBuffer *buf = &inInputData->mBuffers[0];
        if (buf->mData != NULL && buf->mNumberChannels > 0) {
            int channels = (int)buf->mNumberChannels;
            int frames = (int)(buf->mDataByteSize / (sizeof(float) * channels));
            if (frames > 0) {
                goTapSamples((float *)buf->mData, frames, channels);
            }
        }
    }
    // Silence any output side of the aggregate (we re-emit via PortAudio).
    if (outOutputData != NULL) {
        for (UInt32 i = 0; i < outOutputData->mNumberBuffers; i++) {
            if (outOutputData->mBuffers[i].mData != NULL) {
                memset(outOutputData->mBuffers[i].mData, 0,
                       outOutputData->mBuffers[i].mDataByteSize);
            }
        }
    }
    return noErr;
}

OSStatus spikeStartIO(AudioObjectID aggregate) {
    OSStatus err = AudioDeviceCreateIOProcID(aggregate, spikeIOProc, NULL, &gIOProcID);
    if (err != noErr) {
        return err;
    }
    err = AudioDeviceStart(aggregate, gIOProcID);
    if (err != noErr) {
        AudioDeviceDestroyIOProcID(aggregate, gIOProcID);
        gIOProcID = NULL;
    }
    return err;
}

OSStatus spikeStopIO(AudioObjectID aggregate) {
    OSStatus err = noErr;
    if (gIOProcID != NULL) {
        err = AudioDeviceStop(aggregate, gIOProcID);
        AudioDeviceDestroyIOProcID(aggregate, gIOProcID);
        gIOProcID = NULL;
    }
    return err;
}

OSStatus spikeDestroyAggregate(AudioObjectID aggregate) {
    return AudioHardwareDestroyAggregateDevice(aggregate);
}

OSStatus spikeDestroyTap(AudioObjectID tap) {
    return AudioHardwareDestroyProcessTap(tap);
}
