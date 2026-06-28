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
	"github.com/camcast3/MinecraftInfra/client/internal/logging"
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

// setupForce, when set via --force, makes `nz setup` reinstall the modpack even
// when the installed version already matches the manifest (the default skips the
// download and only re-asserts the Prism hooks + helper files).
var setupForce bool

func init() {
	setupCmd.Flags().BoolVarP(&setupForce, "force", "f", false,
		"Reinstall the modpack even if already up to date (default: skip download, just re-assert hooks)")
}

// readVersionFileResilient reads the .negativezone-version file, retrying a few
// times on transient read failures (Windows AV/indexer file locks). Returns the
// trimmed version, or "" if the file is genuinely absent/unreadable. Distinguishes
// a non-existent file (no retry — a real fresh/partial install) from an existing
// file that briefly can't be opened (retry — don't trigger a needless re-download).
func readVersionFileResilient(path string) string {
	for attempt := 0; attempt < 5; attempt++ {
		data, err := os.ReadFile(path)
		if err == nil {
			return strings.TrimSpace(string(data))
		}
		if os.IsNotExist(err) {
			return ""
		}
		time.Sleep(100 * time.Millisecond)
	}
	return ""
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
	logging.Brand("NegativeZone Minecraft setup")
	logging.Separator()
	logging.Blank()

	// Setup mutates the instance directory itself (move-into-place / .bak swap),
	// so it must NOT create a log file inside instanceTarget before the instance
	// is in place. Persist to the global nz.log first (open-per-write, failure
	// safe even on os.Exit); switch to the instance log after placement below.
	logging.UseGlobal()

	// Check Prism not running
	if os.Getenv("NEGATIVEZONE_SKIP_PRISM_CHECK") != "1" && isPrismRunning() {
		logging.Error("Prism Launcher is currently running.")
		logging.Info("Close Prism completely before running setup.")
		os.Exit(1)
	}

	// Locate Prism instances dir
	appdata := os.Getenv("APPDATA")
	if appdata == "" {
		logging.Error("APPDATA not set — are you on Windows?")
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
			logging.Warn("Prism Launcher data folder not found — is Prism installed?")
			logging.Info("If the instance doesn't appear, install Prism: https://prismlauncher.org/download/")
		}
		if err := os.MkdirAll(prismDir, 0o755); err != nil {
			logging.Errorf("Could not create Prism instances folder: %v", err)
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
		logging.Errorf("Could not fetch manifest: %v", err)
		os.Exit(1)
	}

	logging.OKf("Modpack: %s v%s (%.1f MB)",
		manifest.Instance, manifest.Version, float64(manifest.SizeBytes)/(1024*1024))

	instanceTarget := filepath.Join(prismDir, manifest.Instance)
	paths := instance.ResolvePaths(instanceTarget)

	// Check existing install. Evaluated before any directory is created under
	// instanceTarget so a fresh install isn't mistaken for an upgrade.
	isUpgrade := dirExists(instanceTarget)

	if isUpgrade {
		// Read existing version. Retry on transient failure: on Windows a freshly
		// written version file can be briefly locked by AV/indexing, and a single
		// failed read here would wrongly fall through to a full (paid, ~1 GB)
		// re-download instead of the cheap skip path below.
		existingVer := readVersionFileResilient(paths.VersionFile)

		// Already up to date: skip the (paid, bandwidth-heavy) Azure modpack
		// download entirely and just re-assert the per-instance wiring. This is
		// also the cheap repair path for a mangled instance.cfg — re-running
		// `nz setup` rewrites the Prism hooks without touching the modpack.
		// Pass --force to reinstall the modpack anyway.
		if existingVer == manifest.Version && !setupForce {
			logging.OKf("Already up to date (v%s) — skipping modpack download.", manifest.Version)
			logging.Info("Re-asserting Prism hooks + helper files (use --force to reinstall the modpack).")
			logging.Blank()
			logging.UseInstance(paths.NZDir)
			ensureInstanceWiring(instanceTarget, paths)
			logging.Step("Done!")
			logging.OK("Prism hooks and helper files re-asserted.")
			logging.Blank()
			return nil
		}

		logging.Infof("Existing install found: v%s → upgrading to v%s", existingVer, manifest.Version)
	} else {
		logging.Info("Fresh install — no existing instance found.")
	}

	// Confirm
	logging.Blank()
	if os.Getenv("NEGATIVEZONE_NONINTERACTIVE") != "1" {
		fmt.Print("  Continue? (y/N): ")
		reader := bufio.NewReader(os.Stdin)
		answer, _ := reader.ReadString('\n')
		if !strings.HasPrefix(strings.TrimSpace(strings.ToLower(answer)), "y") {
			logging.Warn("Aborted.")
			return nil
		}
	}

	// Download
	logging.Step("Downloading modpack")
	tempZip := filepath.Join(os.TempDir(), fmt.Sprintf("negativezone-setup-%s.zip", manifest.Version))
	defer os.Remove(tempZip)

	actualSHA, err := downloadWithProgress(manifest.URL, tempZip, manifest.SizeBytes)
	if err != nil {
		logging.Errorf("Download failed: %v", err)
		os.Exit(1)
	}

	expectedSHA := strings.ToLower(manifest.SHA256)
	if actualSHA != expectedSHA {
		logging.Error("Download corrupted (SHA-256 mismatch). Try again.")
		os.Exit(1)
	}
	logging.OK("SHA-256 verified")

	// Extract
	logging.Step("Extracting")
	extractDir := filepath.Join(os.TempDir(), fmt.Sprintf("negativezone-setup-extract-%d", time.Now().UnixNano()))
	defer os.RemoveAll(extractDir)

	spin = ui.NewSpinner("Extracting modpack...")
	spin.Start()
	err = extractZip(tempZip, extractDir)
	spin.Stop()

	if err != nil {
		logging.Errorf("Extraction failed: %v", err)
		os.Exit(1)
	}

	srcInstance := filepath.Join(extractDir, manifest.Instance)
	if !dirExists(srcInstance) {
		logging.Error("Extracted zip doesn't contain expected instance folder.")
		os.Exit(1)
	}

	// Pre-swap backup if upgrading
	if isUpgrade {
		logging.Step("Backing up existing instance")
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
		logging.Info("Moving existing instance to .bak...")
		if err := os.Rename(instanceTarget, backupPath); err != nil {
			logging.Errorf("Could not back up existing instance: %v", err)
			os.Exit(1)
		}

		// Move extracted instance into place
		if err := os.Rename(srcInstance, instanceTarget); err != nil {
			// Rollback
			_ = os.Rename(backupPath, instanceTarget)
			logging.Errorf("Install failed (rolled back): %v", err)
			os.Exit(1)
		}

		// Carry user state from .bak
		logging.Step("Restoring user state")
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

		logging.OKf("Restored %d user-state item(s)", restored)
		logging.Dimf("Old instance backup: %s", backupPath)
	} else {
		// Fresh install — just move into place
		if err := os.Rename(srcInstance, instanceTarget); err != nil {
			logging.Errorf("Install failed: %v", err)
			os.Exit(1)
		}
	}

	// Write version marker
	_ = os.MkdirAll(filepath.Join(instanceTarget, ".negativezone"), 0o755)
	_ = os.WriteFile(paths.VersionFile, []byte(manifest.Version), 0o644)

	// Instance is now in place: switch logging into the instance's nz.log so
	// the completion record (and future update/check/backup runs) live with it.
	logging.UseInstance(paths.NZDir)

	ensureInstanceWiring(instanceTarget, paths)

	logging.Step("Setup complete!")
	logging.OKf("Installed %s v%s", manifest.Instance, manifest.Version)
	logging.Blank()
	logging.Info("Launch Prism Launcher and play! The modpack will auto-update on each launch.")
	logging.Blank()

	return nil
}

