package main

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"time"
	"ux-music-sidecar/pkg/mtp"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
	"golang.org/x/text/unicode/norm"
	"golang.org/x/text/width"
)

func (a *App) MTPInitialize() error {
	return a.mtpManager.Initialize()
}

func (a *App) MTPFetchDeviceInfo() (map[string]interface{}, error) {
	return a.mtpManager.FetchDeviceInfo()
}

func (a *App) MTPFetchStorages() ([]mtp.Storage, error) {
	return a.mtpManager.FetchStorages()
}

func (a *App) MTPWalk(opts mtp.WalkOptions) (interface{}, error) {
	fmt.Printf("[Wails] MTPWalk called: StorageID=%d, Path=%s\n", opts.StorageID, opts.FullPath)
	res, err := a.mtpManager.Walk(opts)
	if err != nil {
		fmt.Printf("[Wails] MTPWalk error: %v\n", err)
		return nil, err
	}
	return map[string]interface{}{
		"data": res,
	}, nil
}

func (a *App) MTPUploadFiles(opts mtp.TransferOptions) error {
	return a.mtpManager.UploadFiles(opts, func(data interface{}) {
		wailsRuntime.EventsEmit(a.ctx, "mtp-upload-preprocess", data)
	}, func(prog mtp.TransferProgress) {
		wailsRuntime.EventsEmit(a.ctx, "mtp-upload-progress", prog)
	})
}

func (a *App) MTPDownloadFiles(opts mtp.TransferOptions) error {
	return a.mtpManager.DownloadFiles(opts, func(data interface{}) {
		wailsRuntime.EventsEmit(a.ctx, "mtp-download-preprocess", data)
	}, func(prog mtp.TransferProgress) {
		wailsRuntime.EventsEmit(a.ctx, "mtp-download-progress", prog)
	})
}

func (a *App) MTPUploadFilesWithStructure(data map[string]interface{}) (map[string]interface{}, error) {
	storageID := uint32(data["storageId"].(float64))
	transferList := data["transferList"].([]interface{})

	fmt.Printf("[Wails] MTPUploadFilesWithStructure: storage=%d, items=%d\n", storageID, len(transferList))

	groups := make(map[string][]string)
	for _, item := range transferList {
		m := item.(map[string]interface{})
		src := m["source"].(string)
		dest := m["destination"].(string)
		groups[dest] = append(groups[dest], src)
	}

	successCount := 0
	errorCount := 0

	for dest, sources := range groups {
		parts := strings.Split(strings.Trim(dest, "/"), "/")
		currentPath := ""
		for _, part := range parts {
			currentPath += "/" + part
			_ = a.mtpManager.MakeDirectory(mtp.MakeDirOptions{
				StorageID: storageID,
				FullPath:  currentPath,
			})
		}

		err := a.mtpManager.UploadFiles(mtp.TransferOptions{
			StorageID:   storageID,
			Sources:     sources,
			Destination: dest,
		}, func(data interface{}) {
			wailsRuntime.EventsEmit(a.ctx, "mtp-upload-preprocess", data)
		}, func(prog mtp.TransferProgress) {
			wailsRuntime.EventsEmit(a.ctx, "mtp-upload-progress", prog)
		})

		if err != nil {
			fmt.Printf("[Wails] Upload error to %s: %v\n", dest, err)
			errorCount += len(sources)
		} else {
			successCount += len(sources)
		}
	}

	return map[string]interface{}{
		"successCount": successCount,
		"errorCount":   errorCount,
	}, nil
}

func (a *App) MTPDeleteFile(opts mtp.DeleteOptions) error {
	return a.mtpManager.DeleteFile(opts)
}

func (a *App) MTPMakeDirectory(opts mtp.MakeDirOptions) error {
	return a.mtpManager.MakeDirectory(opts)
}

func (a *App) MTPDispose() error {
	return a.mtpManager.Dispose()
}

func (a *App) MTPGetUntransferredSongs(librarySongs []interface{}) (map[string]interface{}, error) {
	fmt.Printf("[Wails] MTPGetUntransferredSongs started: processing %d library songs\n", len(librarySongs))

	a.mtpMu.Lock()
	connected := a.mtpConnected
	a.mtpMu.Unlock()

	if !connected {
		fmt.Println("[Wails] MTPGetUntransferredSongs: device not connected")
		return map[string]interface{}{
			"untransferredSongs": []interface{}{},
			"deviceFilesList":    []interface{}{},
		}, nil
	}

	deviceFilesMap := make(map[string][]map[string]interface{})
	deviceFilesList := make([]map[string]interface{}, 0)

	storages, err := a.mtpManager.FetchStorages()
	if err != nil || len(storages) == 0 {
		return nil, fmt.Errorf("failed to fetch storages: %v", err)
	}
	storageID := storages[0].ID

	var scanDir func(string)
	scanDir = func(path string) {
		res, err := a.mtpManager.Walk(mtp.WalkOptions{
			StorageID:       storageID,
			FullPath:        path,
			SkipHiddenFiles: true,
		})
		if err != nil {
			fmt.Printf("[Wails] scanDir error (%s): %v\n", path, err)
			return
		}

		items, ok := res.([]interface{})
		if !ok {
			return
		}

		for _, item := range items {
			m, ok := item.(map[string]interface{})
			if !ok {
				continue
			}

			name, _ := m["name"].(string)
			isFolder, _ := m["isFolder"].(bool)
			path, _ := m["path"].(string)

			var size int64
			if s, ok := m["size"].(float64); ok {
				size = int64(s)
			} else if s, ok := m["size"].(json.Number); ok {
				size, _ = s.Int64()
			}

			if isFolder {
				if path != "" {
					scanDir(path)
				}
			} else {
				normName := normalizeFileNameGo(name)
				fileInfo := map[string]interface{}{
					"name":           name,
					"normalizedName": normName,
					"size":           size,
					"path":           path,
				}
				deviceFilesList = append(deviceFilesList, fileInfo)
				deviceFilesMap[normName] = append(deviceFilesMap[normName], fileInfo)
			}
		}
	}

	scanDir("/Music/")
	fmt.Printf("[Wails] Scan complete: %d files found on device\n", len(deviceFilesList))

	untransferredSongs := make([]interface{}, 0)
	for _, song := range librarySongs {
		sMap, ok := song.(map[string]interface{})
		if !ok {
			continue
		}

		pathStr, _ := sMap["path"].(string)
		if pathStr == "" {
			continue
		}

		fileName := filepath.Base(pathStr)
		normName := normalizeFileNameGo(fileName)

		if _, exists := deviceFilesMap[normName]; !exists {
			sMap["_reason"] = fmt.Sprintf("名前不一致: \"%s\"", normName)
			sMap["_normalizedName"] = normName
			untransferredSongs = append(untransferredSongs, sMap)
		}
	}

	fmt.Printf("[Wails] Found %d untransferred songs\n", len(untransferredSongs))
	return map[string]interface{}{
		"untransferredSongs": untransferredSongs,
		"deviceFilesList":    deviceFilesList,
	}, nil
}

