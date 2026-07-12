// Core Audio process tap helpers (declarations only — definitions in
// processtap_darwin.m). Follows the layout validated by cmd/spike-processtap.
#ifndef UX_MUSIC_PROCESSTAP_DARWIN_H
#define UX_MUSIC_PROCESSTAP_DARWIN_H

#include <stdint.h>
#include <CoreAudio/CoreAudio.h>

// Custom status codes returned alongside genuine OSStatus values. Real Core
// Audio errors are four-char codes or negatives, so small positive integers
// are unambiguous.
enum {
	kUXTapErrNoTargets            = 1,
	kUXTapErrBundleAPIUnavailable = 2,
};

// Reports whether CATapDescription supports bundle-ID targeting
// (macOS 26+: bundleIDs / processRestoreEnabled).
int uxTapBundleAPISupported(void);

// Creates a stereo-mixdown tap targeting the given bundle IDs (plus any PIDs)
// via the macOS 26 CATapDescription.bundleIDs API. Returns
// kUXTapErrBundleAPIUnavailable when the running OS lacks that API.
OSStatus uxTapCreateWithBundleIDs(const char **bundleIDs, int bundleCount,
                                  const int *pids, int pidCount,
                                  AudioObjectID *outTap);

// Fallback: resolves bundle IDs to process objects by enumerating
// kAudioHardwarePropertyProcessObjects and matching
// kAudioProcessPropertyBundleID, then creates a stereo-mixdown tap of the
// matched processes plus any PIDs.
OSStatus uxTapCreateByProcessLookup(const char **bundleIDs, int bundleCount,
                                    const int *pids, int pidCount,
                                    AudioObjectID *outTap);

// Reads the tap's stream format (sample rate and channel count).
OSStatus uxTapGetFormat(AudioObjectID tap, double *sampleRate,
                        unsigned int *channels);

// Creates a private aggregate device wired to the tap (with drift
// compensation) plus the current default output device as sub-device.
OSStatus uxTapCreateAggregate(AudioObjectID tap, const char *uid,
                              AudioObjectID *outAggregate);

// Registers the IOProc on the aggregate device and starts IO. Samples are
// delivered to the Go callback uxGoProcessTapSamples with clientID.
OSStatus uxTapStartIO(AudioObjectID aggregate, uintptr_t clientID,
                      AudioDeviceIOProcID *outProcID);

// Stops IO and removes the IOProc.
OSStatus uxTapStopIO(AudioObjectID aggregate, AudioDeviceIOProcID procID);

OSStatus uxTapDestroyAggregate(AudioObjectID aggregate);
OSStatus uxTapDestroy(AudioObjectID tap);

#endif
