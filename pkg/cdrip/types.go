package cdrip

// Track represents a single audio track on a CD
type Track struct {
	Number  int    `json:"number"`
	Title   string `json:"title"`
	Artist  string `json:"artist"`
	Album   string `json:"album"`
	Sectors int    `json:"sectors"`
	Length  string `json:"length,omitempty"` // Derived from sectors if needed
}

// ReleaseInfo represents metadata for a CD release
type ReleaseInfo struct {
	ID      string  `json:"id"`
	Title   string  `json:"title"`
	Artist  string  `json:"artist"`
	Tracks  []Track `json:"tracks"`
	Artwork string  `json:"artwork,omitempty"`
}

// RipOptions configuration for the ripping process
type RipOptions struct {
	Format     string `json:"format"`     // flac, wav, mp3, aac, alac
	Bitrate    string `json:"bitrate"`    // e.g., "320k"
	ArtworkURL string `json:"artworkUrl"` // URL to embed as artwork
}

// RipProgress represents the progress of ripping a track
type RipProgress struct {
	TrackNumber int     `json:"trackNumber"`
	Status      string  `json:"status"` // ripping, encoding, completed, error
	Percent     float64 `json:"percent,omitempty"`
	Error       string  `json:"error,omitempty"`
}
