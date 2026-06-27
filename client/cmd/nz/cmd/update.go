package cmd

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/camcast3/MinecraftInfra/client/internal/instance"
	"github.com/camcast3/MinecraftInfra/client/internal/lock"
	"github.com/camcast3/MinecraftInfra/client/internal/logging"
	"github.com/camcast3/MinecraftInfra/client/internal/packwiz"
	"github.com/camcast3/MinecraftInfra/client/internal/ui"
	"github.com/spf13/cobra"
)

const (
	defaultManifestURL = "https://stmcminecraftprod.blob.core.windows.net/minecraft-modpack/latest.json"
	defaultPackwizURL  = "https://raw.githubusercontent.com/camcast3/MinecraftInfra/main/packwiz/pack.toml"
)

var updateCmd = &cobra.Command{
	Use:   "update",
	Short: "Auto-update the modpack from the server manifest",
	Long: `Delta-syncs the installed modpack against the server's packwiz manifest.

In user-run mode (no INST_DIR set), auto-detects the Craft to Exile 2
instance and refuses to run while Prism is open.

Environment variables:
  INST_DIR                      Instance directory (auto-detected if unset)
  NEGATIVEZONE_MANIFEST_URL     Override manifest URL (testing)
  NEGATIVEZONE_PACKWIZ_CMD      Override packwiz command (testing)`,
	RunE: runUpdate,
}

// updateManifest matches the JSON manifest served by the blob endpoint.
type updateManifest struct {
	Version        string `json:"version"`
	URL            string `json:"url"`
	SHA256         string `json:"sha256"`
	SizeBytes      int64  `json:"sizeBytes"`
	Instance       string `json:"instance"`
	AllowDowngrade bool   `json:"allowDowngrade"`
	PackwizURL     string `json:"packwizUrl"`
}

func runUpdate(cmd *cobra.Command, args []string) error {
	instanceDir := os.Getenv("INST_DIR")
	userRunMode := instanceDir == ""

	if userRunMode {
		logging.Brand("NegativeZone Minecraft client update")
		logging.Separator()

		instanceDir = instance.DefaultC2E2Path()
		if instanceDir == "" || !dirExists(instanceDir) {
			logging.Error("No Craft to Exile 2 instance found.")
			logging.Info("Run 'nz setup' first to install the modpack.")
			os.Exit(1)
		}
		logging.Dimf("Instance: %s", instanceDir)

		// Check Prism not running
		if os.Getenv("NEGATIVEZONE_SKIP_PRISM_CHECK") != "1" && isPrismRunning() {
			logging.Blank()
			logging.Error("Prism Launcher is currently running.")
			logging.Info("Close Prism completely and re-run this update.")
			os.Exit(1)
		}
	}

	if instanceDir == "" || !dirExists(instanceDir) {
		logging.Dim("INST_DIR not set or missing; skipping auto-update.")
		return nil
	}

	paths := instance.ResolvePaths(instanceDir)
	_ = os.MkdirAll(paths.NZDir, 0o755)

	logging.UseInstance(paths.NZDir)

	// Acquire lock
	lockPath := filepath.Join(paths.NZDir, "update.lock")
	lk, err := lock.Acquire(lockPath, 5*time.Minute)
	if err != nil {
		return fmt.Errorf("lock error: %w", err)
	}
	if lk == nil {
		logging.Info("Another update is running (lock held); skipping.")
		return nil
	}
	defer lk.Release()

	// Read installed version
	installedVersion := ""
	if data, err := os.ReadFile(paths.VersionFile); err == nil {
		installedVersion = strings.TrimSpace(string(data))
	}
	logging.Infof("Installed version: '%s'", installedVersion)

	// Fetch manifest
	manifestURL := os.Getenv("NEGATIVEZONE_MANIFEST_URL")
	if manifestURL == "" {
		manifestURL = defaultManifestURL
	}
	if manifestURL != defaultManifestURL {
		logging.Warnf("Using OVERRIDE manifest URL: %s", manifestURL)
	}

	spin := ui.NewSpinner("Checking for updates...")
	spin.Start()
	manifest, err := fetchUpdateManifest(manifestURL)
	spin.Stop()

	if err != nil {
		logging.Warnf("Could not fetch manifest: %v. Launching with current install.", err)
		logging.Dim("Could not reach update server; continuing with current version.")
		return nil
	}
	if manifest.Version == "" {
		logging.Error("Manifest missing 'version' field.")
		logging.Error("Manifest is malformed (missing version). Contact admin.")
		os.Exit(1)
	}
	if manifest.Version == installedVersion {
		logging.Infof("Already on v%s; nothing to do.", manifest.Version)
		if userRunMode {
			logging.OKf("Already on latest version (v%s)", manifest.Version)
		}
		return nil
	}

	// Downgrade check
	if installedVersion != "" && compareVersions(installedVersion, manifest.Version) > 0 {
		if manifest.AllowDowngrade {
			logging.Warnf("Manifest opts into downgrade: v%s -> v%s", installedVersion, manifest.Version)
		} else {
			logging.Infof("Installed v%s is newer than manifest v%s; refusing to downgrade.", installedVersion, manifest.Version)
			if userRunMode {
				logging.Warnf("Your install (v%s) is newer than server (v%s). Skipping.", installedVersion, manifest.Version)
			}
			return nil
		}
	}

	logging.Infof("Updating: %s -> %s", installedVersion, manifest.Version)
	if userRunMode {
		logging.Stepf("Updating v%s → v%s", installedVersion, manifest.Version)
	}

	// Pre-update backup
	logging.Info("Creating pre-update safety snapshot...")
	oldInstDir, hadInstDir := os.LookupEnv("INST_DIR")
	_ = os.Setenv("INST_DIR", instanceDir)
	backupForceOld := backupForce
	backupForce = true
	_ = runBackup(cmd, nil)
	backupForce = backupForceOld
	if hadInstDir {
		_ = os.Setenv("INST_DIR", oldInstDir)
	} else {
		_ = os.Unsetenv("INST_DIR")
	}

	packTomlURL := strings.TrimSpace(manifest.PackwizURL)
	if packTomlURL == "" {
		packTomlURL = defaultPackwizURL
	}
	logging.Infof("Packwiz URL: %s", packTomlURL)
	logging.Step("Syncing modpack with packwiz")

	if err := packwiz.Sync(paths.DotMC, paths.NZDir, packTomlURL); err != nil {
		logging.Errorf("Packwiz sync failed: %v", err)
		logging.Errorf("Update failed: %v", err)
		return err
	}

	if err := os.WriteFile(paths.VersionFile, []byte(manifest.Version), 0o644); err != nil {
		logging.Errorf("Could not write version marker: %v", err)
		return err
	}
	logging.Infof("Update complete: now on v%s", manifest.Version)
	logging.OKf("Updated to v%s", manifest.Version)

	return nil
}

