package server

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"ux-music-sidecar/pkg/normalize"
)

// coerceJSONMap turns arbitrary Wails/JSON payloads into a string-keyed map.
func coerceJSONMap(v interface{}) (map[string]interface{}, bool) {
	if v == nil {
		return nil, false
	}
	if m, ok := v.(map[string]interface{}); ok {
		return m, true
	}
	b, err := json.Marshal(v)
	if err != nil {
		return nil, false
	}
	var out map[string]interface{}
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, false
	}
	return out, true
}

func stringField(m map[string]interface{}, key string) (string, bool) {
	raw, ok := m[key]
	if !ok || raw == nil {
		return "", false
	}
	switch s := raw.(type) {
	case string:
		return s, true
	case json.Number:
		return s.String(), true
	default:
		return "", false
	}
}

func audioPathFromMap(m map[string]interface{}) (string, bool) {
	if p, ok := stringField(m, "path"); ok && strings.TrimSpace(p) != "" {
		return strings.TrimSpace(p), true
	}
	if p, ok := stringField(m, "filePath"); ok && strings.TrimSpace(p) != "" {
		return strings.TrimSpace(p), true
	}
	return "", false
}

func float64Field(m map[string]interface{}, key string) (float64, bool) {
	raw, ok := m[key]
	if !ok || raw == nil {
		return 0, false
	}
	switch x := raw.(type) {
	case float64:
		return x, true
	case float32:
		return float64(x), true
	case int:
		return float64(x), true
	case int64:
		return float64(x), true
	case uint64:
		return float64(x), true
	case json.Number:
		f, err := x.Float64()
		if err != nil {
			return 0, false
		}
		return f, true
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(x), 64)
		if err != nil {
			return 0, false
		}
		return f, true
	default:
		return 0, false
	}
}

func boolField(m map[string]interface{}, key string) (bool, bool) {
	raw, ok := m[key]
	if !ok {
		return false, false
	}
	b, ok := raw.(bool)
	return b, ok
}

func idStringFromMap(m map[string]interface{}) string {
	if s, ok := stringField(m, "id"); ok {
		return strings.TrimSpace(s)
	}
	if f, ok := float64Field(m, "id"); ok {
		return strings.TrimSpace(fmt.Sprintf("%.0f", f))
	}
	return ""
}

func normaliseJobFromPayload(f interface{}, parsed normalizeStartOptions) (normalize.NormalizeJob, bool) {
	m, ok := coerceJSONMap(f)
	if !ok {
		return normalize.NormalizeJob{}, false
	}
	path, ok := audioPathFromMap(m)
	if !ok {
		return normalize.NormalizeJob{}, false
	}
	id := idStringFromMap(m)
	gain, _ := float64Field(m, "gain")

	backup := parsed.Backup
	if b, ok := boolField(m, "backup"); ok {
		backup = b
	}
	basePath := parsed.BasePath
	if bp, ok := stringField(m, "basePath"); ok && strings.TrimSpace(bp) != "" {
		basePath = strings.TrimSpace(bp)
	}

	return normalize.NormalizeJob{
		ID:       id,
		FilePath: path,
		Gain:     gain,
		Backup:   backup,
		Output:   parsed.Output,
		BasePath: basePath,
	}, true
}
