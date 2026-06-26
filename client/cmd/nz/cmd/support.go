package cmd

import (
	"archive/zip"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/camcast3/MinecraftInfra/client/internal/instance"
	"github.com/camcast3/MinecraftInfra/client/internal/logging"
	"github.com/spf13/cobra"
)

var supportCmd = &cobra.Command{
	Use:   "support",
	Short: "Bundle logs + context into a zip to send to the admin",
	Long: `Collects nz.log (and rotated copies), the installed version marker,
instance.cfg, and an environment summary into a single zip file you can DM the
admin when something goes wrong.

By default the bundle is written to your Desktop (falling back to the instance
folder, then the current directory).

Environment variables:
  INST_DIR    Instance directory (auto-detected if unset)`,
	Aliases: []string{"logs"},
	RunE:    runSupport,
}

var supportOut string

// supportItem is one file included in the support bundle (zip name -> source).
type supportItem struct{ name, path string }

func init() {
	supportCmd.Flags().StringVarP(&supportOut, "out", "o", "", "Output zip path (default: Desktop/nz-support-<ts>.zip)")
}

func runSupport(cmd *cobra.Command, args []string) error {
	logging.Brand("NegativeZone support bundle")
	logging.Separator()

	instanceDir := os.Getenv("INST_DIR")
	if instanceDir == "" {
		instanceDir = instance.DefaultC2E2Path()
	}

	// Candidate files to include (deduped, only those that exist).
	var items []supportItem
	add := func(name, path string) {
		if path == "" {
			return
		}
		if _, err := os.Stat(path); err != nil {
			return
		}
		for _, it := range items {
			if it.path == path {
				return
			}
		}
		items = append(items, supportItem{name: name, path: path})
	}

	if instanceDir != "" && dirExists(instanceDir) {
		paths := instance.ResolvePaths(instanceDir)
		add("nz.log", filepath.Join(paths.NZDir, logging.LogFileName))
		add("nz.log.1", filepath.Join(paths.NZDir, logging.LogFileName+".1"))
		// Legacy per-command logs (pre-unification) if still present.
		add("legacy-backup.log", filepath.Join(paths.NZDir, "backup.log"))
		add("legacy-update.log", filepath.Join(paths.NZDir, "update.log"))
		add("negativezone-version.txt", paths.VersionFile)
		add("instance.cfg", paths.InstanceCfg)
	}
	// Global fallback log (used when no instance was attached).
	add("global-nz.log", logging.GlobalLogPath())
	add("global-nz.log.1", logging.GlobalLogPath()+".1")

	summary := buildSupportSummary(instanceDir, items)

	outPath := supportOut
	if outPath == "" {
		outPath = defaultSupportOutPath(instanceDir)
	}

	if err := writeSupportZip(outPath, summary, itemsToMap(items)); err != nil {
		logging.Errorf("Could not write support bundle: %v", err)
		return err
	}

	logging.OKf("Support bundle written: %s", outPath)
	logging.Infof("Included %d log/context file(s).", len(items))
	logging.Info("Send this zip to the admin (e.g., via Discord DM).")
	return nil
}

// buildSupportSummary returns the text of summary.txt for the bundle.
func buildSupportSummary(instanceDir string, items []supportItem) string {
	var b strings.Builder
	fmt.Fprintf(&b, "NegativeZone support bundle\n")
	fmt.Fprintf(&b, "generated: %s\n", time.Now().Format(time.RFC3339))
	fmt.Fprintf(&b, "nz version: %s\n", version)
	fmt.Fprintf(&b, "os/arch: %s/%s\n", runtime.GOOS, runtime.GOARCH)
	fmt.Fprintf(&b, "instance: %s\n", orNone(instanceDir))

	if instanceDir != "" && dirExists(instanceDir) {
		paths := instance.ResolvePaths(instanceDir)
		installed := "(none)"
		if data, err := os.ReadFile(paths.VersionFile); err == nil {
			installed = strings.TrimSpace(string(data))
		}
		fmt.Fprintf(&b, "installed version: %s\n", installed)
	}

	b.WriteString("\nincluded files:\n")
	for _, it := range items {
		fmt.Fprintf(&b, "  %-26s %s\n", it.name, it.path)
	}

	b.WriteString("\nrelevant environment:\n")
	var keys []string
	for _, e := range os.Environ() {
		k := e[:strings.IndexByte(e, '=')]
		if strings.HasPrefix(k, "NEGATIVEZONE_") ||
			k == "INST_DIR" || k == "JAVA_HOME" ||
			k == "APPDATA" || k == "LOCALAPPDATA" || k == "USERPROFILE" {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Fprintf(&b, "  %s=%s\n", k, os.Getenv(k))
	}
	return b.String()
}

func itemsToMap(items []supportItem) map[string]string {
	m := make(map[string]string, len(items))
	for _, it := range items {
		m[it.name] = it.path
	}
	return m
}

// writeSupportZip creates a zip at outPath containing summary.txt plus each
// named file in files (name -> source path).
func writeSupportZip(outPath, summary string, files map[string]string) error {
	if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
		return err
	}
	f, err := os.Create(outPath)
	if err != nil {
		return err
	}
	defer f.Close()

	zw := zip.NewWriter(f)
	defer zw.Close()

	sw, err := zw.Create("summary.txt")
	if err != nil {
		return err
	}
	if _, err := sw.Write([]byte(summary)); err != nil {
		return err
	}

	for name, src := range files {
		data, err := os.ReadFile(src)
		if err != nil {
			continue // best-effort
		}
		w, err := zw.Create(name)
		if err != nil {
			return err
		}
		if _, err := w.Write(data); err != nil {
			return err
		}
	}
	return nil
}

// defaultSupportOutPath chooses Desktop, then the instance dir, then cwd.
func defaultSupportOutPath(instanceDir string) string {
	fileName := fmt.Sprintf("nz-support-%s.zip", time.Now().Format("20060102-150405"))
	if home := os.Getenv("USERPROFILE"); home != "" {
		desktop := filepath.Join(home, "Desktop")
		if info, err := os.Stat(desktop); err == nil && info.IsDir() {
			return filepath.Join(desktop, fileName)
		}
	}
	if instanceDir != "" && dirExists(instanceDir) {
		return filepath.Join(instanceDir, fileName)
	}
	return fileName
}

func orNone(s string) string {
	if s == "" {
		return "(not found)"
	}
	return s
}
