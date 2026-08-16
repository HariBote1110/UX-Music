package flac

import "testing"

func TestCRC16_KnownVector(t *testing.T) {
	// The "check" value for the CRC-16/BUYPASS parameterisation (poly
	// 0x8005, init 0x0000, no reflection, no xorout) over the ASCII string
	// "123456789" is the standard cross-implementation test vector for
	// exactly this variant, which is what FLAC's frame footer CRC-16 uses.
	got := crc16([]byte("123456789"))
	want := uint16(0xFEE8)
	if got != want {
		t.Fatalf("crc16(%q) = %#04x, want %#04x", "123456789", got, want)
	}
}

func TestApplyStereoDecorrelation_Independent(t *testing.T) {
	ch0 := []int32{1, 2, 3}
	ch1 := []int32{4, 5, 6}
	chBufs := [][]int32{ch0, ch1}
	if err := applyStereoDecorrelation(ChannelIndependent, chBufs, 3); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if chBufs[0][0] != 1 || chBufs[1][0] != 4 {
		t.Fatalf("independent assignment must not modify channels, got %v %v", chBufs[0], chBufs[1])
	}
}

func TestApplyStereoDecorrelation_LeftSide(t *testing.T) {
	left := []int32{10, 20, 30}
	side := []int32{3, -5, 7} // left - right
	chBufs := [][]int32{left, side}
	if err := applyStereoDecorrelation(ChannelLeftSide, chBufs, 3); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	wantRight := []int32{7, 25, 23}
	for i, want := range wantRight {
		if chBufs[1][i] != want {
			t.Errorf("right[%d] = %d, want %d", i, chBufs[1][i], want)
		}
	}
	if chBufs[0][0] != 10 {
		t.Fatalf("left channel must be unchanged, got %v", chBufs[0])
	}
}

func TestApplyStereoDecorrelation_RightSide(t *testing.T) {
	side := []int32{3, -5, 7} // left - right
	right := []int32{7, 25, 23}
	chBufs := [][]int32{side, right}
	if err := applyStereoDecorrelation(ChannelRightSide, chBufs, 3); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	wantLeft := []int32{10, 20, 30}
	for i, want := range wantLeft {
		if chBufs[0][i] != want {
			t.Errorf("left[%d] = %d, want %d", i, chBufs[0][i], want)
		}
	}
	if chBufs[1][0] != 7 {
		t.Fatalf("right channel must be unchanged, got %v", chBufs[1])
	}
}

func TestApplyStereoDecorrelation_MidSide(t *testing.T) {
	// left=10, right=7  -> mid = (10+7)>>1 = 8, side = 10-7 = 3
	// left=20, right=25 -> mid = (20+25)>>1 = 22, side = 20-25 = -5
	mid := []int32{8, 22}
	side := []int32{3, -5}
	chBufs := [][]int32{mid, side}
	if err := applyStereoDecorrelation(ChannelMidSide, chBufs, 2); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	wantLeft := []int32{10, 20}
	wantRight := []int32{7, 25}
	for i := range wantLeft {
		if chBufs[0][i] != wantLeft[i] {
			t.Errorf("left[%d] = %d, want %d", i, chBufs[0][i], wantLeft[i])
		}
		if chBufs[1][i] != wantRight[i] {
			t.Errorf("right[%d] = %d, want %d", i, chBufs[1][i], wantRight[i])
		}
	}
}

func TestApplyStereoDecorrelation_RejectsTooFewChannels(t *testing.T) {
	chBufs := [][]int32{{1, 2, 3}}
	if err := applyStereoDecorrelation(ChannelMidSide, chBufs, 3); err == nil {
		t.Fatal("expected an error for mid/side with only 1 channel, got nil")
	}
}

func TestSubframeBitsForChannel(t *testing.T) {
	base := &FrameHeader{BitsPerSample: 16}

	cases := []struct {
		name       string
		assignment ChannelAssignment
		channel    int
		want       int
	}{
		{"independent ch0", ChannelIndependent, 0, 16},
		{"independent ch1", ChannelIndependent, 1, 16},
		{"left/side ch0 (left)", ChannelLeftSide, 0, 16},
		{"left/side ch1 (side)", ChannelLeftSide, 1, 17},
		{"right/side ch0 (side)", ChannelRightSide, 0, 17},
		{"right/side ch1 (right)", ChannelRightSide, 1, 16},
		{"mid/side ch0 (mid)", ChannelMidSide, 0, 16},
		{"mid/side ch1 (side)", ChannelMidSide, 1, 17},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := *base
			h.ChannelAssignmentType = tc.assignment
			if got := subframeBitsForChannel(&h, tc.channel); got != tc.want {
				t.Errorf("got %d, want %d", got, tc.want)
			}
		})
	}
}
