package audio

import (
	"errors"
	"fmt"
	"io"
	"math"
	"math/cmplx"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/go-audio/audio"
	"github.com/go-audio/wav"
	"github.com/gordonklaus/portaudio"
	"github.com/hajimehoshi/go-mp3"
	"github.com/mewkiz/flac"
	"github.com/mewkiz/flac/frame"
	"github.com/mjibson/go-dsp/fft"
)

// Device represents an audio output device
type Device struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	IsDefault   bool   `json:"isDefault"`
	MaxChannels int    `json:"maxChannels"`
}

// Player handles audio playback using PortAudio
type Player struct {
	mu            sync.RWMutex
	stream        *portaudio.Stream
	devices       []*portaudio.DeviceInfo
	currentDevice *portaudio.DeviceInfo
	decoder       Decoder
	file          *os.File

	// Playback state
	playing      bool
	paused       bool
	position     int64 // samples played
	totalSamples int64
	sampleRate   int
	channels     int
	volume       float64

	// FFT Analysis
	fftMu      sync.RWMutex
	fftSamples []float64
	fftResult  []uint8 // 0-255 frequency data
	fftSize    int
	fftWindow  []float64 // Hanning window

	// Callback for events
	onFinished func()
	onProgress func(position, duration float64)
}

// Decoder interface for different audio formats
type Decoder interface {
	Read(p []byte) (int, error)
	SampleRate() int
	Channels() int
	Length() int64 // total samples
	Seek(sample int64) error
	Close() error
}

// NewPlayer creates a new audio player
func NewPlayer() (*Player, error) {
	if err := portaudio.Initialize(); err != nil {
		return nil, fmt.Errorf("failed to initialize PortAudio: %w", err)
	}

	p := &Player{
		volume: 1.0,
	}

	// Initialize FFT
	p.initFFT(2048)

	// Get available devices
	if err := p.refreshDevices(); err != nil {
		portaudio.Terminate()
		return nil, err
	}

	// Select default device
	defaultDevice, err := portaudio.DefaultOutputDevice()
	if err == nil {
		p.currentDevice = defaultDevice
	}

	return p, nil
}

// initFFT initializes FFT buffers
func (p *Player) initFFT(size int) {
	p.fftSize = size
	p.fftSamples = make([]float64, 0, size)
	p.fftResult = make([]uint8, size/2)
	p.fftWindow = make([]float64, size)

	// Hanning Window
	for i := 0; i < size; i++ {
		p.fftWindow[i] = 0.5 * (1 - math.Cos(2*math.Pi*float64(i)/float64(size-1)))
	}
}

// Close terminates the player
func (p *Player) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if p.stream != nil {
		p.stream.Stop()
		p.stream.Close()
	}
	if p.file != nil {
		p.file.Close()
	}

	return portaudio.Terminate()
}

// refreshDevices updates the list of available devices
func (p *Player) refreshDevices() error {
	devices, err := portaudio.Devices()
	if err != nil {
		return fmt.Errorf("failed to get devices: %w", err)
	}

	// Filter to output devices only
	var outputDevices []*portaudio.DeviceInfo
	for _, d := range devices {
		if d.MaxOutputChannels > 0 {
			outputDevices = append(outputDevices, d)
		}
	}

	p.devices = outputDevices
	return nil
}

// ListDevices returns available output devices
func (p *Player) ListDevices() ([]Device, error) {
	p.mu.RLock()
	defer p.mu.RUnlock()

	if err := p.refreshDevices(); err != nil {
		return nil, err
	}

	defaultDevice, _ := portaudio.DefaultOutputDevice()

	var result []Device
	for i, d := range p.devices {
		result = append(result, Device{
			ID:          fmt.Sprintf("%d", i),
			Name:        d.Name,
			IsDefault:   defaultDevice != nil && d.Name == defaultDevice.Name,
			MaxChannels: d.MaxOutputChannels,
		})
	}

	return result, nil
}

