package audio

import (
	"reflect"
	"testing"
)

func TestIsWebKitHelperPath(t *testing.T) {
	t.Parallel()
	cases := []struct {
		path string
		want bool
	}{
		{"/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU", true},
		{"/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent", true},
		{"/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking", true},
		{"/Applications/UX-Music.app/Contents/MacOS/UX-Music", false},
		{"/usr/bin/afplay", false},
		{"", false},
	}
	for _, c := range cases {
		if got := isWebKitHelperPath(c.path); got != c.want {
			t.Errorf("isWebKitHelperPath(%q) = %v, want %v", c.path, got, c.want)
		}
	}
}

const (
	gpuPath = "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
	wcPath  = "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
	appPath = "/Applications/UX-Music.app/Contents/MacOS/UX-Music"
)

// 自プロセスの子孫にある WebKit ヘルパーだけを対象とし、他アプリ（Safari）の
// 共有 WebKit ヘルパーは除外すること。
func TestWebKitHelperPIDsForSelfSelectsOwnDescendantsOnly(t *testing.T) {
	t.Parallel()
	const self = 1000
	procs := []procInfo{
		{PID: 1, PPID: 0, Path: "/sbin/launchd"},
		{PID: self, PPID: 1, Path: appPath},
		// 自アプリ配下の WebKit ヘルパー（子）
		{PID: 1001, PPID: self, Path: gpuPath},
		{PID: 1002, PPID: self, Path: wcPath},
		// 自アプリ配下の孫（WebContent が更に子を持つ構成）
		{PID: 1003, PPID: 1002, Path: gpuPath},
		// Safari（別アプリ）とその WebKit ヘルパー
		{PID: 2000, PPID: 1, Path: "/Applications/Safari.app/Contents/MacOS/Safari"},
		{PID: 2001, PPID: 2000, Path: gpuPath},
		{PID: 2002, PPID: 2000, Path: wcPath},
	}
	got := webKitHelperPIDsForSelf(procs, self)
	want := []int{1001, 1002, 1003}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v (他アプリの WebKit ヘルパーが混入または自配下が漏れている)", got, want)
	}
}

// XPC で launchd 直下に起動され、親チェーンが自プロセスに到達しない共有
// ヘルパーでも、responsible プロセスが自プロセス（またはその子孫）なら対象に
// 含めること。responsible が他アプリのものは除外すること。
func TestWebKitHelperPIDsForSelfUsesResponsiblePID(t *testing.T) {
	t.Parallel()
	const self = 1000
	procs := []procInfo{
		{PID: 1, PPID: 0, Path: "/sbin/launchd"},
		{PID: self, PPID: 1, Path: appPath},
		// launchd 直下だが responsible が自プロセス → 対象
		{PID: 1500, PPID: 1, ResponsiblePID: self, Path: gpuPath},
		// launchd 直下で responsible も他アプリ → 除外
		{PID: 2500, PPID: 1, ResponsiblePID: 2000, Path: gpuPath},
		{PID: 2000, PPID: 1, Path: "/Applications/Safari.app/Contents/MacOS/Safari"},
	}
	got := webKitHelperPIDsForSelf(procs, self)
	want := []int{1500}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v (responsible ベースの帰属が誤り)", got, want)
	}
}

// WebKit ヘルパーが自配下に存在しない場合は空を返すこと（呼び出し側が
// 対象 0 件として扱えるようにする）。
func TestWebKitHelperPIDsForSelfReturnsEmptyWhenNoneOwned(t *testing.T) {
	t.Parallel()
	const self = 1000
	procs := []procInfo{
		{PID: self, PPID: 1, Path: appPath},
		{PID: 2000, PPID: 1, Path: "/Applications/Safari.app/Contents/MacOS/Safari"},
		{PID: 2001, PPID: 2000, Path: gpuPath},
	}
	if got := webKitHelperPIDsForSelf(procs, self); len(got) != 0 {
		t.Fatalf("got %v, want empty", got)
	}
}

// 自プロセス自身は（WebKit 判定に掛からないが念のため）対象に含めないこと。
func TestWebKitHelperPIDsForSelfExcludesSelf(t *testing.T) {
	t.Parallel()
	const self = 1000
	procs := []procInfo{
		{PID: self, PPID: 1, ResponsiblePID: self, Path: gpuPath},
	}
	if got := webKitHelperPIDsForSelf(procs, self); len(got) != 0 {
		t.Fatalf("got %v, want empty (自プロセスは除外)", got)
	}
}
