package cdrip

import (
	"bytes"
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestSecureReadAcceptsMatchingDoubleRead(t *testing.T) {
	fake := newFakeDiscReader(testTOC(), map[int][]byte{0: sector(1), 1: sector(2)})
	data, report, err := SecureReadTrack(fake, 1, SecureReadOptions{MaxAttempts: 4})
	if err != nil || len(report.Unrecoverable) != 0 || !bytes.Equal(data, append(sector(1), sector(2)...)) {
		t.Fatalf("secure read = %v, report=%+v, bytes=%d", err, report, len(data))
	}
	if fake.reads[0] != 2 || fake.reads[1] != 2 {
		t.Fatalf("reads = %+v, want two reads per sector", fake.reads)
	}
	if len(fake.calls) != 2 || fake.calls[0] != (readCall{lba: 0, count: 2}) || fake.calls[1] != (readCall{lba: 0, count: 2}) {
		t.Fatalf("calls = %+v, want two batched reads", fake.calls)
	}
}

func TestSecureReadUsesConfiguredBatches(t *testing.T) {
	toc := testTOC()
	toc.Tracks[0].Length = 30
	toc.LeadOutLBA = 30
	sectors := make(map[int][]byte, 30)
	for i := 0; i < 30; i++ {
		sectors[i] = sector(byte(i))
	}
	fake := newFakeDiscReader(toc, sectors)
	if _, _, err := SecureReadTrack(fake, 1, SecureReadOptions{BlockSize: 27}); err != nil {
		t.Fatal(err)
	}
	if len(fake.calls) != 4 {
		t.Fatalf("calls = %d, want two reads for each of two blocks: %+v", len(fake.calls), fake.calls)
	}
	for _, call := range fake.calls[:2] {
		if call != (readCall{lba: 0, count: 27}) {
			t.Fatalf("first block call = %+v", call)
		}
	}
	for _, call := range fake.calls[2:] {
		if call != (readCall{lba: 27, count: 3}) {
			t.Fatalf("second block call = %+v", call)
		}
	}
}

func TestSecureReadRereadsOnlyJitterySector(t *testing.T) {
	toc := testTOC()
	toc.Tracks[0].Length = 3
	toc.LeadOutLBA = 3
	fake := newFakeDiscReader(toc, map[int][]byte{0: sector(1), 1: sector(2), 2: sector(3)})
	fake.jitter[1] = 1
	if _, _, err := SecureReadTrack(fake, 1, SecureReadOptions{BlockSize: 3}); err != nil {
		t.Fatal(err)
	}
	want := []readCall{{lba: 0, count: 3}, {lba: 0, count: 3}, {lba: 1, count: 1}}
	if !reflect.DeepEqual(fake.calls, want) {
		t.Fatalf("calls = %+v, want %+v", fake.calls, want)
	}
}

func TestSecureReadTrackToStreamsPCM(t *testing.T) {
	fake := newFakeDiscReader(testTOC(), map[int][]byte{0: sector(1), 1: sector(2)})
	var out bytes.Buffer
	if _, err := SecureReadTrackTo(&out, fake, 1, SecureReadOptions{BlockSize: 1}); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(out.Bytes(), append(sector(1), sector(2)...)) {
		t.Fatalf("streamed PCM differs")
	}
}

func TestSecureReadResolvesJitterAndReportsUnrecoverableRanges(t *testing.T) {
	toc := testTOC()
	toc.Tracks[0].Length = 3
	toc.LeadOutLBA = 3
	fake := newFakeDiscReader(toc, map[int][]byte{0: sector(1), 1: sector(2), 2: sector(3)})
	fake.jitter[1] = 2
	fake.unreadable[2] = true
	_, report, err := SecureReadTrack(fake, 1, SecureReadOptions{MaxAttempts: 5})
	if err == nil || !strings.Contains(err.Error(), "unrecoverable") {
		t.Fatalf("error = %v, want unrecoverable", err)
	}
	if len(report.Unrecoverable) != 1 || report.Unrecoverable[0] != (SectorRange{Start: 2, End: 2}) {
		t.Fatalf("unrecoverable = %+v", report.Unrecoverable)
	}
	if len(report.Suspicious) != 1 || report.Suspicious[0] != (SectorRange{Start: 1, End: 1}) {
		t.Fatalf("suspicious = %+v", report.Suspicious)
	}
}

func TestSecureReadBurstReadsOnce(t *testing.T) {
	fake := newFakeDiscReader(testTOC(), map[int][]byte{0: sector(1), 1: sector(2)})
	_, _, err := SecureReadTrack(fake, 1, SecureReadOptions{Mode: "burst"})
	if err != nil || fake.reads[0] != 1 || fake.reads[1] != 1 {
		t.Fatalf("burst error=%v reads=%+v", err, fake.reads)
	}
}

func TestSecureReadOffsetAcrossTracksAndDiscEdges(t *testing.T) {
	toc := TOC{Tracks: []TOCTrack{{Number: 1, StartLBA: 0, Length: 1, Audio: true}, {Number: 2, StartLBA: 1, Length: 1, Audio: true}}, LeadOutLBA: 2}
	fake := newFakeDiscReader(toc, map[int][]byte{0: samples(10, 11), 1: samples(20, 21)})
	data, _, err := SecureReadTrack(fake, 1, SecureReadOptions{OffsetSamples: 1})
	if err != nil || !bytes.Equal(data, append(samples(10, 11)[4:], samples(20, 21)[:4]...)) {
		t.Fatalf("positive offset data mismatch: err=%v", err)
	}
	data, _, err = SecureReadTrack(fake, 1, SecureReadOptions{OffsetSamples: -1})
	expected := make([]byte, CDSectorBytes)
	copy(expected[4:], samples(10, 11)[:CDSectorBytes-4])
	if err != nil || !bytes.Equal(data, expected) {
		t.Fatalf("negative offset data mismatch: err=%v", err)
	}
	data, _, err = SecureReadTrack(fake, 2, SecureReadOptions{OffsetSamples: 1})
	expected = make([]byte, CDSectorBytes)
	copy(expected, samples(20, 21)[4:])
	if err != nil || !bytes.Equal(data, expected) {
		t.Fatalf("disc-end zero fill mismatch: err=%v", err)
	}
}

func TestWritePCMHeader(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.wav")
	if err := WritePCM16LE(path, []byte{1, 2, 3, 4}); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil || len(b) != 48 || string(b[:4]) != "RIFF" || string(b[8:12]) != "WAVE" || string(b[12:16]) != "fmt " || string(b[36:40]) != "data" {
		t.Fatalf("wav = %v len=%d", err, len(b))
	}
	if binary.LittleEndian.Uint32(b[4:8]) != 40 || binary.LittleEndian.Uint32(b[40:44]) != 4 || binary.LittleEndian.Uint16(b[22:24]) != 2 || binary.LittleEndian.Uint32(b[24:28]) != 44100 {
		t.Fatalf("invalid PCM header: %v", b[:44])
	}
}

func TestTOCTracksExcludeData(t *testing.T) {
	tracks := tracksFromTOC(TOC{Tracks: []TOCTrack{{Number: 1, StartLBA: 0, Length: 10, Audio: true}, {Number: 2, StartLBA: 10, Length: 20, Audio: false}}})
	if len(tracks) != 1 || tracks[0].Number != 1 || tracks[0].Sectors != 10 {
		t.Fatalf("tracks = %+v", tracks)
	}
}

func TestRipperFallsBackToCdparanoiaWithoutReaderFactory(t *testing.T) {
	requirePOSIXShellScripts(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "cdparanoia")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nprintf '  1. 12\\n'\n"), 0755); err != nil {
		t.Fatal(err)
	}
	r := NewRipper(path, "", dir)
	tracks, err := r.GetTrackList()
	if err != nil || len(tracks) != 1 || tracks[0].Sectors != 12 {
		t.Fatalf("fallback tracks=%+v err=%v", tracks, err)
	}
}

