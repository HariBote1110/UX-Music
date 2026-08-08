package llamasrv

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestBuildGemmaPrompt_SimpleUserMessage(t *testing.T) {
	prompt := BuildGemmaPrompt("夜のドライブで聴きたい曲を選んで")
	wantStart := "<start_of_turn>user\n"
	wantEnd := "<end_of_turn>\n<start_of_turn>model\n"
	if !strings.HasPrefix(prompt, wantStart) {
		t.Errorf("prompt should start with %q, got %q", wantStart, prompt[:min(len(prompt), 30)])
	}
	if !strings.HasSuffix(prompt, wantEnd) {
		t.Errorf("prompt should end with %q, got %q", wantEnd, prompt[max(0, len(prompt)-30):])
	}
	if !strings.Contains(prompt, "夜のドライブで聴きたい曲を選んで") {
		t.Errorf("prompt should contain user message")
	}
}

func TestComplete_PostsToCompletionEndpoint(t *testing.T) {
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/completion" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"content":"hello world","tokens_predicted":5,"stopped_eos":true}`))
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	res, err := c.Complete(context.Background(), CompleteRequest{
		Prompt:    "test prompt",
		NPredict:  100,
		Temp:      0.7,
		StopWords: []string{"<end_of_turn>"},
	})
	if err != nil {
		t.Fatalf("Complete: %v", err)
	}
	if res.Content != "hello world" {
		t.Errorf("unexpected content: %q", res.Content)
	}
	if res.TokensPredicted != 5 {
		t.Errorf("unexpected tokens_predicted: %d", res.TokensPredicted)
	}
	if gotBody["prompt"] != "test prompt" {
		t.Errorf("prompt not forwarded: %v", gotBody["prompt"])
	}
	if gotBody["n_predict"] != float64(100) {
		t.Errorf("n_predict not forwarded: %v", gotBody["n_predict"])
	}
	stop, _ := gotBody["stop"].([]any)
	if len(stop) != 1 || stop[0] != "<end_of_turn>" {
		t.Errorf("stop not forwarded: %v", gotBody["stop"])
	}
}

func TestComplete_PropagatesHTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(500)
		_, _ = w.Write([]byte("internal error"))
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	_, err := c.Complete(context.Background(), CompleteRequest{Prompt: "x"})
	if err == nil {
		t.Fatal("expected error from 500")
	}
	if !strings.Contains(err.Error(), "500") {
		t.Errorf("error should mention 500: %v", err)
	}
}

func TestChat_FormatsAsGemmaTurn(t *testing.T) {
	var gotPrompt string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		gotPrompt, _ = body["prompt"].(string)
		_, _ = w.Write([]byte(`{"content":"答え"}`))
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	out, err := c.Chat(context.Background(), "質問", ChatOptions{NPredict: 50})
	if err != nil {
		t.Fatal(err)
	}
	if out != "答え" {
		t.Errorf("unexpected content: %q", out)
	}
	if !strings.Contains(gotPrompt, "<start_of_turn>user") || !strings.Contains(gotPrompt, "<start_of_turn>model") {
		t.Errorf("prompt not Gemma-formatted: %q", gotPrompt)
	}
	if !strings.Contains(gotPrompt, "質問") {
		t.Errorf("user message missing: %q", gotPrompt)
	}
}

func TestHealth_OkReturns200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			w.WriteHeader(200)
			return
		}
		w.WriteHeader(404)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	if err := c.Health(context.Background()); err != nil {
		t.Fatalf("Health: %v", err)
	}
}

func TestHealth_RejectsNon200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(503)
	}))
	defer srv.Close()

	c := NewClient(srv.URL)
	if err := c.Health(context.Background()); err == nil {
		t.Fatal("expected error for 503")
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
