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

	"github.com/camcast3/MinecraftInfra/client/internal/compatibility"
	"github.com/camcast3/MinecraftInfra/client/internal/instance"
	"github.com/camcast3/MinecraftInfra/client/internal/logging"
	"github.com/camcast3/MinecraftInfra/client/internal/scope"
	"github.com/camcast3/MinecraftInfra/client/internal/transaction"
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
	Version       string                  `json:"version"`
	URL           string                  `json:"url"`
	SHA256        string                  `json:"sha256"`
	SizeBytes     int64                   `json:"sizeBytes"`
	Instance      string                  `json:"instance"`
	Compatibility *compatibility.Metadata `json:"compatibility,omitempty"`
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
		return fmt.Errorf("Prism Launcher is running")
	}

	// Locate Prism instances dir
	appdata := os.Getenv("APPDATA")
	if appdata == "" {
		return fmt.Errorf("APPDATA not set — are you on Windows?")
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
			return fmt.Errorf("create Prism instances folder: %w", err)
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
		return fmt.Errorf("fetch manifest: %w", err)
	}
	if err := compatibility.Validate(manifest.Version, manifest.Compatibility); err != nil {
		return fmt.Errorf("incompatible modpack release: %w", err)
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
	workID := fmt.Sprintf("%d", time.Now().UnixNano())
	tempZip := filepath.Join(prismDir, ".negativezone-download-"+workID+".zip")
	defer os.Remove(tempZip)

	actualSHA, err := downloadWithProgress(manifest.URL, tempZip, manifest.SizeBytes)
	if err != nil {
		return fmt.Errorf("download modpack: %w", err)
	}

	expectedSHA := strings.ToLower(manifest.SHA256)
	if actualSHA != expectedSHA {
		return fmt.Errorf("download corrupted: SHA-256 mismatch")
	}
	logging.OK("SHA-256 verified")

	// Extract
	logging.Step("Extracting")
	extractDir := filepath.Join(prismDir, ".negativezone-extract-"+workID)
	defer os.RemoveAll(extractDir)

	spin = ui.NewSpinner("Extracting modpack...")
	spin.Start()
	err = extractZip(tempZip, extractDir)
	spin.Stop()

	if err != nil {
		return fmt.Errorf("extract modpack: %w", err)
	}

	srcInstance := filepath.Join(extractDir, manifest.Instance)
	if !dirExists(srcInstance) {
		return fmt.Errorf("extracted zip does not contain expected instance folder %q", manifest.Instance)
	}

	preserveSet, err := scope.MergePreserveStrict(
		scope.FullPreserveSet(),
		filepath.Join(srcInstance, ".negativezone", "preserve-list.json"),
	)
	if err != nil {
		return fmt.Errorf("preflight preservation manifest: %w", err)
	}
	var preservePaths []string
	for _, rel := range preserveSet {
		preservePaths = append(preservePaths, filepath.Join(".minecraft", rel))
	}
	preservePaths = append(preservePaths, filepath.Join(".negativezone", "backups"))

	logging.Step("Building and verifying transactional install")
	result, err := (transaction.Engine{}).Run(transaction.Plan{
		Name:           "setup",
		LiveDir:        instanceTarget,
		RequireLive:    false,
		TargetVersion:  manifest.Version,
		MarkerRelative: ".negativezone-version",
		SkipIfCurrent:  !setupForce,
		Preserve: []transaction.PreserveRule{{
			Version: 1,
			Paths:   preservePaths,
		}},
		Prepare: func(stage string) error {
			if err := transaction.CopyTree(srcInstance, stage); err != nil {
				return err
			}
			return prepareTransactionalWiring(stage, instanceTarget)
		},
		Validate: func(stage string) error {
			if !dirExists(filepath.Join(stage, ".minecraft")) {
				return fmt.Errorf("staged instance is missing .minecraft")
			}
			if !fileExists(filepath.Join(stage, "instance.cfg")) {
				return fmt.Errorf("staged instance is missing instance.cfg")
			}
			return nil
		},
	})
	if err != nil {
		return fmt.Errorf("transactional setup failed: %w", err)
	}

	// Instance is now in place: switch logging into the instance's nz.log so
	// the completion record (and future update/check/backup runs) live with it.
	logging.UseInstance(paths.NZDir)

	if result.BackupDir != "" {
		backupPath := instanceTarget + ".bak"
		if err := os.RemoveAll(backupPath); err != nil {
			logging.Warnf("Could not replace compatibility .bak: %v", err)
		} else if err := transaction.CopyTree(filepath.Join(result.BackupDir, "payload"), backupPath); err != nil {
			logging.Warnf("Could not create compatibility .bak: %v", err)
		} else {
			prevVersion := readVersionFileResilient(filepath.Join(backupPath, ".negativezone-version"))
			createOldInstance(prismDir, manifest.Instance, backupPath, prevVersion)
		}
		logging.Infof("Verified immutable backup: %s", result.BackupDir)
	}
	updatePrismGroups(instanceTarget)

	logging.Step("Setup complete!")
	logging.OKf("Installed %s v%s", manifest.Instance, manifest.Version)
	logging.Blank()
	logging.Info("Launch Prism Launcher and play! nz will check the modpack version before each launch.")
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

	updatePrismGroups(instanceTarget)
}

