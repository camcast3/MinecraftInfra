package cmd

import (
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/camcast3/MinecraftInfra/client/internal/instance"
	"github.com/camcast3/MinecraftInfra/client/internal/lock"
	"github.com/camcast3/MinecraftInfra/client/internal/logging"
	"github.com/camcast3/MinecraftInfra/client/internal/scope"
	"github.com/camcast3/MinecraftInfra/client/internal/ui"
	"github.com/spf13/cobra"
)

var (
	backupForce bool
)

var backupCmd = &cobra.Command{
	Use:   "backup",
	Short: "Snapshot user state (Xaero maps, settings, shaders, etc.)",
	Long: `Creates a timestamped snapshot of user-state files in
<InstanceDir>/.negativezone/backups/<yyyyMMdd-HHmmss>/.

By default, skips if the newest snapshot is less than 3 days old.
Use --force to always create a snapshot (e.g., before an update).

Environment variables:
  INST_DIR                          Instance directory (auto-detected if unset)
  NEGATIVEZONE_BACKUP_DISABLE=1     Skip backup entirely
  NEGATIVEZONE_BACKUP_DAYS=N        Days between snapshots (default 3)
  NEGATIVEZONE_BACKUP_RETAIN=N      Max snapshots to keep (default 3)
  NEGATIVEZONE_BACKUP_INCLUDE_SAVES=1  Also back up saves/ (multi-GB)`,
	RunE: runBackup,
}

func init() {
	backupCmd.Flags().BoolVarP(&backupForce, "force", "f", false, "Bypass cadence skip (always create snapshot)")
}

func runBackup(cmd *cobra.Command, args []string) error {
	// Resolve instance directory
	instanceDir := os.Getenv("INST_DIR")
	if instanceDir == "" {
		instanceDir = instance.DefaultC2E2Path()
	}
	if instanceDir == "" {
		ui.PrintWarn("INST_DIR not set and no default instance found; skipping backup.")
		return nil
	}
	if _, err := os.Stat(instanceDir); os.IsNotExist(err) {
		ui.PrintWarn(fmt.Sprintf("Instance directory does not exist: %s; skipping backup.", instanceDir))
		return nil
	}

	// Opt-out
	if os.Getenv("NEGATIVEZONE_BACKUP_DISABLE") == "1" {
		ui.PrintDim("NEGATIVEZONE_BACKUP_DISABLE=1; skipping backup.")
		return nil
	}

	paths := instance.ResolvePaths(instanceDir)

	if _, err := os.Stat(paths.DotMC); os.IsNotExist(err) {
		ui.PrintWarn(".minecraft missing; nothing to back up.")
		return nil
	}
	_ = os.MkdirAll(paths.NZDir, 0o755)

	log, err := logging.New(filepath.Join(paths.NZDir, "backup.log"), "nz-backup")
	if err != nil {
		ui.PrintWarn(fmt.Sprintf("Could not init log: %v", err))
		// Continue without file logging
	}

	// Config
	intervalDays := getIntEnv("NEGATIVEZONE_BACKUP_DAYS", 3, 0, 90)
	retainCount := getIntEnv("NEGATIVEZONE_BACKUP_RETAIN", 3, 1, 50)
	includeSaves := os.Getenv("NEGATIVEZONE_BACKUP_INCLUDE_SAVES") == "1"

	// Cadence skip
	if !backupForce && intervalDays > 0 {
		if newest := newestSnapshot(paths.BackupsDir); newest != "" {
			info, _ := os.Stat(filepath.Join(paths.BackupsDir, newest))
			if info != nil {
				age := time.Since(info.ModTime())
				if age.Hours() < float64(intervalDays)*24 {
					remaining := float64(intervalDays)*24 - age.Hours()
					ui.PrintDim(fmt.Sprintf("Last backup %.1f day(s) ago; next due in %.1f day(s).",
						age.Hours()/24, remaining/24))
					return nil
				}
			}
		}
	}

	// Lock
	lockPath := filepath.Join(paths.NZDir, "backup.lock")
	lk, err := lock.Acquire(lockPath, 30*time.Minute)
	if err != nil {
		return fmt.Errorf("lock error: %w", err)
	}
	if lk == nil {
		if log != nil {
			log.Info("Another backup is running (lock held); skipping.")
		}
		ui.PrintDim("Another backup is running; skipping.")
		return nil
	}
	defer lk.Release()

	// Create snapshot dir
	_ = os.MkdirAll(paths.BackupsDir, 0o755)
	timestamp := time.Now().Format("20060102-150405")
	snapshotDir := filepath.Join(paths.BackupsDir, timestamp)
	if _, err := os.Stat(snapshotDir); err == nil {
		snapshotDir = fmt.Sprintf("%s-%d", snapshotDir, rand.Intn(999))
	}
	if err := os.MkdirAll(snapshotDir, 0o755); err != nil {
		return fmt.Errorf("creating snapshot dir: %w", err)
	}

	if log != nil {
		log.Infof("Starting backup -> %s", snapshotDir)
	}
	ui.PrintStep("Creating backup snapshot")
	start := time.Now()

	// Get scope + pack-author manifest extension
	dirs, files := scope.BackupScope(includeSaves)
	preserveManifest := filepath.Join(paths.NZDir, "preserve-list.json")
	manifest, _ := scope.LoadPreserveManifest(preserveManifest)
	if manifest != nil {
		for _, p := range manifest.Preserve {
			t := strings.TrimSpace(p)
			if t == "" {
				continue
			}
			// Add to files (pack-author entries are individual config files)
			found := false
			for _, f := range files {
				if f == t {
					found = true
					break
				}
			}
			if !found {
				files = append(files, t)
			}
		}
		if log != nil {
			log.Infof("Added %d pack-author file(s) from preserve-list.json", len(manifest.Preserve))
		}
	}

	copiedAny := false

	// Backup directories via robocopy (fast parallel copy)
	for _, rel := range dirs {
		src := filepath.Join(paths.DotMC, rel)
		if _, err := os.Stat(src); os.IsNotExist(err) {
			continue
		}
		dst := filepath.Join(snapshotDir, rel)
		parent := filepath.Dir(dst)
		_ = os.MkdirAll(parent, 0o755)

		rc := robocopy(src, dst)
		if rc >= 8 {
			if log != nil {
				log.Warnf("robocopy '%s' failed (exit %d); skipping.", rel, rc)
			}
		} else {
			copiedAny = true
		}
	}

	// Backup individual files
	for _, rel := range files {
		src := filepath.Join(paths.DotMC, rel)
		info, err := os.Stat(src)
		if err != nil || info.IsDir() {
			continue
		}
		dst := filepath.Join(snapshotDir, rel)
		parent := filepath.Dir(dst)
		_ = os.MkdirAll(parent, 0o755)

		if err := copyFile(src, dst); err != nil {
			if log != nil {
				log.Warnf("Could not back up file '%s': %v", rel, err)
			}
		} else {
			copiedAny = true
		}
	}

	elapsed := time.Since(start)

	if !copiedAny {
		if log != nil {
			log.Info("No items matched scope; removing empty snapshot.")
		}
		_ = os.RemoveAll(snapshotDir)
		ui.PrintDim("No items matched scope; nothing backed up.")
	} else {
		sizeMB := dirSizeMB(snapshotDir)
		msg := fmt.Sprintf("Backup complete in %.1fs, %.1f MB", elapsed.Seconds(), sizeMB)
		if log != nil {
			log.Info(msg)
		}
		ui.PrintOK(msg)
	}

	// Prune old snapshots
	pruneSnapshots(paths.BackupsDir, retainCount, log)

	return nil
}

