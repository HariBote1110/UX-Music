package server

import (
	"net/http/httptest"
	"testing"

	"ux-music-sidecar/internal/youtube"
)

func TestBuildYouTubeResolveResponse(t *testing.T) {
	info := &youtube.YouTubeVideoInfo{
		ID:        "dQw4w9WgXcQ",
		Title:     "Sample Title",
		Author:    "Sample Channel",
		Duration:  212,
		Thumbnail: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
	}
	got := buildYouTubeResolveResponse(info)
	if got["videoId"] != "dQw4w9WgXcQ" {
		t.Fatalf("videoId: got %v", got["videoId"])
	}
	if got["title"] != "Sample Title" {
		t.Fatalf("title: got %v", got["title"])
	}
	if got["author"] != "Sample Channel" {
		t.Fatalf("author: got %v", got["author"])
	}
	if got["thumbnail"] != "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg" {
		t.Fatalf("thumbnail: got %v", got["thumbnail"])
	}
	if got["duration"] != 212 {
		t.Fatalf("duration: got %v", got["duration"])
	}
}

func TestRemoteYouTubeResolveHandlerRejectsMissingURL(t *testing.T) {
	req := httptest.NewRequest("GET", "/v1/remote/youtube/resolve", nil)
	rec := httptest.NewRecorder()
	remoteYouTubeResolveHandler(rec, req)
	if rec.Code != 400 {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestRemoteYouTubeResolveHandlerRejectsWrongMethod(t *testing.T) {
	req := httptest.NewRequest("POST", "/v1/remote/youtube/resolve?url=https://youtu.be/dQw4w9WgXcQ", nil)
	rec := httptest.NewRecorder()
	remoteYouTubeResolveHandler(rec, req)
	if rec.Code != 405 {
		t.Fatalf("expected 405, got %d", rec.Code)
	}
}

func TestRemoteYouTubeResolveHandlerRejectsInvalidURL(t *testing.T) {
	req := httptest.NewRequest("GET", "/v1/remote/youtube/resolve?url=not-a-youtube-link", nil)
	rec := httptest.NewRecorder()
	remoteYouTubeResolveHandler(rec, req)
	if rec.Code != 400 {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}
