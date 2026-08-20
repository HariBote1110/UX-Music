package mtp

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	gomtp "github.com/ganeshrvel/go-mtpfs/mtp"
)

func newTestManager(dev rawDevice) *Manager {
	m := NewManager()
	m.dev = dev
	return m
}

func TestResolveHandleNotFound(t *testing.T) {
	dev := newFakeDevice()
	_, _, err := resolveHandle(dev, 1, "/Music/missing")
	if err == nil {
		t.Fatal("expected error for missing path")
	}
}

func TestResolveHandleRoot(t *testing.T) {
	dev := newFakeDevice()
	h, _, err := resolveHandle(dev, 1, "/")
	if err != nil {
		t.Fatal(err)
	}
	if h != rootParentHandle {
		t.Fatalf("expected root handle, got %#x", h)
	}
}

func TestWalkSkipHiddenAndRecursive(t *testing.T) {
	dev := newFakeDevice()
	musicDir := dev.addDir(rootParentHandle, "Music")
	dev.addFile(musicDir, "song.mp3", []byte("abc"))
	dev.addFile(musicDir, ".hidden", []byte("x"))
	subDir := dev.addDir(musicDir, "Album")
	dev.addFile(subDir, "track.mp3", []byte("defg"))

	m := newTestManager(dev)

	items, err := m.Walk(WalkOptions{StorageID: 1, FullPath: "/Music", SkipHiddenFiles: true, Recursive: true})
	if err != nil {
		t.Fatal(err)
	}

	names := map[string]FileInfo{}
	for _, it := range items {
		names[it.Name] = it
	}

	if _, ok := names[".hidden"]; ok {
		t.Fatal("hidden file should have been skipped")
	}
	if len(items) != 3 {
		t.Fatalf("expected 3 items (song.mp3, Album, track.mp3), got %d: %+v", len(items), items)
	}
	song, ok := names["song.mp3"]
	if !ok {
		t.Fatal("song.mp3 missing")
	}
	if song.IsFolder || song.Size != 3 || song.Path != "/Music/song.mp3" {
		t.Fatalf("unexpected song.mp3 fields: %+v", song)
	}
	album, ok := names["Album"]
	if !ok || !album.IsFolder {
		t.Fatalf("Album folder missing or not a folder: %+v", album)
	}
	track, ok := names["track.mp3"]
	if !ok || track.Path != "/Music/Album/track.mp3" {
		t.Fatalf("track.mp3 not found under recursive walk: %+v", track)
	}
}

func TestWalkNonExistentPathErrors(t *testing.T) {
	dev := newFakeDevice()
	m := newTestManager(dev)
	if _, err := m.Walk(WalkOptions{StorageID: 1, FullPath: "/DoesNotExist"}); err == nil {
		t.Fatal("expected error for non-existent path")
	}
}

func TestFileInfoJSONShape(t *testing.T) {
	fi := FileInfo{Name: "a.mp3", Path: "/Music/a.mp3", Size: 10, IsFolder: false, Date: "2026-01-01T00:00:00Z"}
	b, err := json.Marshal(fi)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]interface{}
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"name", "path", "size", "isFolder", "date"} {
		if _, ok := m[key]; !ok {
			t.Fatalf("missing JSON key %q in %s", key, b)
		}
	}
}

func TestMakeDirectoryFindOrCreateIdempotent(t *testing.T) {
	dev := newFakeDevice()
	m := newTestManager(dev)

	if err := m.MakeDirectory(MakeDirOptions{StorageID: 1, FullPath: "/Music/Album"}); err != nil {
		t.Fatal(err)
	}
	// Count handles created so far.
	countAfterFirst := dev.nextHandle

	// Calling again with an overlapping path must not create duplicates.
	if err := m.MakeDirectory(MakeDirOptions{StorageID: 1, FullPath: "/Music/Album"}); err != nil {
		t.Fatal(err)
	}
	if dev.nextHandle != countAfterFirst {
		t.Fatalf("expected no new handles on repeat MakeDirectory, before=%d after=%d", countAfterFirst, dev.nextHandle)
	}

	items, err := m.Walk(WalkOptions{StorageID: 1, FullPath: "/Music"})
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].Name != "Album" || !items[0].IsFolder {
		t.Fatalf("unexpected /Music contents: %+v", items)
	}
}