// robocopy mirrors src to dst using robocopy. Returns the exit code.
func robocopy(src, dst string) int {
	cmd := exec.Command("robocopy", src, dst, "/MIR", "/MT:8", "/R:1", "/W:1", "/NP", "/NFL", "/NDL", "/NJH", "/NJS")
	_ = cmd.Run()
	return cmd.ProcessState.ExitCode()
}

// copyFile copies a single file from src to dst.
func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o644)
}

// dirSizeMB walks a directory and returns total size in MB.
func dirSizeMB(dir string) float64 {
	var total int64
	_ = filepath.Walk(dir, func(_ string, info os.FileInfo, _ error) error {
		if info != nil && !info.IsDir() {
			total += info.Size()
		}
		return nil
	})
	return float64(total) / (1024 * 1024)
}

// newestSnapshot returns the name of the newest snapshot dir, or "".
func newestSnapshot(backupsDir string) string {
	entries, err := os.ReadDir(backupsDir)
	if err != nil {
		return ""
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() && isTimestampName(e.Name()) {
			names = append(names, e.Name())
		}
	}
	if len(names) == 0 {
		return ""
	}
	sort.Sort(sort.Reverse(sort.StringSlice(names)))
	return names[0]
}

// isTimestampName checks if a name matches yyyyMMdd-HHmmss(-N)?
func isTimestampName(name string) bool {
	// Simple check: at least 15 chars, starts with 8 digits, dash, 6 digits
	if len(name) < 15 {
		return false
	}
	for i, c := range name[:8] {
		_ = i
		if c < '0' || c > '9' {
			return false
		}
	}
	if name[8] != '-' {
		return false
	}
	for i := 9; i < 15; i++ {
		if name[i] < '0' || name[i] > '9' {
			return false
		}
	}
	return true
}

// pruneSnapshots keeps only the newest `retain` snapshots.
func pruneSnapshots(backupsDir string, retain int, log *logging.Logger) {
	entries, err := os.ReadDir(backupsDir)
	if err != nil {
		return
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() && isTimestampName(e.Name()) {
			names = append(names, e.Name())
		}
	}
	if len(names) <= retain {
		return
	}
	sort.Sort(sort.Reverse(sort.StringSlice(names)))
	for _, name := range names[retain:] {
		path := filepath.Join(backupsDir, name)
		if err := os.RemoveAll(path); err != nil {
			if log != nil {
				log.Warnf("Could not prune '%s': %v", name, err)
			}
		} else {
			if log != nil {
				log.Infof("Pruned old backup: %s", name)
			}
		}
	}
}

// getIntEnv reads an integer from the environment with bounds.
func getIntEnv(name string, defaultVal, min, max int) int {
	raw := os.Getenv(name)
	if raw == "" {
		return defaultVal
	}
	var val int
	if _, err := fmt.Sscanf(raw, "%d", &val); err != nil {
		return defaultVal
	}
	if val < min {
		return min
	}
	if val > max {
		return max
	}
	return val
}
