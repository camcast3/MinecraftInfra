//go:build !windows

package transaction

import "os"

func replaceFile(src, dst string) error {
	return os.Rename(src, dst)
}
