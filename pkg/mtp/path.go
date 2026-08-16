package mtp

import "strings"

// splitPathComponents splits a device path such as "/Music/foo/" into its
// non-empty components, e.g. []string{"Music", "foo"}. The root path ("" or
// "/") yields nil.
func splitPathComponents(p string) []string {
	parts := strings.Split(p, "/")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		if part == "" {
			continue
		}
		out = append(out, part)
	}
	return out
}

// joinPath appends name to a device directory path, always producing a
// leading-slash, non-trailing-slash form (e.g. "/Music" + "foo" ->
// "/Music/foo").
func joinPath(base, name string) string {
	base = strings.TrimSuffix(base, "/")
	if base == "" {
		return "/" + name
	}
	return base + "/" + name
}
