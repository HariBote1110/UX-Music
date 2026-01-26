package mtp

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"runtime"
	"sync"
	"unsafe"

	"path/filepath"

	"github.com/ebitengine/purego"
)

// Helper struct for callbacks
type callbackHandler struct {
	resultChan     chan []byte
	preprocessChan chan []byte
	progressChan   chan []byte
}

var (
	libKalam uintptr
	mu       sync.Mutex

	// We need to keep callbacks alive and route them correcty.
	// Since the C API expects a function pointer and doesn't seem to take a context/user_data pointer,
	// we are strictly limited to SINGLETON behavior or GLOBAL callbacks unless we use libffi closures which purego supports via NewCallback.
	//
	// `kalam.h` signatures:
	// void Initialize(on_cb_result_t onDonePtr);
	// typedef void (*on_cb_result_t)(char*);
	//
	// PureGo's NewCallback converts a Go function to a C function pointer.
	// Since we can only register ONE callback function pointer if we want to route it,
	// checking if we can run concurrent operations...
	// JS implementation wrapped it in a class but we saw `koffi.register` being used PER CALL.
	// "const rawPtr = koffi.register((result) => { ... })"
	// Koffi creates a closure trampoline. PureGo also creates a closure trampoline.
	// So we can support concurrent calls if we create a new callback for each call.
)

// Library functions
var (
	fnInitialize      func(uintptr)
	fnFetchDeviceInfo func(uintptr)
	fnFetchStorages   func(uintptr)
	fnWalk            func(string, uintptr)
	fnDownloadFiles   func(string, uintptr, uintptr, uintptr)
	fnUploadFiles     func(string, uintptr, uintptr, uintptr)
	fnDeleteFile      func(string, uintptr)
	fnMakeDirectory   func(string, uintptr)
	fnDispose         func(uintptr)
)

// Manager handles MTP operations
type Manager struct{}

// NewManager creates a new MTP Manager
func NewManager() *Manager {
	return &Manager{}
}

// Initialize initializes the MTP library
func (m *Manager) Initialize() error {
	mu.Lock()
	defer mu.Unlock()

	if libKalam == 0 {
		if err := loadLibrary(); err != nil {
			return err
		}
	}

	resChan := make(chan []byte, 1)
	cb := purego.NewCallback(func(cStr *byte) {
		resChan <- parseCString(cStr)
	})

	fnInitialize(cb)

	raw := <-resChan
	return parseErrorOnly(raw)
}

func loadLibrary() error {
	// Determine library path
	// In dev: pkg/mtp/lib/libkalam.dylib
	// In prod: (app)/Contents/Frameworks/libkalam.dylib ?? or near binary
	// We need to be careful.
	// For now, assume dev/wd relative or adjacent to binary.

	exePath, err := os.Executable()
	if err != nil {
		return err
	}
	exeDir := filepath.Dir(exePath)

	var libPath string
	if runtime.GOOS == "darwin" {
		// Try multiple locations
		candidates := []string{
			"libkalam.dylib",
			"../Frameworks/libkalam.dylib", // macOS bundle
			"pkg/mtp/lib/libkalam.dylib",   // dev
			filepath.Join(exeDir, "libkalam.dylib"),
			filepath.Join(exeDir, "bin", "macos", "libkalam.dylib"),
		}

		for _, c := range candidates {
			if _, err := os.Stat(c); err == nil {
				libPath = c
				break
			}
		}
		if libPath == "" {
			// Fallback to absolute assumption for dev if running via 'wails dev' from root
			cwd, _ := os.Getwd()
			libPath = filepath.Join(cwd, "pkg/mtp/lib/libkalam.dylib")
		}
	} else {
		return fmt.Errorf("unsupported OS: %s", runtime.GOOS)
	}

	lib, err := purego.Dlopen(libPath, purego.RTLD_NOW|purego.RTLD_GLOBAL)
	if err != nil {
		return fmt.Errorf("failed to load library %s: %w", libPath, err)
	}
	libKalam = lib

	// Register functions
	purego.RegisterLibFunc(&fnInitialize, lib, "Initialize")
	purego.RegisterLibFunc(&fnFetchDeviceInfo, lib, "FetchDeviceInfo")
	purego.RegisterLibFunc(&fnFetchStorages, lib, "FetchStorages")
	purego.RegisterLibFunc(&fnWalk, lib, "Walk")
	purego.RegisterLibFunc(&fnDownloadFiles, lib, "DownloadFiles")
	purego.RegisterLibFunc(&fnUploadFiles, lib, "UploadFiles")
	purego.RegisterLibFunc(&fnDeleteFile, lib, "DeleteFile")
	purego.RegisterLibFunc(&fnMakeDirectory, lib, "MakeDirectory")
	purego.RegisterLibFunc(&fnDispose, lib, "Dispose")

	return nil
}

