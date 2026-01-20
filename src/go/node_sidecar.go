package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"
)

// NodeSidecar manages a Node.js child process for specialized tasks
type NodeSidecar struct {
	cmd        *exec.Cmd
	stdin      io.WriteCloser
	stdout     io.ReadCloser
	stderr     io.ReadCloser
	mu         sync.Mutex
	pending    map[string]chan *SidecarResponse
	running    bool
	scriptPath string
}

// SidecarRequest represents a request sent to the Node.js sidecar
type SidecarRequest struct {
	ID      string      `json:"id"`
	Type    string      `json:"type"`
	Payload interface{} `json:"payload"`
}

// SidecarResponse represents a response from the Node.js sidecar
type SidecarResponse struct {
	ID      string          `json:"id"`
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
	Error   string          `json:"error,omitempty"`
}

// NewNodeSidecar creates a new sidecar manager for the given script
func NewNodeSidecar(scriptPath string) *NodeSidecar {
	return &NodeSidecar{
		scriptPath: scriptPath,
		pending:    make(map[string]chan *SidecarResponse),
	}
}

// Start launches the Node.js process
func (s *NodeSidecar) Start() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.running {
		return nil // Already running
	}

	s.cmd = exec.Command("node", s.scriptPath)

	var err error
	s.stdin, err = s.cmd.StdinPipe()
	if err != nil {
		return fmt.Errorf("failed to get stdin pipe: %w", err)
	}

	s.stdout, err = s.cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("failed to get stdout pipe: %w", err)
	}

	s.stderr, err = s.cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("failed to get stderr pipe: %w", err)
	}

	if err := s.cmd.Start(); err != nil {
		return fmt.Errorf("failed to start node sidecar: %w", err)
	}

	s.running = true
	s.pending = make(map[string]chan *SidecarResponse)

	// Start reading stdout for responses
	go s.readResponses()

	// Forward stderr to Go's stderr
	go s.forwardStderr()

	fmt.Fprintf(os.Stderr, "[NodeSidecar] Started: %s\n", s.scriptPath)
	return nil
}

// Stop terminates the Node.js process
func (s *NodeSidecar) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.running {
		return nil
	}

	// Close stdin to signal EOF to the child
	if s.stdin != nil {
		s.stdin.Close()
	}

	// Wait for process to exit with timeout
	done := make(chan error, 1)
	go func() {
		done <- s.cmd.Wait()
	}()

	select {
	case <-done:
		// Process exited
	case <-time.After(5 * time.Second):
		// Force kill if not exited
		s.cmd.Process.Kill()
	}

	s.running = false
	fmt.Fprintf(os.Stderr, "[NodeSidecar] Stopped: %s\n", s.scriptPath)
	return nil
}

// Invoke sends a request and waits for a response
func (s *NodeSidecar) Invoke(reqType string, payload interface{}) (*SidecarResponse, error) {
	s.mu.Lock()
	if !s.running {
		s.mu.Unlock()
		return nil, fmt.Errorf("sidecar not running")
	}

	// Generate unique request ID
	id := fmt.Sprintf("%d", time.Now().UnixNano())
	respChan := make(chan *SidecarResponse, 1)
	s.pending[id] = respChan
	s.mu.Unlock()

	defer func() {
		s.mu.Lock()
		delete(s.pending, id)
		s.mu.Unlock()
	}()

	// Send request
	req := SidecarRequest{
		ID:      id,
		Type:    reqType,
		Payload: payload,
	}

	data, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	s.mu.Lock()
	_, err = fmt.Fprintln(s.stdin, string(data))
	s.mu.Unlock()

	if err != nil {
		return nil, fmt.Errorf("failed to write to sidecar: %w", err)
	}

	// Wait for response with timeout
	select {
	case resp := <-respChan:
		return resp, nil
	case <-time.After(60 * time.Second):
		return nil, fmt.Errorf("sidecar request timeout")
	}
}

// readResponses reads JSON lines from stdout and dispatches to pending requests
func (s *NodeSidecar) readResponses() {
	scanner := bufio.NewScanner(s.stdout)
	// Increase buffer size for large responses
	buf := make([]byte, 0, 64*1024)
	scanner.Buffer(buf, 1024*1024)

	for scanner.Scan() {
		line := scanner.Text()

		var resp SidecarResponse
		if err := json.Unmarshal([]byte(line), &resp); err != nil {
			fmt.Fprintf(os.Stderr, "[NodeSidecar] Invalid JSON response: %v\n", err)
			continue
		}

		s.mu.Lock()
		if ch, ok := s.pending[resp.ID]; ok {
			ch <- &resp
		}
		s.mu.Unlock()
	}

	if err := scanner.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "[NodeSidecar] Read error: %v\n", err)
	}
}

// forwardStderr forwards the child's stderr to Go's stderr
func (s *NodeSidecar) forwardStderr() {
	scanner := bufio.NewScanner(s.stderr)
	for scanner.Scan() {
		fmt.Fprintf(os.Stderr, "[NodeSidecar:stderr] %s\n", scanner.Text())
	}
}

// IsRunning returns whether the sidecar is currently running
func (s *NodeSidecar) IsRunning() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.running
}
