//go:build darwin

package cdrip

/*
#cgo darwin LDFLAGS: -framework IOKit -framework CoreFoundation
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOBSD.h>
#include <IOKit/storage/IOCDMedia.h>
#include <IOKit/storage/IOCDMediaBSDClient.h>
#include <IOKit/storage/IOCDTypes.h>

static int uxm_cd_copy_device_path(int wanted, char *path, size_t path_len) {
	io_iterator_t iterator = IO_OBJECT_NULL;
	CFMutableDictionaryRef matching = IOServiceMatching(kIOCDMediaClass);
	if (matching == NULL || IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
		return 0;
	}
	int index = 0;
	io_service_t service;
	while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
		CFStringRef bsd_name_key = CFStringCreateWithCString(kCFAllocatorDefault, kIOBSDNameKey, kCFStringEncodingUTF8);
		CFTypeRef value = IORegistryEntryCreateCFProperty(service, bsd_name_key, kCFAllocatorDefault, 0);
		if (bsd_name_key != NULL) CFRelease(bsd_name_key);
		if (value != NULL && CFGetTypeID(value) == CFStringGetTypeID() && index++ == wanted) {
			char bsd_name[256];
			int ok = CFStringGetCString((CFStringRef)value, bsd_name, sizeof(bsd_name), kCFStringEncodingUTF8);
			if (ok && path_len > 0) {
				int written = snprintf(path, path_len, "/dev/r%s", bsd_name);
				ok = written > 0 && (size_t)written < path_len;
			}
			CFRelease(value);
			IOObjectRelease(service);
			while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) IOObjectRelease(service);
			IOObjectRelease(iterator);
			return ok;
		}
		if (value != NULL) CFRelease(value);
		IOObjectRelease(service);
	}
	IOObjectRelease(iterator);
	return 0;
}

static int uxm_cd_read_toc(int fd, void *buffer, uint32_t length, uint32_t *actual) {
	dk_cd_read_toc_t request;
	memset(&request, 0, sizeof(request));
	request.buffer = buffer;
	request.bufferLength = length;
	request.format = kCDTOCFormatTOC;
	if (ioctl(fd, DKIOCCDREADTOC, &request) == -1) return errno;
	*actual = request.bufferLength;
	return 0;
}

static int uxm_cd_read(int fd, uint64_t offset, void *buffer, uint32_t length) {
	dk_cd_read_t request;
	memset(&request, 0, sizeof(request));
	request.offset = offset;
	request.sectorArea = kCDSectorAreaUser;
	request.sectorType = kCDSectorTypeCDDA;
	request.buffer = buffer;
	request.bufferLength = length;
	if (ioctl(fd, DKIOCCDREAD, &request) == -1) return errno;
	return request.bufferLength == length ? 0 : EIO;
}
*/
import "C"

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

// DiscoverNativeDiscDevices returns all IOCDMedia devices in IOKit's order.
func DiscoverNativeDiscDevices() ([]NativeDiscDevice, error) {
	devices := make([]NativeDiscDevice, 0, 1)
	for index := 0; ; index++ {
		var path [256]C.char
		if C.uxm_cd_copy_device_path(C.int(index), &path[0], C.size_t(len(path))) == 0 {
			break
		}
		pathString := C.GoString(&path[0])
		if len(pathString) < len("/dev/r") {
			continue
		}
		devices = append(devices, NativeDiscDevice{BSDName: pathString[len("/dev/r"):], Path: pathString})
	}
	if len(devices) == 0 {
		return nil, ErrNoAudioCD{Reason: "no IOCDMedia device was found"}
	}
	return devices, nil
}

func openNativeDisc() (DiscReader, error) {
	devices, err := DiscoverNativeDiscDevices()
	if err != nil {
		return nil, err
	}
	file, err := os.OpenFile(devices[0].Path, os.O_RDONLY, 0)
	if err != nil {
		return nil, fmt.Errorf("open audio CD %s: %w", devices[0].Path, err)
	}
	return &darwinDiscReader{file: file}, nil
}

// OpenNativeDisc opens the first discovered optical CD in read-only mode.
func OpenNativeDisc() (DiscReader, error) { return openNativeDisc() }

type darwinDiscReader struct{ file *os.File }

func (r *darwinDiscReader) ReadTOC() (TOC, error) {
	// 99 tracks plus A0/A1/A2 (and B0/C0 on multi-session discs) per session can
	// exceed 100 descriptors on an Enhanced CD, so leave generous headroom.
	buffer := make([]byte, 4+255*cdTOCDescriptorBytes)
	var actual C.uint32_t
	code := C.uxm_cd_read_toc(C.int(r.file.Fd()), unsafe.Pointer(&buffer[0]), C.uint32_t(len(buffer)), &actual)
	if code != 0 {
		return TOC{}, fmt.Errorf("read CD TOC: %w", syscallErrno(code))
	}
	if int(actual) > len(buffer) {
		return TOC{}, fmt.Errorf("CD TOC length %d exceeds buffer", actual)
	}
	toc, err := parseCDTOC(buffer[:actual])
	if err != nil {
		return TOC{}, err
	}
	for _, track := range toc.Tracks {
		if track.Audio {
			return toc, nil
		}
	}
	return TOC{}, ErrNoAudioCD{Reason: "TOC contains no audio tracks"}
}

func (r *darwinDiscReader) ReadSectors(lba, count int) ([]byte, error) {
	if lba < 0 || count <= 0 {
		return nil, fmt.Errorf("invalid CD-DA read range: lba=%d count=%d", lba, count)
	}
	data := make([]byte, count*CDSectorBytes)
	code := C.uxm_cd_read(C.int(r.file.Fd()), C.uint64_t(lba*CDSectorBytes), unsafe.Pointer(&data[0]), C.uint32_t(len(data)))
	if code != 0 {
		return nil, fmt.Errorf("read CD-DA sectors lba=%d count=%d: %w", lba, count, syscallErrno(code))
	}
	return data, nil
}

func (r *darwinDiscReader) Close() error { return r.file.Close() }

func syscallErrno(code C.int) error {
	return os.NewSyscallError("ioctl", syscall.Errno(code))
}
