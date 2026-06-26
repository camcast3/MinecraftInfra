// Package ui provides styled terminal output for the NegativeZone CLI.
package ui

import (
	"fmt"
	"os"
	"strings"
	"time"

	"charm.land/lipgloss/v2"
)

var (
	// Styles
	Brand  = lipgloss.NewStyle().Foreground(lipgloss.Color("#FF69B4")).Bold(true)
	OK     = lipgloss.NewStyle().Foreground(lipgloss.Color("#00FF7F"))
	Warn   = lipgloss.NewStyle().Foreground(lipgloss.Color("#FFD700"))
	Err    = lipgloss.NewStyle().Foreground(lipgloss.Color("#FF4500"))
	Dim    = lipgloss.NewStyle().Foreground(lipgloss.Color("#666666"))
	Step   = lipgloss.NewStyle().Foreground(lipgloss.Color("#00BFFF")).Bold(true)
	Info   = lipgloss.NewStyle().Foreground(lipgloss.Color("#FFFFFF"))

	prefix = "[negativezone]"
)

func PrintBrand(msg string) {
	fmt.Println(Brand.Render(msg))
}

func PrintStep(msg string) {
	fmt.Println()
	fmt.Println(Step.Render("==> " + msg))
}

func PrintOK(msg string) {
	fmt.Println(OK.Render("  ✓ " + msg))
}

func PrintWarn(msg string) {
	fmt.Fprintln(os.Stderr, Warn.Render("  ⚠ "+msg))
}

func PrintError(msg string) {
	fmt.Fprintln(os.Stderr, Err.Render("  ✗ "+msg))
}

func PrintInfo(msg string) {
	fmt.Println(Info.Render("  " + msg))
}

func PrintDim(msg string) {
	fmt.Println(Dim.Render("  " + msg))
}

func PrintTagged(msg string) {
	fmt.Printf("%s %s\n", prefix, msg)
}

// Separator prints a horizontal rule.
func Separator() {
	fmt.Println(Dim.Render(strings.Repeat("─", 50)))
}

// Spinner is a simple inline spinner for short operations.
type Spinner struct {
	msg    string
	done   chan struct{}
	frames []string
}

func NewSpinner(msg string) *Spinner {
	return &Spinner{
		msg:    msg,
		done:   make(chan struct{}),
		frames: []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"},
	}
}

func (s *Spinner) Start() {
	go func() {
		i := 0
		for {
			select {
			case <-s.done:
				fmt.Printf("\r%s\r", strings.Repeat(" ", len(s.msg)+4))
				return
			default:
				fmt.Printf("\r  %s %s", s.frames[i%len(s.frames)], s.msg)
				i++
				time.Sleep(80 * time.Millisecond)
			}
		}
	}()
}

func (s *Spinner) Stop() {
	close(s.done)
	time.Sleep(100 * time.Millisecond) // let the goroutine clear the line
}

// ProgressBar renders a simple progress bar to stdout.
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
	p.current = current
	pct := float64(current) / float64(p.total)
	filled := int(pct * float64(p.width))
	bar := strings.Repeat("█", filled) + strings.Repeat("░", p.width-filled)
	mb := float64(current) / (1024 * 1024)
	totalMb := float64(p.total) / (1024 * 1024)
	fmt.Printf("\r  %s [%s] %.1f/%.1f MB (%.0f%%)", p.label, bar, mb, totalMb, pct*100)
}

func (p *ProgressBar) Finish() {
	p.Update(p.total)
	fmt.Println()
}
