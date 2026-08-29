package mtp

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	gomtp "github.com/ganeshrvel/go-mtpfs/mtp"
)

// errNotInitialized is returned when a Manager method is called before a
// successful Initialize (or after Dispose).
var errNotInitialized = errors.New("mtp: device not initialized")

// Manager handles MTP operations against a single connected device. All
// exported methods are serialised by mu, mirroring the behaviour of the
// previous FFI-backed implementation.
type Manager struct {
	mu  sync.Mutex
	dev rawDevice
}

// NewManager creates a new MTP Manager.
func NewManager() *Manager {
	return &Manager{}
}

// Initialize connects to the first available MTP device. Calling it again
// while already connected is a no-op success.
func (m *Manager) Initialize() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.dev != nil {
		return nil
	}

	dev, err := gomtp.SelectDevice("")
	if err != nil {
		return err
	}
	if err := dev.Configure(); err != nil {
		dev.Close()
		return err
	}
	m.dev = dev
	return nil
}

// FetchDeviceInfo returns device info shaped as
// {"mtpDeviceInfo": {...}, "usbDeviceInfo": {...}} for compatibility with
// the frontend/server code that reads those exact keys.
func (m *Manager) FetchDeviceInfo() (map[string]interface{}, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.dev == nil {
		return nil, errNotInitialized
	}

	var info gomtp.DeviceInfo
	if err := m.dev.GetDeviceInfo(&info); err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"mtpDeviceInfo": map[string]interface{}{
			"Manufacturer":  info.Manufacturer,
			"Model":         info.Model,
			"DeviceVersion": info.DeviceVersion,
			"SerialNumber":  info.SerialNumber,
		},
		"usbDeviceInfo": map[string]interface{}{
			"Product": info.Model,
		},
	}, nil
}

// FetchStorages returns the list of storages exposed by the device.
func (m *Manager) FetchStorages() ([]Storage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.dev == nil {
		return nil, errNotInitialized
	}

	var ids gomtp.Uint32Array
	if err := m.dev.GetStorageIDs(&ids); err != nil {
		return nil, err
	}

	storages := make([]Storage, 0, len(ids.Values))
	for _, id := range ids.Values {
		var si gomtp.StorageInfo
		if err := m.dev.GetStorageInfo(id, &si); err != nil {
			return nil, err
		}
		s := Storage{ID: id}
		s.Info.StorageDescription = si.StorageDescription
		s.Info.MaxCapability = int64(si.MaxCapability)
		s.Info.FreeSpaceInBytes = int64(si.FreeSpaceInBytes)
		storages = append(storages, s)
	}
	return storages, nil
}

// Walk lists the contents of opts.FullPath, optionally recursing into
// sub-folders and skipping dotfile-prefixed entries.
func (m *Manager) Walk(opts WalkOptions) ([]FileInfo, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.dev == nil {
		return nil, errNotInitialized
	}

	handle, info, err := resolveHandle(m.dev, opts.StorageID, opts.FullPath)
	if err != nil {
		return nil, err
	}
	if handle != rootParentHandle && info.ObjectFormat != gomtp.OFC_Association {
		return nil, fmt.Errorf("mtp: not a folder: %s", opts.FullPath)
	}

	basePath := normaliseBasePath(opts.FullPath)
	return m.walkDir(opts, handle, basePath)
}

func normaliseBasePath(p string) string {
	if p == "" {
		return "/"
	}
	return "/" + strings.Join(splitPathComponents(p), "/")
}

func (m *Manager) walkDir(opts WalkOptions, parent uint32, basePath string) ([]FileInfo, error) {
	var ids gomtp.Uint32Array
	if err := m.dev.GetObjectHandles(opts.StorageID, gomtp.GOH_ALL_FORMATS, parent, &ids); err != nil {
		return nil, err
	}

	var out []FileInfo
	for _, h := range ids.Values {
		var oi gomtp.ObjectInfo
		if err := m.dev.GetObjectInfo(h, &oi); err != nil {
			return nil, err
		}
		if opts.SkipHiddenFiles && strings.HasPrefix(oi.Filename, ".") {
			continue
		}

		isFolder := oi.ObjectFormat == gomtp.OFC_Association
		childPath := joinPath(basePath, oi.Filename)
		date := ""
		if !oi.ModificationDate.IsZero() {
			date = oi.ModificationDate.Format(time.RFC3339)
		}

		out = append(out, FileInfo{
			Name:     oi.Filename,
			Path:     childPath,
			Size:     int64(oi.CompressedSize),
			IsFolder: isFolder,
			Date:     date,
		})

		if isFolder && opts.Recursive {
			children, err := m.walkDir(opts, h, childPath)
			if err != nil {
				return nil, err
			}
			out = append(out, children...)
		}
	}
	return out, nil
}

