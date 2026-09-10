package cdrip

import "strconv"

const CDSectorBytes = 2352

// DiscReader is the small operating-system seam used by the Go ripping core.
type DiscReader interface {
	ReadTOC() (TOC, error)
	ReadSectors(lba int, count int) ([]byte, error)
	Close() error
}

type TOC struct {
	Tracks     []TOCTrack
	LeadOutLBA int
}

type TOCTrack struct {
	Number   int
	StartLBA int
	Length   int
	Audio    bool
}

func tracksFromTOC(toc TOC) []Track {
	tracks := make([]Track, 0, len(toc.Tracks))
	for _, item := range toc.Tracks {
		if !item.Audio {
			continue
		}
		tracks = append(tracks, Track{
			Number:  item.Number,
			Title:   fmtTrackTitle(item.Number),
			Artist:  "Unknown Artist",
			Sectors: item.Length,
		})
	}
	return tracks
}

func fmtTrackTitle(number int) string {
	return "Track " + strconv.Itoa(number)
}