func TestUploadFilesProgress(t *testing.T) {
	dev := newFakeDevice()
	m := newTestManager(dev)

	dir := t.TempDir()
	localFile := filepath.Join(dir, "song.mp3")
	content := []byte("hello world")
	if err := os.WriteFile(localFile, content, 0o644); err != nil {
		t.Fatal(err)
	}

	var progressed []TransferProgress
	err := m.UploadFiles(TransferOptions{
		StorageID:   1,
		Sources:     []string{localFile},
		Destination: "/Music",
	}, nil, func(p TransferProgress) {
		progressed = append(progressed, p)
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(progressed) == 0 {
		t.Fatal("expected at least one progress event")
	}
	last := progressed[len(progressed)-1]
	if last.Name != "song.mp3" || last.BytesTransferred != int64(len(content)) || last.TotalBytes != int64(len(content)) {
		t.Fatalf("unexpected progress event: %+v", last)
	}
	if !strings.HasSuffix(last.FullPath, "/Music/song.mp3") {
		t.Fatalf("unexpected FullPath: %s", last.FullPath)
	}

	items, err := m.Walk(WalkOptions{StorageID: 1, FullPath: "/Music"})
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].Name != "song.mp3" {
		t.Fatalf("uploaded file not visible via Walk: %+v", items)
	}
}

func TestDownloadFilesProgress(t *testing.T) {
	dev := newFakeDevice()
	musicDir := dev.addDir(rootParentHandle, "Music")
	content := []byte("device content")
	dev.addFile(musicDir, "track.mp3", content)

	m := newTestManager(dev)
	destDir := t.TempDir()

	var progressed []TransferProgress
	err := m.DownloadFiles(TransferOptions{
		StorageID:   1,
		Sources:     []string{"/Music/track.mp3"},
		Destination: destDir,
	}, nil, func(p TransferProgress) {
		progressed = append(progressed, p)
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(progressed) == 0 {
		t.Fatal("expected progress events")
	}
	last := progressed[len(progressed)-1]
	if last.BytesTransferred != int64(len(content)) || last.TotalBytes != int64(len(content)) {
		t.Fatalf("unexpected progress: %+v", last)
	}

	got, err := os.ReadFile(filepath.Join(destDir, "track.mp3"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, content) {
		t.Fatalf("downloaded content mismatch: got %q want %q", got, content)
	}
}

func TestFetchStoragesConversion(t *testing.T) {
	dev := newFakeDevice()
	dev.storageIDs = []uint32{42}
	dev.storages[42] = gomtp.StorageInfo{
		StorageDescription: "Internal storage",
		MaxCapability:      1000,
		FreeSpaceInBytes:   500,
	}
	m := newTestManager(dev)

	storages, err := m.FetchStorages()
	if err != nil {
		t.Fatal(err)
	}
	if len(storages) != 1 {
		t.Fatalf("expected 1 storage, got %d", len(storages))
	}
	s := storages[0]
	if s.ID != 42 || s.Info.StorageDescription != "Internal storage" || s.Info.MaxCapability != 1000 || s.Info.FreeSpaceInBytes != 500 {
		t.Fatalf("unexpected storage conversion: %+v", s)
	}

	b, err := json.Marshal(s)
	if err != nil {
		t.Fatal(err)
	}
	var m2 map[string]interface{}
	json.Unmarshal(b, &m2)
	if _, ok := m2["Sid"]; !ok {
		t.Fatalf("missing Sid JSON key: %s", b)
	}
	info, ok := m2["Info"].(map[string]interface{})
	if !ok {
		t.Fatalf("missing Info JSON key: %s", b)
	}
	for _, key := range []string{"StorageDescription", "MaxCapability", "FreeSpaceInBytes"} {
		if _, ok := info[key]; !ok {
			t.Fatalf("missing Info.%s JSON key: %s", key, b)
		}
	}
}

func TestFetchDeviceInfoMapShape(t *testing.T) {
	dev := newFakeDevice()
	dev.deviceInfo = gomtp.DeviceInfo{
		Manufacturer: "Acme",
		Model:        "Walkman X",
	}
	m := newTestManager(dev)

	info, err := m.FetchDeviceInfo()
	if err != nil {
		t.Fatal(err)
	}
	mtpInfo, ok := info["mtpDeviceInfo"].(map[string]interface{})
	if !ok {
		t.Fatalf("missing mtpDeviceInfo: %+v", info)
	}
	if mtpInfo["Model"] != "Walkman X" {
		t.Fatalf("unexpected Model: %+v", mtpInfo)
	}
}

func TestDeleteFileRemovesObject(t *testing.T) {
	dev := newFakeDevice()
	musicDir := dev.addDir(rootParentHandle, "Music")
	dev.addFile(musicDir, "song.mp3", []byte("x"))

	m := newTestManager(dev)
	if err := m.DeleteFile(DeleteOptions{StorageID: 1, Files: []string{"/Music/song.mp3"}}); err != nil {
		t.Fatal(err)
	}

	items, err := m.Walk(WalkOptions{StorageID: 1, FullPath: "/Music"})
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 0 {
		t.Fatalf("expected file to be deleted, got %+v", items)
	}
}
