package main

import (
	"fmt"
	"math"
	"ux-music-sidecar/pkg/audio"
)

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
func (a *App) AudioPlay(filePath string) error {
	if a.audioPlayer == nil {
		return fmt.Errorf("audio player not initialized")
	}
	if err := a.audioPlayer.Play(filePath); err != nil {
		return err
	}
	a.updateOSNowPlayingByPath(filePath, true)
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
	return nil
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
	return nil
}
