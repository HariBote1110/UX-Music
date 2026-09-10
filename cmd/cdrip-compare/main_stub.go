//go:build !darwin

package main

import "fmt"

func main() { fmt.Println("cdrip-compare is supported only on macOS") }
