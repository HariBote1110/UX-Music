// Package llamasrv talks to a llama.cpp `llama-server` process.
//
// Two pieces:
//   - Client: HTTP client for the /completion and /health endpoints.
//   - Server: lifecycle wrapper that spawns `llama-server` on demand.
//
// We use /completion + an explicit Gemma chat template rather than
// /v1/chat/completions because llama-server 9700 returned empty content for
// Gemma 4 GGUFs through the OpenAI-compatible endpoint, with and without
// --jinja.  /completion is the stable contract for now.
package llamasrv

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const gemmaEndOfTurn = "<end_of_turn>"

// BuildGemmaPrompt wraps a single user message in Gemma's chat template:
//
//	<start_of_turn>user
//	{message}<end_of_turn>
//	<start_of_turn>model
func BuildGemmaPrompt(userMessage string) string {
	var b strings.Builder
	b.WriteString("<start_of_turn>user\n")
	b.WriteString(userMessage)
	b.WriteString(gemmaEndOfTurn)
	b.WriteString("\n<start_of_turn>model\n")
	return b.String()
}

// CompleteRequest is the payload posted to /completion. Fields with zero values
// are omitted so server defaults apply.
type CompleteRequest struct {
	Prompt    string   `json:"prompt"`
	NPredict  int      `json:"n_predict,omitempty"`
	Temp      float64  `json:"temperature,omitempty"`
	TopP      float64  `json:"top_p,omitempty"`
	StopWords []string `json:"stop,omitempty"`
	Seed      int      `json:"seed,omitempty"`
}

// CompleteResult mirrors the subset of /completion's JSON response we use.
type CompleteResult struct {
	Content         string `json:"content"`
	TokensPredicted int    `json:"tokens_predicted"`
	StoppedEOS      bool   `json:"stopped_eos"`
	StoppedWord     bool   `json:"stopped_word"`
	StoppingWord    string `json:"stopping_word"`
	Timings         struct {
		PredictedPerSecond float64 `json:"predicted_per_second"`
		PredictedMS        float64 `json:"predicted_ms"`
	} `json:"timings"`
}

// ChatOptions are knobs for Client.Chat.
type ChatOptions struct {
	NPredict int
	Temp     float64
	TopP     float64
}

// Client is a small HTTP client for a running llama-server.
type Client struct {
	baseURL string
	http    *http.Client
}

// NewClient returns a Client bound to baseURL (e.g. http://127.0.0.1:18080).
func NewClient(baseURL string) *Client {
	return &Client{
		baseURL: strings.TrimRight(baseURL, "/"),
		http: &http.Client{
			// Generation can take a while for long outputs.
			Timeout: 5 * time.Minute,
		},
	}
}

// Complete posts to /completion and returns the parsed result.
func (c *Client) Complete(ctx context.Context, req CompleteRequest) (CompleteResult, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return CompleteResult{}, fmt.Errorf("llamasrv: marshal request: %w", err)
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/completion", bytes.NewReader(body))
	if err != nil {
		return CompleteResult{}, fmt.Errorf("llamasrv: build request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return CompleteResult{}, fmt.Errorf("llamasrv: POST /completion: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode/100 != 2 {
		raw, _ := io.ReadAll(resp.Body)
		return CompleteResult{}, fmt.Errorf("llamasrv: %d from /completion: %s", resp.StatusCode, truncate(string(raw), 200))
	}

	var out CompleteResult
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return CompleteResult{}, fmt.Errorf("llamasrv: decode /completion: %w", err)
	}
	return out, nil
}

// Chat sends one user message wrapped in Gemma's chat template, stops at the
// next <end_of_turn>, and returns the assistant content.
func (c *Client) Chat(ctx context.Context, userMessage string, opts ChatOptions) (string, error) {
	req := CompleteRequest{
		Prompt:    BuildGemmaPrompt(userMessage),
		NPredict:  opts.NPredict,
		Temp:      opts.Temp,
		TopP:      opts.TopP,
		StopWords: []string{gemmaEndOfTurn},
	}
	res, err := c.Complete(ctx, req)
	if err != nil {
		return "", err
	}
	return res.Content, nil
}

// Health hits /health and expects a 2xx response.
func (c *Client) Health(ctx context.Context) error {
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+"/health", nil)
	if err != nil {
		return err
	}
	resp, err := c.http.Do(httpReq)
	if err != nil {
		return fmt.Errorf("llamasrv: GET /health: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("llamasrv: /health returned %d", resp.StatusCode)
	}
	return nil
}

// BaseURL returns the configured base URL (read-only).
func (c *Client) BaseURL() string { return c.baseURL }

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
