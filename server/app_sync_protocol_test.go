package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSyncIdentityIncludesSchemaCapabilitiesAndNegotiation(t *testing.T) {
	newTempSyncStore(t)
	req := httptest.NewRequest(http.MethodGet, "/sync/identity", nil)
	req.Header.Set(syncProtocolVersionHeader, "0.1")
	req.Header.Set(syncCapabilitiesHeader, "library.snapshot.v1,library.import.v1,unknown.future.v1")
	rec := httptest.NewRecorder()

	syncIdentityHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	var response syncIdentityResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode identity: %v", err)
	}
	// ここはデバイス間で交換されるワイヤ契約なので、定数ではなくリテラルで固定する。
	// 定数と突き合わせると本番側を書き換えてもテストが追随してしまい、互換性を
	// 壊す変更を検出できない。ワイヤバージョンを上げるときは、この期待値を
	// 意図的に書き換えること（＝ピア側の対応が必要という合図）。
	if response.ProtocolVersion != "0.2" {
		t.Fatalf("advertised protocolVersion must stay %q until the wire contract is bumped, got %q", "0.2", response.ProtocolVersion)
	}
	if response.SchemaVersion != "2026-06-09" {
		t.Fatalf("advertised schemaVersion must stay %q until the wire contract is bumped, got %q", "2026-06-09", response.SchemaVersion)
	}
	if response.MinCompatibleProtocolVersion != "0.1" {
		t.Fatalf("advertised minCompatibleProtocolVersion must stay %q until the wire contract is bumped, got %q", "0.1", response.MinCompatibleProtocolVersion)
	}
	if !stringSliceContains(response.Capabilities, "library.import.v1") {
		t.Fatalf("identity should advertise import capability: %#v", response.Capabilities)
	}
	if !response.Negotiation.Compatible || response.Negotiation.RequestedProtocolVersion != "0.1" {
		t.Fatalf("expected compatible negotiation for 0.1 peer: %#v", response.Negotiation)
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
			ProtocolVersion: "1.0",
			SchemaVersion:   "2099-01-01",
		})
	}))
	defer remote.Close()

	if _, err := fetchSyncIdentity(context.Background(), remote.URL); err == nil {
		t.Fatal("expected incompatible protocol major to be rejected")
	}
}

func TestSyncSchemaEndpointReturnsExtensibleContract(t *testing.T) {
	newTempSyncStore(t)
	req := httptest.NewRequest(http.MethodGet, "/sync/schema", nil)
	rec := httptest.NewRecorder()

	NewLANHTTPHandler(NewApp()).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	var schema syncProtocolSchemaDocument
	if err := json.Unmarshal(rec.Body.Bytes(), &schema); err != nil {
		t.Fatalf("decode schema: %v", err)
	}
	if schema.Protocol != syncProtocolName || schema.ProtocolVersion != syncProtocolVersion {
		t.Fatalf("unexpected protocol schema identity: %#v", schema)
	}
	if !stringSliceContains(schema.Capabilities, "library.import.v1") {
		t.Fatalf("schema should list import capability: %#v", schema.Capabilities)
	}
	if schema.Extensibility.UnknownFields != "ignore" || schema.Extensibility.ExtensionsField != "extensions" {
		t.Fatalf("schema should define forward-compatible extension rules: %#v", schema.Extensibility)
	}
	if len(schema.Endpoints) == 0 || len(schema.Messages) == 0 {
		t.Fatalf("schema should describe endpoints and messages: %#v", schema)
	}
}
