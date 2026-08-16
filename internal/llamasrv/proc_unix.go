//go:build !windows

package llamasrv

import (
	"os/exec"
	"syscall"
)

// configureProcAttr は起動前に呼ばれ、子プロセスを独立したプロセスグループに
// 所属させる。SIGTERM をプロセスグループ全体へ送って一括終了させるための下準備。
func configureProcAttr(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// terminateProc は SIGTERM を送って穏当な終了を促す。呼び出し側
// (terminateLocked) が一定時間後に Kill へエスカレーションする。
func terminateProc(cmd *exec.Cmd) error {
	return cmd.Process.Signal(syscall.SIGTERM)
}

// isProcAlive は signal 0 を送ってプロセスの生死だけを確認する
// （実際にシグナルは配送されない、Unix の伝統的な生存確認手段）。
func isProcAlive(cmd *exec.Cmd) bool {
	return cmd.Process.Signal(syscall.Signal(0)) == nil
}
