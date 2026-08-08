// Package audioembed stores CLAP audio embeddings on disk.
//
// Two files live side-by-side in the user data directory:
//
//	audio_embeddings_index.json  — { dim, entries: { track_id: { row, version, analysed_at } } }
//	audio_embeddings.bin         — packed float32 vectors, row R at byte offset R*dim*4
//
// Re-embedding a track allocates a new row at the end of the bin file and
// repoints the index; the old row becomes dead space (compaction is left for
// a later optimisation pass once the format is stable).
package audioembed

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	// EmbedDim is the LAION-CLAP music_audioset (HTSAT-tiny) output dimension.
	EmbedDim = 512

	indexFileName = "audio_embeddings_index.json"
	vectorFile    = "audio_embeddings.bin"

	bytesPerVector = EmbedDim * 4 // float32
)

// Embedding is one stored vector with its provenance.
type Embedding struct {
	Vector     []float32
	Version    string
	AnalysedAt time.Time
}

// indexEntry mirrors the on-disk JSON layout.
type indexEntry struct {
	Row        int64  `json:"row"`
	Version    string `json:"version"`
	AnalysedAt int64  `json:"analysed_at_unix"`
}

type indexFile struct {
	Dim     int                   `json:"dim"`
	Entries map[string]indexEntry `json:"entries"`
}

// Store is the disk-backed embedding store. Safe for concurrent use.
type Store struct {
	dir string

	mu      sync.Mutex
	entries map[string]indexEntry
	// nextRow is the row index assigned to the next Put (== current row count
	// in the bin file, including dead rows from replaced entries).
	nextRow int64
}

// NewStore opens (or initialises) the embedding store rooted at dir.
func NewStore(dir string) (*Store, error) {
	if dir == "" {
		return nil, fmt.Errorf("audioembed: empty directory")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("audioembed: mkdir: %w", err)
	}
	s := &Store{dir: dir, entries: map[string]indexEntry{}}
	if err := s.loadIndex(); err != nil {
		return nil, err
	}
	// nextRow tracks the bin file size so re-Puts append rather than overwrite.
	if info, err := os.Stat(s.binPath()); err == nil {
		s.nextRow = info.Size() / bytesPerVector
	}
	return s, nil
}

func (s *Store) indexPath() string { return filepath.Join(s.dir, indexFileName) }
func (s *Store) binPath() string   { return filepath.Join(s.dir, vectorFile) }

func (s *Store) loadIndex() error {
	bytes, err := os.ReadFile(s.indexPath())
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("audioembed: read index: %w", err)
	}
	if len(bytes) == 0 {
		return nil
	}
	var idx indexFile
	if err := json.Unmarshal(bytes, &idx); err != nil {
		return fmt.Errorf("audioembed: parse index: %w", err)
	}
	if idx.Dim != 0 && idx.Dim != EmbedDim {
		return fmt.Errorf("audioembed: index dim mismatch: got %d, want %d", idx.Dim, EmbedDim)
	}
	if idx.Entries != nil {
		s.entries = idx.Entries
	}
	return nil
}

func (s *Store) saveIndexLocked() error {
	idx := indexFile{Dim: EmbedDim, Entries: s.entries}
	bytes, err := json.MarshalIndent(idx, "", "  ")
	if err != nil {
		return fmt.Errorf("audioembed: marshal index: %w", err)
	}
	tmp := s.indexPath() + ".tmp"
	if err := os.WriteFile(tmp, bytes, 0o644); err != nil {
		return fmt.Errorf("audioembed: write index tmp: %w", err)
	}
	if err := os.Rename(tmp, s.indexPath()); err != nil {
		return fmt.Errorf("audioembed: rename index: %w", err)
	}
	return nil
}

// Get returns the stored embedding for trackID, if any.
func (s *Store) Get(trackID string) (Embedding, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.entries[trackID]
	if !ok {
		return Embedding{}, false, nil
	}
	vec, err := s.readVectorAtLocked(entry.Row)
	if err != nil {
		return Embedding{}, false, err
	}
	return Embedding{
		Vector:     vec,
		Version:    entry.Version,
		AnalysedAt: time.Unix(entry.AnalysedAt, 0).UTC(),
	}, true, nil
}

// Put stores (or replaces) the embedding for trackID.
func (s *Store) Put(trackID string, e Embedding) error {
	if len(e.Vector) != EmbedDim {
		return fmt.Errorf("audioembed: vector dim %d, want %d", len(e.Vector), EmbedDim)
	}
	if trackID == "" {
		return fmt.Errorf("audioembed: empty trackID")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	row := s.nextRow
	if err := s.appendVectorLocked(e.Vector); err != nil {
		return err
	}
	s.nextRow++

	ts := e.AnalysedAt
	if ts.IsZero() {
		ts = time.Now().UTC()
	}
	s.entries[trackID] = indexEntry{
		Row:        row,
		Version:    e.Version,
		AnalysedAt: ts.Unix(),
	}
	return s.saveIndexLocked()
}

// Needs returns true if trackID has no embedding, or its stored version
// differs from currentVersion.
func (s *Store) Needs(trackID, currentVersion string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.entries[trackID]
	if !ok {
		return true
	}
	return entry.Version != currentVersion
}

// Count returns the number of tracks with a stored embedding.
func (s *Store) Count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.entries)
}

// Iterate calls fn for every stored embedding. Returning false from fn stops.
// Iteration order is not guaranteed.
func (s *Store) Iterate(fn func(trackID string, e Embedding) bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for trackID, entry := range s.entries {
		vec, err := s.readVectorAtLocked(entry.Row)
		if err != nil {
			return err
		}
		cont := fn(trackID, Embedding{
			Vector:     vec,
			Version:    entry.Version,
			AnalysedAt: time.Unix(entry.AnalysedAt, 0).UTC(),
		})
		if !cont {
			return nil
		}
	}
	return nil
}

func (s *Store) appendVectorLocked(vec []float32) error {
	f, err := os.OpenFile(s.binPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("audioembed: open bin: %w", err)
	}
	defer f.Close()
	buf := make([]byte, bytesPerVector)
	for i, v := range vec {
		binary.LittleEndian.PutUint32(buf[i*4:(i+1)*4], math.Float32bits(v))
	}
	if _, err := f.Write(buf); err != nil {
		return fmt.Errorf("audioembed: write bin: %w", err)
	}
	return nil
}

func (s *Store) readVectorAtLocked(row int64) ([]float32, error) {
	f, err := os.Open(s.binPath())
	if err != nil {
		return nil, fmt.Errorf("audioembed: open bin: %w", err)
	}
	defer f.Close()
	buf := make([]byte, bytesPerVector)
	if _, err := f.ReadAt(buf, row*bytesPerVector); err != nil {
		return nil, fmt.Errorf("audioembed: read row %d: %w", row, err)
	}
	vec := make([]float32, EmbedDim)
	for i := 0; i < EmbedDim; i++ {
		vec[i] = math.Float32frombits(binary.LittleEndian.Uint32(buf[i*4 : (i+1)*4]))
	}
	return vec, nil
}

// readFile exists only for tests that want to assert file presence without
// importing os in the test (keeps the test file lean). It is not exported.
func readFile(path string) ([]byte, error) { return os.ReadFile(path) }