func parseCString(ptr *byte) []byte {
	if ptr == nil {
		return nil
	}
	// PureGo doesn't have CString to GoString helper directly exposed?
	// We can scan.
	// Actually purego doesn't, but we can unsafe cast.
	// Or simply iterate.
	// C string is null terminated.

	// Fast way:
	/*
		p := unsafe.Pointer(ptr)
		return []byte(C.GoString((*C.char)(p))) -- no Cgo
	*/

	var b []byte
	current := ptr
	for *current != 0 {
		b = append(b, *current)
		// pointer arithmetic not allowed on *byte without unsafe
		// we need unsafe
		// return BytePtrToString(ptr)
		break // wait, loop helper needed
	}
	// Let's use string helper
	return []byte(bytePtrToString(ptr))
}

func bytePtrToString(ptr *byte) string {
	if ptr == nil {
		return ""
	}
	// Find length
	var length int
	for {
		p := *(*byte)(unsafe.Pointer(uintptr(unsafe.Pointer(ptr)) + uintptr(length)))
		if p == 0 {
			break
		}
		length++
	}
	return string(unsafe.Slice(ptr, length))
}

// ... Reimplement methods using purego ...

// FetchDeviceInfo returns device info
func (m *Manager) FetchDeviceInfo() (map[string]interface{}, error) {
	mu.Lock()
	defer mu.Unlock()

	resChan := make(chan []byte, 1)
	cb := purego.NewCallback(func(cStr *byte) {
		resChan <- parseCString(cStr)
	})

	fnFetchDeviceInfo(cb)
	raw := <-resChan

	var resp MTPResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, err
	}
	if resp.Error != "" {
		return nil, errors.New(resp.Error)
	}

	if data, ok := resp.Data.(map[string]interface{}); ok {
		return data, nil
	}
	return nil, nil // empty?
}

// FetchStorages returns list of storages
func (m *Manager) FetchStorages() ([]Storage, error) {
	mu.Lock()
	defer mu.Unlock()

	resChan := make(chan []byte, 1)
	cb := purego.NewCallback(func(cStr *byte) {
		resChan <- parseCString(cStr)
	})

	fnFetchStorages(cb)
	raw := <-resChan

	var resp MTPResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, err
	}
	if resp.Error != "" {
		return nil, errors.New(resp.Error)
	}

	dataBytes, _ := json.Marshal(resp.Data)
	var storages []Storage
	if err := json.Unmarshal(dataBytes, &storages); err != nil {
		return nil, err
	}
	return storages, nil
}

// Walk lists files
func (m *Manager) Walk(opts WalkOptions) (interface{}, error) {
	mu.Lock()
	defer mu.Unlock()

	inputJSON, _ := json.Marshal(opts)

	resChan := make(chan []byte, 1)
	cb := purego.NewCallback(func(cStr *byte) {
		resChan <- parseCString(cStr)
	})

	fnWalk(string(inputJSON), cb)
	raw := <-resChan

	var resp MTPResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, err
	}
	if resp.Error != "" {
		return nil, errors.New(resp.Error)
	}
	return resp.Data, nil
}

