// Core Audio process tap helpers (manual reference counting — no ARC, so
// this file compiles safely alongside cgo-generated C sources). Adapted from
// the validated spike in cmd/spike-processtap.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>

#include "processtap_darwin.h"

// Implemented in Go (processtap_darwin.go, //export uxGoProcessTapSamples).
extern void uxGoProcessTapSamples(uintptr_t clientID, float *samples,
                                  int frames, int channels);

// Translates PIDs to Core Audio process objects, skipping any that fail
// (e.g. a process that exited between listing and tapping).
static NSMutableArray *uxTranslatePIDs(const int *pids, int pidCount) {
    NSMutableArray *objects = [NSMutableArray array];
    for (int i = 0; i < pidCount; i++) {
        AudioObjectPropertyAddress addr = {
            kAudioHardwarePropertyTranslatePIDToProcessObject,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain,
        };
        pid_t qualifier = (pid_t)pids[i];
        AudioObjectID object = 0;
        UInt32 size = sizeof(object);
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr,
                                       sizeof(qualifier), &qualifier,
                                       &size, &object) == noErr && object != 0) {
            [objects addObject:@(object)];
        }
    }
    return objects;
}

static NSArray *uxBundleIDArray(const char **bundleIDs, int bundleCount) {
    NSMutableArray *bundles = [NSMutableArray array];
    for (int i = 0; i < bundleCount; i++) {
        if (bundleIDs[i] == NULL) {
            continue;
        }
        NSString *bundle = [NSString stringWithUTF8String:bundleIDs[i]];
        if (bundle != nil && bundle.length > 0) {
            [bundles addObject:bundle];
        }
    }
    return bundles;
}

static OSStatus uxCreateTapFromDescription(CATapDescription *desc,
                                           AudioObjectID *outTap) {
    desc.name = @"UX-Music process tap";
    desc.privateTap = YES;
    desc.muteBehavior = CATapMutedWhenTapped;
    return AudioHardwareCreateProcessTap(desc, outTap);
}

int uxTapBundleAPISupported(void) {
    return [CATapDescription
               instancesRespondToSelector:@selector(setBundleIDs:)] ? 1 : 0;
}

OSStatus uxTapCreateWithBundleIDs(const char **bundleIDs, int bundleCount,
                                  const int *pids, int pidCount,
                                  AudioObjectID *outTap) {
    OSStatus err = noErr;
    @autoreleasepool {
        if (!uxTapBundleAPISupported()) {
            return (OSStatus)kUXTapErrBundleAPIUnavailable;
        }
        NSArray *bundles = uxBundleIDArray(bundleIDs, bundleCount);
        NSMutableArray *processObjects = uxTranslatePIDs(pids, pidCount);
        if (bundles.count == 0 && processObjects.count == 0) {
            return (OSStatus)kUXTapErrNoTargets;
        }
        CATapDescription *desc = [[[CATapDescription alloc]
            initStereoMixdownOfProcesses:processObjects] autorelease];
        // macOS 26: target helper processes by bundle ID. Combined with
        // processRestoreEnabled the tap re-attaches automatically when a
        // helper (e.g. com.apple.WebKit.GPU) relaunches. Applied through KVC
        // so this file still compiles against pre-26 SDKs.
        if (bundles.count > 0) {
            [desc setValue:bundles forKey:@"bundleIDs"];
        }
        if ([desc respondsToSelector:@selector(setProcessRestoreEnabled:)]) {
            [desc setValue:@YES forKey:@"processRestoreEnabled"];
        }
        err = uxCreateTapFromDescription(desc, outTap);
    }
    return err;
}

// Copies the bundle ID of a Core Audio process object. Autoreleased.
static NSString *uxProcessBundleID(AudioObjectID processObject) {
    AudioObjectPropertyAddress addr = {
        kAudioProcessPropertyBundleID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    CFStringRef bundle = NULL;
    UInt32 size = sizeof(bundle);
    if (AudioObjectGetPropertyData(processObject, &addr, 0, NULL,
                                   &size, &bundle) != noErr || bundle == NULL) {
        return nil;
    }
    return [(NSString *)bundle autorelease];
}

OSStatus uxTapCreateByProcessLookup(const char **bundleIDs, int bundleCount,
                                    const int *pids, int pidCount,
                                    AudioObjectID *outTap) {
    OSStatus err = noErr;
    @autoreleasepool {
        NSMutableArray *processObjects = uxTranslatePIDs(pids, pidCount);

        if (bundleCount > 0) {
            NSArray *bundles = uxBundleIDArray(bundleIDs, bundleCount);
            AudioObjectPropertyAddress addr = {
                kAudioHardwarePropertyProcessObjectList,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain,
            };
            UInt32 size = 0;
            if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr,
                                               0, NULL, &size) == noErr &&
                size > 0) {
                AudioObjectID *list = (AudioObjectID *)malloc(size);
                if (list != NULL &&
                    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr,
                                               0, NULL, &size, list) == noErr) {
                    UInt32 count = size / sizeof(AudioObjectID);
                    for (UInt32 i = 0; i < count; i++) {
                        NSString *bundle = uxProcessBundleID(list[i]);
                        if (bundle == nil) {
                            continue;
                        }
                        for (NSString *want in bundles) {
                            if ([bundle isEqualToString:want]) {
                                [processObjects addObject:@(list[i])];
                                break;
                            }
                        }
                    }
                }
                free(list);
            }
        }

        if (processObjects.count == 0) {
            return (OSStatus)kUXTapErrNoTargets;
        }
        CATapDescription *desc = [[[CATapDescription alloc]
            initStereoMixdownOfProcesses:processObjects] autorelease];
        err = uxCreateTapFromDescription(desc, outTap);
    }
    return err;
}

