//go:build !windows

package server

import "syscall"

// processAliveForTest は TestRemoteFileHandler_StreamAAC_ClientDisconnectKillsFfmpeg
// が使う生存確認ヘルパー。signal 0 は実際にはシグナルを配送せず、プロセスの
// 存在確認だけを行う（internal/llamasrv の isProcAlive と同じ手法）。
func processAliveForTest(pid int) bool {
	if pid <= 0 {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}
