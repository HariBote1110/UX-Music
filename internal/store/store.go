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

	path := s.GetPath(name)
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
