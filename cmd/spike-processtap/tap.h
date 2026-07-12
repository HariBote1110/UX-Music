// Spike: Core Audio process tap helpers (declarations only — definitions in tap.m)
#ifndef SPIKE_PROCESSTAP_TAP_H
#define SPIKE_PROCESSTAP_TAP_H

#include <CoreAudio/CoreAudio.h>

// Translates a PID to its Core Audio process object.
OSStatus spikeTranslatePID(int pid, AudioObjectID *outObject);

// Creates a stereo-mixdown process tap for the given process object.
// mute != 0 sets CATapMutedWhenTapped.
OSStatus spikeCreateTap(AudioObjectID processObject, int mute, AudioObjectID *outTap);

// Reads the tap's stream format.
OSStatus spikeGetTapFormat(AudioObjectID tap, double *sampleRate,
                           unsigned int *channels, unsigned int *formatFlags,
                           unsigned int *bitsPerChannel, unsigned int *formatID);

// Creates a private aggregate device wired to the tap (plus the default
// output device as sub-device, mirroring Apple's recommended layout).
// uidSuffix keeps repeated aggregates unique within one run.
OSStatus spikeCreateAggregate(AudioObjectID tap, const char *uidSuffix,
                              AudioObjectID *outAggregate);

// Registers the IOProc on the aggregate device and starts IO.
OSStatus spikeStartIO(AudioObjectID aggregate);

// Stops IO and removes the IOProc.
OSStatus spikeStopIO(AudioObjectID aggregate);

OSStatus spikeDestroyAggregate(AudioObjectID aggregate);
OSStatus spikeDestroyTap(AudioObjectID tap);

#endif
