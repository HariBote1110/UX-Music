package server

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestNewLANHTTPHandlerIncludesSyncIdentity(t *testing.T) {
	newTempSyncStore(t)
	handler := NewLANHTTPHandler(NewApp())
	req := httptest.NewRequest(http.MethodGet, "/sync/identity", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected sync identity to be registered, got %d: %s", rec.Code, rec.Body.String())
	}
}
