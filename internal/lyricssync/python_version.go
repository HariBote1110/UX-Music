package lyricssync

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

func lyricsDummyModeEnabledInEnv() bool {
	v := strings.ToLower(strings.TrimSpace(os.Getenv("UX_MUSIC_LYRICS_SYNC_DUMMY")))
	return v == "1" || v == "true" || v == "yes"
}

// verifyLyricsSidecarPython fails if exe is not CPython 3.10–3.12 inclusive
// (matches python/pyproject.toml requires-python upper bound below 3.13).
func verifyLyricsSidecarPython(exe string) error {
	cmd := exec.Command(exe, "-c", `
import sys
vi = sys.version_info[:2]
raise SystemExit(0 if (3, 10) <= vi <= (3, 12) else 1)
`)
	out, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	txt := strings.TrimSpace(string(out))
	hint := "python/.venv が古いバージョン（例: Python 3.14）で作られていることが多いです。リポジトリルートで " +
		"「rm -rf python/.venv && make lyrics-sync-python」を実行してください。Homebrew を使う場合は `brew install python@3.12` 後に再度 make してください。"
	msg := fmt.Errorf(
		"歌詞同期用 Python が要件を満たしません (要 CPython 3.10〜3.12)。現在の実行ファイル: %s\n%s",
		exe,
		hint,
	)
	if txt != "" {
		return fmt.Errorf("%w\ninterpreter出力: %s", msg, txt)
	}
	return msg
}