func fetchUpdateManifest(url string) (*updateManifest, error) {
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	var m updateManifest
	if err := json.NewDecoder(resp.Body).Decode(&m); err != nil {
		return nil, err
	}
	return &m, nil
}

func downloadWithProgress(url, dest string, expectedSize int64) (string, error) {
	client := &http.Client{Timeout: 10 * time.Minute}
	resp, err := client.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	size := resp.ContentLength
	if size <= 0 {
		size = expectedSize
	}

	f, err := os.Create(dest)
	if err != nil {
		return "", err
	}
	defer f.Close()

	hasher := sha256.New()
	writer := io.MultiWriter(f, hasher)

	if size > 0 {
		bar := ui.NewProgressBar(size, "")
		buf := make([]byte, 64*1024)
		var written int64
		for {
			n, readErr := resp.Body.Read(buf)
			if n > 0 {
				if _, wErr := writer.Write(buf[:n]); wErr != nil {
					return "", wErr
				}
				written += int64(n)
				bar.Update(written)
			}
			if readErr == io.EOF {
				break
			}
			if readErr != nil {
				return "", readErr
			}
		}
		bar.Finish()
	} else {
		if _, err := io.Copy(writer, resp.Body); err != nil {
			return "", err
		}
	}

	return hex.EncodeToString(hasher.Sum(nil)), nil
}

func extractZip(zipPath, destDir string) error {
	r, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer r.Close()

	for _, f := range r.File {
		path := filepath.Join(destDir, filepath.FromSlash(f.Name))

		// Prevent zip slip
		if !strings.HasPrefix(path, filepath.Clean(destDir)+string(os.PathSeparator)) {
			continue
		}

		if f.FileInfo().IsDir() {
			_ = os.MkdirAll(path, 0o755)
			continue
		}

		_ = os.MkdirAll(filepath.Dir(path), 0o755)
		outFile, err := os.Create(path)
		if err != nil {
			return err
		}

		rc, err := f.Open()
		if err != nil {
			outFile.Close()
			return err
		}

		_, err = io.Copy(outFile, rc)
		rc.Close()
		outFile.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

func isPrismRunning() bool {
	// Check for PrismLauncher process
	cmd := exec.Command("tasklist", "/FI", "IMAGENAME eq prismlauncher.exe", "/NH")
	output, err := cmd.Output()
	if err != nil {
		return false
	}
	return strings.Contains(strings.ToLower(string(output)), "prismlauncher")
}

func fileHash(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

func dirExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
