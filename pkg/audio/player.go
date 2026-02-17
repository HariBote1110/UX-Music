package audio

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"math/cmplx"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"
	"ux-music-sidecar/internal/config"

	"github.com/go-audio/audio"
	"github.com/go-audio/wav"
	"github.com/gordonklaus/portaudio"
	"github.com/hajimehoshi/go-mp3"
	"github.com/mewkiz/flac"
	"github.com/mewkiz/flac/frame"
	"github.com/mewkiz/flac/meta"
	"github.com/mjibson/go-dsp/fft"
)

// Device represents an audio output device
type Device struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	IsDefault   bool   `json:"isDefault"`
	MaxChannels int    `json:"maxChannels"`
}

const (
	equalizerBandCount  = 10
	equalizerDefaultQ   = 1.41
	equalizerShelfSlope = 1.0
)

var equalizerFrequencies = [equalizerBandCount]float64{31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000}

type biquadCoefficients struct {
	b0 float64
	b1 float64
	b2 float64
	a1 float64
	a2 float64
}

type biquadState struct {
	x1 float64
	x2 float64
	y1 float64
	y2 float64
}

type equalizerConfig struct {
	active       bool
	preamp       float32
	coefficients [equalizerBandCount]biquadCoefficients
}

type equalizerSettings struct {
	active   bool
	preampDB float64
	bandDB   [equalizerBandCount]float64
}

// Player handles audio playback using PortAudio
type Player struct {
	mu            sync.RWMutex
	stream        *portaudio.Stream
	devices       []*portaudio.DeviceInfo
	currentDevice *portaudio.DeviceInfo
	decoder       Decoder
	file          *os.File

	// Playback state (atomic for lock-free access in callback)
	playing      atomic.Bool
	paused       atomic.Bool
	position     atomic.Int64 // samples played
	totalSamples int64
	sampleRate   int
	channels     int
	volume       atomic.Uint64 // stored as float64 bits

	// Ring buffer for pre-decoded audio data
	ringBuf       []float32     // Pre-decoded float32 samples
	ringBufSize   int           // Total size of ring buffer
	ringReadPos   atomic.Int64  // Read position (callback reads from here)
	ringWritePos  atomic.Int64  // Write position (decoder writes here)
	ringAvailable atomic.Int64  // Number of samples available
	decoderStop   chan struct{} // Signal to stop decoder goroutine
	decoderDone   chan struct{} // Signal that decoder has stopped

	// Audio buffer (pre-allocated to avoid allocation in callback)
	audioBuf     []byte
	audioBufSize int

	// FFT Analysis
	fftMu       sync.RWMutex
	fftSamples  []float64
	fftResult   []uint8 // 0-255 frequency data
	fftSize     int
	fftWindow   []float64      // Hanning window
	fftLocalBuf []float64      // Local buffer for collecting samples
	fftChan     chan []float64 // Channel for async FFT processing

	// Equaliser
	eqSettingsMu sync.RWMutex
	eqSettings   equalizerSettings
	eqConfig     atomic.Value // equalizerConfig
	eqStates     [][]biquadState

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

	p := &Player{}
	p.setVolume(1.0)

	// Initialize FFT
	p.initFFT(2048)
	p.eqConfig.Store(defaultEqualizerConfig())

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
	p.fftLocalBuf = make([]float64, 0, size) // Local buffer for batch collection
	p.fftChan = make(chan []float64, 4)      // Buffered channel for async FFT

	// Start FFT processor goroutine
	go p.fftProcessor()

	// Hanning Window
	for i := 0; i < size; i++ {
		p.fftWindow[i] = 0.5 * (1 - math.Cos(2*math.Pi*float64(i)/float64(size-1)))
	}

	// Pre-allocate audio buffer (enough for typical frame size)
	p.audioBufSize = 4096 * 4 * 2 // 4096 frames * 4 bytes per sample (stereo int16)
	p.audioBuf = make([]byte, p.audioBufSize)
}

// fftProcessor processes FFT data asynchronously
func (p *Player) fftProcessor() {
	var samples []float64
	for input := range p.fftChan {
		samples = append(samples, input...)

		// Process when we have enough samples
		for len(samples) >= p.fftSize {
			// Extract exactly fftSize samples
			fftInput := make([]float64, p.fftSize)
			copy(fftInput, samples[:p.fftSize])
			samples = samples[p.fftSize:]

			p.calculateFFT(fftInput)
		}
	}
}

// Atomic helper functions
func (p *Player) setVolume(v float64) {
	p.volume.Store(math.Float64bits(v))
}

