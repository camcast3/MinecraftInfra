package cmd

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/camcast3/MinecraftInfra/client/internal/instance"
	"github.com/camcast3/MinecraftInfra/client/internal/scope"
	"github.com/camcast3/MinecraftInfra/client/internal/ui"
	"github.com/spf13/cobra"
)

const (
	defaultSetupManifestURL = "https://stmcminecraftprod.blob.core.windows.net/minecraft-modpack/latest.json"
	nzBinaryName            = "nz.exe"
)

var setupCmd = &cobra.Command{
	Use:   "setup",
	Short: "First-time install or upgrade of the Prism instance",
	Long: `Downloads and installs the NegativeZone modpack as a Prism Launcher
instance. On upgrade, preserves user state (maps, settings, saves, shaders).

Configures Prism's PreLaunchCommand (version check) and PostExitCommand
(periodic backup) to point at this binary's 'check' and 'backup' subcommands.

Run with no arguments for a guided experience.

Environment variables:
  NEGATIVEZONE_MANIFEST_URL     Override manifest URL (testing)`,
	RunE: runSetup,
}

// setupManifest extends the update manifest with setup-specific fields.
type setupManifest struct {
	Version   string `json:"version"`
	URL       string `json:"url"`
	SHA256    string `json:"sha256"`
	SizeBytes int64  `json:"sizeBytes"`
	Instance  string `json:"instance"`
}