func TestRipperNativeFactoryIsGatedAndFallsBackOnOpenError(t *testing.T) {
	requirePOSIXShellScripts(t)
	t.Setenv("UX_MUSIC_CDRIP_NATIVE", "1")
	previous := nativeDiscFactory
	t.Cleanup(func() { nativeDiscFactory = previous })
	nativeDiscFactory = func() (DiscReader, error) { return nil, errors.New("permission denied") }
	dir := t.TempDir()
	path := filepath.Join(dir, "cdparanoia")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nprintf '  1. 12\\n'\n"), 0755); err != nil {
		t.Fatal(err)
	}
	r := NewRipper(path, "", dir)
	tracks, err := r.GetTrackList()
	if err != nil || len(tracks) != 1 || tracks[0].Sectors != 12 {
		t.Fatalf("native open fallback tracks=%+v err=%v", tracks, err)
	}
}

func TestRipperNativeFactoryIsDisabledByDefault(t *testing.T) {
	t.Setenv("UX_MUSIC_CDRIP_NATIVE", "0")
	if r := NewRipper("", "", ""); r.openDisc != nil {
		t.Fatal("native reader factory should be disabled unless explicitly enabled")
	}
}

type fakeDiscReader struct {
	toc        TOC
	sectors    map[int][]byte
	reads      map[int]int
	jitter     map[int]int
	unreadable map[int]bool
	calls      []readCall
}

type readCall struct {
	lba   int
	count int
}

func newFakeDiscReader(toc TOC, sectors map[int][]byte) *fakeDiscReader {
	return &fakeDiscReader{toc: toc, sectors: sectors, reads: map[int]int{}, jitter: map[int]int{}, unreadable: map[int]bool{}}
}
func (f *fakeDiscReader) ReadTOC() (TOC, error) { return f.toc, nil }
func (f *fakeDiscReader) ReadSectors(lba, count int) ([]byte, error) {
	f.calls = append(f.calls, readCall{lba: lba, count: count})
	result := make([]byte, 0, count*CDSectorBytes)
	var readErr error
	for i := 0; i < count; i++ {
		sectorLBA := lba + i
		f.reads[sectorLBA]++
		if f.unreadable[sectorLBA] {
			readErr = errors.New("unreadable")
			continue
		}
		data := append([]byte(nil), f.sectors[sectorLBA]...)
		if f.reads[sectorLBA] <= f.jitter[sectorLBA] && len(data) > 0 {
			data[0] ^= byte(f.reads[sectorLBA])
		}
		result = append(result, data...)
	}
	return result, readErr
}
func (f *fakeDiscReader) Close() error { return nil }

func testTOC() TOC {
	return TOC{Tracks: []TOCTrack{{Number: 1, StartLBA: 0, Length: 2, Audio: true}}, LeadOutLBA: 2}
}
func sector(v byte) []byte { return bytes.Repeat([]byte{v}, CDSectorBytes) }
func samples(a, b byte) []byte {
	data := make([]byte, CDSectorBytes)
	data[0], data[1], data[2], data[3] = a, 0, b, 0
	return data
}
