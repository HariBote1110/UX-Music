#ifndef HANWEN_USB_LIBUSB_CONFIG_H
#define HANWEN_USB_LIBUSB_CONFIG_H

#define _GNU_SOURCE 1
#define PLATFORM_POSIX 1
#define ENABLE_LOGGING 1
#define DEFAULT_VISIBILITY __attribute__((visibility("default")))
#define PRINTF_FORMAT(a, b) __attribute__((format(printf, a, b)))
#define HAVE_CLOCK_GETTIME 1
#define HAVE_EVENTFD 1
#define HAVE_NFDS_T 1
#define HAVE_PIPE2 1
#define HAVE_SYS_TIME_H 1
#define HAVE_STRUCT_TIMESPEC 1
#define HAVE_TIMERFD 1
#define HAVE_ASM_TYPES_H 1
#define HAVE_SYSLOG 1
#define HAVE_PTHREAD_SETNAME_NP 1
#define HAVE_PTHREAD_CONDATTR_SETCLOCK 1

#endif