// MakeDirectory creates every missing component of opts.FullPath. Creating
// a directory that already exists is a no-op success.
func (m *Manager) MakeDirectory(opts MakeDirOptions) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.dev == nil {
		return errNotInitialized
	}

	_, err := m.mkdirChain(opts.StorageID, opts.FullPath)
	return err
}

// mkdirChain finds-or-creates every component of fullPath and returns the
// handle of the final directory. Callers must already hold m.mu.
func (m *Manager) mkdirChain(storageID uint32, fullPath string) (uint32, error) {
	parent := rootParentHandle
	for _, name := range splitPathComponents(fullPath) {
		h, found, err := findChild(m.dev, storageID, parent, name)
		if err != nil {
			return 0, err
		}
		if !found {
			info := gomtp.ObjectInfo{
				StorageID:       storageID,
				ObjectFormat:    gomtp.OFC_Association,
				AssociationType: gomtp.AT_GenericFolder,
				ParentObject:    parent,
				Filename:        name,
			}
			_, _, handle, err := m.dev.SendObjectInfo(storageID, parent, &info)
			if err != nil {
				return 0, err
			}
			h = handle
		}
		parent = h
	}
	return parent, nil
}

// findChild looks up a direct child of parent by name.
func findChild(dev rawDevice, storageID, parent uint32, name string) (handle uint32, found bool, err error) {
	var ids gomtp.Uint32Array
	if err := dev.GetObjectHandles(storageID, gomtp.GOH_ALL_FORMATS, parent, &ids); err != nil {
		return 0, false, err
	}
	for _, h := range ids.Values {
		var oi gomtp.ObjectInfo
		if err := dev.GetObjectInfo(h, &oi); err != nil {
			return 0, false, err
		}
		if oi.Filename == name {
			return h, true, nil
		}
	}
	return 0, false, nil
}

// resolveHandle resolves a device path to its object handle and info. The
// root path ("" or "/") resolves to rootParentHandle with a zero-value
// ObjectInfo.
func resolveHandle(dev rawDevice, storageID uint32, path string) (uint32, gomtp.ObjectInfo, error) {
	parent := rootParentHandle
	var info gomtp.ObjectInfo

	components := splitPathComponents(path)
	for _, name := range components {
		h, found, err := findChild(dev, storageID, parent, name)
		if err != nil {
			return 0, gomtp.ObjectInfo{}, err
		}
		if !found {
			return 0, gomtp.ObjectInfo{}, fmt.Errorf("mtp: path not found: %s", path)
		}
		var oi gomtp.ObjectInfo
		if err := dev.GetObjectInfo(h, &oi); err != nil {
			return 0, gomtp.ObjectInfo{}, err
		}
		parent = h
		info = oi
	}
	return parent, info, nil
}

// DeleteFile deletes each of opts.Files (resolved from device paths). The
// MTP spec deletes association (folder) contents recursively on most
// devices; DeleteObject is invoked once per path.
func (m *Manager) DeleteFile(opts DeleteOptions) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.dev == nil {
		return errNotInitialized
	}

	for _, p := range opts.Files {
		handle, _, err := resolveHandle(m.dev, opts.StorageID, p)
		if err != nil {
			return err
		}
		if err := m.dev.DeleteObject(handle); err != nil {
			return err
		}
	}
	return nil
}

// UploadFiles copies opts.Sources (local file or directory paths) into the
// device directory opts.Destination, creating any missing destination
// directories first.
func (m *Manager) UploadFiles(opts TransferOptions, onPre func(interface{}), onProg func(TransferProgress)) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.dev == nil {
		return errNotInitialized
	}

	if _, err := m.mkdirChain(opts.StorageID, opts.Destination); err != nil {
		return err
	}

	if onPre != nil {
		onPre(map[string]interface{}{"count": len(opts.Sources)})
	}

	for _, src := range opts.Sources {
		if err := m.uploadPath(opts.StorageID, src, opts.Destination, onProg); err != nil {
			return err
		}
	}
	return nil
}

