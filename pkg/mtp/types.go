package mtp

// MTPResponse is the raw response structure from Kalam library
type MTPResponse struct {
	Error string      `json:"error"`
	Data  interface{} `json:"data"`
}

// Storage represents an MTP storage device
type Storage struct {
	ID          uint32 `json:"Id"`
	Description string `json:"Description"`
	Name        string `json:"Name"`
	Capacity    int64  `json:"Capacity"`
	FreeSpace   int64  `json:"FreeSpace"`
}

// FileInfo represents a file on MTP device
type FileInfo struct {
	Name     string `json:"name"`
	FullPath string `json:"fullPath"`
	Size     int64  `json:"size"`
	IsFolder bool   `json:"isFolder"`
	Date     string `json:"date"`
}

// WalkOptions input for Walk function
type WalkOptions struct {
	StorageID           uint32 `json:"storageId"`
	FullPath            string `json:"fullPath"`
	Recursive           bool   `json:"recursive"`
	SkipDisallowedFiles bool   `json:"skipDisallowedFiles"`
	SkipHiddenFiles     bool   `json:"skipHiddenFiles"`
}

// TransferOptions input for Upload/Download
type TransferOptions struct {
	StorageID       uint32   `json:"storageId"`
	Sources         []string `json:"sources"`
	Destination     string   `json:"destination"`
	PreprocessFiles bool     `json:"preprocessFiles"`
}

// TransferProgress progress event data
type TransferProgress struct {
	Name             string `json:"name"`
	FullPath         string `json:"fullPath"`
	BytesTransferred int64  `json:"bytesTransferred"`
	TotalBytes       int64  `json:"totalBytes"`
}

// DeleteOptions input for Delete function
type DeleteOptions struct {
	StorageID uint32   `json:"storageId"`
	Files     []string `json:"files"`
}

// MakeDirOptions input for MakeDirectory function
type MakeDirOptions struct {
	StorageID uint32 `json:"storageId"`
	FullPath  string `json:"fullPath"`
}
