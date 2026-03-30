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
