package main

import "testing"

func TestEnsureWearTrackOrder_AssignsSequentialByPathWhenAllTrackZero(t *testing.T) {
	songs := []map[string]interface{}{
		{"id": "z", "album": "LP", "title": "Zebra", "path": "/lib/02-z.flac", "trackNumber": 0, "discNumber": 0},
		{"id": "a", "album": "LP", "title": "Alpha", "path": "/lib/01-a.flac", "trackNumber": 0, "discNumber": 0},
	}
	ensureWearTrackOrder(songs)
	byID := map[string]map[string]interface{}{}
	for _, m := range songs {
		byID[wearStringField(m, "id")] = m
	}
	if wearIntField(byID["a"], "trackNumber") != 1 {
		t.Fatalf("want track 1 for 01-a, got %+v", byID["a"])
	}
	if wearIntField(byID["z"], "trackNumber") != 2 {
		t.Fatalf("want track 2 for 02-z, got %+v", byID["z"])
	}
	if wearIntField(byID["a"], "discNumber") != 1 || wearIntField(byID["z"], "discNumber") != 1 {
		t.Fatalf("want disc 1 for single-disc album, got a=%d z=%d",
			wearIntField(byID["a"], "discNumber"), wearIntField(byID["z"], "discNumber"))
	}
}

func TestEnsureWearTrackOrder_RespectsExistingTags(t *testing.T) {
	songs := []map[string]interface{}{
		{"id": "b", "album": "LP", "title": "B", "path": "/b.flac", "trackNumber": 2, "discNumber": 1},
		{"id": "a", "album": "LP", "title": "A", "path": "/a.flac", "trackNumber": 1, "discNumber": 1},
	}
	ensureWearTrackOrder(songs)
	if wearIntField(songs[0], "trackNumber") != 2 || wearIntField(songs[1], "trackNumber") != 1 {
		t.Fatalf("existing tags should be preserved: %+v", songs)
	}
}

func TestEnsureWearTrackOrder_JSONFloatTrackNumbers(t *testing.T) {
	songs := []map[string]interface{}{
		{"id": "x", "album": "LP", "title": "X", "path": "/x.flac", "trackNumber": float64(3), "discNumber": float64(1)},
	}
	ensureWearTrackOrder(songs)
	if wearIntField(songs[0], "trackNumber") != 3 {
		t.Fatalf("want 3, got %+v", songs[0]["trackNumber"])
	}
}
