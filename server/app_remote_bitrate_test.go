package server

import "testing"

func TestNormaliseAACBitrateKbps_ValidValuesPassThrough(t *testing.T) {
	for _, want := range []int{128, 192, 256, 320} {
		if got := normaliseAACBitrateKbps(want); got != want {
			t.Fatalf("normaliseAACBitrateKbps(%d) = %d, want %d", want, got, want)
		}
	}
}

func TestNormaliseAACBitrateKbps_InvalidValuesClampToDefault(t *testing.T) {
	for _, bad := range []int{0, -1, 64, 100, 200, 999} {
		if got := normaliseAACBitrateKbps(bad); got != defaultAACBitrateKbps {
			t.Fatalf("normaliseAACBitrateKbps(%d) = %d, want default %d", bad, got, defaultAACBitrateKbps)
		}
	}
}

func TestParseAACBitrateQueryParam_MissingOrInvalidDefaults(t *testing.T) {
	cases := []string{"", "abc", "0", "-5", "100"}
	for _, raw := range cases {
		if got := parseAACBitrateQueryParam(raw); got != defaultAACBitrateKbps {
			t.Fatalf("parseAACBitrateQueryParam(%q) = %d, want default %d", raw, got, defaultAACBitrateKbps)
		}
	}
}

func TestParseAACBitrateQueryParam_ValidValues(t *testing.T) {
	cases := map[string]int{"128": 128, "192": 192, "256": 256, "320": 320}
	for raw, want := range cases {
		if got := parseAACBitrateQueryParam(raw); got != want {
			t.Fatalf("parseAACBitrateQueryParam(%q) = %d, want %d", raw, got, want)
		}
	}
}

func TestRemoteTranscodeCacheStem_IncludesBitrateSuffixExceptLegacy128(t *testing.T) {
	stem192 := remoteTranscodeCacheStem("song-1", 192)
	stem256 := remoteTranscodeCacheStem("song-1", 256)
	if stem192 == stem256 {
		t.Fatalf("cache stems for different bitrates must differ: %q == %q", stem192, stem256)
	}
	legacyStem := remoteLegacyTranscodeCacheStem("song-1")
	stem128 := remoteTranscodeCacheStem("song-1", 128)
	if stem128 == legacyStem {
		t.Fatalf("128 kbps cache stem must use the new suffixed name, not the legacy name: %q", stem128)
	}
	if stem192 == legacyStem {
		t.Fatalf("192 kbps cache stem must not collide with legacy 128 kbps name: %q", stem192)
	}
}
