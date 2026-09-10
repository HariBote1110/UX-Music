#include "_cgo_export.h"
#include <stdint.h>

void* paStreamUserData(uintptr_t id) {
	return (void*)id;
}

int cb(const void *inputBuffer, void *outputBuffer, unsigned long frames, const PaStreamCallbackTimeInfo *timeInfo, PaStreamCallbackFlags statusFlags, void *userData) {
	streamCallback((void*)inputBuffer, outputBuffer, frames, (PaStreamCallbackTimeInfo*)timeInfo, statusFlags, userData);
	return paContinue;
}

//using a variable ensures that the callback signature is checked
PaStreamCallback* paStreamCallback = cb;
