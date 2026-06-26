// Package logging provides file-based logging for NegativeZone client operations.
package logging

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Logger writes timestamped log lines to a file and optionally to stdout.
type Logger struct {
	path   string
	mu     sync.Mutex
	quiet  bool
	prefix string
}

// New creates a logger that writes to the given file path.
// Parent directories are created if needed.
func New(path string, prefix string) (*Logger, error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("creating log directory: %w", err)
	}
	return &Logger{path: path, prefix: prefix}, nil
}

// SetQuiet suppresses stdout echo (log file still written).
func (l *Logger) SetQuiet(q bool) { l.quiet = q }

func (l *Logger) write(level, msg string) {
	l.mu.Lock()
	defer l.mu.Unlock()

	line := fmt.Sprintf("%s [%s] %s\n", time.Now().Format(time.RFC3339), level, msg)

	// Best-effort file write
	if f, err := os.OpenFile(l.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
		_, _ = f.WriteString(line)
		_ = f.Close()
	}

	if !l.quiet {
		fmt.Printf("[%s] %s\n", l.prefix, msg)
	}
}

func (l *Logger) Info(msg string)                 { l.write("INFO", msg) }
func (l *Logger) Infof(f string, a ...any)        { l.write("INFO", fmt.Sprintf(f, a...)) }
func (l *Logger) Warn(msg string)                 { l.write("WARN", msg) }
func (l *Logger) Warnf(f string, a ...any)        { l.write("WARN", fmt.Sprintf(f, a...)) }
func (l *Logger) Error(msg string)                { l.write("ERROR", msg) }
func (l *Logger) Errorf(f string, a ...any)       { l.write("ERROR", fmt.Sprintf(f, a...)) }