func normalizeFileNameGo(fileName string) string {
	name := norm.NFC.String(fileName)
	name = width.Fold.String(name)
	name = strings.ToLower(name)
	return name
}

func (a *App) GetMTPDevices() (interface{}, error) {
	fmt.Println("[Wails] GetMTPDevices called")
	a.mtpMu.Lock()
	connected := a.mtpConnected
	a.mtpMu.Unlock()

	if !connected {
		return map[string]interface{}{
			"device":   nil,
			"storages": []interface{}{},
		}, nil
	}

	deviceInfo, _ := a.mtpManager.FetchDeviceInfo()
	storages, _ := a.mtpManager.FetchStorages()

	storagesForUI := make([]map[string]interface{}, 0)
	for _, s := range storages {
		storagesForUI = append(storagesForUI, map[string]interface{}{
			"id":          s.ID,
			"free":        s.Info.FreeSpaceInBytes,
			"total":       s.Info.MaxCapability,
			"description": s.Info.StorageDescription,
		})
	}

	deviceName := "MTP Device"
	if deviceInfo != nil {
		if mtpInfo, ok := deviceInfo["mtpDeviceInfo"].(map[string]interface{}); ok {
			if name, ok := mtpInfo["Model"].(string); ok && name != "" {
				deviceName = name
			}
		}
	}

	return map[string]interface{}{
		"device": map[string]interface{}{
			"name": deviceName,
		},
		"storages": storagesForUI,
	}, nil
}

func (a *App) startMTPMonitor() {
	go func() {
		ticker := time.NewTicker(3 * time.Second)
		defer ticker.Stop()

		fmt.Println("[MTP Monitor] Started polling for MTP devices")

		for range ticker.C {
			a.mtpMu.Lock()
			wasConnected := a.mtpConnected
			a.mtpMu.Unlock()

			if wasConnected {
				_, err := a.mtpManager.FetchStorages()
				if err != nil {
					fmt.Println("[MTP Monitor] Device disconnected")
					a.mtpManager.Dispose()
					a.mtpMu.Lock()
					a.mtpConnected = false
					a.mtpMu.Unlock()
					wailsRuntime.EventsEmit(a.ctx, "mtp-device-disconnected")
				}
				continue
			}

			err := a.mtpManager.Initialize()
			if err != nil {
				continue
			}

			fmt.Println("[MTP Monitor] Device connected, fetching info...")

			deviceInfo, err := a.mtpManager.FetchDeviceInfo()
			if err != nil {
				fmt.Printf("[MTP Monitor] Failed to fetch device info: %v\n", err)
				a.mtpManager.Dispose()
				continue
			}

			storages, err := a.mtpManager.FetchStorages()
			if err != nil {
				fmt.Printf("[MTP Monitor] Failed to fetch storages: %v\n", err)
				a.mtpManager.Dispose()
				continue
			}
			fmt.Printf("[MTP Monitor] Fetched %d storages: %+v\n", len(storages), storages)

			storagesForUI := make([]map[string]interface{}, 0)
			for _, s := range storages {
				storagesForUI = append(storagesForUI, map[string]interface{}{
					"id":          s.ID,
					"free":        s.Info.FreeSpaceInBytes,
					"total":       s.Info.MaxCapability,
					"description": s.Info.StorageDescription,
				})
			}

			deviceName := "MTP Device"
			if deviceInfo != nil {
				if mtpInfo, ok := deviceInfo["mtpDeviceInfo"].(map[string]interface{}); ok {
					if name, ok := mtpInfo["Model"].(string); ok && name != "" {
						deviceName = name
					}
				}
				if deviceName == "MTP Device" {
					if usbInfo, ok := deviceInfo["usbDeviceInfo"].(map[string]interface{}); ok {
						if name, ok := usbInfo["Product"].(string); ok && name != "" {
							deviceName = name
						}
					}
				}
			}

			payload := map[string]interface{}{
				"device": map[string]interface{}{
					"name":          deviceName,
					"mtpDeviceInfo": deviceInfo,
				},
				"storages": storagesForUI,
			}

			a.mtpMu.Lock()
			a.mtpConnected = true
			a.mtpMu.Unlock()

			fmt.Printf("[MTP Monitor] Device connected: %s\n", deviceName)
			wailsRuntime.EventsEmit(a.ctx, "mtp-device-connected", payload)

			ticker.Reset(5 * time.Second)
		}
	}()
}