func runSetup(cmd *cobra.Command, args []string) error {
	ui.PrintBrand("NegativeZone Minecraft setup")
	ui.Separator()
	fmt.Println()

	// Check Prism not running
	if os.Getenv("NEGATIVEZONE_SKIP_PRISM_CHECK") != "1" && isPrismRunning() {
		ui.PrintError("Prism Launcher is currently running.")
		ui.PrintInfo("Close Prism completely before running setup.")
		os.Exit(1)
	}

	// Locate Prism instances dir
	appdata := os.Getenv("APPDATA")
	if appdata == "" {
		ui.PrintError("APPDATA not set — are you on Windows?")
		os.Exit(1)
	}
	prismDir := filepath.Join(appdata, "PrismLauncher", "instances")
	if !dirExists(prismDir) {
		// Prism creates this dir on its first launch, but a fresh winget
		// install (via install.ps1) may not have been launched yet. Create
		// it so setup works immediately; Prism picks up the instance on next
		// open. Warn only if PrismLauncher itself is absent (likely uninstalled).
		prismRoot := filepath.Join(appdata, "PrismLauncher")
		if !dirExists(prismRoot) {
			ui.PrintWarn("Prism Launcher data folder not found — is Prism installed?")
			ui.PrintInfo("If the instance doesn't appear, install Prism: https://prismlauncher.org/download/")
		}
		if err := os.MkdirAll(prismDir, 0o755); err != nil {
			ui.PrintError(fmt.Sprintf("Could not create Prism instances folder: %v", err))
			os.Exit(1)
		}
	}

	// Fetch manifest
	manifestURL := os.Getenv("NEGATIVEZONE_MANIFEST_URL")
	if manifestURL == "" {
		manifestURL = defaultSetupManifestURL
	}

	spin := ui.NewSpinner("Fetching modpack manifest...")
	spin.Start()
	manifest, err := fetchSetupManifest(manifestURL)
	spin.Stop()

	if err != nil {
		ui.PrintError(fmt.Sprintf("Could not fetch manifest: %v", err))
		os.Exit(1)
	}

	ui.PrintOK(fmt.Sprintf("Modpack: %s v%s (%.1f MB)",
		manifest.Instance, manifest.Version, float64(manifest.SizeBytes)/(1024*1024)))

	instanceTarget := filepath.Join(prismDir, manifest.Instance)
	paths := instance.ResolvePaths(instanceTarget)

	// Check existing install
	isUpgrade := dirExists(instanceTarget)
	if isUpgrade {
		// Read existing version
		existingVer := ""
		if data, err := os.ReadFile(paths.VersionFile); err == nil {
			existingVer = strings.TrimSpace(string(data))
		}
		ui.PrintInfo(fmt.Sprintf("Existing install found: v%s → upgrading to v%s", existingVer, manifest.Version))
	} else {
		ui.PrintInfo("Fresh install — no existing instance found.")
	}

	// Confirm
	fmt.Println()
	if os.Getenv("NEGATIVEZONE_NONINTERACTIVE") != "1" {
		fmt.Print("  Continue? (y/N): ")
		reader := bufio.NewReader(os.Stdin)
		answer, _ := reader.ReadString('\n')
		if !strings.HasPrefix(strings.TrimSpace(strings.ToLower(answer)), "y") {
			ui.PrintWarn("Aborted.")
			return nil
		}
	}

	// Download
	ui.PrintStep("Downloading modpack")
	tempZip := filepath.Join(os.TempDir(), fmt.Sprintf("negativezone-setup-%s.zip", manifest.Version))
	defer os.Remove(tempZip)

	actualSHA, err := downloadWithProgress(manifest.URL, tempZip, manifest.SizeBytes)
	if err != nil {
		ui.PrintError(fmt.Sprintf("Download failed: %v", err))
		os.Exit(1)
	}

	expectedSHA := strings.ToLower(manifest.SHA256)
	if actualSHA != expectedSHA {
		ui.PrintError("Download corrupted (SHA-256 mismatch). Try again.")
		os.Exit(1)
	}
	ui.PrintOK("SHA-256 verified")

	// Extract
	ui.PrintStep("Extracting")
	extractDir := filepath.Join(os.TempDir(), fmt.Sprintf("negativezone-setup-extract-%d", time.Now().UnixNano()))
	defer os.RemoveAll(extractDir)

	spin = ui.NewSpinner("Extracting modpack...")
	spin.Start()
	err = extractZip(tempZip, extractDir)
	spin.Stop()

	if err != nil {
		ui.PrintError(fmt.Sprintf("Extraction failed: %v", err))
		os.Exit(1)
	}

	srcInstance := filepath.Join(extractDir, manifest.Instance)
	if !dirExists(srcInstance) {
		ui.PrintError("Extracted zip doesn't contain expected instance folder.")
		os.Exit(1)
	}

	// Pre-swap backup if upgrading
	if isUpgrade {
		ui.PrintStep("Backing up existing instance")
		backupPath := instanceTarget + ".bak"
		if dirExists(backupPath) {
			_ = os.RemoveAll(backupPath)
		}

		// Run curated snapshot via our own backup command
		os.Setenv("INST_DIR", instanceTarget)
		backupForceOld := backupForce
		backupForce = true
		_ = runBackup(cmd, nil)
		backupForce = backupForceOld

		// Move existing instance to .bak
		ui.PrintInfo("Moving existing instance to .bak...")
		if err := os.Rename(instanceTarget, backupPath); err != nil {
			ui.PrintError(fmt.Sprintf("Could not back up existing instance: %v", err))
			os.Exit(1)
		}

		// Move extracted instance into place
		if err := os.Rename(srcInstance, instanceTarget); err != nil {
			// Rollback
			_ = os.Rename(backupPath, instanceTarget)
			ui.PrintError(fmt.Sprintf("Install failed (rolled back): %v", err))
			os.Exit(1)
		}

		// Carry user state from .bak
		ui.PrintStep("Restoring user state")
		preserveSet := scope.MergePreserve(
			scope.FullPreserveSet(),
			filepath.Join(instanceTarget, ".negativezone", "preserve-list.json"),
		)

		oldDotMC := filepath.Join(backupPath, ".minecraft")
		newDotMC := filepath.Join(instanceTarget, ".minecraft")
		restored := 0
		if dirExists(oldDotMC) {
			_ = os.MkdirAll(newDotMC, 0o755)
			for _, rel := range preserveSet {
				src := filepath.Join(oldDotMC, rel)
				if !pathExists(src) {
					continue
				}
				dst := filepath.Join(newDotMC, rel)
				if pathExists(dst) {
					_ = os.RemoveAll(dst)
				}
				parent := filepath.Dir(dst)
				_ = os.MkdirAll(parent, 0o755)
				// Copy (not move) so .bak stays complete
				if err := copyPath(src, dst); err == nil {
					restored++
				}
			}
		}

		// Carry over .negativezone/backups/
		oldBackups := filepath.Join(backupPath, ".negativezone", "backups")
		if dirExists(oldBackups) {
			newNZDir := filepath.Join(instanceTarget, ".negativezone")
			_ = os.MkdirAll(newNZDir, 0o755)
			_ = copyDir(oldBackups, filepath.Join(newNZDir, "backups"))
		}

		ui.PrintOK(fmt.Sprintf("Restored %d user-state item(s)", restored))
		ui.PrintDim(fmt.Sprintf("Old instance backup: %s", backupPath))
	} else {
		// Fresh install — just move into place
		if err := os.Rename(srcInstance, instanceTarget); err != nil {
			ui.PrintError(fmt.Sprintf("Install failed: %v", err))
			os.Exit(1)
		}
	}

	// Write version marker
	_ = os.MkdirAll(filepath.Join(instanceTarget, ".negativezone"), 0o755)
	_ = os.WriteFile(paths.VersionFile, []byte(manifest.Version), 0o644)

	// Configure Prism hooks (instance.cfg)
	ui.PrintStep("Configuring Prism hooks")
	configurePrismHooks(paths.InstanceCfg)

	// Install nz binary into .negativezone/
	ui.PrintStep("Installing nz binary")
	installNZBinary(filepath.Join(instanceTarget, ".negativezone"))

	// Drop a double-click "Update" launcher so players never type a path.
	ui.PrintStep("Creating update launcher")
	installUpdateLauncher(instanceTarget)

	ui.PrintStep("Setup complete!")
	ui.PrintOK(fmt.Sprintf("Installed %s v%s", manifest.Instance, manifest.Version))
	fmt.Println()
	ui.PrintInfo("Launch Prism Launcher and play! The modpack will auto-update on each launch.")
	fmt.Println()

	return nil
}

