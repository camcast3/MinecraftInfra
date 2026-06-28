package logging

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// freshLogger returns a logger writing to <dir>/nz.log with the console set to
// ERROR so test runs stay quiet, plus the resolved file path.
func freshLogger(t *testing.T) (*Logger, string) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, LogFileName)
	l := &Logger{consoleLevel: LevelError}
	l.SetLogFile(path)
	return l, path
}

func TestEmitWritesLeveledLines(t *testing.T) {
	l, path := freshLogger(t)
	l.emit(LevelInfo, "info-line", "", os.Stdout)
	l.emit(LevelWarn, "warn-line", "", os.Stderr)
	l.emit(LevelError, "error-line", "", os.Stderr)
	l.close()

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read log: %v", err)
	}
	got := string(data)
	for _, want := range []string{"[INFO] info-line", "[WARN] warn-line", "[ERROR] error-line"} {
		if !strings.Contains(got, want) {
			t.Errorf("log missing %q; got:\n%s", want, got)
		}
	}
}

func TestEmitStripsAnsiForNonTTY(t *testing.T) {
	colored := "\x1b[38;2;102;102;102m  hi\x1b[m"
	if !strings.Contains(colored, "\x1b[") {
		t.Fatal("test input must contain ANSI SGR escapes")
	}

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	defer r.Close()

	l := &Logger{consoleLevel: LevelInfo}
	l.emit(LevelInfo, "hi", colored, w)
	if err := w.Close(); err != nil {
		t.Fatalf("close pipe writer: %v", err)
	}

	data, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("read pipe: %v", err)
	}
	got := string(data)
	if strings.Contains(got, "\x1b[") {
		t.Fatalf("console output contains ANSI escape: %q", got)
	}
	if strings.TrimRight(got, "\r\n") != "  hi" {
		t.Fatalf("console output = %q, want stripped text", got)
	}
}

func TestANSISGRStripsColorSequences(t *testing.T) {
	input := "plain \x1b[38;2;102;102;102mhi\x1b[m \x1b[1;32mthere\x1b[0m"
	if got, want := ansiSGR.ReplaceAllString(input, ""), "plain hi there"; got != want {
		t.Fatalf("ansiSGR.ReplaceAllString() = %q, want %q", got, want)
	}
}

func TestStreamSupportsColorHonorsNoColor(t *testing.T) {
	t.Setenv("NO_COLOR", "1")
	if streamSupportsColor(os.Stdout) {
		t.Fatal("streamSupportsColor returned true with NO_COLOR set")
	}
}

func TestPendingBufferFlushesToInstance(t *testing.T) {
	dir := t.TempDir()
	l := &Logger{consoleLevel: LevelError}
	// No file attached yet: these buffer.
	l.fileOnly("--- header ---")
	l.emit(LevelInfo, "buffered-before-attach", "", os.Stdout)

	path := filepath.Join(dir, LogFileName)
	l.SetLogFile(path)
	l.emit(LevelInfo, "after-attach", "", os.Stdout)
	l.close()

	data, _ := os.ReadFile(path)
	got := string(data)
	for _, want := range []string{"--- header ---", "buffered-before-attach", "after-attach"} {
		if !strings.Contains(got, want) {
			t.Errorf("flushed log missing %q; got:\n%s", want, got)
		}
	}
}

func TestPendingFlushesToFallbackOnClose(t *testing.T) {
	dir := t.TempDir()
	fallback := filepath.Join(dir, "global", LogFileName)
	l := &Logger{consoleLevel: LevelError, fallback: fallback}
	l.emit(LevelError, "no-instance-error", "", os.Stderr)
	l.close()

	data, err := os.ReadFile(fallback)
	if err != nil {
		t.Fatalf("read fallback: %v", err)
	}
	if !strings.Contains(string(data), "no-instance-error") {
		t.Errorf("fallback log missing buffered line; got:\n%s", data)
	}
}

func TestRotationAtSizeThreshold(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, LogFileName)
	// Pre-seed an oversized log file.
	big := strings.Repeat("x", maxLogBytes+10)
	if err := os.WriteFile(path, []byte(big), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	l := &Logger{consoleLevel: LevelError}
	l.SetLogFile(path)
	l.emit(LevelInfo, "fresh-line", "", os.Stdout)
	l.close()

	if _, err := os.Stat(path + ".1"); err != nil {
		t.Errorf("expected rotated %s.1 to exist: %v", path, err)
	}
	data, _ := os.ReadFile(path)
	if len(data) >= maxLogBytes {
		t.Errorf("new log should be small after rotation, got %d bytes", len(data))
	}
	if !strings.Contains(string(data), "fresh-line") {
		t.Errorf("new log missing fresh line")
	}
}

func TestNilLoggerDoesNotPanic(t *testing.T) {
	var l *Logger
	// None of these should panic on a nil receiver.
	l.emit(LevelInfo, "x", "y", os.Stdout)
	l.fileOnly("z")
	l.SetLogFile("ignored")
	l.close()
}

func TestWriterCapturesLines(t *testing.T) {
	// Writer operates on the global logger; attach it to a temp file.
	dir := t.TempDir()
	path := filepath.Join(dir, LogFileName)
	std = &Logger{consoleLevel: LevelError}
	std.SetLogFile(path)
	w := Writer(LevelDebug)
	_, _ = w.Write([]byte("first line\r\nsecond line\n"))
	_, _ = w.Write([]byte("partial "))
	_, _ = w.Write([]byte("completed\n"))
	std.close()

	data, _ := os.ReadFile(path)
	got := string(data)
	for _, want := range []string{"[DEBUG] first line", "[DEBUG] second line", "[DEBUG] partial completed"} {
		if !strings.Contains(got, want) {
			t.Errorf("writer log missing %q; got:\n%s", want, got)
		}
	}
}

func TestGlobalLogPathHonorsEnvOverride(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("NEGATIVEZONE_LOG_DIR", dir)
	got := GlobalLogPath()
	want := filepath.Join(dir, LogFileName)
	if got != want {
		t.Errorf("GlobalLogPath() = %q, want %q", got, want)
	}
}
