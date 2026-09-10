package portaudio

import "testing"

func TestPortAudioInitDevicesTerminateSmoke(t *testing.T) {
	if err := Initialize(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := Terminate(); err != nil {
			t.Fatal(err)
		}
	}()
	devices, err := Devices()
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("PortAudio enumerated %d device(s)", len(devices))
	device, err := DefaultOutputDevice()
	if err != nil && err != NoDefaultOutputDevice {
		t.Fatal(err)
	}
	if device != nil {
		t.Logf("default output device: %s", device.Name)
	}
}
