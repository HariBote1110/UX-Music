// Reproduces the libusb context leak in go-mtpfs SelectDevice by calling it
// repeatedly with no MTP device attached, logging the open FD count.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"

	gomtp "github.com/ganeshrvel/go-mtpfs/mtp"
)

func fdCount() int {
	out, _ := exec.Command("sh", "-c", "lsof -p "+strconv.Itoa(os.Getpid())+" | wc -l").Output()
	n, _ := strconv.Atoi(strings.TrimSpace(string(out)))
	return n - 1
}

func main() {
	var rl syscall.Rlimit
	syscall.Getrlimit(syscall.RLIMIT_NOFILE, &rl)
	fmt.Printf("rlimit nofile: soft=%d hard=%d\n", rl.Cur, rl.Max)
	for i := 1; ; i++ {
		_, err := gomtp.SelectDevice("")
		if i%50 == 0 || i > 440 {
			fmt.Printf("iter=%d fds=%d err=%v\n", i, fdCount(), err)
		}
	}
}
