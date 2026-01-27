package audio

import (
	"errors"
	"fmt"
	"io"
	"math"
	"math/cmplx"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

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
			file.Close()
			return err
		}
		p.decoder = dec
		p.file = nil // FLAC decoder manages the file now
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

	samplesToRead := len(out)
	if int64(samplesToRead) > available {
		samplesToRead = int(available)
	}

	// Read samples from ring buffer
	for i := 0; i < samplesToRead; i++ {
		idx := (readPos + int64(i)) % ringBufSize
		out[i] = ringBuf[idx] * float32(volume)
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
}

func newFLACDecoder(file *os.File) (*flacDecoder, error) {
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

	// Start building index in background
	go dec.buildIndex()

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
		close(d.indexDone)
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
	reflect.NewAt(field.Type(), unsafe.Pointer(field.UnsafeAddr())).Elem().Set(reflect.ValueOf(table))
	return true
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
	applied := d.seekApplied
	d.mu.RUnlock()

	if seekTable == nil || applied {
		return
	}

	d.mu.Lock()
	defer d.mu.Unlock()
	if d.seekApplied || d.seekTable == nil {
		return
	}
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

	d.waitForIndex()
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
	if d.stream != nil {
		d.stream.Close()
	}
	if d.file != nil {
		return d.file.Close()
	}
	return nil
}
