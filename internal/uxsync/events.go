package uxsync

import (
	"sort"
	"strings"
	"time"
)

const minimumCountedPlayDurationMs int64 = 30000

type PlayEvent struct {
	EventID           string    `json:"eventId"`
	TrackID           string    `json:"trackId"`
	DeviceID          string    `json:"deviceId"`
	PlaybackSessionID string    `json:"playbackSessionId,omitempty"`
	DeviceSequence    int64     `json:"deviceSequence"`
	PlayedAt          time.Time `json:"playedAt"`
	CountedAt         time.Time `json:"countedAt,omitempty"`
	DurationPlayedMs  int64     `json:"durationPlayedMs"`
	Completed         bool      `json:"completed"`
}

type PlayCount struct {
	Count   int      `json:"count"`
	History []string `json:"history"`
}

type EventAck struct {
	DeviceID          string   `json:"deviceId"`
	MaxDeviceSequence int64    `json:"maxDeviceSequence,omitempty"`
	AckedEventIDs     []string `json:"ackedEventIds,omitempty"`
}

func MergePlayEvents(existing, incoming []PlayEvent) []PlayEvent {
	merged := make([]PlayEvent, 0, len(existing)+len(incoming))
	seen := map[string]bool{}

	add := func(event PlayEvent) {
		key := eventIdentity(event)
		if key == "" {
			merged = append(merged, event)
			return
		}
		if seen[key] {
			return
		}
		seen[key] = true
		merged = append(merged, event)
	}

	for _, event := range existing {
		add(event)
	}
	for _, event := range incoming {
		add(event)
	}

	sort.SliceStable(merged, func(i, j int) bool {
		if merged[i].PlayedAt.Equal(merged[j].PlayedAt) {
			if merged[i].DeviceID == merged[j].DeviceID {
				return merged[i].DeviceSequence < merged[j].DeviceSequence
			}
			return merged[i].DeviceID < merged[j].DeviceID
		}
		return merged[i].PlayedAt.Before(merged[j].PlayedAt)
	})

	return merged
}

func PlayCountsByTrack(events []PlayEvent) map[string]PlayCount {
	counts := map[string]PlayCount{}
	for _, event := range MergePlayEvents(nil, events) {
		trackID := strings.TrimSpace(event.TrackID)
		if trackID == "" {
			continue
		}
		if !isCountedPlay(event) {
			if _, ok := counts[trackID]; !ok {
				counts[trackID] = PlayCount{}
			}
			continue
		}
		count := counts[trackID]
		count.Count++
		count.History = append(count.History, eventHistoryTime(event).Format(time.RFC3339))
		counts[trackID] = count
	}
	return counts
}

func PruneAcknowledgedOutbox(events []PlayEvent, ack EventAck) []PlayEvent {
	ackedIDs := map[string]bool{}
	for _, id := range ack.AckedEventIDs {
		id = strings.TrimSpace(id)
		if id != "" {
			ackedIDs[id] = true
		}
	}

	remaining := make([]PlayEvent, 0, len(events))
	for _, event := range events {
		if ack.DeviceID == event.DeviceID {
			if ack.MaxDeviceSequence > 0 && event.DeviceSequence > 0 && event.DeviceSequence <= ack.MaxDeviceSequence {
				continue
			}
			if ackedIDs[event.EventID] {
				continue
			}
		}
		remaining = append(remaining, event)
	}
	return remaining
}

func eventIdentity(event PlayEvent) string {
	if id := strings.TrimSpace(event.EventID); id != "" {
		return "event:" + id
	}
	if event.DeviceID != "" && event.DeviceSequence > 0 {
		return "device-sequence:" + event.DeviceID + ":" + formatInt64(event.DeviceSequence)
	}
	return ""
}

func isCountedPlay(event PlayEvent) bool {
	return event.Completed || event.DurationPlayedMs >= minimumCountedPlayDurationMs
}

func eventHistoryTime(event PlayEvent) time.Time {
	if !event.CountedAt.IsZero() {
		return event.CountedAt
	}
	return event.PlayedAt
}

func formatInt64(value int64) string {
	if value == 0 {
		return "0"
	}
	negative := value < 0
	if negative {
		value = -value
	}
	var digits [20]byte
	i := len(digits)
	for value > 0 {
		i--
		digits[i] = byte('0' + value%10)
		value /= 10
	}
	if negative {
		i--
		digits[i] = '-'
	}
	return string(digits[i:])
}
