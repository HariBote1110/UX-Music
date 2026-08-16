package mtp

import (
	"errors"
	"io"

	gomtp "github.com/ganeshrvel/go-mtpfs/mtp"
)

// fakeDevice is an in-memory implementation of rawDevice used for unit
// testing the manager's path-resolution / walk / mkdir / transfer logic
// without touching real MTP hardware.
type fakeDevice struct {
	nextHandle uint32
	objects    map[uint32]gomtp.ObjectInfo
	data       map[uint32][]byte
	children   map[uint32][]uint32
	storages   map[uint32]gomtp.StorageInfo
	storageIDs []uint32
	deviceInfo gomtp.DeviceInfo
}

func newFakeDevice() *fakeDevice {
	return &fakeDevice{
		nextHandle: 1,
		objects:    make(map[uint32]gomtp.ObjectInfo),
		data:       make(map[uint32][]byte),
		children:   make(map[uint32][]uint32),
		storages:   make(map[uint32]gomtp.StorageInfo),
	}
}

// addDir registers a folder under parent (rootParentHandle for the root)
// and returns its handle.
func (f *fakeDevice) addDir(parent uint32, name string) uint32 {
	h := f.nextHandle
	f.nextHandle++
	f.objects[h] = gomtp.ObjectInfo{
		Filename:     name,
		ObjectFormat: gomtp.OFC_Association,
		ParentObject: parent,
	}
	f.children[parent] = append(f.children[parent], h)
	return h
}

// addFile registers a file under parent with the given content and returns
// its handle.
func (f *fakeDevice) addFile(parent uint32, name string, content []byte) uint32 {
	h := f.nextHandle
	f.nextHandle++
	f.objects[h] = gomtp.ObjectInfo{
		Filename:         name,
		ObjectFormat:     gomtp.OFC_Undefined,
		ParentObject:     parent,
		CompressedSize:   uint32(len(content)),
	}
	f.data[h] = content
	f.children[parent] = append(f.children[parent], h)
	return h
}

func (f *fakeDevice) GetDeviceInfo(info *gomtp.DeviceInfo) error {
	*info = f.deviceInfo
	return nil
}

func (f *fakeDevice) GetStorageIDs(info *gomtp.Uint32Array) error {
	info.Values = f.storageIDs
	return nil
}

func (f *fakeDevice) GetStorageInfo(id uint32, info *gomtp.StorageInfo) error {
	si, ok := f.storages[id]
	if !ok {
		return errors.New("fake: unknown storage")
	}
	*info = si
	return nil
}

func (f *fakeDevice) GetObjectHandles(storageID, objFormatCode, parent uint32, info *gomtp.Uint32Array) error {
	info.Values = append([]uint32{}, f.children[parent]...)
	return nil
}

func (f *fakeDevice) GetObjectInfo(handle uint32, info *gomtp.ObjectInfo) error {
	oi, ok := f.objects[handle]
	if !ok {
		return errors.New("fake: unknown handle")
	}
	*info = oi
	return nil
}

func (f *fakeDevice) SendObjectInfo(wantStorageID, wantParent uint32, info *gomtp.ObjectInfo) (storageID, parent, handle uint32, err error) {
	h := f.nextHandle
	f.nextHandle++
	f.objects[h] = *info
	f.children[wantParent] = append(f.children[wantParent], h)
	return wantStorageID, wantParent, h, nil
}

func (f *fakeDevice) SendObject(r io.Reader, size int64, cb gomtp.ProgressFunc) error {
	buf, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	// Associate with the most recently created object (mirrors the real
	// device, where SendObject always follows SendObjectInfo in the same
	// session).
	h := f.nextHandle - 1
	f.data[h] = buf
	if cb != nil {
		return cb(int64(len(buf)))
	}
	return nil
}

func (f *fakeDevice) GetObject(handle uint32, w io.Writer, cb gomtp.ProgressFunc) error {
	buf, ok := f.data[handle]
	if !ok {
		return errors.New("fake: no data for handle")
	}
	if _, err := w.Write(buf); err != nil {
		return err
	}
	if cb != nil {
		return cb(int64(len(buf)))
	}
	return nil
}

func (f *fakeDevice) DeleteObject(handle uint32) error {
	for _, child := range f.children[handle] {
		_ = f.DeleteObject(child)
	}
	delete(f.objects, handle)
	delete(f.data, handle)
	delete(f.children, handle)
	return nil
}

func (f *fakeDevice) Close() error { return nil }
func (f *fakeDevice) Done()        {}

var _ rawDevice = (*fakeDevice)(nil)
