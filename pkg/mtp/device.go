package mtp

import (
	"io"

	gomtp "github.com/ganeshrvel/go-mtpfs/mtp"
)

// rootParentHandle is the parent handle used by the MTP spec to mean
// "the root of the storage" (0xFFFFFFFF).
const rootParentHandle uint32 = 0xFFFFFFFF

// rawDevice is the subset of *gomtp.Device operations the manager depends
// on. It exists so unit tests can exercise the path-resolution / walk /
// mkdir / transfer logic against an in-memory fake instead of real
// hardware.
type rawDevice interface {
	GetDeviceInfo(info *gomtp.DeviceInfo) error
	GetStorageIDs(info *gomtp.Uint32Array) error
	GetStorageInfo(id uint32, info *gomtp.StorageInfo) error
	GetObjectHandles(storageID, objFormatCode, parent uint32, info *gomtp.Uint32Array) error
	GetObjectInfo(handle uint32, info *gomtp.ObjectInfo) error
	SendObjectInfo(wantStorageID, wantParent uint32, info *gomtp.ObjectInfo) (storageID, parent, handle uint32, err error)
	SendObject(r io.Reader, size int64, cb gomtp.ProgressFunc) error
	GetObject(handle uint32, w io.Writer, cb gomtp.ProgressFunc) error
	DeleteObject(handle uint32) error
	Close() error
	Done()
}

// *gomtp.Device satisfies rawDevice with no adapter needed.
var _ rawDevice = (*gomtp.Device)(nil)
