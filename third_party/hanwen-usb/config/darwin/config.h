#ifndef HANWEN_USB_LIBUSB_CONFIG_H
#define HANWEN_USB_LIBUSB_CONFIG_H

#define PLATFORM_POSIX 1
#define ENABLE_LOGGING 1
#define DEFAULT_VISIBILITY __attribute__((visibility("default")))
#define PRINTF_FORMAT(a, b) __attribute__((format(printf, a, b)))
#define HAVE_CLOCK_GETTIME 1
#define HAVE_PTHREAD_THREADID_NP 1
#define HAVE_SYS_TIME_H 1
#define HAVE_STRUCT_TIMESPEC 1
#define HAVE_IOKIT_USB_IOUSBHOSTFAMILYDEFINITIONS_H 1

#endif
