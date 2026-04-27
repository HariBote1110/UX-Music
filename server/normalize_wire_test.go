package server

import (
	"encoding/json"
	"strings"
	"testing"

	"ux-music-sidecar/pkg/normalize"
)

type wailsLikeFile struct {
	ID   string  `json:"id"`
	Path string  `json:"path"`
	Gain float64 `json:"gain"`
}

func TestCoerceJSONMapFromStruct(t *testing.T) {
	in := wailsLikeFile{ID: "u1", Path: "/Music/a.flac", Gain: -3.25}
	m, ok := coerceJSONMap(interface{}(in))
	if !ok {
		t.Fatalf("coerceJSONMap(struct) = false")
	}
	if m["id"] != "u1" || m["path"] != "/Music/a.flac" {
		t.Fatalf("coerceJSONMap(struct) = %#v", m)
	}
}

func TestNormaliseJobFromPayloadUsesFilePathAlias(t *testing.T) {
	opts := normalizeStartOptions{Output: normalize.OutputSettings{Mode: "overwrite"}}
	m := map[string]interface{}{
		"id":       "row-1",
		"filePath": "/data/track.wav",
		"gain":     float64(1.5),
	}
	job, ok := normaliseJobFromPayload(m, opts)
	if !ok {
		t.Fatalf("normaliseJobFromPayload = false")
	}
	if job.FilePath != "/data/track.wav" || job.Gain != 1.5 || job.ID != "row-1" {
		t.Fatalf("job = %#v", job)
	}
}

func TestNormaliseJobFromPayloadGainAsJSONNumber(t *testing.T) {
	const raw = `{"id":"a","path":"/x.flac","gain":-2.25}`
	dec := json.NewDecoder(strings.NewReader(raw))
	dec.UseNumber()
	var m map[string]interface{}
	if err := dec.Decode(&m); err != nil {
		t.Fatal(err)
	}
	opts := normalizeStartOptions{}
	job, ok := normaliseJobFromPayload(m, opts)
	if !ok {
		t.Fatalf("normaliseJobFromPayload = false")
	}
	if job.Gain != -2.25 {
		t.Fatalf("Gain = %v, want -2.25", job.Gain)
	}
}

func TestNormaliseJobFromPayloadRejectsEmptyPath(t *testing.T) {
	opts := normalizeStartOptions{}
	_, ok := normaliseJobFromPayload(map[string]interface{}{
		"id": "x", "path": "  ",
	}, opts)
	if ok {
		t.Fatalf("expected reject empty path")
	}
}
