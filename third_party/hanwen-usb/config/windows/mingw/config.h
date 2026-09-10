#ifndef HANWEN_USB_LIBUSB_CONFIG_H
#define HANWEN_USB_LIBUSB_CONFIG_H

#define PLATFORM_WINDOWS 1
#define ENABLE_LOGGING 1
#define DEFAULT_VISIBILITY
#define PRINTF_FORMAT(a, b) __attribute__((format(__printf__, a, b)))
#define HAVE_CLOCK_GETTIME 1
#define HAVE_STRUCT_TIMESPEC 1

#endif
