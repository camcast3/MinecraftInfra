package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/camcast3/MinecraftInfra/client/internal/instance"
	"github.com/camcast3/MinecraftInfra/client/internal/logging"
	"github.com/spf13/cobra"
)

const (
	defaultLatestVersionURL = "https://stmcminecraftprod.blob.core.windows.net/minecraft-modpack/latest-version.txt"
	updateOneLiner          = "nz update"
	wikiURL                 = "https://wiki.negativezone.cc/updating"
)

var checkCmd = &cobra.Command{
	Use:   "check",
	Short: "Pre-launch version gate (blocks stale clients)",
	Long: `Compares the installed modpack version against the server's latest
version pointer and blocks the launch if they differ.

This is designed to be set as Prism's PreLaunchCommand so players
can't join with a mismatched modpack (FML handshake failure).

Exit codes:
  0 = version matches (or fail-open: offline, no marker, bypass set)
  1 = version mismatch (launch blocked)

Environment variables:
  INST_DIR                            Instance directory
  NEGATIVEZONE_SKIP_VERSION_CHECK=1   Bypass the check
  NEGATIVEZONE_LATEST_VERSION_URL     Override pointer URL (testing)`,
	RunE: runCheck,
}

func runCheck(cmd *cobra.Command, args []string) error {
	// Bypass
	if os.Getenv("NEGATIVEZONE_SKIP_VERSION_CHECK") == "1" {
		logging.Dim("NEGATIVEZONE_SKIP_VERSION_CHECK=1; skipping version check.")
		return nil
	}

	instanceDir := os.Getenv("INST_DIR")
	if instanceDir == "" {
		instanceDir = instance.DefaultC2E2Path()
	}
	if instanceDir == "" {
		logging.Dim("INST_DIR not set; skipping version check.")
		return nil
	}
	if _, err := os.Stat(instanceDir); os.IsNotExist(err) {
		logging.Dimf("Instance not found: %s; skipping version check.", instanceDir)
		return nil
	}

	paths := instance.ResolvePaths(instanceDir)
	logging.UseInstance(paths.NZDir)

	// Read installed version
	installedVersion := ""
	if data, err := os.ReadFile(paths.VersionFile); err == nil {
		installedVersion = strings.TrimSpace(string(data))
	}
	if installedVersion == "" {
		logging.Dim("No installed version marker; skipping version check.")
		return nil
	}

	// Fetch latest version
	versionURL := os.Getenv("NEGATIVEZONE_LATEST_VERSION_URL")
	if versionURL == "" {
		versionURL = defaultLatestVersionURL
	}

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(versionURL)
	if err != nil {
		logging.Dimf("Could not fetch latest version (%v); allowing launch.", err)
		return nil
	}
	defer resp.Body.Close()

	// Fail-open on any non-200: a transient CDN 404/5xx must NOT be parsed as
	// the version string (raw.githubusercontent.com returns a "404: Not Found"
	// body that would otherwise read as a bogus version and falsely block).
	if resp.StatusCode != http.StatusOK {
		logging.Dimf("Latest version pointer returned HTTP %d; allowing launch.", resp.StatusCode)
		return nil
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 256))
	if err != nil {
		logging.Dimf("Could not read latest version (%v); allowing launch.", err)
		return nil
	}
	latestVersion := strings.TrimSpace(string(body))
	if latestVersion == "" {
		logging.Dim("Latest version pointer was empty; allowing launch.")
		return nil
	}

	// Compare
	if installedVersion == latestVersion {
		logging.Debugf("Version OK: installed v%s matches server.", installedVersion)
		return nil
	}

	// Determine direction
	direction := "mismatch"
	if compareVersions(installedVersion, latestVersion) < 0 {
		direction = "behind"
	} else if compareVersions(installedVersion, latestVersion) > 0 {
		direction = "ahead"
	}

	// Block launch
	logging.Blank()
	logging.Error("════════════════════════════════════════════════════════════")
	logging.Error("  MODPACK VERSION MISMATCH")
	logging.Errorf("  installed: v%s", installedVersion)
	logging.Errorf("  server:    v%s  (%s)", latestVersion, direction)
	logging.Error("════════════════════════════════════════════════════════════")
	logging.Blank()
	logging.Info("The server is pinned to a specific modpack version.")
	logging.Info("Joining with a different client version would fail at the FML handshake.")
	logging.Blank()
	logging.Info("Run this to update:")
	logging.Blank()
	logging.Step(updateOneLiner)
	logging.Blank()
	if direction == "ahead" {
		logging.Warn("Your client is AHEAD of the server. Contact the admin if you")
		logging.Warn("need a rollback (allowDowngrade must be set in the manifest).")
		logging.Blank()
	}
	logging.Dimf("Walk-through: %s", wikiURL)
	logging.Dim("(Set NEGATIVEZONE_SKIP_VERSION_CHECK=1 to bypass for offline play.)")
	logging.Blank()

	os.Exit(1)
	return nil
}

// compareVersions does a simple numeric version comparison.
// Returns -1, 0, or 1.
func compareVersions(a, b string) int {
	aParts := strings.Split(a, ".")
	bParts := strings.Split(b, ".")

	maxLen := len(aParts)
	if len(bParts) > maxLen {
		maxLen = len(bParts)
	}

	for i := 0; i < maxLen; i++ {
		var aNum, bNum int
		if i < len(aParts) {
			fmt.Sscanf(aParts[i], "%d", &aNum)
		}
		if i < len(bParts) {
			fmt.Sscanf(bParts[i], "%d", &bNum)
		}
		if aNum < bNum {
			return -1
		}
		if aNum > bNum {
			return 1
		}
	}
	return 0
}

// Manifest for the update check (minimal fields needed by check)
type versionManifest struct {
	Version string `json:"version"`
}

func fetchManifest(url string) (*versionManifest, error) {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var m versionManifest
	if err := json.NewDecoder(resp.Body).Decode(&m); err != nil {
		return nil, err
	}
	return &m, nil
}