func (p *Player) getVolume() float64 {
	return math.Float64frombits(p.volume.Load())
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

	// Stop current playback and decoder goroutine
	if p.decoderStop != nil {
		close(p.decoderStop)
		<-p.decoderDone
	}
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
		// Pass file to FLAC decoder (it needs io.ReadSeeker for seeking)
		dec, err := newFLACDecoder(file)
		if err != nil {
			// mewkiz/flac が対応できないFLACファイルの場合、FFmpegにフォールバック
			fmt.Printf("[Audio] FLAC native decoder failed: %v — falling back to FFmpeg\n", err)
			file.Close()
			p.file = nil
			ffDec, ffErr := newFFmpegDecoder(filePath)
			if ffErr != nil {
				return fmt.Errorf("both FLAC and FFmpeg decoders failed: FLAC=%w, FFmpeg=%v", err, ffErr)
			}
			p.decoder = ffDec
		} else {
			p.decoder = dec
			p.file = nil // FLAC decoder manages the file now
		}
	case ".m4a", ".mp4", ".aac", ".ogg":
		file.Close()
		p.file = nil
		dec, err := newFFmpegDecoder(filePath)
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
	p.position.Store(0)

	// Initialize ring buffer (1 second of audio)
	p.ringBufSize = p.sampleRate * p.channels * 2 // 2 seconds buffer
	p.ringBuf = make([]float32, p.ringBufSize)
	p.ringReadPos.Store(0)
	p.ringWritePos.Store(0)
	p.ringAvailable.Store(0)
	p.decoderStop = make(chan struct{})
	p.decoderDone = make(chan struct{})
	p.eqStates = make([][]biquadState, max(1, p.channels))
	for channelIndex := 0; channelIndex < len(p.eqStates); channelIndex++ {
		p.eqStates[channelIndex] = make([]biquadState, equalizerBandCount)
	}
	p.rebuildEqualizerConfig(p.sampleRate)

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

	// Create callback stream
	stream, err := portaudio.OpenStream(params, func(out []float32) {
		p.processAudio(out)
	})
	if err != nil {
		return fmt.Errorf("failed to open stream: %w", err)
	}

	p.stream = stream
	p.playing.Store(true)
	p.paused.Store(false)

	// Start background decoder goroutine
	go p.decoderLoop()

	if err := stream.Start(); err != nil {
		return fmt.Errorf("failed to start stream: %w", err)
	}

	fmt.Printf("[Audio] Playing: %s on %s (SR: %d, CH: %d)\n", filePath, device.Name, p.sampleRate, p.channels)
	return nil
}

