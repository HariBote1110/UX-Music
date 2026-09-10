//go:build darwin || linux
// +build darwin linux

#include "portaudio/src/common/pa_allocation.c"
#include "portaudio/src/common/pa_converters.c"
#include "portaudio/src/common/pa_cpuload.c"
#include "portaudio/src/common/pa_debugprint.c"
#include "portaudio/src/common/pa_dither.c"
#include "portaudio/src/common/pa_front.c"
#include "portaudio/src/common/pa_process.c"
#include "portaudio/src/common/pa_ringbuffer.c"
#include "portaudio/src/common/pa_stream.c"
#include "portaudio/src/common/pa_trace.c"
#include "portaudio/src/os/unix/pa_unix_hostapis.c"
#include "portaudio/src/os/unix/pa_unix_util.c"
#if defined(__APPLE__)
#include "portaudio/src/hostapi/coreaudio/pa_mac_core.c"
#include "portaudio/src/hostapi/coreaudio/pa_mac_core_blocking.c"
#include "portaudio/src/hostapi/coreaudio/pa_mac_core_utilities.c"
#else
#include "portaudio/src/hostapi/alsa/pa_linux_alsa.c"
#endif
