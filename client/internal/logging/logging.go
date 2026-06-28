// Package logging is the single emission point for the NegativeZone client.
//
// Every user-facing line goes through this package, which does two things at
// once:
//
//   - writes a full-detail, timestamped, plain-text record to nz.log (always
//     at DEBUG and above), and
//   - renders a styled line to the console (stdout/stderr), filtered by the
//     active console verbosity level.
//
// This replaces the previous split where internal/logging wrote a file and
// internal/ui printed an unpersisted styled narrative. ui is now used only for
// the style palette and the interactive Spinner/ProgressBar widgets.
//
// # Log file target
//
// The logger starts in a buffered "pending" state at Init: lines are held in
// memory (and echoed to the console immediately) until a target is known.
// Commands call UseInstance once they resolve an instance directory, which
// flushes the buffer into <instance>/.negativezone/nz.log and continues writing
// there. If no instance is ever attached, Close flushes the buffer to a stable
// global fallback (%LOCALAPPDATA%\NegativeZone\nz.log, overridable via
// NEGATIVEZONE_LOG_DIR) so logs are always findable.
//
// # No held file handle
//
// Each line is written by opening the target file in append mode, writing, and
// closing it immediately. This matters on Windows: keeping nz.log open inside
// an instance directory would lock that directory and break setup's
// instance→.bak rename. Open-per-write keeps the volume-trivial CLI logging
// simple and lock-free.
//
// The global logger is always non-nil, so no command can crash on log init.
package logging

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/camcast3/MinecraftInfra/client/internal/ui"
)

// ansiSGR matches ANSI SGR (color/style) escape sequences, e.g. the truecolor
// `\x1b[38;2;102;102;102m` and reset `\x1b[m` that lipgloss emits.
var ansiSGR = regexp.MustCompile("\x1b\\[[0-9;]*m")