// SetDevice sets the output device by ID
func (p *Player) SetDevice(deviceID string) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	var idx int
	if _, err := fmt.Sscanf(deviceID, "%d", &idx); err != nil {
		return fmt.Errorf("invalid device ID: %s", deviceID)
	}

	if idx < 0 || idx >= len(p.devices) {
		return fmt.Errorf("device ID out of range: %d", idx)
	}

	p.currentDevice = p.devices[idx]
	fmt.Printf("[Audio] Device set to: %s\n", p.currentDevice.Name)
	return nil
}

// GetCurrentDevice returns the current device name
func (p *Player) GetCurrentDevice() string {
	p.mu.RLock()
	defer p.mu.RUnlock()

	if p.currentDevice != nil {
		return p.currentDevice.Name
	}
	return ""
}

// Play starts playback of an audio file
func (p *Player) Play(filePath string) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	// Stop current playback
	if p.stream != nil {
		p.stream.Stop()
		p.stream.Close()
		p.stream = nil
	}
	if p.file != nil {
		p.file.Close()
		p.file = nil
	}
	if p.decoder != nil {
		p.decoder.Close()
		p.decoder = nil
	}

	// Open file
	file, err := os.Open(filePath)
	if err != nil {
		return fmt.Errorf("failed to open file: %w", err)
	}
	p.file = file

	// Create decoder based on extension
	ext := strings.ToLower(filepath.Ext(filePath))
	switch ext {
	case ".mp3":
		dec, err := newMP3Decoder(file)
		if err != nil {
			file.Close()
			return err
		}
		p.decoder = dec
	case ".wav":
		dec, err := newWAVDecoder(file)
		if err != nil {
			file.Close()
			return err
		}
		p.decoder = dec
	case ".flac":
		file.Close() // flac package opens file itself
		dec, err := newFLACDecoder(filePath)
		if err != nil {
			return err
		}
		p.decoder = dec
	default:
		file.Close()
		return fmt.Errorf("unsupported format: %s", ext)
	}

	p.sampleRate = p.decoder.SampleRate()
	p.channels = p.decoder.Channels()
	p.totalSamples = p.decoder.Length()
	p.position = 0

	// Select device
	device := p.currentDevice
	if device == nil {
		device, _ = portaudio.DefaultOutputDevice()
	}
	if device == nil {
		return errors.New("no output device available")
	}

	// Create stream parameters
	params := portaudio.StreamParameters{
		Output: portaudio.StreamDeviceParameters{
			Device:   device,
			Channels: min(p.channels, device.MaxOutputChannels),
			Latency:  device.DefaultLowOutputLatency,
		},
		SampleRate:      float64(p.sampleRate),
		FramesPerBuffer: 4096,
	}

	// Buffer for audio data
	buffer := make([]float32, params.FramesPerBuffer*params.Output.Channels)

	// Create callback stream
	stream, err := portaudio.OpenStream(params, func(out []float32) {
		p.processAudio(out)
	})
	if err != nil {
		return fmt.Errorf("failed to open stream: %w", err)
	}

	p.stream = stream
	p.playing = true
	p.paused = false
	_ = buffer // Will be used in callback

	if err := stream.Start(); err != nil {
		return fmt.Errorf("failed to start stream: %w", err)
	}

	fmt.Printf("[Audio] Playing: %s on %s (SR: %d, CH: %d)\n", filePath, device.Name, p.sampleRate, p.channels)
	return nil
}