func updatePrismGroups(instanceTarget string) {
	// Sort instances into Prism groups so the live install ("Latest") is
	// visually separated from upgrade leftovers (the .bak + side-by-side
	// "(old)") under "Backup". Self-heals on every run; absent dirs are skipped.
	logging.Step("Updating Prism instance groups")
	instancesDir := filepath.Dir(instanceTarget)
	name := filepath.Base(instanceTarget)
	setPrismInstanceGroup(instancesDir, map[string][]string{
		"Latest": {name},
		"Backup": {name + ".bak", name + " (old)"},
	})
}

func prepareTransactionalWiring(stageDir, finalInstanceDir string) error {
	if err := configurePrismHooksAt(
		filepath.Join(stageDir, "instance.cfg"),
		finalInstanceDir,
	); err != nil {
		return fmt.Errorf("configure Prism hooks: %w", err)
	}
	if err := installNZBinaryStrict(filepath.Join(stageDir, ".negativezone")); err != nil {
		return fmt.Errorf("install nz binary: %w", err)
	}
	if err := writeUpdateLauncher(stageDir, finalInstanceDir); err != nil {
		return fmt.Errorf("write update launcher: %w", err)
	}
	return nil
}

// prismGroup is one entry in instgroups.json's "groups" object.
type prismGroup struct {
	Hidden    bool     `json:"hidden"`
	Instances []string `json:"instances"`
}

// prismInstGroups mirrors Prism's instances/instgroups.json on-disk shape.
type prismInstGroups struct {
	FormatVersion string                `json:"formatVersion"`
	Groups        map[string]prismGroup `json:"groups"`
}

// setPrismInstanceGroup writes instances/instgroups.json to assign managed
// instances to named groups (e.g. "Latest", "Backup"). Idempotent and additive,
// It preserves any groups the player created, strips our managed instances out
// of every existing
// group before re-assigning (so an instance can't end up in two groups), and
// skips instances whose folder is absent (so a missing .bak/(old) doesn't leave
// an empty "Backup" group). Written as BOM-less UTF-8 to match Prism's own file.
func setPrismInstanceGroup(instancesDir string, assignments map[string][]string) {
	if !dirExists(instancesDir) {
		logging.Warnf("Instances dir not found at %s; skipping group update", instancesDir)
		return
	}
	groupsFile := filepath.Join(instancesDir, "instgroups.json")

	// Every instance we manage, so we can strip them from pre-existing groups.
	managed := map[string]bool{}
	for _, insts := range assignments {
		for _, in := range insts {
			managed[in] = true
		}
	}

	final := map[string]prismGroup{}

	// Preserve player-created groups, minus any managed instances we're about to
	// re-assign below.
	if data, err := os.ReadFile(groupsFile); err == nil {
		var existing prismInstGroups
		if json.Unmarshal(data, &existing) == nil {
			for groupName, g := range existing.Groups {
				if _, isOurs := assignments[groupName]; isOurs {
					continue
				}
				var kept []string
				for _, in := range g.Instances {
					if !managed[in] {
						kept = append(kept, in)
					}
				}
				if len(kept) == 0 {
					continue
				}
				final[groupName] = prismGroup{Hidden: g.Hidden, Instances: kept}
			}
		} else {
			logging.Warnf("Could not parse %s; rewriting from scratch", groupsFile)
		}
	}

	// Assign our managed instances, skipping any whose folder doesn't exist.
	for groupName, insts := range assignments {
		present := []string{}
		for _, in := range insts {
			if dirExists(filepath.Join(instancesDir, in)) {
				present = append(present, in)
			}
		}
		if len(present) == 0 {
			continue
		}
		final[groupName] = prismGroup{Hidden: false, Instances: present}
	}

	payload := prismInstGroups{FormatVersion: "1", Groups: final}
	out, err := json.MarshalIndent(payload, "", "    ")
	if err != nil {
		logging.Warnf("Could not encode instgroups.json: %v", err)
		return
	}
	if err := os.WriteFile(groupsFile, out, 0o644); err != nil {
		logging.Warnf("Could not write instgroups.json: %v", err)
		return
	}
	logging.OK("Prism groups updated (live -> Latest; .bak / (old) -> Backup if present)")
}

// createOldInstance copies the just-made .bak into a clean side-by-side
// "<instance> (old)" instance with its launch hooks disabled, so a player can
// one-click launch the previous version from Prism if the upgrade misbehaves.
// The raw .bak folder (trailing ".bak") confuses Prism's UI and still has the
// active PreLaunch version-check that would block its launch; this copy fixes
// both. Best-effort: on failure the .bak remains as the filesystem rollback.
func createOldInstance(instancesDir, instanceName, backupPath, prevVersion string) {
	oldName := instanceName + " (old)"
	oldPath := filepath.Join(instancesDir, oldName)

	logging.Step("Creating side-by-side 'old' instance for one-click rollback")
	if dirExists(oldPath) {
		_ = os.RemoveAll(oldPath)
	}
	if err := copyDir(backupPath, oldPath); err != nil {
		logging.Warnf("Could not create side-by-side old instance (%v). Your .bak at %s is still intact for rollback.", err, backupPath)
		return
	}

	display := fmt.Sprintf("%s v%s (old)", instanceName, prevVersion)
	if prevVersion == "" {
		display = instanceName + " (old)"
	}
	disableHooksAndRename(filepath.Join(oldPath, "instance.cfg"), display)
	logging.OKf("Old instance available in Prism as '%s' (launch hooks disabled)", oldName)
}

