package main

import (
	"encoding/json"
	"sort"
	"strings"
)

// ensureWearTrackOrder fills missing per-disc track indices for /wear/songs so mobile clients can sort
// albums consistently. When every track in an (album × disc) bucket has trackNumber 0, we order by
// path then title and assign 1..n (matching typical folder / rip order).
func ensureWearTrackOrder(songs []map[string]interface{}) {
	if len(songs) == 0 {
		return
	}
	byAlbum := make(map[string][]map[string]interface{})
	order := make([]string, 0)
	for _, m := range songs {
		key := wearNormAlbumKey(m)
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
			d := wearIntField(m, "discNumber")
			if _, seen := byDisc[d]; !seen {
				discOrder = append(discOrder, d)
			}
			byDisc[d] = append(byDisc[d], m)
		}
		sort.Ints(discOrder)
		for _, d := range discOrder {
			bucket := byDisc[d]
			if !wearAllTrackNumbersZero(bucket) {
				continue
			}
			sort.Slice(bucket, func(i, j int) bool {
				return wearPathTitleLess(bucket[i], bucket[j])
			})
			for i, m := range bucket {
				m["trackNumber"] = i + 1
				if wearIntField(m, "discNumber") == 0 && d == 0 && len(discOrder) == 1 {
					m["discNumber"] = 1
				}
			}
		}
	}
}

func wearNormAlbumKey(m map[string]interface{}) string {
	t := strings.TrimSpace(wearStringField(m, "album"))
	if t == "" {
		return "Unknown Album"
	}
	return t
}

func wearStringField(m map[string]interface{}, key string) string {
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

func wearIntField(m map[string]interface{}, key string) int {
	v, ok := m[key]
	if !ok || v == nil {
		return 0
	}
	i, ok := wearCoerceInt(v)
	if !ok {
		return 0
	}
	return i
}

func wearCoerceInt(v interface{}) (int, bool) {
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

func wearAllTrackNumbersZero(bucket []map[string]interface{}) bool {
	for _, m := range bucket {
		if wearIntField(m, "trackNumber") != 0 {
			return false
		}
	}
	return len(bucket) > 0
}

func wearPathTitleLess(a, b map[string]interface{}) bool {
	pa := strings.ToLower(wearStringField(a, "path"))
	pb := strings.ToLower(wearStringField(b, "path"))
	if pa != pb {
		return pa < pb
	}
	ta := strings.ToLower(wearStringField(a, "title"))
	tb := strings.ToLower(wearStringField(b, "title"))
	return ta < tb
}
