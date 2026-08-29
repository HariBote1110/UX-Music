package diagnostics

import "testing"

// TestResolvePprofAddr covers the loopback-only allowlist used to gate the
// diagnostics-only net/http/pprof server. Anything that is not explicitly a
// 127.0.0.1 or localhost host must be refused so UXMUSIC_PPROF can never be
// used to expose profiling data on a LAN-reachable interface.
func TestResolvePprofAddr(t *testing.T) {
	tests := []struct {
		name    string
		env     string
		wantOK  bool
		wantVal string
	}{
		{name: "empty is disabled", env: "", wantOK: false},
		{name: "127.0.0.1 with port", env: "127.0.0.1:6060", wantOK: true, wantVal: "127.0.0.1:6060"},
		{name: "localhost with port", env: "localhost:6060", wantOK: true, wantVal: "localhost:6060"},
		{name: "IPv6 loopback with port", env: "[::1]:6060", wantOK: true, wantVal: "[::1]:6060"},
		{name: "wildcard host refused", env: "0.0.0.0:6060", wantOK: false},
		{name: "all interfaces shorthand refused", env: ":6060", wantOK: false},
		{name: "non-loopback host refused", env: "192.168.1.5:6060", wantOK: false},
		{name: "missing port refused", env: "127.0.0.1", wantOK: false},
		{name: "garbage refused", env: "not-an-address", wantOK: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotVal, gotOK := ResolvePprofAddr(tt.env)
			if gotOK != tt.wantOK {
				t.Fatalf("ResolvePprofAddr(%q) ok = %v, want %v", tt.env, gotOK, tt.wantOK)
			}
			if gotOK && gotVal != tt.wantVal {
				t.Fatalf("ResolvePprofAddr(%q) = %q, want %q", tt.env, gotVal, tt.wantVal)
			}
		})
	}
}