// calculateFFT computes FFT and updates frequency data
func (p *Player) calculateFFT(input []float64) {
	if len(input) != p.fftSize {
		return
	}

	// Apply window
	for i := 0; i < p.fftSize; i++ {
		input[i] *= p.fftWindow[i]
	}

	// Calculate FFT
	fftRes := fft.FFTReal(input)

	p.fftMu.Lock()
	defer p.fftMu.Unlock()

	// Convert to magnitude and scale to 0-255
	// We only need first half (Nyquist)
	for i := 0; i < len(p.fftResult) && i < len(fftRes); i++ {
		mag := cmplx.Abs(fftRes[i])

		// Log scale mapping simluating AnalyserNode
		// mag approaches 0 -> -inf dB
		// mag ~ 1 -> 0 dB? (depends on normalization)

		var db float64
		if mag > 0 {
			db = 20 * math.Log10(mag)
		} else {
			db = -100
		}

		// Map -100dB..-30dB to 0..255
		// This is generic, might need tuning
		minDecibels := -100.0
		maxDecibels := -30.0

		if db < minDecibels {
			db = minDecibels
		}
		if db > maxDecibels {
			db = maxDecibels
		}

		scaled := uint8((db - minDecibels) * 255 / (maxDecibels - minDecibels))
		p.fftResult[i] = scaled
	}
}

// GetFrequencyData returns the current frequency data for visualization
func (p *Player) GetFrequencyData() []uint8 {
	p.fftMu.RLock()
	defer p.fftMu.RUnlock()

	// Copy data to avoid race conditions
	result := make([]uint8, len(p.fftResult))
	copy(result, p.fftResult)
	return result
}

// processAudio is called by PortAudio to fill the output buffer
func (p *Player) processAudio(out []float32) {
	p.mu.RLock()
	decoding := p.decoder
	playing := p.playing
	paused := p.paused
	volume := p.volume
	channels := p.channels
	p.mu.RUnlock()

	if !playing || paused || decoding == nil {
		// Fill with silence
		for i := range out {
			out[i] = 0
		}

		// Clear FFT result when not playing
		p.fftMu.Lock()
		for i := range p.fftResult {
			p.fftResult[i] = 0
		}
		p.fftMu.Unlock()
		return
	}

	// Read samples from decoder
	// The decoder returns int16 samples, we need to convert to float32
	bytesNeeded := len(out) * 2 // 2 bytes per sample for int16
	buf := make([]byte, bytesNeeded)
	n, err := decoding.Read(buf)
	if err != nil && err != io.EOF {
		for i := range out {
			out[i] = 0
		}
		return
	}

	// Convert int16 to float32
	samples := n / 2

	// Collect mix down samples for FFT
	for i := 0; i < samples && i < len(out); i++ {
		sample := int16(buf[i*2]) | int16(buf[i*2+1])<<8
		floatSample := float32(sample) / 32768.0 * float32(volume)
		out[i] = floatSample

		// Downmix for FFT (take average of channels, or just first channel)
		if i%channels == 0 {
			// Simply using Left channel for now for performance
			// Ideally we should sum channels but we are in the hot loop
			val := float64(floatSample)
			// Collect for FFT
			p.fftMu.Lock()
			if len(p.fftSamples) < p.fftSize {
				p.fftSamples = append(p.fftSamples, val)
			}
			// If buffer full, triggering update elsewhere or double buffering would be better
			// For simplicity, we just keep the buffer full-ish
			p.fftMu.Unlock()
		}
	}

	// Process FFT if we have enough samples
	// Doing this in a separate goroutine to avoid blocking audio callback
	p.fftMu.Lock()
	if len(p.fftSamples) >= p.fftSize {
		// Copy buffer and clear
		input := make([]float64, p.fftSize)
		copy(input, p.fftSamples[:p.fftSize])
		// Keep some overlap? For now just clear
		p.fftSamples = p.fftSamples[:0]
		p.fftMu.Unlock()

		go p.calculateFFT(input)
	} else {
		p.fftMu.Unlock()
	}

	// Fill remaining with silence
	for i := samples; i < len(out); i++ {
		out[i] = 0
	}

	// Update position
	if channels > 0 {
		p.mu.Lock()
		p.position += int64(samples / channels)
		p.mu.Unlock()
	}

	// Check if finished
	if err == io.EOF || n == 0 {
		p.mu.Lock()
		p.playing = false
		callback := p.onFinished
		p.mu.Unlock()

		if callback != nil {
			go callback()
		}
	}
}

// Pause pauses playback
func (p *Player) Pause() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if p.stream == nil {
		return nil
	}

	p.paused = true
	return nil
}

