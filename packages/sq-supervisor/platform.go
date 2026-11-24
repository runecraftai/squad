package main

import (
	"runtime"
)

// strictPlatform reports whether this build can honour strict Linux mode at
// all. Non-Linux hosts keep Squad's existing behaviour and never receive a
// half-guarantee from this binary.
func strictPlatform() bool {
	return runtime.GOOS == "linux"
}

func platformName() string {
	return runtime.GOOS + "/" + runtime.GOARCH
}