// disableHooksAndRename sets OverrideCommands=false (kill switch that leaves the
// command lines intact but inert) and rewrites name= to displayName in an
// instance.cfg. Used for the side-by-side "(old)" rollback instance.
func disableHooksAndRename(cfgPath, displayName string) {
	data, err := os.ReadFile(cfgPath)
	if err != nil {
		return
	}
	lines := strings.Split(string(data), "\n")
	sawOverride, sawName := false, false
	for i, line := range lines {
		if strings.HasPrefix(line, "OverrideCommands=") {
			lines[i] = "OverrideCommands=false"
			sawOverride = true
		} else if strings.HasPrefix(line, "name=") {
			lines[i] = "name=" + displayName
			sawName = true
		}
	}
	if !sawOverride {
		lines = append(lines, "OverrideCommands=false")
	}
	if !sawName {
		lines = append(lines, "name="+displayName)
	}
	_ = os.WriteFile(cfgPath, []byte(strings.Join(lines, "\n")), 0o644)
}

// updateLauncherName is the double-click launcher players use to update.
const updateLauncherName = "Update Craft to Exile 2.cmd"

// installUpdateLauncher writes a .cmd launcher that runs the bundled nz.exe
// update, so players can update with a double-click instead of typing a path.
// The launcher always lands in the instance dir (safe under tests); on a real
// player run it is also copied to the Desktop. The console window is kept on
// purpose — players want to see the packwiz progress + "Updated to vX".
func installUpdateLauncher(instanceDir string) {
	if err := writeUpdateLauncher(instanceDir, instanceDir); err != nil {
		logging.Warnf("Could not write update launcher: %v", err)
		return
	}
	inInstance := filepath.Join(instanceDir, updateLauncherName)
	logging.OKf("Update launcher: %s", inInstance)

	// Best-effort Desktop copy on real player runs only (tests set
	// NEGATIVEZONE_NONINTERACTIVE=1, and we must not pollute the real Desktop
	// from a sandboxed test).
	if os.Getenv("NEGATIVEZONE_NONINTERACTIVE") == "1" {
		return
	}
	data, err := os.ReadFile(inInstance)
	if err != nil {
		return
	}
	if home := os.Getenv("USERPROFILE"); home != "" {
		desktop := filepath.Join(home, "Desktop")
		if info, err := os.Stat(desktop); err == nil && info.IsDir() {
			dst := filepath.Join(desktop, updateLauncherName)
			if err := os.WriteFile(dst, data, 0o644); err == nil {
				logging.OK("Added 'Update Craft to Exile 2' to your Desktop")
			}
		}
	}
}

func writeUpdateLauncher(writeInstanceDir, commandInstanceDir string) error {
	nzBin := filepath.Join(commandInstanceDir, ".negativezone", nzBinaryName)
	content := "@echo off\r\n" +
		"title Update Craft to Exile 2\r\n" +
		"echo Updating Craft to Exile 2 -- close Prism first if it is open.\r\n" +
		"echo.\r\n" +
		"\"" + nzBin + "\" update\r\n" +
		"echo.\r\n" +
		"echo Done. You can close this window and launch the game.\r\n" +
		"pause\r\n"

	return os.WriteFile(filepath.Join(writeInstanceDir, updateLauncherName), []byte(content), 0o644)
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
// Qt's writer re-emits the identical bytes.
func formatQtINIValue(value string) string {
	escaped := strings.ReplaceAll(value, `\`, `\\`)
	escaped = strings.ReplaceAll(escaped, `"`, `\"`)
	return `"` + escaped + `"`
}

// configurePrismHooks writes the PreLaunch and PostExit commands into instance.cfg.
func configurePrismHooks(cfgPath string) {
	if err := configurePrismHooksAt(cfgPath, filepath.Dir(cfgPath)); err != nil {
		logging.Warnf("Could not configure Prism hooks: %v", err)
		return
	}
	logging.OK("Prism PreLaunch (version check) and PostExit (backup) hooks configured")
}

func configurePrismHooksAt(cfgPath, finalInstanceDir string) error {
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
	nzBin := filepath.ToSlash(filepath.Join(finalInstanceDir, ".negativezone", nzBinaryName))

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

	if err := os.WriteFile(cfgPath, []byte(strings.Join(lines, "\n")), 0o644); err != nil {
		return err
	}
	return nil
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

func installNZBinaryStrict(nzDir string) error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(nzDir, 0o755); err != nil {
		return err
	}
	return copyFileLarge(self, filepath.Join(nzDir, nzBinaryName))
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