OSStatus uxTapGetFormat(AudioObjectID tap, double *sampleRate,
                        unsigned int *channels) {
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
    }
    return err;
}

// Copies the tap's UID string (kAudioTapPropertyUID). Autoreleased.
static NSString *uxTapUID(AudioObjectID tap, OSStatus *outErr) {
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

// Copies the default output device UID. Autoreleased (nil on error).
static NSString *uxDefaultOutputUID(void) {
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

OSStatus uxTapCreateAggregate(AudioObjectID tap, const char *uid,
                              AudioObjectID *outAggregate) {
    OSStatus err = noErr;
    @autoreleasepool {
        NSString *tapUID = uxTapUID(tap, &err);
        if (err != noErr || tapUID == nil) {
            return err != noErr ? err : kAudioHardwareUnspecifiedError;
        }
        NSString *aggregateUID = [NSString stringWithUTF8String:uid];
        NSMutableDictionary *desc = [NSMutableDictionary dictionary];
        desc[@(kAudioAggregateDeviceNameKey)] =
            [NSString stringWithFormat:@"UX-Music tap aggregate %@", aggregateUID];
        desc[@(kAudioAggregateDeviceUIDKey)] = aggregateUID;
        desc[@(kAudioAggregateDeviceIsPrivateKey)] = @YES;
        desc[@(kAudioAggregateDeviceIsStackedKey)] = @NO;
        desc[@(kAudioAggregateDeviceTapAutoStartKey)] = @YES;
        desc[@(kAudioAggregateDeviceTapListKey)] = @[ @{
            @(kAudioSubTapUIDKey) : tapUID,
            @(kAudioSubTapDriftCompensationKey) : @YES,
        } ];
        NSString *outputUID = uxDefaultOutputUID();
        if (outputUID != nil) {
            desc[@(kAudioAggregateDeviceMainSubDeviceKey)] = outputUID;
            desc[@(kAudioAggregateDeviceSubDeviceListKey)] =
                @[ @{@(kAudioSubDeviceUIDKey) : outputUID} ];
        }
        err = AudioHardwareCreateAggregateDevice((CFDictionaryRef)desc,
                                                 outAggregate);
    }
    return err;
}

OSStatus uxTapGetAggregateInputFormat(AudioObjectID aggregate,
                                      double *sampleRate,
                                      unsigned int *channels) {
    // The IOProc runs at the aggregate's clock, i.e. the nominal sample rate
    // (the underlying output device rate, e.g. 192kHz for a hi-res DAC).
    // Drift compensation resamples the tap into that clock, so the input
    // stream format's 48kHz claim does NOT describe what the IOProc gets.
    AudioObjectPropertyAddress rateAddr = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    Float64 nominalRate = 0;
    UInt32 size = sizeof(nominalRate);
    OSStatus err = AudioObjectGetPropertyData(aggregate, &rateAddr, 0, NULL,
                                              &size, &nominalRate);
    if (err != noErr) {
        return err;
    }
    *sampleRate = nominalRate;

    AudioObjectPropertyAddress formatAddr = {
        kAudioDevicePropertyStreamFormat,
        kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMain,
    };
    AudioStreamBasicDescription asbd = {0};
    size = sizeof(asbd);
    if (AudioObjectGetPropertyData(aggregate, &formatAddr, 0, NULL,
                                   &size, &asbd) == noErr &&
        asbd.mChannelsPerFrame > 0) {
        *channels = asbd.mChannelsPerFrame;
    }
    return noErr;
}

static OSStatus uxTapIOProc(AudioObjectID inDevice, const AudioTimeStamp *inNow,
                            const AudioBufferList *inInputData,
                            const AudioTimeStamp *inInputTime,
                            AudioBufferList *outOutputData,
                            const AudioTimeStamp *inOutputTime,
                            void *inClientData) {
    (void)inDevice; (void)inNow; (void)inInputTime; (void)inOutputTime;
    if (inInputData != NULL && inInputData->mNumberBuffers > 0) {
        const AudioBuffer *buf = &inInputData->mBuffers[0];
        if (buf->mData != NULL && buf->mNumberChannels > 0) {
            int channels = (int)buf->mNumberChannels;
            int frames = (int)(buf->mDataByteSize / (sizeof(float) * channels));
            if (frames > 0) {
                uxGoProcessTapSamples((uintptr_t)inClientData,
                                      (float *)buf->mData, frames, channels);
            }
        }
    }
    // Silence any output side of the aggregate; the player re-emits the
    // samples through its own PortAudio stream.
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

OSStatus uxTapStartIO(AudioObjectID aggregate, uintptr_t clientID,
                      AudioDeviceIOProcID *outProcID) {
    OSStatus err = AudioDeviceCreateIOProcID(aggregate, uxTapIOProc,
                                             (void *)clientID, outProcID);
    if (err != noErr) {
        return err;
    }
    err = AudioDeviceStart(aggregate, *outProcID);
    if (err != noErr) {
        AudioDeviceDestroyIOProcID(aggregate, *outProcID);
        *outProcID = NULL;
    }
    return err;
}

OSStatus uxTapStopIO(AudioObjectID aggregate, AudioDeviceIOProcID procID) {
    OSStatus err = noErr;
    if (procID != NULL) {
        err = AudioDeviceStop(aggregate, procID);
        AudioDeviceDestroyIOProcID(aggregate, procID);
    }
    return err;
}

OSStatus uxTapDestroyAggregate(AudioObjectID aggregate) {
    return AudioHardwareDestroyAggregateDevice(aggregate);
}

OSStatus uxTapDestroy(AudioObjectID tap) {
    return AudioHardwareDestroyProcessTap(tap);
}