// Resume resumes playback
func (p *Player) Resume() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if p.stream == nil {
		return nil
	}

	p.paused = false
	return nil
}

// Stop stops playback
func (p *Player) Stop() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if p.stream != nil {
		p.stream.Stop()
		p.stream.Close()
		p.stream = nil
	}

	p.playing = false
	p.paused = false
	p.position = 0

	return nil
}

// Seek seeks to a position in seconds
func (p *Player) Seek(seconds float64) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if p.decoder == nil {
		return nil
	}

	targetSample := int64(seconds * float64(p.sampleRate))
	if targetSample < 0 {
		targetSample = 0
	}
	if targetSample > p.totalSamples {
		targetSample = p.totalSamples
	}

	if err := p.decoder.Seek(targetSample); err != nil {
		return err
	}

	p.position = targetSample
	return nil
}

// SetVolume sets the volume (0.0 to 1.0)
func (p *Player) SetVolume(volume float64) {
	p.mu.Lock()
	defer p.mu.Unlock()

	if volume < 0 {
		volume = 0
	}
	if volume > 1 {
		volume = 1
	}
	p.volume = volume
}

// GetPosition returns the current position in seconds
func (p *Player) GetPosition() float64 {
	p.mu.RLock()
	defer p.mu.RUnlock()

	if p.sampleRate == 0 {
		return 0
	}
	return float64(p.position) / float64(p.sampleRate)
}

// GetDuration returns the total duration in seconds
func (p *Player) GetDuration() float64 {
	p.mu.RLock()
	defer p.mu.RUnlock()

	if p.sampleRate == 0 {
		return 0
	}
	return float64(p.totalSamples) / float64(p.sampleRate)
}

// IsPlaying returns true if currently playing
func (p *Player) IsPlaying() bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.playing && !p.paused
}

// IsPaused returns true if paused
func (p *Player) IsPaused() bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.paused
}

// SetOnFinished sets the callback for when playback finishes
func (p *Player) SetOnFinished(callback func()) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.onFinished = callback
}

// StartProgressReporting starts a goroutine that reports progress
func (p *Player) StartProgressReporting(interval time.Duration, callback func(position, duration float64)) {
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		for range ticker.C {
			p.mu.RLock()
			playing := p.playing
			p.mu.RUnlock()

			if !playing {
				return
			}

			callback(p.GetPosition(), p.GetDuration())
		}
	}()
}

// Helper function
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// ============ MP3 Decoder ============

type mp3Decoder struct {
	decoder    *mp3.Decoder
	sampleRate int
	channels   int
	length     int64
}

func newMP3Decoder(r io.ReadSeeker) (*mp3Decoder, error) {
	dec, err := mp3.NewDecoder(r)
	if err != nil {
		return nil, fmt.Errorf("failed to create MP3 decoder: %w", err)
	}

	return &mp3Decoder{
		decoder:    dec,
		sampleRate: dec.SampleRate(),
		channels:   2,                // MP3 is always stereo from go-mp3
		length:     dec.Length() / 4, // 4 bytes per sample (2 channels * 2 bytes)
	}, nil
}

func (d *mp3Decoder) Read(p []byte) (int, error) {
	return d.decoder.Read(p)
}

func (d *mp3Decoder) SampleRate() int {
	return d.sampleRate
}

func (d *mp3Decoder) Channels() int {
	return d.channels
}

func (d *mp3Decoder) Length() int64 {
	return d.length
}

func (d *mp3Decoder) Seek(sample int64) error {
	offset := sample * int64(d.channels) * 2 // 2 bytes per sample
	_, err := d.decoder.Seek(offset, io.SeekStart)
	return err
}

func (d *mp3Decoder) Close() error {
	return nil
}

// ============ WAV Decoder ============

type wavDecoder struct {
	decoder       *wav.Decoder
	sampleRate    int
	channels      int
	bitsPerSample int
	length        int64
	buffer        *audio.IntBuffer
}

