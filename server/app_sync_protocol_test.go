package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestIdentityIncludesSchemaCapabilitiesAndNegotiation(t *testing.T) {
	newTempSyncStore(t)
	req := httptest.NewRequest(http.MethodGet, "/v1/identity", nil)
	req.Header.Set(syncProtocolVersionHeader, "1.0")
	req.Header.Set(syncCapabilitiesHeader, "library.snapshot.v1,library.import.v1,unknown.future.v1")
	rec := httptest.NewRecorder()

	identityHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	var response identityResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode identity: %v", err)
	}
	// ここはデバイス間で交換されるワイヤ契約なので、定数ではなくリテラルで固定する。
	// 定数と突き合わせると本番側を書き換えてもテストが追随してしまい、互換性を
	// 壊す変更を検出できない。ワイヤバージョンを上げるときは、この期待値を
	// 意図的に書き換えること（＝ピア側の対応が必要という合図）。
	if response.ProtocolVersion != "1.0" {
		t.Fatalf("advertised protocolVersion must stay %q until the wire contract is bumped, got %q", "1.0", response.ProtocolVersion)
	}
	if response.SchemaVersion != "2026-06-09" {
		t.Fatalf("advertised schemaVersion must stay %q until the wire contract is bumped, got %q", "2026-06-09", response.SchemaVersion)
	}
	if response.MinCompatibleProtocolVersion != "1.0" {
		t.Fatalf("advertised minCompatibleProtocolVersion must stay %q until the wire contract is bumped, got %q", "1.0", response.MinCompatibleProtocolVersion)
	}
	if !stringSliceContains(response.Capabilities, "library.import.v1") {
		t.Fatalf("identity should advertise import capability: %#v", response.Capabilities)
	}
	if !response.Negotiation.Compatible || response.Negotiation.RequestedProtocolVersion != "1.0" {
		t.Fatalf("expected compatible negotiation for 1.0 peer: %#v", response.Negotiation)
	}
	if !stringSliceContains(response.Negotiation.AcceptedCapabilities, "library.import.v1") {
		t.Fatalf("expected shared capability to be accepted: %#v", response.Negotiation)
	}
	if stringSliceContains(response.Negotiation.AcceptedCapabilities, "unknown.future.v1") {
		t.Fatalf("unknown capabilities should not be accepted: %#v", response.Negotiation)
	}
}

func TestFetchSyncIdentitySendsProtocolNegotiationHeaders(t *testing.T) {
	newTempSyncStore(t)
	var observedVersion string
	var observedCapabilities string
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		observedVersion = r.Header.Get(syncProtocolVersionHeader)
		observedCapabilities = r.Header.Get(syncCapabilitiesHeader)
		writeJSON(w, syncIdentityResponse{
			DeviceID:        "dev_remote",
			DisplayName:     "Remote",
			ProtocolVersion: syncProtocolVersion,
			SchemaVersion:   syncSchemaVersion,
		})
	}))
	defer remote.Close()

	identity, err := fetchSyncIdentity(context.Background(), remote.URL)
	if err != nil {
		t.Fatalf("fetch identity: %v", err)
	}
	if identity.DeviceID != "dev_remote" {
		t.Fatalf("unexpected identity: %#v", identity)
	}
	if observedVersion != syncProtocolVersion {
		t.Fatalf("expected protocol version header %q, got %q", syncProtocolVersion, observedVersion)
	}
	if !containsCSVToken(observedCapabilities, "library.import.v1") {
		t.Fatalf("expected capabilities header to include import support, got %q", observedCapabilities)
	}
}

func TestFetchSyncIdentityRejectsIncompatibleProtocolMajor(t *testing.T) {
	newTempSyncStore(t)
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, syncIdentityResponse{
			DeviceID:        "dev_future",
			DisplayName:     "Future Device",
			ProtocolVersion: "2.0",
			SchemaVersion:   "2099-01-01",
		})
	}))
	defer remote.Close()

	if _, err := fetchSyncIdentity(context.Background(), remote.URL); err == nil {
		t.Fatal("expected incompatible protocol major to be rejected")
	}
}
