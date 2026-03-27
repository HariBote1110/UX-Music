package lyricssync

import "testing"

func TestParseWhisperJSONSegments(t *testing.T) {
	raw := []byte(`{
	  "segments": [
	    { "start": 0.5, "end": 1.2, "text": "hello" },
	    { "t0": 150, "t1": 240, "text": "world" }
	  ]
	}`)

	segments, err := parseWhisperJSON(raw)
	if err != nil {
		t.Fatalf("parseWhisperJSON returned error: %v", err)
	}
	if len(segments) != 2 {
		t.Fatalf("len(segments)=%d, want 2", len(segments))
	}
	if segments[0].Start != 0.5 || segments[0].End != 1.2 {
		t.Fatalf("unexpected first segment: %+v", segments[0])
	}
	if segments[1].Start != 1.5 || segments[1].End != 2.4 {
		t.Fatalf("unexpected second segment: %+v", segments[1])
	}
}

func TestParseWhisperJSONTranscription(t *testing.T) {
	raw := []byte(`{
	  "transcription": [
	    {
	      "timestamps": { "from": "00:00:00,000", "to": "00:00:02,500" },
	      "offsets": { "from": 0, "to": 2500 },
	      "text": "line one"
	    },
	    {
	      "timestamps": { "from": "00:00:02,500", "to": "00:00:04,000" },
	      "offsets": { "from": 2500, "to": 4000 },
	      "text": "line two"
	    }
	  ]
	}`)

	segments, err := parseWhisperJSON(raw)
	if err != nil {
		t.Fatalf("parseWhisperJSON returned error: %v", err)
	}
	if len(segments) != 2 {
		t.Fatalf("len(segments)=%d, want 2", len(segments))
	}
	if segments[0].Start != 0 || segments[0].End != 2.5 {
		t.Fatalf("unexpected first transcription segment: %+v", segments[0])
	}
	if segments[1].Start != 2.5 || segments[1].End != 4.0 {
		t.Fatalf("unexpected second transcription segment: %+v", segments[1])
	}
}

func TestParseTimestampString(t *testing.T) {
	got, ok := parseTimestampString("00:01:02,345")
	if !ok {
		t.Fatalf("parseTimestampString should parse valid input")
	}
	want := 62.345
	if got != want {
		t.Fatalf("got=%f want=%f", got, want)
	}
}