// UploadFiles uploads files
func (m *Manager) UploadFiles(opts TransferOptions, onPre func(interface{}), onProg func(TransferProgress)) error {
	mu.Lock()
	defer mu.Unlock()

	inputJSON, _ := json.Marshal(opts)

	doneChan := make(chan []byte, 1)

	cbPre := purego.NewCallback(func(cStr *byte) {
		str := parseCString(cStr)
		if onPre != nil {
			var wrapper MTPResponse
			if err := json.Unmarshal(str, &wrapper); err == nil {
				onPre(wrapper.Data)
			}
		}
	})
	cbProg := purego.NewCallback(func(cStr *byte) {
		str := parseCString(cStr)
		if onProg != nil {
			var wrapper MTPResponse
			if err := json.Unmarshal(str, &wrapper); err == nil {
				dataBytes, _ := json.Marshal(wrapper.Data)
				var prog TransferProgress
				json.Unmarshal(dataBytes, &prog)
				onProg(prog)
			}
		}
	})
	cbDone := purego.NewCallback(func(cStr *byte) {
		doneChan <- parseCString(cStr)
	})

	fnUploadFiles(string(inputJSON), cbPre, cbProg, cbDone)

	raw := <-doneChan

	return parseErrorOnly(raw)
}

// DownloadFiles downloads files
func (m *Manager) DownloadFiles(opts TransferOptions, onPre func(interface{}), onProg func(TransferProgress)) error {
	mu.Lock()
	defer mu.Unlock()

	inputJSON, _ := json.Marshal(opts)

	doneChan := make(chan []byte, 1)

	cbPre := purego.NewCallback(func(cStr *byte) {
		str := parseCString(cStr)
		if onPre != nil {
			var wrapper MTPResponse
			if err := json.Unmarshal(str, &wrapper); err == nil {
				onPre(wrapper.Data)
			}
		}
	})
	cbProg := purego.NewCallback(func(cStr *byte) {
		str := parseCString(cStr)
		if onProg != nil {
			var wrapper MTPResponse
			if err := json.Unmarshal(str, &wrapper); err == nil {
				dataBytes, _ := json.Marshal(wrapper.Data)
				var prog TransferProgress
				json.Unmarshal(dataBytes, &prog)
				onProg(prog)
			}
		}
	})
	cbDone := purego.NewCallback(func(cStr *byte) {
		doneChan <- parseCString(cStr)
	})

	fnDownloadFiles(string(inputJSON), cbPre, cbProg, cbDone)

	raw := <-doneChan

	return parseErrorOnly(raw)
}

// DeleteFile deletes files
func (m *Manager) DeleteFile(opts DeleteOptions) error {
	mu.Lock()
	defer mu.Unlock()

	inputJSON, _ := json.Marshal(opts)
	resChan := make(chan []byte, 1)
	cb := purego.NewCallback(func(cStr *byte) {
		resChan <- parseCString(cStr)
	})

	fnDeleteFile(string(inputJSON), cb)
	raw := <-resChan

	return parseErrorOnly(raw)
}

// MakeDirectory creates directory
func (m *Manager) MakeDirectory(opts MakeDirOptions) error {
	mu.Lock()
	defer mu.Unlock()

	inputJSON, _ := json.Marshal(opts)
	resChan := make(chan []byte, 1)
	cb := purego.NewCallback(func(cStr *byte) {
		resChan <- parseCString(cStr)
	})

	fnMakeDirectory(string(inputJSON), cb)
	raw := <-resChan

	return parseErrorOnly(raw)
}

// Dispose library
func (m *Manager) Dispose() error {
	mu.Lock()
	defer mu.Unlock()

	resChan := make(chan []byte, 1)
	cb := purego.NewCallback(func(cStr *byte) {
		resChan <- parseCString(cStr)
	})

	fnDispose(cb)
	raw := <-resChan

	return parseErrorOnly(raw)
}

func parseErrorOnly(raw []byte) error {
	var resp MTPResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		return err
	}
	if resp.Error != "" {
		return errors.New(resp.Error)
	}
	return nil
}
