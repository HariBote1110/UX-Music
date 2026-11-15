package store

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"ux-music-sidecar/internal/config"
)

type Store struct {
	mu  sync.Mutex
	mem map[string]interface{} // in-memory cache for Load; invalidated on Save
}

var Instance = &Store{}

func (s *Store) GetPath(name string) string {
	return filepath.Join(config.GetUserDataPath(), name+".json")
}

func (s *Store) Load(name string) (interface{}, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.loadLocked(name)
}

// loadLocked is Load for callers that already hold s.mu.
func (s *Store) loadLocked(name string) (interface{}, error) {
	if s.mem != nil {
		if data, ok := s.mem[name]; ok {
			return data, nil
		}
	}

	path := s.GetPath(name)
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil, nil
	}

	bytes, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read store file: %w", err)
	}

	if len(bytes) == 0 {
		return nil, nil
	}

	var data interface{}
	if err := json.Unmarshal(bytes, &data); err != nil {
		return nil, fmt.Errorf("failed to unmarshal json: %w", err)
	}
	if s.mem == nil {
		s.mem = make(map[string]interface{})
	}
	s.mem[name] = data
	return data, nil
}

// LoadSlice loads `name` and returns its contents as []interface{}.
// Missing or empty stores yield a non-nil empty slice; type mismatches return an error.
func (s *Store) LoadSlice(name string) ([]interface{}, error) {
	raw, err := s.Load(name)
	if err != nil {
		return nil, err
	}
	if raw == nil {
		return []interface{}{}, nil
	}
	arr, ok := raw.([]interface{})
	if !ok {
		return nil, fmt.Errorf("store %q: expected []interface{}, got %T", name, raw)
	}
	return arr, nil
}

// LoadMap loads `name` and returns its contents as map[string]interface{}.
// Missing or empty stores yield a non-nil empty map; type mismatches return an error.
func (s *Store) LoadMap(name string) (map[string]interface{}, error) {
	raw, err := s.Load(name)
	if err != nil {
		return nil, err
	}
	if raw == nil {
		return map[string]interface{}{}, nil
	}
	m, ok := raw.(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("store %q: expected map[string]interface{}, got %T", name, raw)
	}
	return m, nil
}

func (s *Store) Save(name string, data interface{}) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.saveLocked(name, data)
}

// saveLocked is Save for callers that already hold s.mu.
func (s *Store) saveLocked(name string, data interface{}) error {
	path := s.GetPath(name)
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return fmt.Errorf("failed to create store directory: %w", err)
	}
	bytes, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal json: %w", err)
	}

	if err := os.WriteFile(path, bytes, 0644); err != nil {
		return fmt.Errorf("failed to write store file: %w", err)
	}
	if s.mem != nil {
		delete(s.mem, name)
	}
	return nil
}

// UpdateMap performs a read-modify-write on the map stored under `name` while
// holding the store lock for the whole sequence, so concurrent updates cannot
// lose each other's changes. mutate receives a shallow copy of the stored map
// (an empty map when the store is missing or empty). The copy is saved only
// when mutate returns changed == true and a nil error; otherwise nothing is
// written. A failed save leaves the cached value and the file untouched.
func (s *Store) UpdateMap(name string, mutate func(m map[string]interface{}) (changed bool, err error)) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	raw, err := s.loadLocked(name)
	if err != nil {
		return err
	}
	current := map[string]interface{}{}
	if raw != nil {
		m, ok := raw.(map[string]interface{})
		if !ok {
			return fmt.Errorf("store %q: expected map[string]interface{}, got %T", name, raw)
		}
		current = m
	}
	working := make(map[string]interface{}, len(current))
	for k, v := range current {
		working[k] = v
	}
	changed, err := mutate(working)
	if err != nil {
		return err
	}
	if !changed {
		return nil
	}
	return s.saveLocked(name, working)
}