// streamSupportsColor reports whether f is an interactive terminal that can
// render ANSI color. False when f is a pipe/file — notably when Prism runs the
// PreLaunch/PostExit hooks via QProcess and captures their output, where raw
// `\x1b[..m` codes would otherwise leak into the launch console as literal text.
// Honors the NO_COLOR convention. Uses os.ModeCharDevice (stdlib, cross-platform)
// so no terminal dependency is needed.
func streamSupportsColor(f *os.File) bool {
	if f == nil || os.Getenv("NO_COLOR") != "" {
		return false
	}
	fi, err := f.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

var (
	stdoutColor = streamSupportsColor(os.Stdout)
	stderrColor = streamSupportsColor(os.Stderr)
)

func consoleStreamSupportsColor(stream *os.File) bool {
	switch stream {
	case os.Stdout:
		return stdoutColor
	case os.Stderr:
		return stderrColor
	default:
		return streamSupportsColor(stream)
	}
}

// Level controls both the file record tag and console filtering.
type Level int

const (
	LevelDebug Level = iota
	LevelInfo
	LevelWarn
	LevelError
)

func (l Level) tag() string {
	switch l {
	case LevelDebug:
		return "DEBUG"
	case LevelWarn:
		return "WARN"
	case LevelError:
		return "ERROR"
	default:
		return "INFO"
	}
}

// maxLogBytes is the size threshold at which nz.log is rotated to nz.log.1.
// Rotation is evaluated when a target file is (re)attached, i.e. once per run.
const maxLogBytes = 5 << 20 // 5 MiB

// LogFileName is the unified log file name written into an instance's
// .negativezone directory (and the global fallback location).
const LogFileName = "nz.log"

// Logger is the unified file + console logger. The zero value is unusable;
// use the package-level functions, which operate on a ready global instance.
type Logger struct {
	mu           sync.Mutex
	consoleLevel Level
	path         string   // target file; "" while buffering
	pending      []string // buffered file lines before a target is attached
	fallback     string   // global fallback path used by Close if no instance
	closed       bool
}

// std is the always-non-nil global logger. It is safe to use before Init: it
// simply buffers and echoes at the default INFO console level.
var std = &Logger{consoleLevel: LevelInfo}

// L returns the global logger.
func L() *Logger { return std }

// Init configures the global logger. It is called once from the root command's
// PersistentPreRunE. headerFields are appended (one per line) to the run header
// written at the top of this invocation's log section.
func Init(consoleLevel Level, explicitFile string, headerFields ...string) {
	std.mu.Lock()
	std.consoleLevel = consoleLevel
	std.fallback = globalFallbackPath()
	std.closed = false
	std.mu.Unlock()

	ui.SetQuiet(consoleLevel > LevelInfo)

	// Run header — file only, so console output stays clean.
	var b strings.Builder
	b.WriteString("──── nz run ")
	b.WriteString(time.Now().Format(time.RFC3339))
	b.WriteString(" ────")
	std.fileOnly(b.String())
	for _, f := range headerFields {
		std.fileOnly(f)
	}

	if explicitFile != "" {
		std.SetLogFile(explicitFile)
	}
}

// SetConsoleLevel adjusts console verbosity at runtime.
func SetConsoleLevel(l Level) {
	std.mu.Lock()
	std.consoleLevel = l
	std.mu.Unlock()
	ui.SetQuiet(l > LevelInfo)
}

// UseInstance attaches <nzDir>/nz.log as the log target, flushing any buffered
// lines into it. Safe to call multiple times (last one wins).
func UseInstance(nzDir string) {
	if nzDir == "" {
		return
	}
	std.SetLogFile(filepath.Join(nzDir, LogFileName))
}

// UseGlobal attaches the stable global fallback log as the target, flushing any
// buffered lines into it. Used by commands (e.g. setup) that mutate the
// instance directory itself and therefore must not create a log file inside it
// before the instance is in place.
func UseGlobal() { std.SetLogFile(globalFallbackPath()) }

// SetLogFile points the logger at an explicit file path, flushing buffered
// lines into it and rotating it first if it has grown past the size cap.
func (l *Logger) SetLogFile(path string) {
	if l == nil || path == "" {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	rotateIfNeeded(path)
	for _, ln := range l.pending {
		writeLine(path, ln)
	}
	l.pending = nil
	l.path = path
}

// Close flushes any pending buffer to the global fallback (if no file was ever
// attached). Open-per-write means there is no handle to close. Safe to call
// multiple times.
func Close() { std.close() }

func (l *Logger) close() {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return
	}
	l.closed = true
	if l.path == "" && len(l.pending) > 0 && l.fallback != "" {
		rotateIfNeeded(l.fallback)
		for _, ln := range l.pending {
			writeLine(l.fallback, ln)
		}
		l.pending = nil
	}
}

// emit writes a single record: always to the file/buffer, and to the console
// when the level passes the console filter.
func (l *Logger) emit(level Level, fileText, consoleText string, stream *os.File) {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	line := time.Now().Format(time.RFC3339) + " [" + level.tag() + "] " + fileText
	l.append(line)
	if level >= l.consoleLevel && consoleText != "" {
		// Strip ANSI color when the stream isn't an interactive terminal (e.g.
		// Prism captures hook output via a pipe) so raw escape codes don't leak
		// into the console as literal `\x1b[..m` text.
		if !consoleStreamSupportsColor(stream) {
			consoleText = ansiSGR.ReplaceAllString(consoleText, "")
		}
		fmt.Fprintln(stream, consoleText)
	}
}

// fileOnly appends a raw line to the file/buffer with no console output and no
// level tag (used for run headers).
func (l *Logger) fileOnly(text string) {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.append(text)
}

// append routes a fully-formatted line to the file or the pending buffer. The
// caller must hold l.mu.
func (l *Logger) append(line string) {
	if l.path != "" {
		writeLine(l.path, line)
	} else {
		l.pending = append(l.pending, line)
	}
}

// writeLine appends a single line to path, creating parent dirs as needed.
// Best-effort: failures are silently ignored so logging never breaks a command.
func writeLine(path, line string) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	_, _ = f.WriteString(line + "\n")
	_ = f.Close()
}

func rotateIfNeeded(path string) {
	info, err := os.Stat(path)
	if err != nil || info.Size() < maxLogBytes {
		return
	}
	rotated := path + ".1"
	_ = os.Remove(rotated)
	_ = os.Rename(path, rotated)
}

func globalFallbackPath() string {
	dir := strings.TrimSpace(os.Getenv("NEGATIVEZONE_LOG_DIR"))
	if dir == "" {
		base := os.Getenv("LOCALAPPDATA")
		if base == "" {
			if cache, err := os.UserCacheDir(); err == nil {
				base = cache
			} else {
				base = os.TempDir()
			}
		}
		dir = filepath.Join(base, "NegativeZone")
	}
	return filepath.Join(dir, LogFileName)
}

