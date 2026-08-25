package server

import (
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
	"ux-music-sidecar/pkg/audio"
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

// MarkNextPlaybackRemoteInitiated marks that the next AudioPlay or
// AudioStartWebViewTap call starts a remote-initiated session (triggered by
// POST /v1/remote/command {"action":"play-song"}, not a local click). That
// call will silence the desktop's own speaker output for the session while
// leaving the LAN relay untouched (see pkg/audio.Player.SetLocalMuted).
// The renderer calls this from handleRemotePlaySongEvent, right before
// invoking playSong for the remotely-requested song.
func (a *App) MarkNextPlaybackRemoteInitiated() {
	a.remoteInitiatedNext.Store(true)
}

// consumeRemoteInitiatedNext reports whether the next playback start was
// marked remote-initiated, resetting the marker so it only ever applies to
// one call. A local play (AudioPlay/AudioStartWebViewTap invoked without a
// prior MarkNextPlaybackRemoteInitiated) reads false here and so unmutes.
func (a *App) consumeRemoteInitiatedNext() bool {
	return a.remoteInitiatedNext.Swap(false)
}

// AudioIsLocalMuted reports whether local speaker output is currently
// silenced (remote-initiated playback session). Surfaced additively in
// GET /v1/remote/state as "localMuted".
func (a *App) AudioIsLocalMuted() bool {
	if a.audioPlayer == nil {
		return false
	}
	return a.audioPlayer.IsLocalMuted()
}

// AudioPlay starts playback of an audio file
func (a *App) AudioPlay(filePath string, gainLinear float64) error {
	if a.audioPlayer == nil {
		return fmt.Errorf("audio player not initialized")
	}
	remoteInitiated := a.consumeRemoteInitiatedNext()
	if err := a.audioPlayer.Play(filePath, gainLinear); err != nil {
		fmt.Printf("[Audio] Play failed (%s): %v\n", filePath, err)
		return err
	}
	// Local files via play-song stay silent for a remote-initiated session;
	// any ordinary local play (remoteInitiated == false) unmutes, ending a
	// previous remote-initiated session's mute.
	a.audioPlayer.SetLocalMuted(remoteInitiated)
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

// AudioStartWebViewTap starts capturing the WKWebView helper processes'
// audio via a Core Audio process tap and plays it through the normal
// playback pipeline (EQ, gain, FFT, volume). The tapped helpers are muted at
// source, so only the processed output is audible.
//
// Targeting is limited to the WebKit helper processes this application owns
// (its own descendants / responsible children). Targeting by bundle ID would
// tap the *shared*, system-wide WebKit processes and thereby capture and mute
// other apps' audio too (e.g. Safari's YouTube playback) — the very bug this
// resolves. Helper PIDs are resolved at each start so that a freshly spawned
// helper (embed just mounted, or a video switch that respawned it) is picked
// up. When no helper is owned yet the call returns an error so the frontend
// can surface it.
func (a *App) AudioStartWebViewTap() error {
	if a.audioPlayer == nil {
		return fmt.Errorf("audio player not initialized")
	}
	pids, err := audio.WebKitHelperPIDs()
	if err != nil {
		fmt.Printf("[Audio] WebView tap: WebKit helper enumeration failed: %v\n", err)
		return err
	}
	if len(pids) == 0 {
		err := fmt.Errorf("no WebKit helper process owned by this app was found to tap")
		fmt.Printf("[Audio] WebView tap: %v\n", err)
		return err
	}
	fmt.Printf("[Audio] WebView tap: targeting own WebKit helper PIDs %v\n", pids)
	targets := audio.ProcessTapTargets{PIDs: pids}
	remoteInitiated := a.consumeRemoteInitiatedNext()
	if err := a.audioPlayer.PlayProcessTap(targets, 1.0); err != nil {
		fmt.Printf("[Audio] WebView tap start failed: %v\n", err)
		return err
	}
	// The tapped WebKit helper is muted at source either way (see the doc
	// comment above); this additionally gates the *local* re-render so a
	// remote-initiated embed session stays silent on the desktop while the
	// separate relay tap (server/app_remote_relay_notify.go) keeps working.
	a.audioPlayer.SetLocalMuted(remoteInitiated)
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

// resolveInitialVolume reads the saved master volume out of a loaded
// "settings" map (as returned by store.Instance.LoadMap) and clamps it to
// the valid 0.0-1.0 range. ok is false when the map is nil/empty or the
// "volume" entry is missing or not a number, in which case the caller
// should leave the audio player's default volume untouched.
//
// This exists so Startup can apply the saved master volume deterministically
// when the audio player is created (see the call site in app.go), rather
// than relying on the renderer to push it later. Before the native queue
// cutover (progress/native-play-queue.md), every playSong() call went
// through the renderer's playLocal(), which pushed the slider's volume via
// AudioSetVolume on every playback start — incidentally masking the fact
// that the Go player always boots at volume 1.0. Once Go's startQueueItem
// began starting playback directly, that renderer-side push stopped
// happening on the first play after launch, so playback started at the
// player's default (1.0) until the user touched the volume slider.
func resolveInitialVolume(settings map[string]interface{}) (float64, bool) {
	if settings == nil {
		return 0, false
	}
	raw, exists := settings["volume"]
	if !exists {
		return 0, false
	}
	volume, ok := raw.(float64)
	if !ok {
		return 0, false
	}
	if volume < 0 {
		volume = 0
	}
	if volume > 1 {
		volume = 1
	}
	return volume, true
}

// AudioDebugOutputRMS returns the RMS of the most recent output callback
// buffer (post volume/gain/EQ). Diagnostic probe for E2E volume checks.
func (a *App) AudioDebugOutputRMS() float64 {
	if a.audioPlayer == nil {
		return 0
	}
	return sanitizeFiniteFloat64(a.audioPlayer.OutputRMS())
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
	// Optional: not every caller knows the library song/artwork ID (e.g.
	// YouTube embeds), so these are additive and default to "" — see
	// remoteStateHandler's songId/artworkId fields.
	songID, _ := metadata["songId"].(string)
	artworkID, _ := metadata["artworkId"].(string)

	playing := false
	if a.audioPlayer != nil {
		playing = a.audioPlayer.IsPlaying()
	}
	a.updateOSNowPlayingMetadata(title, artist, album, artwork, playing)
	a.mediaStateMu.Lock()
	a.mediaSongID = strings.TrimSpace(songID)
	a.mediaArtworkID = strings.TrimSpace(artworkID)
	a.mediaStateMu.Unlock()
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
					a.emit("audio-devices-changed", nil)
				}
				currentDefault := liveDefaultName(devices)
				if currentDefault != lastDefaultName {
					lastDefaultName = currentDefault
					fmt.Printf("[Audio] Default device changed to: %s\n", currentDefault)
					a.emit("audio-default-device-changed", nil)
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
