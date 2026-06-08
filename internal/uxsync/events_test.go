package uxsync

import (
	"testing"
	"time"
)

func TestMergePlayEvents_deduplicatesResentEventID(t *testing.T) {
	playedAt := time.Date(2026, 6, 8, 12, 0, 0, 0, time.UTC)
	event := PlayEvent{
		EventID:          "evt_air_0001",
		TrackID:          "trk_1",
		DeviceID:         "macbook-air",
		DeviceSequence:   1,
		PlayedAt:         playedAt,
		CountedAt:        playedAt.Add(2 * time.Minute),
		DurationPlayedMs: 185000,
		Completed:        true,
	}

	merged := MergePlayEvents([]PlayEvent{event}, []PlayEvent{event})
	counts := PlayCountsByTrack(merged)

	if len(merged) != 1 {
		t.Fatalf("expected one unique event, got %d", len(merged))
	}
	if counts["trk_1"].Count != 1 {
		t.Fatalf("expected one counted play, got %d", counts["trk_1"].Count)
	}
}

func TestPlayCountsByTrack_countsConcurrentPlaysAsSeparateEvents(t *testing.T) {
	playedAt := time.Date(2026, 6, 8, 12, 0, 0, 0, time.UTC)
	events := []PlayEvent{
		{
			EventID:          "evt_mini_0001",
			TrackID:          "trk_1",
			DeviceID:         "mac-mini",
			DeviceSequence:   1,
			PlayedAt:         playedAt,
			CountedAt:        playedAt.Add(3 * time.Minute),
			DurationPlayedMs: 180000,
			Completed:        true,
		},
		{
			EventID:          "evt_air_0001",
			TrackID:          "trk_1",
			DeviceID:         "macbook-air",
			DeviceSequence:   1,
			PlayedAt:         playedAt.Add(30 * time.Second),
			CountedAt:        playedAt.Add(3 * time.Minute),
			DurationPlayedMs: 170000,
			Completed:        true,
		},
	}

	counts := PlayCountsByTrack(events)

	if counts["trk_1"].Count != 2 {
		t.Fatalf("expected both devices to count as independent plays, got %d", counts["trk_1"].Count)
	}
	if len(counts["trk_1"].History) != 2 {
		t.Fatalf("expected two history entries, got %d", len(counts["trk_1"].History))
	}
}

func TestPlayCountsByTrack_ignoresIncompleteShortPreview(t *testing.T) {
	events := []PlayEvent{
		{
			EventID:          "evt_air_preview",
			TrackID:          "trk_1",
			DeviceID:         "macbook-air",
			DeviceSequence:   1,
			PlayedAt:         time.Date(2026, 6, 8, 12, 0, 0, 0, time.UTC),
			DurationPlayedMs: 12000,
			Completed:        false,
		},
	}

	counts := PlayCountsByTrack(events)

	if counts["trk_1"].Count != 0 {
		t.Fatalf("expected short incomplete preview not to count, got %d", counts["trk_1"].Count)
	}
}

func TestPruneAcknowledgedOutbox_keepsOnlyUnacknowledgedEvents(t *testing.T) {
	events := []PlayEvent{
		{EventID: "evt_air_0001", DeviceID: "macbook-air", DeviceSequence: 1},
		{EventID: "evt_air_0002", DeviceID: "macbook-air", DeviceSequence: 2},
		{EventID: "evt_air_0003", DeviceID: "macbook-air", DeviceSequence: 3},
		{EventID: "evt_other_0001", DeviceID: "other", DeviceSequence: 1},
	}

	remaining := PruneAcknowledgedOutbox(events, EventAck{
		DeviceID:          "macbook-air",
		MaxDeviceSequence: 2,
		AckedEventIDs:     []string{"evt_air_0003"},
	})

	if len(remaining) != 1 {
		t.Fatalf("expected only other device event to remain, got %d: %#v", len(remaining), remaining)
	}
	if remaining[0].EventID != "evt_other_0001" {
		t.Fatalf("unexpected remaining event: %#v", remaining[0])
	}
}
