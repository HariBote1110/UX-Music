//go:build windows

package mtp

import "errors"

var errMTPUnsupportedOnWindows = errors.New("MTP is not supported on Windows")

type Manager struct{}

func NewManager() *Manager {
	return &Manager{}
}

func (m *Manager) Initialize() error {
	return errMTPUnsupportedOnWindows
}

func (m *Manager) FetchDeviceInfo() (map[string]interface{}, error) {
	return nil, errMTPUnsupportedOnWindows
}

func (m *Manager) FetchStorages() ([]Storage, error) {
	return nil, errMTPUnsupportedOnWindows
}

func (m *Manager) Walk(opts WalkOptions) (interface{}, error) {
	return nil, errMTPUnsupportedOnWindows
}

func (m *Manager) UploadFiles(opts TransferOptions, onPre func(interface{}), onProg func(TransferProgress)) error {
	return errMTPUnsupportedOnWindows
}

func (m *Manager) DownloadFiles(opts TransferOptions, onPre func(interface{}), onProg func(TransferProgress)) error {
	return errMTPUnsupportedOnWindows
}

func (m *Manager) DeleteFile(opts DeleteOptions) error {
	return errMTPUnsupportedOnWindows
}

func (m *Manager) MakeDirectory(opts MakeDirOptions) error {
	return errMTPUnsupportedOnWindows
}

func (m *Manager) Dispose() error {
	return nil
}
