package uxsync

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"strings"
	"time"
)

type PairingSession struct {
	DeviceID  string    `json:"deviceId"`
	Code      string    `json:"code"`
	CreatedAt time.Time `json:"createdAt"`
	ExpiresAt time.Time `json:"expiresAt"`
}

func PairingCode(sharedSecret []byte) string {
	sum := sha256.Sum256(sharedSecret)
	number := binary.BigEndian.Uint32(sum[:4]) % 1000000
	return fmt.Sprintf("%06d", number)
}

func NewPairingSession(deviceID string, sharedSecret []byte, now time.Time, ttl time.Duration) PairingSession {
	if ttl <= 0 {
		ttl = 2 * time.Minute
	}
	return PairingSession{
		DeviceID:  strings.TrimSpace(deviceID),
		Code:      PairingCode(sharedSecret),
		CreatedAt: now,
		ExpiresAt: now.Add(ttl),
	}
}

func (s PairingSession) IsExpired(now time.Time) bool {
	return !now.Before(s.ExpiresAt)
}