// updateLauncherName is the double-click launcher players use to update.
const updateLauncherName = "Update Craft to Exile 2.cmd"

// installUpdateLauncher writes a .cmd launcher that runs the bundled nz.exe
// update, so players can update with a double-click instead of typing a path.
// The launcher always lands in the instance dir (safe under tests); on a real
// player run it is also copied to the Desktop. The console window is kept on
// purpose — players want to see the packwiz progress + "Updated to vX".
func installUpdateLauncher(instanceDir string) {
	nzBin := filepath.Join(instanceDir, ".negativezone", nzBinaryName)
	content := "@echo off\r\n" +
		"title Update Craft to Exile 2\r\n" +
		"echo Updating Craft to Exile 2 -- close Prism first if it is open.\r\n" +
		"echo.\r\n" +
		"\"" + nzBin + "\" update\r\n" +
		"echo.\r\n" +
		"echo Done. You can close this window and launch the game.\r\n" +
		"pause\r\n"

	inInstance := filepath.Join(instanceDir, updateLauncherName)
	if err := os.WriteFile(inInstance, []byte(content), 0o644); err != nil {
		ui.PrintWarn(fmt.Sprintf("Could not write update launcher: %v", err))
		return
	}
	ui.PrintOK(fmt.Sprintf("Update launcher: %s", inInstance))

	// Best-effort Desktop copy on real player runs only (tests set
	// NEGATIVEZONE_NONINTERACTIVE=1, and we must not pollute the real Desktop
	// from a sandboxed test).
	if os.Getenv("NEGATIVEZONE_NONINTERACTIVE") == "1" {
		return
	}
	if home := os.Getenv("USERPROFILE"); home != "" {
		desktop := filepath.Join(home, "Desktop")
		if info, err := os.Stat(desktop); err == nil && info.IsDir() {
			dst := filepath.Join(desktop, updateLauncherName)
			if err := os.WriteFile(dst, []byte(content), 0o644); err == nil {
				ui.PrintOK("Added 'Update Craft to Exile 2' to your Desktop")
			}
		}
	}
}

func fetchSetupManifest(url string) (*setupManifest, error) {
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	var m setupManifest
	if err := json.NewDecoder(resp.Body).Decode(&m); err != nil {
		return nil, err
	}
	return &m, nil
}

// configurePrismHooks writes the PreLaunch and PostExit commands into instance.cfg.
func configurePrismHooks(cfgPath string) {
	nzPath := filepath.Dir(cfgPath)
	nzBin := filepath.Join(nzPath, ".negativezone", nzBinaryName)

	preLaunch := fmt.Sprintf(`"%s" check`, nzBin)
	postExit := fmt.Sprintf(`"%s" backup`, nzBin)

	// Read existing cfg or start fresh
	var lines []string
	if data, err := os.ReadFile(cfgPath); err == nil {
		lines = strings.Split(string(data), "\n")
	}

	// Update/add required keys
	keys := map[string]string{
		"OverrideCommands":  "true",
		"PreLaunchCommand":  preLaunch,
		"PostExitCommand":   postExit,
	}

	for key, val := range keys {
		found := false
		for i, line := range lines {
			if strings.HasPrefix(line, key+"=") {
				lines[i] = key + "=" + val
				found = true
				break
			}
		}
		if !found {
			lines = append(lines, key+"="+val)
		}
	}

	_ = os.WriteFile(cfgPath, []byte(strings.Join(lines, "\n")), 0o644)
	ui.PrintOK("Prism PreLaunch (version check) and PostExit (backup) hooks configured")
}

// installNZBinary copies the running executable into the .negativezone dir.
func installNZBinary(nzDir string) {
	self, err := os.Executable()
	if err != nil {
		ui.PrintWarn("Could not determine own path; skipping binary install.")
		return
	}

	dst := filepath.Join(nzDir, nzBinaryName)
	if err := copyFileLarge(self, dst); err != nil {
		ui.PrintWarn(fmt.Sprintf("Could not install binary: %v", err))
		return
	}
	ui.PrintOK(fmt.Sprintf("Installed %s into %s", nzBinaryName, nzDir))
}

// copyFileLarge copies a file using streaming (suitable for large binaries).
func copyFileLarge(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, in)
	return err
}

// copyPath copies a file or directory. Uses robocopy for dirs on Windows.
func copyPath(src, dst string) error {
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return copyDir(src, dst)
	}
	return copyFile(src, dst)
}

// fetchText downloads a small text file and returns its trimmed content.
func fetchText(url string) (string, error) {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}
