// Package lock provides cross-process file locking for NegativeZone client scripts.
package lock

import (
	"fmt"
	"os"
	"time"
)

// FileLock represents an exclusive file lock.
type FileLock struct {
	path string
	file *os.File
}

// Acquire attempts to take an exclusive lock at path. If a lock file exists
// and is older than staleAfter, it is removed and retried. Returns nil if the
// lock is already held by another process.
func Acquire(path string, staleAfter time.Duration) (*FileLock, error) {
	// Check for stale lock
	if info, err := os.Stat(path); err == nil {
		age := time.Since(info.ModTime())
		if age > staleAfter {
			_ = os.Remove(path)
		} else {
			return nil, nil // lock held by someone else
		}
	}

	// Try to create exclusively
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		if os.IsExist(err) {
			return nil, nil // race: someone else grabbed it
		}
		return nil, fmt.Errorf("acquiring lock: %w", err)
	}

	// Write PID for debugging
	_, _ = fmt.Fprintf(f, "%d\n", os.Getpid())

	return &FileLock{path: path, file: f}, nil
}

// Release closes the lock file handle and removes the lock file.
func (l *FileLock) Release() {
	if l.file != nil {
		_ = l.file.Close()
	}
	_ = os.Remove(l.path)
}
