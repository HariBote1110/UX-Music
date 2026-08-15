package audio

import "testing"

// prefillSatisfied は「出力ストリームを開始してよいか」を決める純粋関数。
// 初回再生時、decoderLoop がリングバッファへ十分な量を書き込む前に
// stream.Start() してしまうと、processAudio のコールバックが空/半端な
// バッファを読み、音が途切れる／歪む不具合が発生していた。
func TestPrefillSatisfied(t *testing.T) {
	const framesPerBuffer = 4096
	const channels = 2
	threshold := framesPerBuffer * channels

	cases := []struct {
		name            string
		available       int
		decoderFinished bool
		want            bool
	}{
		{"buffer empty, decoder still running", 0, false, false},
		{"below one FramesPerBuffer, decoder still running", threshold - 1, false, false},
		{"exactly at threshold, decoder still running", threshold, false, true},
		{"above threshold, decoder still running", threshold + 512, false, true},
		{"decoder already finished with a very short track (never reaches threshold)", 10, true, true},
		{"decoder already finished with an empty buffer", 0, true, true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := prefillSatisfied(tc.available, framesPerBuffer, channels, tc.decoderFinished)
			if got != tc.want {
				t.Fatalf("prefillSatisfied(available=%d, framesPerBuffer=%d, channels=%d, decoderFinished=%v) = %v, want %v",
					tc.available, framesPerBuffer, channels, tc.decoderFinished, got, tc.want)
			}
		})
	}
}
