package server

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// buildEmbedPageHTML: 動画 ID の検証と HTML 生成の純粋ロジック。
func TestBuildEmbedPageHTMLValidID(t *testing.T) {
	html, err := buildEmbedPageHTML("jNQXAC9IVRw")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, want := range []string{
		"jNQXAC9IVRw",
		"https://www.youtube.com/iframe_api",
		"postMessage",
		"ux-embed",
	} {
		if !strings.Contains(html, want) {
			t.Errorf("html should contain %q", want)
		}
	}
}

func TestBuildEmbedPageHTMLRejectsInvalidIDs(t *testing.T) {
	for _, id := range []string{
		"",
		"short",
		"toolongvideoid",
		"<script>bad",
		"abc def ghi",
		`abcdefghij"`,
	} {
		if _, err := buildEmbedPageHTML(id); err == nil {
			t.Errorf("id %q should be rejected", id)
		}
	}
}

// /embed ハンドラー: 正常系は text/html、動画 ID 不正は 400。
func TestEmbedHostHandler(t *testing.T) {
	handler := newEmbedHostHandler()

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/embed?v=jNQXAC9IVRw", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Errorf("content-type = %q, want text/html", ct)
	}
	body, _ := io.ReadAll(rec.Body)
	if !strings.Contains(string(body), "jNQXAC9IVRw") {
		t.Errorf("body should contain the video id")
	}

	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/embed?v=<script>", nil))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("invalid id status = %d, want 400", rec.Code)
	}

	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/other", nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("unknown path status = %d, want 404", rec.Code)
	}
}

// embedHostPageURL: 127.0.0.1 のループバック URL を構築する。
func TestEmbedHostPageURL(t *testing.T) {
	got := embedHostPageURL(43210, "jNQXAC9IVRw")
	want := "http://127.0.0.1:43210/embed?v=jNQXAC9IVRw"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}