// decoderLoop runs in background and fills the ring buffer
func (p *Player) decoderLoop() {
	defer close(p.decoderDone)

	// Temporary buffer for reading from decoder
	readBuf := make([]byte, 8192)

	for {
		select {
		case <-p.decoderStop:
			return
		default:
		}

		// Check if buffer has space
		available := p.ringAvailable.Load()
		if available >= int64(p.ringBufSize-8192) {
			// Buffer is full enough, wait a bit
			time.Sleep(5 * time.Millisecond)
			continue
		}

		// Read from decoder
		p.mu.RLock()
		decoder := p.decoder
		channels := p.channels
		p.mu.RUnlock()

		if decoder == nil {
			return
		}

		n, err := decoder.Read(readBuf)
		if n > 0 {
			// Convert int16 to float32 and write to ring buffer
			samples := n / 2
			writePos := p.ringWritePos.Load()

			for i := 0; i < samples; i++ {
				sample := int16(readBuf[i*2]) | int16(readBuf[i*2+1])<<8
				floatSample := float32(sample) / 32768.0

				idx := (writePos + int64(i)) % int64(p.ringBufSize)
				p.ringBuf[idx] = floatSample
			}

			p.ringWritePos.Store((writePos + int64(samples)) % int64(p.ringBufSize))
			p.ringAvailable.Add(int64(samples))
		}

		if err == io.EOF || n == 0 {
			// Wait for buffer to drain, then signal end
			for p.ringAvailable.Load() > 0 && p.playing.Load() {
				time.Sleep(10 * time.Millisecond)
			}

			p.playing.Store(false)

			p.mu.RLock()
			callback := p.onFinished
			p.mu.RUnlock()

			if callback != nil {
				go callback()
			}
			return
		}

		if err != nil {
			fmt.Printf("[Audio] Decoder error: %v\n", err)
			return
		}

		// Small sleep to prevent busy loop
		if available > int64(p.ringBufSize/2) {
			time.Sleep(1 * time.Millisecond)
		}

		_ = channels // Used for position tracking if needed
	}
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
// CRITICAL: This runs in a real-time audio thread - NO LOCKS, NO ALLOCATIONS
func (p *Player) processAudio(out []float32) {
	// Read atomic state without locks
	playing := p.playing.Load()
	paused := p.paused.Load()
	volume := p.getVolume()

	if !playing || paused {
		// Fill with silence
		for i := range out {
			out[i] = 0
		}
		return
	}

	// Read from ring buffer (completely lock-free)
	available := p.ringAvailable.Load()
	readPos := p.ringReadPos.Load()
	ringBuf := p.ringBuf
	ringBufSize := int64(p.ringBufSize)
	channels := p.channels
	eqCfg := defaultEqualizerConfig()
	if loadedConfig, ok := p.eqConfig.Load().(equalizerConfig); ok {
		eqCfg = loadedConfig
	}
	eqStates := p.eqStates
	useEqualizer := eqCfg.active && channels > 0 && len(eqStates) >= channels

	samplesToRead := len(out)
	if int64(samplesToRead) > available {
		samplesToRead = int(available)
	}

	// Read samples from ring buffer
	for i := 0; i < samplesToRead; i++ {
		idx := (readPos + int64(i)) % ringBufSize
		outputSample := float64(ringBuf[idx])

		if useEqualizer {
			outputSample *= float64(eqCfg.preamp)
			channelIndex := i % channels
			channelState := eqStates[channelIndex]

			for bandIndex := 0; bandIndex < equalizerBandCount; bandIndex++ {
				outputSample = processBiquadSample(outputSample, eqCfg.coefficients[bandIndex], &channelState[bandIndex])
			}
		}

		outputSample *= volume
		if outputSample > 1 {
			outputSample = 1
		} else if outputSample < -1 {
			outputSample = -1
		}
		out[i] = float32(outputSample)
	}

	// Fill remaining with silence
	for i := samplesToRead; i < len(out); i++ {
		out[i] = 0
	}

	// Update read position and available count
	if samplesToRead > 0 {
		p.ringReadPos.Store((readPos + int64(samplesToRead)) % ringBufSize)
		p.ringAvailable.Add(-int64(samplesToRead))

		// Update position (samples played)
		if channels > 0 {
			p.position.Add(int64(samplesToRead / channels))
		}

		// Send samples for FFT (every nth callback to reduce overhead)
		if p.fftChan != nil && samplesToRead >= 512 {
			// Create FFT samples from left channel
			fftSamples := make([]float64, samplesToRead/channels)
			for i := 0; i < samplesToRead && i/channels < len(fftSamples); i += channels {
				idx := (readPos + int64(i)) % ringBufSize
				fftSamples[i/channels] = float64(ringBuf[idx])
			}
			select {
			case p.fftChan <- fftSamples:
			default:
			}
		}
	}
}

// Pause pauses playback
func (p *Player) Pause() error {
	p.mu.RLock()
	stream := p.stream
	p.mu.RUnlock()

	if stream == nil {
		return nil
	}

	p.paused.Store(true)
	return nil
}

// Resume resumes playback
func (p *Player) Resume() error {
	p.mu.RLock()
	stream := p.stream
	p.mu.RUnlock()

	if stream == nil {
		return nil
	}

	p.paused.Store(false)
	return nil
}

// Stop stops playback
func (p *Player) Stop() error {
	// Stop decoder goroutine first
	if p.decoderStop != nil {
		close(p.decoderStop)
		<-p.decoderDone
		p.decoderStop = nil
		p.decoderDone = nil
	}

	p.mu.Lock()
	if p.stream != nil {
		p.stream.Stop()
		p.stream.Close()
		p.stream = nil
	}
	p.mu.Unlock()

	p.playing.Store(false)
	p.paused.Store(false)
	p.position.Store(0)
	p.ringAvailable.Store(0)
	p.ringReadPos.Store(0)
	p.ringWritePos.Store(0)

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

	// Clear ring buffer on seek
	p.ringAvailable.Store(0)
	p.ringReadPos.Store(0)
	p.ringWritePos.Store(0)

	p.position.Store(targetSample)
	return nil
}

// SetVolume sets the volume (0.0 to 1.0)
func (p *Player) SetVolume(volume float64) {
	if volume < 0 {
		volume = 0
	}
	if volume > 1 {
		volume = 1
	}
	p.setVolume(volume)
}

// SetEqualizer updates equaliser settings used by real-time audio callback.
func (p *Player) SetEqualizer(active bool, preampDB float64, bands []float64) {
	nextSettings := equalizerSettings{
		active:   active,
		preampDB: clampFloat64(sanitiseFinite(preampDB), -24, 24),
	}
	for i := 0; i < equalizerBandCount; i++ {
		if i >= len(bands) {
			continue
		}
		nextSettings.bandDB[i] = clampFloat64(sanitiseFinite(bands[i]), -24, 24)
	}

	p.eqSettingsMu.Lock()
	p.eqSettings = nextSettings
	p.eqSettingsMu.Unlock()

	p.mu.RLock()
	sampleRate := p.sampleRate
	p.mu.RUnlock()

	p.rebuildEqualizerConfig(sampleRate)
}

// GetPosition returns the current position in seconds
func (p *Player) GetPosition() float64 {
	p.mu.RLock()
	sampleRate := p.sampleRate
	p.mu.RUnlock()

	if sampleRate == 0 {
		return 0
	}
	return float64(p.position.Load()) / float64(sampleRate)
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
	return p.playing.Load() && !p.paused.Load()
}

// IsPaused returns true if paused
func (p *Player) IsPaused() bool {
	return p.paused.Load()
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
			if !p.playing.Load() {
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

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func defaultEqualizerConfig() equalizerConfig {
	cfg := equalizerConfig{
		active: false,
		preamp: 1,
	}
	for i := 0; i < equalizerBandCount; i++ {
		cfg.coefficients[i] = identityBiquad()
	}
	return cfg
}

func (p *Player) rebuildEqualizerConfig(sampleRate int) {
	if sampleRate <= 0 {
		sampleRate = 44100
	}

	p.eqSettingsMu.RLock()
	settings := p.eqSettings
	p.eqSettingsMu.RUnlock()

	cfg := defaultEqualizerConfig()
	if !settings.active {
		p.eqConfig.Store(cfg)
		return
	}

	cfg.active = true
	cfg.preamp = float32(math.Pow(10, settings.preampDB/20))
	for bandIndex := 0; bandIndex < equalizerBandCount; bandIndex++ {
		frequency := limitFrequency(equalizerFrequencies[bandIndex], sampleRate)
		gainDB := settings.bandDB[bandIndex]
		switch {
		case bandIndex == 0:
			cfg.coefficients[bandIndex] = makeLowShelfCoefficients(sampleRate, frequency, equalizerShelfSlope, gainDB)
		case bandIndex == equalizerBandCount-1:
			cfg.coefficients[bandIndex] = makeHighShelfCoefficients(sampleRate, frequency, equalizerShelfSlope, gainDB)
		default:
			cfg.coefficients[bandIndex] = makePeakingCoefficients(sampleRate, frequency, equalizerDefaultQ, gainDB)
		}
	}

	p.eqConfig.Store(cfg)
}

func limitFrequency(frequency float64, sampleRate int) float64 {
	minimum := 10.0
	nyquist := float64(sampleRate) / 2
	maximum := nyquist * 0.95
	if maximum < minimum {
		maximum = minimum
	}
	return clampFloat64(frequency, minimum, maximum)
}

func makePeakingCoefficients(sampleRate int, frequency, q, gainDB float64) biquadCoefficients {
	if math.Abs(gainDB) < 0.0001 {
		return identityBiquad()
	}
	if q <= 0 {
		q = equalizerDefaultQ
	}

	omega := 2 * math.Pi * frequency / float64(sampleRate)
	sinOmega := math.Sin(omega)
	cosOmega := math.Cos(omega)
	alpha := sinOmega / (2 * q)
	a := math.Pow(10, gainDB/40)

	b0 := 1 + alpha*a
	b1 := -2 * cosOmega
	b2 := 1 - alpha*a
	a0 := 1 + alpha/a
	a1 := -2 * cosOmega
	a2 := 1 - alpha/a

	return normaliseBiquad(b0, b1, b2, a0, a1, a2)
}

func makeLowShelfCoefficients(sampleRate int, frequency, slope, gainDB float64) biquadCoefficients {
	if math.Abs(gainDB) < 0.0001 {
		return identityBiquad()
	}
	if slope <= 0 {
		slope = equalizerShelfSlope
	}

	omega := 2 * math.Pi * frequency / float64(sampleRate)
	sinOmega := math.Sin(omega)
	cosOmega := math.Cos(omega)
	a := math.Pow(10, gainDB/40)
	alpha := sinOmega / 2 * math.Sqrt((a+1/a)*(1/slope-1)+2)
	beta := 2 * math.Sqrt(a) * alpha

	b0 := a * ((a + 1) - (a-1)*cosOmega + beta)
	b1 := 2 * a * ((a - 1) - (a+1)*cosOmega)
	b2 := a * ((a + 1) - (a-1)*cosOmega - beta)
	a0 := (a + 1) + (a-1)*cosOmega + beta
	a1 := -2 * ((a - 1) + (a+1)*cosOmega)
	a2 := (a + 1) + (a-1)*cosOmega - beta

	return normaliseBiquad(b0, b1, b2, a0, a1, a2)
}

func makeHighShelfCoefficients(sampleRate int, frequency, slope, gainDB float64) biquadCoefficients {
	if math.Abs(gainDB) < 0.0001 {
		return identityBiquad()
	}
	if slope <= 0 {
		slope = equalizerShelfSlope
	}

	omega := 2 * math.Pi * frequency / float64(sampleRate)
	sinOmega := math.Sin(omega)
	cosOmega := math.Cos(omega)
	a := math.Pow(10, gainDB/40)
	alpha := sinOmega / 2 * math.Sqrt((a+1/a)*(1/slope-1)+2)
	beta := 2 * math.Sqrt(a) * alpha

	b0 := a * ((a + 1) + (a-1)*cosOmega + beta)
	b1 := -2 * a * ((a - 1) + (a+1)*cosOmega)
	b2 := a * ((a + 1) + (a-1)*cosOmega - beta)
	a0 := (a + 1) - (a-1)*cosOmega + beta
	a1 := 2 * ((a - 1) - (a+1)*cosOmega)
	a2 := (a + 1) - (a-1)*cosOmega - beta

	return normaliseBiquad(b0, b1, b2, a0, a1, a2)
}

func normaliseBiquad(b0, b1, b2, a0, a1, a2 float64) biquadCoefficients {
	if math.Abs(a0) < 1e-12 {
		return identityBiquad()
	}
	return biquadCoefficients{
		b0: b0 / a0,
		b1: b1 / a0,
		b2: b2 / a0,
		a1: a1 / a0,
		a2: a2 / a0,
	}
}

func identityBiquad() biquadCoefficients {
	return biquadCoefficients{b0: 1}
}

func processBiquadSample(input float64, coeff biquadCoefficients, state *biquadState) float64 {
	output := coeff.b0*input + coeff.b1*state.x1 + coeff.b2*state.x2 - coeff.a1*state.y1 - coeff.a2*state.y2
	state.x2 = state.x1
	state.x1 = input
	state.y2 = state.y1
	state.y1 = output
	return output
}

func sanitiseFinite(value float64) float64 {
	if math.IsNaN(value) || math.IsInf(value, 0) {
		return 0
	}
	return value
}

func clampFloat64(value, minimum, maximum float64) float64 {
	if value < minimum {
		return minimum
	}
	if value > maximum {
		return maximum
	}
	return value
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
	bytesPerSample := (int(dec.BitDepth) + 7) / 8
	if bytesPerSample == 0 {
		bytesPerSample = 2 // Default to 16-bit
	}

	pcmLen := dec.PCMLen()
	bytesPerFrame := int64(bytesPerSample * format.NumChannels)
	length := int64(0)
	if bytesPerFrame > 0 {
		length = int64(pcmLen) / bytesPerFrame
	}

	return &wavDecoder{
		decoder:       dec,
		sampleRate:    int(format.SampleRate),
		channels:      int(format.NumChannels),
		bitsPerSample: int(dec.BitDepth),
		length:        length,
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
		sample := wavSampleToInt16(d.buffer.Data[i], d.bitsPerSample)
		p[bytesWritten] = byte(sample)
		p[bytesWritten+1] = byte(sample >> 8)
		bytesWritten += 2
	}

	return bytesWritten, nil
}

func wavSampleToInt16(sample int, bitDepth int) int16 {
	if bitDepth <= 0 {
		return int16(clamp(sample, -32768, 32767))
	}

	switch {
	case bitDepth == 8:
		// WAV 8-bit PCM is unsigned (0..255). Center and scale to int16 range.
		scaled := (sample - 128) << 8
		return int16(clamp(scaled, -32768, 32767))
	case bitDepth < 16:
		shift := 16 - bitDepth
		scaled := sample << shift
		return int16(clamp(scaled, -32768, 32767))
	case bitDepth > 16:
		shift := bitDepth - 16
		scaled := sample >> shift
		return int16(clamp(scaled, -32768, 32767))
	default:
		return int16(clamp(sample, -32768, 32767))
	}
}

func clamp(v, minV, maxV int) int {
	if v < minV {
		return minV
	}
	if v > maxV {
		return maxV
	}
	return v
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
	bytesPerSample := d.bitsPerSample / 8
	if bytesPerSample == 0 {
		bytesPerSample = 2 // Default to 16-bit
	}

	// Calculate byte offset from start of audio data
	offset := sample * int64(d.channels) * int64(bytesPerSample)

	// Use the decoder's Seek method which handles seeking within PCM data
	_, err := d.decoder.Seek(offset, io.SeekStart)
	if err != nil {
		return fmt.Errorf("failed to seek WAV: %w", err)
	}

	return nil
}

func (d *wavDecoder) Close() error {
	return nil
}

// ============ FFmpeg Decoder (M4A/MP4/AAC/OGG) ============

type ffmpegDecoder struct {
	filePath   string
	sampleRate int
	channels   int
	length     int64
	cmd        *exec.Cmd
	stdout     io.ReadCloser
}

func newFFmpegDecoder(filePath string) (*ffmpegDecoder, error) {
	const outputSampleRate = 44100
	const outputChannels = 2

	d := &ffmpegDecoder{
		filePath:   filePath,
		sampleRate: outputSampleRate,
		channels:   outputChannels,
	}

	if durationSec, ok := probeDurationSeconds(filePath); ok && durationSec > 0 {
		d.length = int64(durationSec * float64(outputSampleRate))
	}

	if err := d.startAt(0); err != nil {
		return nil, err
	}

	return d, nil
}

func resolveCommandPath(name string) (string, error) {
	if name == "ffmpeg" && config.FFmpegPath != "" {
		return config.FFmpegPath, nil
	}
	if name == "ffprobe" && config.FFprobePath != "" {
		return config.FFprobePath, nil
	}

	path, err := exec.LookPath(name)
	if err != nil {
		return "", fmt.Errorf("%s not found in PATH", name)
	}
	return path, nil
}

func probeDurationSeconds(filePath string) (float64, bool) {
	ffprobePath, err := resolveCommandPath("ffprobe")
	if err != nil {
		return 0, false
	}

	cmd := exec.Command(
		ffprobePath,
		"-v", "error",
		"-show_entries", "format=duration",
		"-of", "default=noprint_wrappers=1:nokey=1",
		filePath,
	)
	out, err := cmd.Output()
	if err != nil {
		return 0, false
	}

	s := strings.TrimSpace(string(out))
	if s == "" || s == "N/A" {
		return 0, false
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil || v <= 0 {
		return 0, false
	}
	return v, true
}

func (d *ffmpegDecoder) startAt(seconds float64) error {
	ffmpegPath, err := resolveCommandPath("ffmpeg")
	if err != nil {
		return err
	}

	args := []string{"-hide_banner", "-loglevel", "error"}
	if seconds > 0 {
		args = append(args, "-ss", fmt.Sprintf("%.3f", seconds))
	}
	args = append(args,
		"-i", d.filePath,
		"-vn",
		"-f", "s16le",
		"-acodec", "pcm_s16le",
		"-ac", strconv.Itoa(d.channels),
		"-ar", strconv.Itoa(d.sampleRate),
		"-",
	)

	cmd := exec.Command(ffmpegPath, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("failed to open ffmpeg stdout: %w", err)
	}
	cmd.Stderr = io.Discard

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to start ffmpeg: %w", err)
	}

	d.cmd = cmd
	d.stdout = stdout
	return nil
}

func (d *ffmpegDecoder) stopProcess() {
	if d.stdout != nil {
		_ = d.stdout.Close()
		d.stdout = nil
	}
	if d.cmd != nil {
		if d.cmd.Process != nil {
			_ = d.cmd.Process.Kill()
		}
		_ = d.cmd.Wait()
		d.cmd = nil
	}
}

func (d *ffmpegDecoder) Read(p []byte) (int, error) {
	if d.stdout == nil {
		return 0, io.EOF
	}

	n, err := d.stdout.Read(p)
	if err == io.EOF {
		d.stopProcess()
	}
	return n, err
}

func (d *ffmpegDecoder) SampleRate() int {
	return d.sampleRate
}

func (d *ffmpegDecoder) Channels() int {
	return d.channels
}

func (d *ffmpegDecoder) Length() int64 {
	return d.length
}

func (d *ffmpegDecoder) Seek(sample int64) error {
	if sample < 0 {
		sample = 0
	}
	seconds := float64(sample) / float64(d.sampleRate)
	d.stopProcess()
	return d.startAt(seconds)
}

func (d *ffmpegDecoder) Close() error {
	d.stopProcess()
	return nil
}

// ============ FLAC Decoder ============

// flacFrameIndex stores sample position to file offset mapping
type flacFrameIndex struct {
	samplePos int64 // Sample position at start of frame
	offset    int64 // File offset at start of frame (absolute)
}

type flacDecoder struct {
	file          *os.File // Keep file handle for closing
	filePath      string   // Keep path for re-opening if needed
	stream        *flac.Stream
	sampleRate    int
	channels      int
	length        int64
	frame         *frame.Frame
	framePos      int
	frameIndex    []flacFrameIndex // Index of frame positions
	indexBuilt    bool             // Whether index has been built
	indexBuilding bool             // Whether index is being built
	indexDone     chan struct{}    // Signals that indexing is complete
	seekTable     *meta.SeekTable
	seekApplied   bool
	mu            sync.RWMutex

	// FFmpeg fallback for files that mewkiz/flac cannot parse
	ffmpegFallback *ffmpegDecoder
	useFFmpeg      bool
	parseErrors    int // consecutive parse errors
}

// detectID3v2Size checks for an ID3v2 header at the start of the reader.
// Returns the total size of the ID3v2 tag (header + data + optional footer).
// Returns 0 if no ID3v2 header is found. Reader position is restored after checking.
func detectID3v2Size(r io.ReadSeeker) int64 {
	pos, err := r.Seek(0, io.SeekCurrent)
	if err != nil {
		return 0
	}

	header := make([]byte, 10)
	if _, err := io.ReadFull(r, header); err != nil {
		r.Seek(pos, io.SeekStart)
		return 0
	}

	// Restore position
	r.Seek(pos, io.SeekStart)

	// Check "ID3" magic bytes
	if header[0] != 'I' || header[1] != 'D' || header[2] != '3' {
		return 0
	}

	// Parse synchsafe integer (4 bytes, each byte uses only lower 7 bits)
	size := int64(header[6]&0x7F)<<21 |
		int64(header[7]&0x7F)<<14 |
		int64(header[8]&0x7F)<<7 |
		int64(header[9]&0x7F)

	total := int64(10) + size // 10-byte header + tag data

	// Check footer flag (bit 4 of flags byte)
	if header[5]&0x10 != 0 {
		total += 10
	}

	return total
}

// remuxFLACFile uses FFmpeg to remux a FLAC file, converting ID3v2 tags to
// proper VorbisComment metadata. Audio data is copied without re-encoding.
func remuxFLACFile(filePath string) error {
	ffmpegPath, err := resolveCommandPath("ffmpeg")
	if err != nil {
		return err
	}

	dir := filepath.Dir(filePath)
	base := filepath.Base(filePath)
	tmpPath := filepath.Join(dir, ".uxmusic_fix_"+base)

	cmd := exec.Command(ffmpegPath,
		"-hide_banner", "-loglevel", "error",
		"-i", filePath,
		"-c:a", "copy", // Copy audio stream — no re-encoding
		"-map_metadata", "0", // Preserve metadata
		"-y",
		tmpPath,
	)
	cmd.Stderr = io.Discard

	if err := cmd.Run(); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("ffmpeg remux failed: %w", err)
	}

	// Verify output file has reasonable size
	outInfo, err := os.Stat(tmpPath)
	if err != nil {
		return fmt.Errorf("remuxed file not found: %w", err)
	}
	inInfo, err := os.Stat(filePath)
	if err != nil {
		os.Remove(tmpPath)
		return err
	}
	// Sanity: output should be at least 70% of input (audio is identical, only metadata differs)
	if outInfo.Size() < inInfo.Size()*70/100 {
		os.Remove(tmpPath)
		return fmt.Errorf("remuxed file unexpectedly small (%d vs %d bytes)", outInfo.Size(), inInfo.Size())
	}

	// Atomic replace (Unix: old fd remains valid after rename)
	if err := os.Rename(tmpPath, filePath); err != nil {
		os.Remove(tmpPath)
		return err
	}

	// Clear cached FLAC index (file content/offsets changed)
	if cachePath := getFLACCachePath(filePath); cachePath != "" {
		os.Remove(cachePath)
	}

	return nil
}

func newFLACDecoder(file *os.File) (*flacDecoder, error) {
	var id3v2Detected bool

	// Check for ID3v2 header at the start of the file
	id3Size := detectID3v2Size(file)
	if id3Size > 0 {
		id3v2Detected = true
		fmt.Printf("[Audio] FLAC: ID3v2 tag detected (%d bytes) in %s — skipping for native playback\n",
			id3Size, filepath.Base(file.Name()))
		// Seek past ID3v2 header so mewkiz/flac can find the "fLaC" signature
		if _, err := file.Seek(id3Size, io.SeekStart); err != nil {
			return nil, fmt.Errorf("failed to seek past ID3v2 header: %w", err)
		}
	}

	// Use NewSeek to create a seekable stream
	stream, err := flac.NewSeek(file)
	if err != nil {
		return nil, fmt.Errorf("failed to open FLAC: %w", err)
	}

	dec := &flacDecoder{
		file:       file,
		filePath:   file.Name(),
		stream:     stream,
		sampleRate: int(stream.Info.SampleRate),
		channels:   int(stream.Info.NChannels),
		length:     int64(stream.Info.NSamples),
		frameIndex: make([]flacFrameIndex, 0),
		indexDone:  make(chan struct{}),
	}

	if id3v2Detected {
		// For ID3v2 files: skip background index building (file will be remuxed).
		// Seeking still works via the stream's built-in SeekTable if present.
		dec.indexBuilt = true
		close(dec.indexDone)

		// Apply existing SeekTable from stream metadata if available
		for _, block := range stream.Blocks {
			if table, ok := block.Body.(*meta.SeekTable); ok {
				dec.seekTable = table
				dec.applySeekTable()
				break
			}
		}

		// Schedule background remux: ID3v2 → VorbisComment
		go func(path string) {
			// Wait briefly for decoder initialisation to settle
			time.Sleep(2 * time.Second)
			if err := remuxFLACFile(path); err != nil {
				fmt.Printf("[Audio] FLAC: Metadata fix failed for %s: %v\n", filepath.Base(path), err)
			} else {
				fmt.Printf("[Audio] FLAC: Metadata fixed for %s (ID3v2 → VorbisComment)\n", filepath.Base(path))
			}
		}(dec.filePath)

		return dec, nil
	}

	// ---- Normal path (no ID3v2) ----

	// Check disk cache first
	cachePath := getFLACCachePath(dec.filePath)
	if cachePath != "" {
		if points := loadFLACIndex(cachePath); len(points) > 0 {
			fmt.Printf("[Audio] FLAC: Loaded index from cache (%d points)\n", len(points))
			dec.seekTable = &meta.SeekTable{Points: points}
			dec.indexBuilt = true
			close(dec.indexDone)
			dec.applySeekTable()
			return dec, nil
		}
	}

	// Check if the stream already has a SeekTable in its metadata blocks
	var existingTable *meta.SeekTable
	for _, block := range stream.Blocks {
		if table, ok := block.Body.(*meta.SeekTable); ok {
			existingTable = table
			break
		}
	}

	if existingTable != nil {
		fmt.Printf("[Audio] FLAC: Using existing SeekTable with %d points\n", len(existingTable.Points))
		dec.seekTable = existingTable
		dec.indexBuilt = true
		close(dec.indexDone)
		dec.applySeekTable()
	} else {
		// Start building index in background only if no SeekTable exists
		go dec.buildIndex()
	}

	return dec, nil
}

// buildIndex builds frame index in background
func (d *flacDecoder) buildIndex() {
	d.mu.Lock()
	if d.indexBuilding || d.indexBuilt {
		d.mu.Unlock()
		return
	}
	d.indexBuilding = true
	d.mu.Unlock()

	defer func() {
		d.mu.Lock()
		d.indexBuilding = false
		d.indexBuilt = true
		// Ensure channel is not already closed
		select {
		case <-d.indexDone:
		default:
			close(d.indexDone)
		}
		d.mu.Unlock()
	}()

	// Open a separate file handle for indexing
	indexFile, err := os.Open(d.filePath)
	if err != nil {
		return
	}
	defer indexFile.Close()

	// Create a separate stream for indexing
	indexStream, err := flac.NewSeek(indexFile)
	if err != nil {
		return
	}
	defer indexStream.Close()

	rs, ok := flacStreamReadSeeker(indexStream)
	if !ok {
		return
	}
	dataStart, ok := flacStreamDataStart(indexStream)
	if !ok {
		return
	}

	// Parse all frames and record their sample positions + offsets
	var samplePos uint64
	var points []meta.SeekPoint
	for {
		offset, err := rs.Seek(0, io.SeekCurrent)
		if err != nil {
			return
		}
		fr, err := indexStream.ParseNext()
		if err != nil {
			if err == io.EOF {
				break
			}
			return
		}

		points = append(points, meta.SeekPoint{
			SampleNum: samplePos,
			Offset:    uint64(offset - dataStart),
			NSamples:  fr.BlockSize,
		})
		d.frameIndex = append(d.frameIndex, flacFrameIndex{
			samplePos: int64(samplePos),
			offset:    offset,
		})

		samplePos += uint64(fr.BlockSize)
	}

	if len(points) == 0 {
		return
	}

	d.mu.Lock()
	d.seekTable = &meta.SeekTable{Points: points}
	d.mu.Unlock()

	// Save to disk cache
	cachePath := getFLACCachePath(d.filePath)
	if cachePath != "" {
		saveFLACIndex(cachePath, points)
		fmt.Printf("[Audio] FLAC: Saved index to cache (%d points)\n", len(points))
	}
}

func flacStreamReadSeeker(stream *flac.Stream) (io.ReadSeeker, bool) {
	value := reflect.ValueOf(stream).Elem()
	field := value.FieldByName("r")
	if !field.IsValid() {
		return nil, false
	}
	reader := reflect.NewAt(field.Type(), unsafe.Pointer(field.UnsafeAddr())).Elem().Interface()
	rs, ok := reader.(io.ReadSeeker)
	return rs, ok
}

func flacStreamDataStart(stream *flac.Stream) (int64, bool) {
	value := reflect.ValueOf(stream).Elem()
	field := value.FieldByName("dataStart")
	if !field.IsValid() {
		return 0, false
	}
	dataStart := reflect.NewAt(field.Type(), unsafe.Pointer(field.UnsafeAddr())).Elem().Int()
	return dataStart, true
}

func flacStreamSetSeekTable(stream *flac.Stream, table *meta.SeekTable) bool {
	value := reflect.ValueOf(stream).Elem()
	field := value.FieldByName("seekTable")
	if !field.IsValid() {
		return false
	}
	// Important: Use TryLock if available or just ensure we're not violating internal invariants.
	// The flac.Stream.Seek method uses this field.
	reflect.NewAt(field.Type(), unsafe.Pointer(field.UnsafeAddr())).Elem().Set(reflect.ValueOf(table))
	return true
}

// BuildFLACIndex pre-generates the seeking index for a FLAC file
func BuildFLACIndex(filePath string) error {
	// Check if already exists
	cachePath := getFLACCachePath(filePath)
	if cachePath == "" {
		return errors.New("failed to get cache path")
	}
	if _, err := os.Stat(cachePath); err == nil {
		// Already exists
		return nil
	}

	file, err := os.Open(filePath)
	if err != nil {
		return err
	}
	defer file.Close()

	stream, err := flac.NewSeek(file)
	if err != nil {
		return err
	}
	defer stream.Close()

	rs, ok := flacStreamReadSeeker(stream)
	if !ok {
		return errors.New("failed to get read seeker")
	}
	dataStart, ok := flacStreamDataStart(stream)
	if !ok {
		return errors.New("failed to get data start")
	}

	var samplePos uint64
	var points []meta.SeekPoint
	for {
		offset, err := rs.Seek(0, io.SeekCurrent)
		if err != nil {
			return err
		}
		fr, err := stream.ParseNext()
		if err != nil {
			if err == io.EOF {
				break
			}
			return err
		}

		points = append(points, meta.SeekPoint{
			SampleNum: samplePos,
			Offset:    uint64(offset - dataStart),
			NSamples:  fr.BlockSize,
		})
		samplePos += uint64(fr.BlockSize)
	}

	if len(points) > 0 {
		saveFLACIndex(cachePath, points)
	}
	return nil
}

func (d *flacDecoder) Read(p []byte) (int, error) {
	// If already switched to FFmpeg fallback, delegate
	if d.useFFmpeg && d.ffmpegFallback != nil {
		return d.ffmpegFallback.Read(p)
	}

	bytesWritten := 0

	for bytesWritten+1 < len(p) {
		// Need new frame?
		if d.frame == nil || d.framePos >= int(d.frame.BlockSize) {
			frame, err := d.stream.ParseNext()
			if err != nil {
				if err == io.EOF {
					return bytesWritten, io.EOF
				}

				// mewkiz/flac がフレームをパースできない場合、FFmpegにフォールバック
				d.parseErrors++
				fmt.Printf("[Audio] FLAC ParseNext error (count=%d): %v\n", d.parseErrors, err)

				if d.parseErrors >= 3 || bytesWritten == 0 {
					if switchErr := d.switchToFFmpeg(); switchErr == nil {
						// FFmpegに切り替え成功。残りはFFmpegから読む
						if bytesWritten > 0 {
							return bytesWritten, nil
						}
						return d.ffmpegFallback.Read(p)
					}
					return bytesWritten, err
				}
				// Skip this frame and try the next
				continue
			}
			d.parseErrors = 0 // reset on success
			d.frame = frame
			d.framePos = 0
		}

		// Read samples from frame
		bps := d.stream.Info.BitsPerSample
		for d.framePos < int(d.frame.BlockSize) && bytesWritten+1 < len(p) {
			for ch := 0; ch < d.channels && bytesWritten+1 < len(p); ch++ {
				sample := d.frame.Subframes[ch].Samples[d.framePos]
				// Scale to 16-bit
				var sample16 int16
				if bps > 16 {
					sample16 = int16(sample >> (bps - 16))
				} else if bps < 16 {
					sample16 = int16(sample << (16 - bps))
				} else {
					sample16 = int16(sample)
				}
				p[bytesWritten] = byte(sample16)
				p[bytesWritten+1] = byte(sample16 >> 8)
				bytesWritten += 2
			}
			d.framePos++
		}
	}

	return bytesWritten, nil
}

// switchToFFmpeg は mewkiz/flac でデコードできないFLACファイルをFFmpegに切り替える
func (d *flacDecoder) switchToFFmpeg() error {
	if d.useFFmpeg {
		return nil // Already switched
	}

	fmt.Printf("[Audio] FLAC: Switching to FFmpeg fallback for %s\n", d.filePath)

	// Close native FLAC stream
	if d.stream != nil {
		d.stream.Close()
		d.stream = nil
	}
	if d.file != nil {
		d.file.Close()
		d.file = nil
	}

	ffDec, err := newFFmpegDecoder(d.filePath)
	if err != nil {
		return fmt.Errorf("FFmpeg fallback failed: %w", err)
	}

	d.ffmpegFallback = ffDec
	d.useFFmpeg = true
	return nil
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

func (d *flacDecoder) waitForIndex() {
	d.mu.RLock()
	built := d.indexBuilt
	done := d.indexDone
	d.mu.RUnlock()

	if built {
		return
	}
	<-done
}

func (d *flacDecoder) applySeekTable() {
	d.mu.RLock()
	seekTable := d.seekTable
	d.mu.RUnlock()

	if seekTable == nil {
		return
	}

	d.mu.Lock()
	defer d.mu.Unlock()
	// Always apply the current seekTable to ensure we have the best accuracy
	if flacStreamSetSeekTable(d.stream, d.seekTable) {
		d.seekApplied = true
	}
}

func (d *flacDecoder) Seek(sample int64) error {
	if sample < 0 {
		sample = 0
	}
	if sample > d.length {
		sample = d.length
	}

	// If using FFmpeg fallback, delegate seek
	if d.useFFmpeg && d.ffmpegFallback != nil {
		return d.ffmpegFallback.Seek(sample)
	}

	// Non-blocking: apply whatever index we have right now
	d.applySeekTable()

	// Use the stream's Seek method
	actualSample, err := d.stream.Seek(uint64(sample))
	if err != nil {
		return fmt.Errorf("failed to seek FLAC: %w", err)
	}

	// Reset frame state so Read will get a fresh frame
	d.frame = nil
	d.framePos = 0

	_ = actualSample // The stream seeks to the frame containing this sample
	return nil
}

func (d *flacDecoder) Close() error {
	if d.ffmpegFallback != nil {
		d.ffmpegFallback.Close()
	}
	if d.stream != nil {
		d.stream.Close()
	}
	if d.file != nil {
		return d.file.Close()
	}
	return nil
}

// ============ FLAC Cache Helpers ============

func getFLACCacheDir() string {
	cacheDir, err := os.UserCacheDir()
	if err != nil {
		return ""
	}
	dir := filepath.Join(cacheDir, "UX-Music", "flac-index")
	os.MkdirAll(dir, 0755)
	return dir
}

func getFLACCachePath(filePath string) string {
	info, err := os.Stat(filePath)
	if err != nil {
		return ""
	}
	h := sha256.New()
	h.Write([]byte(filePath))
	binary.Write(h, binary.LittleEndian, info.Size())
	binary.Write(h, binary.LittleEndian, info.ModTime().Unix())
	hash := fmt.Sprintf("%x", h.Sum(nil))

	dir := getFLACCacheDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, hash+".idx")
}

func saveFLACIndex(cachePath string, points []meta.SeekPoint) {
	f, err := os.Create(cachePath)
	if err != nil {
		return
	}
	defer f.Close()

	for _, p := range points {
		binary.Write(f, binary.LittleEndian, p.SampleNum)
		binary.Write(f, binary.LittleEndian, p.Offset)
		binary.Write(f, binary.LittleEndian, uint16(p.NSamples))
	}
}

func loadFLACIndex(cachePath string) []meta.SeekPoint {
	f, err := os.Open(cachePath)
	if err != nil {
		return nil
	}
	defer f.Close()

	var points []meta.SeekPoint
	for {
		var sampleNum, offset uint64
		var nSamples uint16
		if err := binary.Read(f, binary.LittleEndian, &sampleNum); err != nil {
			break
		}
		if err := binary.Read(f, binary.LittleEndian, &offset); err != nil {
			break
		}
		if err := binary.Read(f, binary.LittleEndian, &nSamples); err != nil {
			break
		}
		points = append(points, meta.SeekPoint{
			SampleNum: sampleNum,
			Offset:    offset,
			NSamples:  uint16(nSamples),
		})
	}
	return points
}