func (m *Manager) uploadPath(storageID uint32, localPath, destDir string, onProg func(TransferProgress)) error {
	fi, err := os.Stat(localPath)
	if err != nil {
		return err
	}

	if fi.IsDir() {
		subDest := joinPath(destDir, filepath.Base(localPath))
		if _, err := m.mkdirChain(storageID, subDest); err != nil {
			return err
		}
		entries, err := os.ReadDir(localPath)
		if err != nil {
			return err
		}
		for _, e := range entries {
			if err := m.uploadPath(storageID, filepath.Join(localPath, e.Name()), subDest, onProg); err != nil {
				return err
			}
		}
		return nil
	}

	destParent, err := m.mkdirChain(storageID, destDir)
	if err != nil {
		return err
	}

	f, err := os.Open(localPath)
	if err != nil {
		return err
	}
	defer f.Close()

	name := filepath.Base(localPath)
	fullDestPath := joinPath(destDir, name)

	info := gomtp.ObjectInfo{
		StorageID:        storageID,
		ObjectFormat:     gomtp.OFC_Undefined,
		ParentObject:     destParent,
		Filename:         name,
		CompressedSize:   uint32(fi.Size()),
		ModificationDate: fi.ModTime(),
	}
	if _, _, _, err := m.dev.SendObjectInfo(storageID, destParent, &info); err != nil {
		return err
	}

	return m.dev.SendObject(f, fi.Size(), func(sent int64) error {
		if onProg != nil {
			onProg(TransferProgress{
				Name:             name,
				FullPath:         fullDestPath,
				BytesTransferred: sent,
				TotalBytes:       fi.Size(),
			})
		}
		return nil
	})
}

// DownloadFiles copies opts.Sources (device paths) into the local directory
// opts.Destination.
func (m *Manager) DownloadFiles(opts TransferOptions, onPre func(interface{}), onProg func(TransferProgress)) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.dev == nil {
		return errNotInitialized
	}

	if onPre != nil {
		onPre(map[string]interface{}{"count": len(opts.Sources)})
	}

	for _, src := range opts.Sources {
		handle, info, err := resolveHandle(m.dev, opts.StorageID, src)
		if err != nil {
			return err
		}
		isRoot := handle == rootParentHandle
		if isRoot {
			info.Filename = filepath.Base(src)
			info.ObjectFormat = gomtp.OFC_Association
		}
		if err := m.downloadNode(opts.StorageID, handle, info, opts.Destination, onProg); err != nil {
			return err
		}
	}
	return nil
}

func (m *Manager) downloadNode(storageID, handle uint32, info gomtp.ObjectInfo, localDestDir string, onProg func(TransferProgress)) error {
	if info.ObjectFormat == gomtp.OFC_Association {
		subLocal := filepath.Join(localDestDir, info.Filename)
		if err := os.MkdirAll(subLocal, 0o755); err != nil {
			return err
		}

		var ids gomtp.Uint32Array
		if err := m.dev.GetObjectHandles(storageID, gomtp.GOH_ALL_FORMATS, handle, &ids); err != nil {
			return err
		}
		for _, h := range ids.Values {
			var oi gomtp.ObjectInfo
			if err := m.dev.GetObjectInfo(h, &oi); err != nil {
				return err
			}
			if err := m.downloadNode(storageID, h, oi, subLocal, onProg); err != nil {
				return err
			}
		}
		return nil
	}

	if err := os.MkdirAll(localDestDir, 0o755); err != nil {
		return err
	}
	localPath := filepath.Join(localDestDir, info.Filename)
	f, err := os.Create(localPath)
	if err != nil {
		return err
	}
	defer f.Close()

	total := int64(info.CompressedSize)
	return m.dev.GetObject(handle, f, func(sent int64) error {
		if onProg != nil {
			onProg(TransferProgress{
				Name:             info.Filename,
				FullPath:         localPath,
				BytesTransferred: sent,
				TotalBytes:       total,
			})
		}
		return nil
	})
}

// Dispose closes the connection to the device, if any. Subsequent calls to
// Initialize will attempt to reconnect from scratch.
func (m *Manager) Dispose() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.dev == nil {
		return nil
	}
	err := m.dev.Close()
	m.dev.Done()
	m.dev = nil
	return err
}
