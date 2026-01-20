package main

import "sync"

type AppConfig struct {
	UserDataPath string
	mu           sync.RWMutex
}

var config = AppConfig{}

func (c *AppConfig) SetUserDataPath(path string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.UserDataPath = path
}

func (c *AppConfig) GetUserDataPath() string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.UserDataPath
}
