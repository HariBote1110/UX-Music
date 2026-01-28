package main

import (
	"fmt"
	"ux-music-sidecar/pkg/audio"
)

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
	return a.audioPlayer.Play(filePath)
}

// AudioPause pauses playback
func (a *App) AudioPause() error {
	if a.audioPlayer == nil {
		return nil
	}
	return a.audioPlayer.Pause()
}

// AudioResume resumes playback
func (a *App) AudioResume() error {
	if a.audioPlayer == nil {
		return nil
	}
	return a.audioPlayer.Resume()
}

// AudioStop stops playback
func (a *App) AudioStop() error {
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

// AudioGetPosition returns the current position in seconds
func (a *App) AudioGetPosition() float64 {
	if a.audioPlayer == nil {
		return 0
	}
	return a.audioPlayer.GetPosition()
}

// AudioGetDuration returns the total duration in seconds
func (a *App) AudioGetDuration() float64 {
	if a.audioPlayer == nil {
		return 0
	}
	return a.audioPlayer.GetDuration()
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
