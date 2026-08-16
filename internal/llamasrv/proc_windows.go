//go:build windows

package llamasrv

import (
	"os/exec"
	"syscall"
)

// windowsStillActive は GetExitCodeProcess が「まだ実行中」を表すために返す
// 定数値（Windows API の STILL_ACTIVE = 259）。exec/syscall パッケージには
// 定義が無いためここで持つ。
const windowsStillActive = 259

// configureProcAttr は起動前に呼ばれる。Unix 版はここで Setpgid を使って
// 独立プロセスグループを作るが、syscall.SysProcAttr に Setpgid フィールドが
// 存在するのは POSIX 系のみで Windows には無い。CREATE_NEW_PROCESS_GROUP を
// 指定しておくと Ctrl+Break 相当のグループシグナルは送れるようになるが、
// 本実装は Kill（強制終了）しか使わないため実質的な意味は薄い。それでも
// 将来グループ単位の制御を足す余地を残すために設定しておく。
func configureProcAttr(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP}
}

// terminateProc: Windows には SIGTERM に相当する「穏当な終了」を促す
// 標準的な手段が無い（GenerateConsoleCtrlEvent はコンソールを共有する
// プロセスにしか届かず、ここでは条件を満たさない）。そのため Unix 版のような
// 段階的エスカレーション（SIGTERM→3秒待機→SIGKILL）を模倣せず、最初から
// TerminateProcess 相当の強制終了（cmd.Process.Kill）を行う。
// これは Unix 版より弱い挙動であり、llama-server 側に終了処理（一時ファイル
// 削除等）が将来追加された場合はここが先に壊れる点に注意。
func terminateProc(cmd *exec.Cmd) error {
	return cmd.Process.Kill()
}

// isProcAlive は Unix 版の「signal 0」に相当する生存確認手段が Windows には
// 無いため、syscall.OpenProcess + syscall.GetExitCodeProcess で代替する。
// プロセスハンドルを取得できない、または GetExitCodeProcess が
// STILL_ACTIVE 以外を返した場合は「生存していない」とみなす。
func isProcAlive(cmd *exec.Cmd) bool {
	h, err := syscall.OpenProcess(syscall.PROCESS_QUERY_INFORMATION, false, uint32(cmd.Process.Pid))
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
