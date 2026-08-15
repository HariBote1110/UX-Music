package audio

import "testing"

// NewPlayer が起動時にワームアップを実行しても、失敗を Player の初期化に
// 波及させてはならない（warmUpOutputDevice はベストエフォート）。出力
// デバイスの無い CI 環境や 48kHz/stereo を拒否するデバイスでも NewPlayer
// は必ず使用可能な Player を返すこと。
func TestNewPlayerSucceedsRegardlessOfWarmUp(t *testing.T) {
	player, err := NewPlayer()
	if err != nil {
		t.Fatalf("NewPlayer failed: %v", err)
	}
	if player == nil {
		t.Fatal("NewPlayer returned a nil player without error")
	}
	defer player.Close()
}

// warmUpOutputDevice はデバイス未解決時（出力デバイスが存在しない）には
// 何も開かず、静かに戻ること。パニックせず、Player の再生系フィールド
// （p.stream 等）にも触れないことをあわせて確認する。
func TestWarmUpOutputDeviceNoOutputDeviceIsNoOp(t *testing.T) {
	player := &Player{}
	// currentDevice も devices も未設定 = resolvedOutputDevice がシステム
	// デフォルトへフォールバックする。テスト環境でデフォルト出力が存在
	// する場合はそのまま短時間ウォームアップされるが、いずれの経路でも
	// panic せず、また再生用フィールドを変更しないことを検証する。
	player.warmUpOutputDevice()

	if player.stream != nil {
		t.Fatal("warmUpOutputDevice must not assign p.stream")
	}
	if player.sampleRate != 0 {
		t.Fatal("warmUpOutputDevice must not mutate p.sampleRate")
	}
}
