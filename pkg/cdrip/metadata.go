package cdrip

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const userAgent = "UXMusic/0.1.0 ( contact@example.com )"

// MusicBrainz API response structs (partial)
type mbReleaseResponse struct {
	Releases []mbRelease `json:"releases"`
}

type mbRelease struct {
	ID           string    `json:"id"`
	Title        string    `json:"title"`
	ArtistCredit []mbLabel `json:"artist-credit"`
	Media        []mbMedia `json:"media"`
	Date         string    `json:"date"`
	Score        int       `json:"score,omitempty"`
}

type mbLabel struct {
	Name string `json:"name"`
}

type mbMedia struct {
	Tracks []mbTrack `json:"tracks"`
}

type mbTrack struct {
	Title     string      `json:"title"`
	Position  interface{} `json:"position"` // Can be string or int in JSON
	Recording mbRecording `json:"recording"`
}

type mbRecording struct {
	ArtistCredit []mbLabel `json:"artist-credit"`
}

type caaResponse struct {
	Images []caaImage `json:"images"`
}

type caaImage struct {
	Front bool   `json:"front"`
	Image string `json:"image"`
}

func queryMusicBrainz(reqURL string) (json.RawMessage, error) {
	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest("GET", reqURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", userAgent)

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == 404 {
		return nil, nil // Not found
	}
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("API returned status: %d", resp.StatusCode)
	}

	var data json.RawMessage
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, err
	}
	return data, nil
}

func getCoverArtURL(releaseID string) string {
	u := fmt.Sprintf("https://coverartarchive.org/release/%s", releaseID)
	data, err := queryMusicBrainz(u)
	if err != nil || data == nil {
		return ""
	}

	var res caaResponse
	if err := json.Unmarshal(data, &res); err != nil {
		return ""
	}

	for _, img := range res.Images {
		if img.Front {
			return strings.Replace(img.Image, "http:", "https:", 1)
		}
	}
	if len(res.Images) > 0 {
		return strings.Replace(res.Images[0].Image, "http:", "https:", 1)
	}
	return ""
}

// SearchByTOC searches for metadata using CD TOC
func SearchByTOC(tracks []Track) ([]ReleaseInfo, error) {
	currentOffset := 150
	var offsets []string
	for _, t := range tracks {
		offsets = append(offsets, strconv.Itoa(currentOffset))
		currentOffset += t.Sectors
	}

	// Format: 1 + tracks_count + leadout_sectors + track_offsets...
	// currentOffset is now the leadout sector (start of leadout)
	params := []string{"1", strconv.Itoa(len(tracks)), strconv.Itoa(currentOffset)}
	params = append(params, offsets...)
	tocQuery := strings.Join(params, "+")

	reqURL := fmt.Sprintf("https://musicbrainz.org/ws/2/discid/-?toc=%s&fmt=json", tocQuery)
	data, err := queryMusicBrainz(reqURL)
	if err != nil {
		return nil, err
	}
	if data == nil {
		return []ReleaseInfo{}, nil
	}

	var res mbReleaseResponse
	if err := json.Unmarshal(data, &res); err != nil {
		// Sometimes discid returns a direct release object if only one match?
		// Currently assuming standard "releases" array structure for simplicity as per nodejs
		return []ReleaseInfo{}, err
	}

	return convertReleases(res.Releases), nil
}

// SearchByText searches for metadata using text query
func SearchByText(query string) ([]ReleaseInfo, error) {
	q := url.QueryEscape(query)
	reqURL := fmt.Sprintf("https://musicbrainz.org/ws/2/release/?query=%s&fmt=json&limit=15", q)

	data, err := queryMusicBrainz(reqURL)
	if err != nil {
		return nil, err
	}
	if data == nil {
		return []ReleaseInfo{}, nil
	}

	var res mbReleaseResponse
	if err := json.Unmarshal(data, &res); err != nil {
		return []ReleaseInfo{}, err
	}

	return convertReleases(res.Releases), nil
}

// ApplyMetadata fetches detailed info for a release and merges it with tracks
func ApplyMetadata(tracks []Track, releaseID string) (*ReleaseInfo, error) {
	fmt.Printf("[Metadata] Applying metadata for release ID: %s\n", releaseID)
	reqURL := fmt.Sprintf("https://musicbrainz.org/ws/2/release/%s?inc=artist-credits+recordings&fmt=json", releaseID)
	data, err := queryMusicBrainz(reqURL)
	if err != nil || data == nil {
		fmt.Printf("[Metadata] Failed to fetch release: %v\n", err)
		return nil, fmt.Errorf("failed to fetch release details")
	}

	var release mbRelease
	if err := json.Unmarshal(data, &release); err != nil {
		fmt.Printf("[Metadata] Failed to unmarshal release: %v\n", err)
		return nil, err
	}

	fmt.Println("[Metadata] Fetching cover art...")
	artwork := getCoverArtURL(releaseID)
	fmt.Printf("[Metadata] Cover art URL: %s\n", artwork)

	albumArtist := "Unknown Artist"
	if len(release.ArtistCredit) > 0 {
		albumArtist = release.ArtistCredit[0].Name
	}
	albumTitle := release.Title

	var mbTracks []mbTrack
	if len(release.Media) > 0 {
		mbTracks = release.Media[0].Tracks
	}

	resultTracks := make([]Track, len(tracks))
	copy(resultTracks, tracks)

	for i := range resultTracks {
		// Find matching track by position (assuming simple 1-1 mapping for now)
		var match *mbTrack
		if i < len(mbTracks) {
			match = &mbTracks[i]
		}
		// Attempt to find by number if possible.
		// (MB API returns position as string or int, simplified here)

		if match != nil {
			resultTracks[i].Title = match.Title
			resultTracks[i].Album = albumTitle
			if len(match.Recording.ArtistCredit) > 0 {
				resultTracks[i].Artist = match.Recording.ArtistCredit[0].Name
			} else {
				resultTracks[i].Artist = albumArtist
			}
		} else {
			resultTracks[i].Album = albumTitle
			resultTracks[i].Artist = albumArtist
		}
	}

	fmt.Println("[Metadata] Metadata application complete")
	return &ReleaseInfo{
		ID:      release.ID,
		Title:   albumTitle,
		Artist:  albumArtist,
		Tracks:  resultTracks,
		Artwork: artwork,
	}, nil
}

func convertReleases(mbs []mbRelease) []ReleaseInfo {
	var result []ReleaseInfo
	for _, r := range mbs {
		artist := "Unknown"
		if len(r.ArtistCredit) > 0 {
			artist = r.ArtistCredit[0].Name
		}
		result = append(result, ReleaseInfo{
			ID:     r.ID,
			Title:  r.Title,
			Artist: artist,
		})
	}
	return result
}