// GlobalLogPath returns the stable global fallback log path (the location used
// when no instance log is attached). Exposed for the support bundler.
func GlobalLogPath() string { return globalFallbackPath() }

// ─── Semantic emission API (package-level, operate on the global logger) ─────
//
// Console mapping:
//   Brand/Step/OK/Info/Dim/Separator → INFO   (stdout)
//   Debug                            → DEBUG  (stdout, --verbose only)
//   Warn                             → WARN   (stderr)
//   Error                            → ERROR  (stderr)
// The file always records every call (DEBUG+).

// Brand prints the bold pink banner line.
func Brand(msg string) {
	std.emit(LevelInfo, "=== "+msg, ui.Brand.Render(msg), os.Stdout)
}

// Separator prints a dim horizontal rule.
func Separator() {
	std.emit(LevelInfo, strings.Repeat("-", 50), ui.Separator(), os.Stdout)
}

// Step prints a highlighted "==> step" header, preceded by a blank console line.
func Step(msg string) {
	if std.consoleLevel <= LevelInfo {
		fmt.Println()
	}
	std.emit(LevelInfo, "==> "+msg, ui.Step.Render("==> "+msg), os.Stdout)
}

// Stepf is the printf form of Step.
func Stepf(format string, a ...any) { Step(fmt.Sprintf(format, a...)) }

// OK prints a green success line with a check mark.
func OK(msg string) {
	std.emit(LevelInfo, "OK: "+msg, ui.OK.Render("  ✓ "+msg), os.Stdout)
}

// OKf is the printf form of OK.
func OKf(format string, a ...any) { OK(fmt.Sprintf(format, a...)) }

// Info prints a normal informational line.
func Info(msg string) {
	std.emit(LevelInfo, msg, ui.Info.Render("  "+msg), os.Stdout)
}

// Infof is the printf form of Info.
func Infof(format string, a ...any) { Info(fmt.Sprintf(format, a...)) }

// Dim prints a low-emphasis line (hints, paths).
func Dim(msg string) {
	std.emit(LevelInfo, msg, ui.Dim.Render("  "+msg), os.Stdout)
}

// Dimf is the printf form of Dim.
func Dimf(format string, a ...any) { Dim(fmt.Sprintf(format, a...)) }

// Debug records detail to the file; it reaches the console only with --verbose.
func Debug(msg string) {
	std.emit(LevelDebug, msg, ui.Dim.Render("  [debug] "+msg), os.Stdout)
}

// Debugf is the printf form of Debug.
func Debugf(format string, a ...any) { Debug(fmt.Sprintf(format, a...)) }

// Warn prints a warning to stderr.
func Warn(msg string) {
	std.emit(LevelWarn, msg, ui.Warn.Render("  ⚠ "+msg), os.Stderr)
}

// Warnf is the printf form of Warn.
func Warnf(format string, a ...any) { Warn(fmt.Sprintf(format, a...)) }

// Error prints an error to stderr.
func Error(msg string) {
	std.emit(LevelError, msg, ui.Err.Render("  ✗ "+msg), os.Stderr)
}

// Errorf is the printf form of Error.
func Errorf(format string, a ...any) { Error(fmt.Sprintf(format, a...)) }

// Blank prints an empty console line (no file record). Suppressed when the
// console is quieter than INFO.
func Blank() {
	if std.consoleLevel <= LevelInfo {
		fmt.Println()
	}
}

// ─── External process output capture ─────────────────────────────────────────

// Writer returns an io.Writer that records whatever is written to it into the
// log at the given level, one line per newline. Use it for cmd.Stdout /
// cmd.Stderr so external tool (packwiz, robocopy) output lands in nz.log.
func Writer(level Level) io.Writer {
	return &lineWriter{level: level}
}

type lineWriter struct {
	level Level
	buf   []byte
}

func (w *lineWriter) Write(p []byte) (int, error) {
	w.buf = append(w.buf, p...)
	for {
		i := indexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		line := strings.TrimRight(string(w.buf[:i]), "\r")
		w.buf = w.buf[i+1:]
		if line != "" {
			std.emit(w.level, line, "", os.Stderr)
		}
	}
	return len(p), nil
}

func indexByte(b []byte, c byte) int {
	for i := range b {
		if b[i] == c {
			return i
		}
	}
	return -1
}
