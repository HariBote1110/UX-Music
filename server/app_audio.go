package server

import (
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
	"ux-music-sidecar/pkg/audio"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

type AudioEqualizerSettings struct {
	Active bool      `json:"active"`
	Preamp float64   `json:"preamp"`
	Bands  []float64 `json:"bands"`
}

func sanitizeFiniteFloat64(value float64) float64 {
	if math.IsNaN(value) || math.IsInf(value, 0) {
		return 0
	}
	return value
}

// AudioListDevices returns available audio output devices
func (a *App) AudioListDevices() ([]audio.Device, error) {
	if a.audioPlayer == nil {
		return nil, fmt.Errorf("audio player not initialized")
	}
	return a.audioPlayer.ListDevices()
}

// AudioSetDevice sets the audio output device
func (a *App) AudioSetDevice(deviceID string) error {
	if a.audioPlayer == nil {
		return fmt.Errorf("audio player not initialized")
	}
	return a.audioPlayer.SetDevice(deviceID)
}

// AudioGetCurrentDevice returns the current device name
func (a *App) AudioGetCurrentDevice() string {
	if a.audioPlayer == nil {
		return ""
	}
	return a.audioPlayer.GetCurrentDevice()
}

// AudioPlay starts playback of an audio file
func (a *App) AudioPlay(filePath string, gainLinear float64) error {
	if a.audioPlayer == nil {
		return fmt.Errorf("audio player not initialized")
	}
	if err := a.audioPlayer.Play(filePath, gainLinear); err != nil {
		fmt.Printf("[Audio] Play failed (%s): %v\n", filePath, err)
		return err
	}
	a.updateOSNowPlayingByPath(filePath, true)
	a.pushDiscordPresence(true)
	return nil
}

// AudioPause pauses playback
func (a *App) AudioPause() error {
	if a.audioPlayer == nil {
		return nil
	}
	if err := a.audioPlayer.Pause(); err != nil {
		return err
	}
	a.updateOSPlaybackState(false)
	a.pushDiscordPresence(false)
	return nil
}

// AudioResume resumes playback
func (a *App) AudioResume() error {
	if a.audioPlayer == nil {
		return nil
	}
	if err := a.audioPlayer.Resume(); err != nil {
		return err
	}
	a.updateOSPlaybackState(true)
	a.pushDiscordPresence(true)
	return nil
}

// AudioStop stops playback
func (a *App) AudioStop() error {
	if a.audioPlayer == nil {
		return nil
	}
	if err := a.audioPlayer.Stop(); err != nil {
		return err
	}
	a.clearOSNowPlayingState()
	a.pushDiscordPresence(false)
	return nil
}

// webViewTapBundleIDs lists the WebKit helper processes that emit WKWebView
// audio. On modern macOS the GPU process (com.apple.WebKit.GPU) renders the
// audio; com.apple.WebKit.WebContent is included to cover configurations
// where audio is rendered inside the content process instead.
var webViewTapBundleIDs = []string{
	"com.apple.WebKit.GPU",
	"com.apple.WebKit.WebContent",
}

// AudioStartWebViewTap starts capturing the WKWebView helper processes'
// audio via a Core Audio process tap and plays it through the normal
// playback pipeline (EQ, gain, FFT, volume). The tapped helpers are muted at
// source, so only the processed output is audible.
func (a *App) AudioStartWebViewTap() error {
	if a.audioPlayer == nil {
		return fmt.Errorf("audio player not initialized")
	}
	targets := audio.ProcessTapTargets{BundleIDs: webViewTapBundleIDs}
	if err := a.audioPlayer.PlayProcessTap(targets, 1.0); err != nil {
		fmt.Printf("[Audio] WebView tap start failed: %v\n", err)
		return err
	}
	return nil
}

// AudioStopWebViewTap stops the WebView tap and returns the player to
// normal file playback use.
func (a *App) AudioStopWebViewTap() error {
	if a.audioPlayer == nil {
		return nil
	}
	return a.audioPlayer.Stop()
}

// AudioSeek seeks to a position in seconds
func (a *App) AudioSeek(seconds float64) error {
	if a.audioPlayer == nil {
		return nil
	}
	return a.audioPlayer.Seek(seconds)
}

// AudioSetVolume sets the volume (0.0 to 1.0)
func (a *App) AudioSetVolume(volume float64) {
	if a.audioPlayer == nil {
		return
	}
	a.audioPlayer.SetVolume(volume)
}

// AudioSetNormalisationGain sets loudness normalisation linear gain (1.0 = unity).
func (a *App) AudioSetNormalisationGain(gain float64) {
	if a.audioPlayer == nil {
		return
	}
	a.audioPlayer.SetNormalisationGain(sanitizeFiniteFloat64(gain))
}

// AudioSetEqualizer updates equaliser settings for backend playback.
func (a *App) AudioSetEqualizer(settings AudioEqualizerSettings) {
	if a.audioPlayer == nil {
		return
	}
	a.audioPlayer.SetEqualizer(settings.Active, sanitizeFiniteFloat64(settings.Preamp), settings.Bands)
}

// AudioGetPosition returns the current position in seconds
func (a *App) AudioGetPosition() float64 {
	if a.audioPlayer == nil {
		return 0
	}
	return sanitizeFiniteFloat64(a.audioPlayer.GetPosition())
}

// AudioGetDuration returns the total duration in seconds
func (a *App) AudioGetDuration() float64 {
	if a.audioPlayer == nil {
		return 0
	}
	return sanitizeFiniteFloat64(a.audioPlayer.GetDuration())
}

// AudioIsPlaying returns true if currently playing
func (a *App) AudioIsPlaying() bool {
	if a.audioPlayer == nil {
		return false
	}
	return a.audioPlayer.IsPlaying()
}

// AudioIsPaused returns true if paused
func (a *App) AudioIsPaused() bool {
	if a.audioPlayer == nil {
		return false
	}
	return a.audioPlayer.IsPaused()
}

// AudioGetFrequencyData returns the current frequency data for visualization
func (a *App) AudioGetFrequencyData() []uint8 {
	if a.audioPlayer == nil {
		return []uint8{}
	}
	data := a.audioPlayer.GetFrequencyData()
	return data
}

// AudioGetStatus returns playback status in one call for Wails polling.
func (a *App) AudioGetStatus() map[string]interface{} {
	if a.audioPlayer == nil {
		return map[string]interface{}{
			"position": 0.0,
			"duration": 0.0,
			"playing":  false,
			"paused":   false,
		}
	}

	return map[string]interface{}{
		"position": sanitizeFiniteFloat64(a.audioPlayer.GetPosition()),
		"duration": sanitizeFiniteFloat64(a.audioPlayer.GetDuration()),
		"playing":  a.audioPlayer.IsPlaying(),
		"paused":   a.audioPlayer.IsPaused(),
	}
}

// AudioSetNowPlayingMetadata updates OS-level now playing metadata.
func (a *App) AudioSetNowPlayingMetadata(metadata map[string]interface{}) error {
	if metadata == nil {
		return nil
	}

	title, _ := metadata["title"].(string)
	artist, _ := metadata["artist"].(string)
	album, _ := metadata["album"].(string)
	artwork, _ := metadata["artwork"].(string)

	playing := false
	if a.audioPlayer != nil {
		playing = a.audioPlayer.IsPlaying()
	}
	a.updateOSNowPlayingMetadata(title, artist, album, artwork, playing)
	a.pushDiscordPresence(playing)
	return nil
}

// deviceListFingerprint creates a comparable string from device names only (detects add/remove).
func deviceListFingerprint(devices []audio.Device) string {
	names := make([]string, len(devices))
	for i, d := range devices {
		names[i] = d.Name
	}
	sort.Strings(names)
	return strings.Join(names, "\x00")
}

// defaultDeviceName returns the name of the device currently flagged as default, or empty string.
func defaultDeviceName(devices []audio.Device) string {
	for _, d := range devices {
		if d.IsDefault {
			return d.Name
		}
	}
	return ""
}

// StartDeviceWatcher begins polling for audio device changes.
// Emits "audio-devices-changed" when the device list changes (add/remove).
// Emits "audio-default-device-changed" when the system default output changes.
func (a *App) StartDeviceWatcher() {
	if a.audioPlayer == nil || a.ctx == nil {
		return
	}
	a.deviceWatcherStop = make(chan struct{})

	go func() {
		// liveDefaultName returns the live OS default output name. On
		// darwin we go through CoreAudio because PortAudio caches its
		// DefaultOutputDevice() lookup at Pa_Initialize() time and never
		// observes runtime changes. On other platforms we fall back to
		// the PortAudio-reported default from ListDevices().
		liveDefaultName := func(devices []audio.Device) string {
			if name := audio.SystemDefaultOutputName(); name != "" {
				return name
			}
			return defaultDeviceName(devices)
		}

		var lastListFP string
		var lastDefaultName string
		if devices, err := a.audioPlayer.ListDevices(); err == nil {
			lastListFP = deviceListFingerprint(devices)
			lastDefaultName = liveDefaultName(devices)
		}

		ticker := time.NewTicker(3 * time.Second)
		defer ticker.Stop()

		for {
			select {
			case <-a.deviceWatcherStop:
				return
			case <-ticker.C:
				devices, err := a.audioPlayer.ListDevices()
				if err != nil {
					continue
				}
				listFP := deviceListFingerprint(devices)
				if listFP != lastListFP {
					lastListFP = listFP
					fmt.Println("[Audio] Device list changed, notifying frontend")
					wailsRuntime.EventsEmit(a.ctx, "audio-devices-changed")
				}
				currentDefault := liveDefaultName(devices)
				if currentDefault != lastDefaultName {
					lastDefaultName = currentDefault
					fmt.Printf("[Audio] Default device changed to: %s\n", currentDefault)
					wailsRuntime.EventsEmit(a.ctx, "audio-default-device-changed")
				}
			}
		}
	}()
}

// StopDeviceWatcher stops the device polling goroutine.
func (a *App) StopDeviceWatcher() {
	if a.deviceWatcherStop != nil {
		close(a.deviceWatcherStop)
		a.deviceWatcherStop = nil
	}
}
