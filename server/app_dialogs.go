package server

import (
	"context"
	"errors"
)

// ErrGUIRequired indicates the requested operation needs an active GUI
// session (e.g. a native file/folder picker) and cannot be completed while
// the server is running headless (e.g. under --serve).
var ErrGUIRequired = errors.New("this operation requires the GUI")

// FileFilter mirrors the subset of Wails' FileFilter used by the server
// package, kept independent of the Wails runtime so DialogProvider has no
// GUI-toolkit dependency outside app_wails_adapter.go.
type FileFilter struct {
	DisplayName string
	Pattern     string
}

// DialogOptions mirrors the subset of Wails' OpenDialogOptions actually used
// by the server package.
type DialogOptions struct {
	Title            string
	Filters          []FileFilter
	DefaultDirectory string
}

// DialogProvider abstracts native file/folder picker dialogs so the server
// package can run headless. GUI mode backs it with Wails (see
// app_wails_adapter.go); headless mode uses headlessDialogProvider, which
// fails every call with ErrGUIRequired.
type DialogProvider interface {
	OpenFileDialog(ctx context.Context, opts DialogOptions) (string, error)
	OpenMultipleFilesDialog(ctx context.Context, opts DialogOptions) ([]string, error)
	OpenDirectoryDialog(ctx context.Context, opts DialogOptions) (string, error)
}

// headlessDialogProvider is the default DialogProvider when no GUI is
// attached. Every operation fails with ErrGUIRequired.
type headlessDialogProvider struct{}

func (headlessDialogProvider) OpenFileDialog(context.Context, DialogOptions) (string, error) {
	return "", ErrGUIRequired
}

func (headlessDialogProvider) OpenMultipleFilesDialog(context.Context, DialogOptions) ([]string, error) {
	return nil, ErrGUIRequired
}

func (headlessDialogProvider) OpenDirectoryDialog(context.Context, DialogOptions) (string, error) {
	return "", ErrGUIRequired
}