func newWAVDecoder(r io.ReadSeeker) (*wavDecoder, error) {
	dec := wav.NewDecoder(r)
	if !dec.IsValidFile() {
		return nil, errors.New("invalid WAV file")
	}

	format := dec.Format()
	bytesPerSample := int(dec.BitDepth) / 8
	if bytesPerSample == 0 {
		bytesPerSample = 2 // Default to 16-bit
	}

	pcmLen := dec.PCMLen()

	return &wavDecoder{
		decoder:       dec,
		sampleRate:    int(format.SampleRate),
		channels:      int(format.NumChannels),
		bitsPerSample: int(dec.BitDepth),
		length:        int64(pcmLen) / int64(format.NumChannels) / int64(bytesPerSample),
		buffer:        &audio.IntBuffer{Data: make([]int, 4096)},
	}, nil
}

func (d *wavDecoder) Read(p []byte) (int, error) {
	n, err := d.decoder.PCMBuffer(d.buffer)
	if err != nil {
		return 0, err
	}
	if n == 0 {
		return 0, io.EOF
	}

	// Convert int samples to bytes
	bytesWritten := 0
	for i := 0; i < n && bytesWritten+1 < len(p); i++ {
		sample := int16(d.buffer.Data[i])
		p[bytesWritten] = byte(sample)
		p[bytesWritten+1] = byte(sample >> 8)
		bytesWritten += 2
	}

	return bytesWritten, nil
}

func (d *wavDecoder) SampleRate() int {
	return d.sampleRate
}

func (d *wavDecoder) Channels() int {
	return d.channels
}

func (d *wavDecoder) Length() int64 {
	return d.length
}

func (d *wavDecoder) Seek(sample int64) error {
	// WAV seeking is complex and not reliably supported
	// TODO: implement proper seeking in future version
	return nil
}

func (d *wavDecoder) Close() error {
	return nil
}

// ============ FLAC Decoder ============

type flacDecoder struct {
	stream     *flac.Stream
	sampleRate int
	channels   int
	length     int64
	frame      *frame.Frame
	framePos   int
}

func newFLACDecoder(path string) (*flacDecoder, error) {
	stream, err := flac.Open(path)
	if err != nil {
		return nil, fmt.Errorf("failed to open FLAC: %w", err)
	}

	return &flacDecoder{
		stream:     stream,
		sampleRate: int(stream.Info.SampleRate),
		channels:   int(stream.Info.NChannels),
		length:     int64(stream.Info.NSamples),
	}, nil
}

func (d *flacDecoder) Read(p []byte) (int, error) {
	bytesWritten := 0

	for bytesWritten+1 < len(p) {
		// Need new frame?
		if d.frame == nil || d.framePos >= int(d.frame.BlockSize) {
			frame, err := d.stream.ParseNext()
			if err != nil {
				if err == io.EOF {
					return bytesWritten, io.EOF
				}
				return bytesWritten, err
			}
			d.frame = frame
			d.framePos = 0
		}

		// Read samples from frame
		for d.framePos < int(d.frame.BlockSize) && bytesWritten+1 < len(p) {
			for ch := 0; ch < d.channels && bytesWritten+1 < len(p); ch++ {
				sample := d.frame.Subframes[ch].Samples[d.framePos]
				// Scale to 16-bit
				sample16 := int16(sample >> (d.stream.Info.BitsPerSample - 16))
				p[bytesWritten] = byte(sample16)
				p[bytesWritten+1] = byte(sample16 >> 8)
				bytesWritten += 2
			}
			d.framePos++
		}
	}

	return bytesWritten, nil
}

func (d *flacDecoder) SampleRate() int {
	return d.sampleRate
}

func (d *flacDecoder) Channels() int {
	return d.channels
}

func (d *flacDecoder) Length() int64 {
	return d.length
}

func (d *flacDecoder) Seek(sample int64) error {
	// FLAC seeking is not reliably supported with current implementation
	// TODO: implement proper seeking in future version
	return nil
}

func (d *flacDecoder) Close() error {
	return d.stream.Close()
}
