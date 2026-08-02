package server

import (
	"encoding/json"
	"sort"
	"strings"
)

// ensureRemoteTrackOrder fills missing per-disc track indices for /v1/remote/songs so mobile clients can sort
// albums consistently. When every track in an (album × disc) bucket has trackNumber 0, we order by
// path then title and assign 1..n (matching typical folder / rip order).
func ensureRemoteTrackOrder(songs []map[string]interface{}) {
	if len(songs) == 0 {
		return
	}
	byAlbum := make(map[string][]map[string]interface{})
	order := make([]string, 0)
	for _, m := range songs {
		key := remoteNormAlbumKey(m)
		if _, seen := byAlbum[key]; !seen {
			order = append(order, key)
		}
		byAlbum[key] = append(byAlbum[key], m)
	}
	for _, albumKey := range order {
		list := byAlbum[albumKey]
		byDisc := make(map[int][]map[string]interface{})
		discOrder := make([]int, 0)
		for _, m := range list {
			d := remoteIntField(m, "discNumber")
			if _, seen := byDisc[d]; !seen {
				discOrder = append(discOrder, d)
			}
			byDisc[d] = append(byDisc[d], m)
		}
		sort.Ints(discOrder)
		for _, d := range discOrder {
			bucket := byDisc[d]
			if !remoteAllTrackNumbersZero(bucket) {
				continue
			}
			sort.Slice(bucket, func(i, j int) bool {
				return remotePathTitleLess(bucket[i], bucket[j])
			})
			for i, m := range bucket {
				m["trackNumber"] = i + 1
				if remoteIntField(m, "discNumber") == 0 && d == 0 && len(discOrder) == 1 {
					m["discNumber"] = 1
				}
			}
		}
	}
}

func remoteNormAlbumKey(m map[string]interface{}) string {
	t := strings.TrimSpace(remoteStringField(m, "album"))
	if t == "" {
		return "Unknown Album"
	}
	return t
}

func remoteStringField(m map[string]interface{}, key string) string {
	v, ok := m[key]
	if !ok || v == nil {
		return ""
	}
	switch x := v.(type) {
	case string:
		return x
	default:
		return ""
	}
}

func remoteIntField(m map[string]interface{}, key string) int {
	v, ok := m[key]
	if !ok || v == nil {
		return 0
	}
	i, ok := remoteCoerceInt(v)
	if !ok {
		return 0
	}
	return i
}

func remoteCoerceInt(v interface{}) (int, bool) {
	switch x := v.(type) {
	case int:
		return x, true
	case int32:
		return int(x), true
	case int64:
		return int(x), true
	case float64:
		return int(x), true
	case json.Number:
		n, err := x.Int64()
		return int(n), err == nil
	default:
		return 0, false
	}
}

func remoteAllTrackNumbersZero(bucket []map[string]interface{}) bool {
	for _, m := range bucket {
		if remoteIntField(m, "trackNumber") != 0 {
			return false
		}
	}
	return len(bucket) > 0
}

func remotePathTitleLess(a, b map[string]interface{}) bool {
	pa := strings.ToLower(remoteStringField(a, "path"))
	pb := strings.ToLower(remoteStringField(b, "path"))
	if pa != pb {
		return pa < pb
	}
	ta := strings.ToLower(remoteStringField(a, "title"))
	tb := strings.ToLower(remoteStringField(b, "title"))
	return ta < tb
}
