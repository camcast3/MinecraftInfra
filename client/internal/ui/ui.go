// Package ui provides styled terminal output for the NegativeZone CLI.
//
// ui owns presentation only: the lipgloss style palette and the interactive
// Spinner / ProgressBar widgets. All log emission (and the styled console
// narrative built from these styles) is driven by the logging package, so a
// single call site produces both the persisted nz.log line and the terminal
// output. When quiet mode is enabled (via SetQuiet), the interactive widgets
// become no-ops so they don't clutter a suppressed console.
package ui

import (
	"fmt"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"charm.land/lipgloss/v2"
)

// Style palette. These are the single source of truth for NegativeZone colors;
// the logging package renders its console output through them.
var (
	Brand = lipgloss.NewStyle().Foreground(lipgloss.Color("#FF69B4")).Bold(true)
	OK    = lipgloss.NewStyle().Foreground(lipgloss.Color("#00FF7F"))
	Warn  = lipgloss.NewStyle().Foreground(lipgloss.Color("#FFD700"))
	Err   = lipgloss.NewStyle().Foreground(lipgloss.Color("#FF4500"))
	Dim   = lipgloss.NewStyle().Foreground(lipgloss.Color("#666666"))
	Step  = lipgloss.NewStyle().Foreground(lipgloss.Color("#00BFFF")).Bold(true)
	Info  = lipgloss.NewStyle().Foreground(lipgloss.Color("#FFFFFF"))
)

// quiet suppresses the interactive widgets (spinner / progress bar). It is set
// by the logging package when the console is running at WARN/ERROR verbosity.
var quiet atomic.Bool

// SetQuiet toggles suppression of interactive widgets.
func SetQuiet(q bool) { quiet.Store(q) }

// Quiet reports whether interactive widgets are suppressed.
func Quiet() bool { return quiet.Load() }

// Separator returns a horizontal rule rendered in the dim style.
func Separator() string {
	return Dim.Render(strings.Repeat("─", 50))
}

// Spinner is a simple inline spinner for short operations. It renders to stderr
// so it never interleaves with stdout that may be piped/captured, and is a
// no-op when quiet mode is enabled.
type Spinner struct {
	msg    string
	done   chan struct{}
	frames []string
	active bool
}

func NewSpinner(msg string) *Spinner {
	return &Spinner{
		msg:    msg,
		done:   make(chan struct{}),
		frames: []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"},
	}
}

func (s *Spinner) Start() {
	if quiet.Load() {
		return
	}
	s.active = true
	go func() {
		i := 0
		for {
			select {
			case <-s.done:
				fmt.Fprintf(os.Stderr, "\r%s\r", strings.Repeat(" ", len(s.msg)+4))
				return
			default:
				fmt.Fprintf(os.Stderr, "\r  %s %s", s.frames[i%len(s.frames)], s.msg)
				i++
				time.Sleep(80 * time.Millisecond)
			}
		}
	}()
}

func (s *Spinner) Stop() {
	if !s.active {
		return
	}
	s.active = false
	close(s.done)
	time.Sleep(100 * time.Millisecond) // let the goroutine clear the line
}

// ProgressBar renders a simple download progress bar to stderr. It is a no-op
// when quiet mode is enabled.
type ProgressBar struct {
	total   int64
	current int64
	width   int
	label   string
}

func NewProgressBar(total int64, label string) *ProgressBar {
	return &ProgressBar{total: total, width: 40, label: label}
}

func (p *ProgressBar) Update(current int64) {
	if quiet.Load() || p.total <= 0 {
		return
	}
	p.current = current
	pct := float64(current) / float64(p.total)
	filled := int(pct * float64(p.width))
	if filled > p.width {
		filled = p.width
	}
	bar := strings.Repeat("█", filled) + strings.Repeat("░", p.width-filled)
	mb := float64(current) / (1024 * 1024)
	totalMb := float64(p.total) / (1024 * 1024)
	fmt.Fprintf(os.Stderr, "\r  %s [%s] %.1f/%.1f MB (%.0f%%)", p.label, bar, mb, totalMb, pct*100)
}

func (p *ProgressBar) Finish() {
	if quiet.Load() || p.total <= 0 {
		return
	}
	p.Update(p.total)
	fmt.Fprintln(os.Stderr)
}
