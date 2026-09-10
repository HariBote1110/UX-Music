package mtp

import (
	"testing"

	"github.com/hanwen/usb"
)

func TestFindDevicesWithRealUSBContext(t *testing.T) {
	context := usb.NewContext()
	if context == nil {
		t.Fatal("libusb_init returned a nil context")
	}
	defer context.Exit()

	devices, err := FindDevices(context)
	if err != nil {
		t.Fatalf("FindDevices failed: %v", err)
	}
	for _, device := range devices {
		_ = device.Close()
		device.Done()
	}
}
