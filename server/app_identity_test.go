package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// containsRole reports whether roles contains want. Shared by mode-related tests.
func containsRole(roles []string, want string) bool {
	for _, r := range roles {
		if r == want {
			return true
		}
	}
	return false
}

func TestIdentityHandlerReportsHeadlessRole(t *testing.T) {
	newTempSyncStore(t)
	original := CurrentServerMode()
	defer SetServerMode(original)
	SetServerMode(ModeHeadless)

	handler := NewLANHTTPHandler(NewApp())
	req := httptest.NewRequest(http.MethodGet, "/v1/identity", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	var resp identityResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode identity response: %v", err)
	}
	if !containsRole(resp.Roles, "headless") {
		t.Fatalf("expected roles to contain headless, got %#v", resp.Roles)
	}
	if containsRole(resp.Roles, "gui") {
		t.Fatalf("did not expect gui role while in headless mode, got %#v", resp.Roles)
	}
}

func TestIdentityHandlerReportsGUIRole(t *testing.T) {
	newTempSyncStore(t)
	original := CurrentServerMode()
	defer SetServerMode(original)
	SetServerMode(ModeGUI)

	handler := NewLANHTTPHandler(NewApp())
	req := httptest.NewRequest(http.MethodGet, "/v1/identity", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	var resp identityResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode identity response: %v", err)
	}
	if !containsRole(resp.Roles, "gui") {
		t.Fatalf("expected roles to contain gui, got %#v", resp.Roles)
	}
	if containsRole(resp.Roles, "headless") {
		t.Fatalf("did not expect headless role while in gui mode, got %#v", resp.Roles)
	}
}
