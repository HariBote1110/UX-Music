//go:build windows

package server

import "syscall"

// windowsStillActive は GetExitCodeProcess が「まだ実行中」を表すために返す
// 値（Windows API の STILL_ACTIVE = 259）。internal/llamasrv/proc_windows.go
// と同じ理由・同じ手法だが、パッケージが異なるため定義も分けている。
const windowsStillActive = 259

// processAliveForTest は Unix の signal 0 に相当する生存確認手段が Windows
// には無いため、OpenProcess + GetExitCodeProcess で代替する。
func processAliveForTest(pid int) bool {
	if pid <= 0 {
		return false
	}
	h, err := syscall.OpenProcess(syscall.PROCESS_QUERY_INFORMATION, false, uint32(pid))
	if err != nil {
		return false
	}
	defer syscall.CloseHandle(h)

	var exitCode uint32
	if err := syscall.GetExitCodeProcess(h, &exitCode); err != nil {
		return false
	}
	return exitCode == windowsStillActive
}
