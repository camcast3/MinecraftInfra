// Package scope defines the shared backup/preserve file and directory lists
// used across all NegativeZone client subcommands (backup, update, setup, migrate).
//
// Adding a new file or directory to the backup scope is a single edit here —
// all subcommands pick up the change automatically.
package scope

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// Directories backed up wholesale (relative to .minecraft/).
// XaeroWorldMap is the dominant size term (multi-GB on heavy explorers).
// NOTE: only add whole-directory entries here when ALL files inside are
// client-side. Mixed dirs (client + server files) belong in .user-prefs.txt
// as individual file entries instead.
var Directories = []string{
	"XaeroWaypoints",
	"XaeroWorldMap",
	"journeymap",
	"screenshots",
	"shaderpacks",
	"resourcepacks",
	"config/jei",
	"config/emi",
	// Jade HUD — all 5 files are client-side display prefs
	"config/jade",
	// Inventory Profiles Next — per-server profiles + main config
	"config/inventoryprofilesnext",
	// Drippy Loading Screen — custom loading screen backgrounds/layout
	"config/drippyloadingscreen",
	// Animation Overhaul — player animation settings
	"config/animation_overhaul",
}

// Files backed up individually (relative to .minecraft/).
var Files = []string{
	"options.txt",
	"optionsof.txt",
	"optionsshaders.txt",
	"hotbar.nbt",
	"servers.dat",
	"usercache.json",
	"usernamecache.json",
}

// PreserveExtra lists additional relative paths that update/setup restore
// from the old .minecraft but are NOT part of the periodic backup snapshot
// (too large or not user-authored). These are dirs/files like saves/, logs/,
// crash-reports/ that survive an update swap but don't need daily snapshots.
var PreserveExtra = []string{
	"saves",
	"logs",
	"crash-reports",
	"local",
	"backups",
	"realms_persistence.json",
}

// FullPreserveSet returns the union of Directories + Files + PreserveExtra,
// which is the complete set of paths preserved across an update/setup swap.
func FullPreserveSet() []string {
	seen := make(map[string]struct{})
	var result []string
	for _, lists := range [][]string{Directories, Files, PreserveExtra} {
		for _, p := range lists {
			if _, ok := seen[p]; !ok {
				seen[p] = struct{}{}
				result = append(result, p)
			}
		}
	}
	return result
}

// BackupScope returns Directories + Files — the set of paths included in a
// periodic snapshot. If includeSaves is true, "saves" is appended to the
// directory list.
func BackupScope(includeSaves bool) (dirs []string, files []string) {
	dirs = append([]string{}, Directories...)
	files = append([]string{}, Files...)
	if includeSaves {
		dirs = append(dirs, "saves")
	}
	return dirs, files
}

// PreserveManifest represents the JSON structure of preserve-list.json
// shipped by the pack author.
type PreserveManifest struct {
	Preserve []string `json:"preserve"`
}

// LoadPreserveManifest reads and parses a preserve-list.json file.
// Returns nil with no error if the file doesn't exist.
func LoadPreserveManifest(path string) (*PreserveManifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var m PreserveManifest
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, err
	}
	return &m, nil
}

// MergePreserve returns the union of base paths and manifest entries,
// preserving order and deduplicating. Tries manifestPaths in order, using
// the first one that exists and parses successfully.
func MergePreserve(base []string, manifestPaths ...string) []string {
	seen := make(map[string]struct{})
	var result []string
	for _, p := range base {
		t := strings.TrimSpace(p)
		if t == "" {
			continue
		}
		if _, ok := seen[t]; !ok {
			seen[t] = struct{}{}
			result = append(result, t)
		}
	}

	for _, mp := range manifestPaths {
		if mp == "" {
			continue
		}
		m, err := LoadPreserveManifest(mp)
		if err != nil || m == nil {
			continue
		}
		for _, p := range m.Preserve {
			t := strings.TrimSpace(p)
			if t == "" {
				continue
			}
			// Normalize path separators for Windows
			t = filepath.FromSlash(t)
			if _, ok := seen[t]; !ok {
				seen[t] = struct{}{}
				result = append(result, t)
			}
		}
		break // use first successful manifest
	}

	return result
}
