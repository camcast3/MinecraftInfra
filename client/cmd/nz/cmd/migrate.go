package cmd

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/camcast3/MinecraftInfra/client/internal/instance"
	"github.com/camcast3/MinecraftInfra/client/internal/logging"
	"github.com/spf13/cobra"
)

var (
	migrateOld string
	migrateNew string
)

var migrateCmd = &cobra.Command{
	Use:   "migrate",
	Short: "Copy settings between instances interactively",
	Long: `Copies client-side settings (keybinds, video options, shaders,
Xaero/JourneyMap waypoints) from an old Minecraft instance into a new one.

With no arguments, auto-detects Prism/CurseForge instances and prompts
you to pick source and destination interactively.

servers.dat is NOT copied (the pack ships its own).`,
	RunE: runMigrate,
}

func init() {
	migrateCmd.Flags().StringVar(&migrateOld, "from", "", "Path to old instance")
	migrateCmd.Flags().StringVar(&migrateNew, "to", "", "Path to new instance")
}

// Migrate scope (settings only — NOT saves, logs, etc.)
var migrateFiles = []string{
	"options.txt",
	"optionsof.txt",
	"optionsshaders.txt",
	"hotbar.nbt",
}

var migrateFolders = []string{
	"journeymap",
	"XaeroWaypoints",
	"XaeroWorldMap",
}

func runMigrate(cmd *cobra.Command, args []string) error {
	logging.Brand("NegativeZone settings migrator")
	logging.Separator()

	candidates := instance.FindAll()

	oldPath := migrateOld
	newPath := migrateNew

	if oldPath == "" {
		oldPath = promptInstance("Path to your OLD instance (the one with your settings):", candidates)
	}
	if newPath == "" {
		newPath = promptInstance("Path to your NEW instance (copy settings INTO):", candidates)
	}

	oldMC := instance.ResolveMinecraftRoot(oldPath)
	newMC := instance.ResolveMinecraftRoot(newPath)

	if oldMC == newMC {
		logging.Error("Old and new instance resolve to the same folder!")
		os.Exit(1)
	}

	// Build plan
	type planItem struct {
		Type       string
		Name       string
		Source     string
		Overwrites bool
	}
	var plan []planItem

	for _, f := range migrateFiles {
		src := filepath.Join(oldMC, f)
		if fileExists(src) {
			plan = append(plan, planItem{
				Type:       "File",
				Name:       f,
				Source:     src,
				Overwrites: pathExists(filepath.Join(newMC, f)),
			})
		}
	}
	for _, d := range migrateFolders {
		src := filepath.Join(oldMC, d)
		if dirExists(src) {
			plan = append(plan, planItem{
				Type:       "Folder",
				Name:       d,
				Source:     src,
				Overwrites: pathExists(filepath.Join(newMC, d)),
			})
		}
	}

	if len(plan) == 0 {
		logging.Warn("Nothing to migrate — none of the expected items exist in the old instance.")
		logging.Dimf("Looked in: %s", oldMC)
		logging.Blank()
		for _, f := range migrateFiles {
			logging.Dimf("  file   %s", f)
		}
		for _, d := range migrateFolders {
			logging.Dimf("  folder %s", d)
		}
		return nil
	}

	// Preview
	logging.Step("Migration plan")
	logging.Infof("From: %s", oldMC)
	logging.Infof("To:   %s", newMC)
	logging.Blank()
	for _, item := range plan {
		overwrite := ""
		if item.Overwrites {
			overwrite = " (will overwrite existing)"
		}
		logging.Infof("  %s: %s%s", item.Type, item.Name, overwrite)
	}
	logging.Blank()

	// Confirm
	fmt.Print("  Proceed? (y/N): ")
	reader := bufio.NewReader(os.Stdin)
	answer, _ := reader.ReadString('\n')
	answer = strings.TrimSpace(strings.ToLower(answer))
	if answer != "y" && answer != "yes" {
		logging.Warn("Aborted.")
		return nil
	}

	// Apply
	logging.Step("Applying")
	timestamp := fmt.Sprintf("_migration-backup-%s", timeStampNow())
	backupDir := filepath.Join(newMC, timestamp)
	backupCreated := false

	for _, item := range plan {
		dst := filepath.Join(newMC, item.Name)
		if pathExists(dst) {
			if !backupCreated {
				_ = os.MkdirAll(backupDir, 0o755)
				backupCreated = true
			}
			logging.Dimf("  backup: %s", item.Name)
			_ = os.Rename(dst, filepath.Join(backupDir, item.Name))
		}
		logging.OKf("copy: %s", item.Name)
		if item.Type == "File" {
			_ = copyFile(item.Source, dst)
		} else {
			_ = copyDir(item.Source, dst)
		}
	}

	// Done
	logging.Step("Done")
	if backupCreated {
		logging.Infof("Overwritten items backed up to: %s", backupDir)
	}
	logging.Blank()
	logging.Info("Next steps:")
	logging.Info("  1. Launch the new instance and verify keybinds, video settings, waypoints.")
	logging.Info("  2. Port mod configs manually (config/) one mod at a time.")
	logging.Dim("     Bulk-copying config/ between modpack versions can crash the game.")
	logging.Blank()

	return nil
}

func promptInstance(prompt string, candidates []instance.Info) string {
	logging.Blank()
	logging.Info(prompt)
	if len(candidates) > 0 {
		for i, c := range candidates {
			fmt.Printf("  [%d] %-10s %s\n", i+1, c.Launcher, c.Name)
			logging.Dimf("       %s", c.Path)
		}
		fmt.Println("  [m]  Type a path manually")
	}

	reader := bufio.NewReader(os.Stdin)
	for {
		fmt.Print("  Pick one: ")
		choice, _ := reader.ReadString('\n')
		choice = strings.TrimSpace(choice)
		if choice == "" {
			continue
		}

		// Numeric selection
		var idx int
		if _, err := fmt.Sscanf(choice, "%d", &idx); err == nil {
			idx--
			if idx >= 0 && idx < len(candidates) {
				return candidates[idx].Path
			}
			logging.Warn("Out of range")
			continue
		}

		if choice == "m" || choice == "M" {
			fmt.Print("  Path: ")
			p, _ := reader.ReadString('\n')
			p = strings.TrimSpace(strings.Trim(p, `"`))
			if dirExists(p) {
				return p
			}
			logging.Warnf("Not found: %s", p)
			continue
		}

		// Maybe they pasted a path
		cleaned := strings.Trim(choice, `"`)
		if dirExists(cleaned) {
			return cleaned
		}
		logging.Warn("Enter a number, 'm' for manual, or paste a full path.")
	}
}

func timeStampNow() string {
	return time.Now().Format("20060102-150405")
}

// copyDir recursively copies a directory using robocopy for performance.
// robocopy output is captured into nz.log at DEBUG.
func copyDir(src, dst string) error {
	cmd := exec.Command("robocopy", src, dst, "/MIR", "/MT:8", "/R:1", "/W:1", "/NP", "/NFL", "/NDL", "/NJH", "/NJS")
	cmd.Stdout = logging.Writer(logging.LevelDebug)
	cmd.Stderr = logging.Writer(logging.LevelDebug)
	_ = cmd.Run()
	rc := cmd.ProcessState.ExitCode()
	if rc >= 8 {
		return fmt.Errorf("robocopy exit %d", rc)
	}
	return nil
}