// ensureInstanceWiring (re-)installs the per-instance helper files: the Prism
// PreLaunch/PostExit hooks, the nz binary, and the double-click update launcher.
// Idempotent — safe to call on a fresh install or to repair an existing one.
func ensureInstanceWiring(instanceTarget string, paths instance.Paths) {
	// Configure Prism hooks (instance.cfg)
	logging.Step("Configuring Prism hooks")
	configurePrismHooks(paths.InstanceCfg)

	// Install nz binary into .negativezone/
	logging.Step("Installing nz binary")
	installNZBinary(filepath.Join(instanceTarget, ".negativezone"))

	// Drop a double-click "Update" launcher so players never type a path.
	logging.Step("Creating update launcher")
	installUpdateLauncher(instanceTarget)
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
		logging.Warnf("Could not write update launcher: %v", err)
		return
	}
	logging.OKf("Update launcher: %s", inInstance)

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
				logging.OK("Added 'Update Craft to Exile 2' to your Desktop")
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

// formatQtINIValue emits Qt's canonical escaped form for an instance.cfg value:
// escape `\` -> `\\` and `"` -> `\"`, then wrap the whole value in `"..."`.
//
// Prism stores instance.cfg as a Qt QSettings INI file. Qt's reader treats a
// backslash as an escape character (\\, \", \n, \r, \t, \uXXXX, \xXX) and treats
// unwrapped `"..."` segments as quoted runs that get concatenated with the
// surrounding whitespace stripped. Our PreLaunch/PostExit commands are full of
// literal quotes and backslashes (e.g. `"C:\Users\...\nz.exe" backup`), so a raw
// write gets mangled the very first time Prism rewrites the cfg (just clicking
// Launch updates lastLaunchTime and resaves): `\U`, `\c`, `\A`, ... are eaten as
// escape sequences and the command collapses to garbage like
// `C:sersarltppData...z.exebackup`, then fails to launch.
//
// The escaped form round-trips idempotently: Qt's reader undoes the escapes and
// Qt's writer re-emits the identical bytes. Mirrors Format-QtIniValue in
// docs/assets/setup.ps1 and infra/azure/scripts/publish-prism-pack.ps1 — keep in
// sync.
func formatQtINIValue(value string) string {
	escaped := strings.ReplaceAll(value, `\`, `\\`)
	escaped = strings.ReplaceAll(escaped, `"`, `\"`)
	return `"` + escaped + `"`
}

// configurePrismHooks writes the PreLaunch and PostExit commands into instance.cfg.
func configurePrismHooks(cfgPath string) {
	nzPath := filepath.Dir(cfgPath)

	// Use FORWARD slashes for the exe path. Prism stores instance.cfg as a Qt
	// QSettings INI where backslash is an escape char, so a raw Windows path
	// (C:\Users\...) gets its letters eaten on Prism's first resave — the
	// `C:sersarltppData...` bug. Even correct `\\`-escaping is one missed
	// round-trip away from re-mangling. Forward slashes have NO escape meaning in
	// Qt's INI reader or in QProcess::splitCommand, and Windows CreateProcess
	// (which Prism's QProcess uses) launches a forward-slash absolute path fine
	// — verified empirically on Windows. formatQtINIValue still wraps + escapes
	// the surrounding quotes so the space in "Craft to Exile 2" survives.
	//
	// We deliberately do NOT use a bare `nz` + PATH command: QProcess bare-name
	// resolution depends on the PATH Prism captured at *its* startup (stale until
	// Prism restarts), and a PreLaunchCommand that fails to start is FATAL in
	// Prism — it blocks the game from launching. A fixed absolute path has no
	// PATH dependency and can never be mangled.
	nzBin := filepath.ToSlash(filepath.Join(nzPath, ".negativezone", nzBinaryName))

	// Build the raw commands (real path + quotes), then Qt-escape so Prism's
	// round-trip resave doesn't eat the quotes. See formatQtINIValue.
	preLaunch := formatQtINIValue(fmt.Sprintf(`"%s" check`, nzBin))
	postExit := formatQtINIValue(fmt.Sprintf(`"%s" backup`, nzBin))

	// Read existing cfg or start fresh
	var lines []string
	if data, err := os.ReadFile(cfgPath); err == nil {
		lines = strings.Split(string(data), "\n")
	}

	// Update/add required keys. OverrideCommands is a bare bool (not Qt-escaped);
	// the two command values are already escaped above.
	keys := map[string]string{
		"OverrideCommands": "true",
		"PreLaunchCommand": preLaunch,
		"PostExitCommand":  postExit,
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
	logging.OK("Prism PreLaunch (version check) and PostExit (backup) hooks configured")
}

// installNZBinary copies the running executable into the .negativezone dir.
func installNZBinary(nzDir string) {
	self, err := os.Executable()
	if err != nil {
		logging.Warn("Could not determine own path; skipping binary install.")
		return
	}

	dst := filepath.Join(nzDir, nzBinaryName)

	// If we're already running as the installed binary (e.g. a user re-ran
	// `nz setup` from inside .negativezone to repair hooks), copying the file
	// onto itself would fail with a sharing-violation. It's already in place, so
	// just skip — nothing to do.
	if sameFile(self, dst) {
		logging.OKf("%s already installed in %s", nzBinaryName, nzDir)
		return
	}

	if err := copyFileLarge(self, dst); err != nil {
		logging.Warnf("Could not install binary: %v", err)
		return
	}
	logging.OKf("Installed %s into %s", nzBinaryName, nzDir)
}

// sameFile reports whether two paths refer to the same on-disk file, comparing
// resolved absolute paths and (when both exist) os.SameFile identity.
func sameFile(a, b string) bool {
	absA, errA := filepath.Abs(a)
	absB, errB := filepath.Abs(b)
	if errA == nil && errB == nil && strings.EqualFold(absA, absB) {
		return true
	}
	ia, errA := os.Stat(a)
	ib, errB := os.Stat(b)
	if errA == nil && errB == nil {
		return os.SameFile(ia, ib)
	}
	return false
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
