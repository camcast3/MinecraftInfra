// Package instance provides Prism/CurseForge instance detection and path resolution.
package instance

import (
	"os"
	"path/filepath"
)

// Info describes a discovered Minecraft launcher instance.
type Info struct {
	Launcher string // "Prism" or "CurseForge"
	Name     string
	Path     string
}

// Paths holds the resolved paths for a NegativeZone managed instance.
type Paths struct {
	Instance    string // top-level instance dir
	DotMC       string // .minecraft
	NZDir       string // .negativezone
	BackupsDir  string // .negativezone/backups
	VersionFile string // .negativezone-version
	InstanceCfg string // instance.cfg
}

// ResolvePaths computes standard subpaths from an instance directory.
func ResolvePaths(instanceDir string) Paths {
	nz := filepath.Join(instanceDir, ".negativezone")
	return Paths{
		Instance:    instanceDir,
		DotMC:       filepath.Join(instanceDir, ".minecraft"),
		NZDir:       nz,
		BackupsDir:  filepath.Join(nz, "backups"),
		VersionFile: filepath.Join(instanceDir, ".negativezone-version"),
		InstanceCfg: filepath.Join(instanceDir, "instance.cfg"),
	}
}

// FindPrismInstances scans the standard Prism Launcher instances folder.
func FindPrismInstances() []Info {
	appdata := os.Getenv("APPDATA")
	if appdata == "" {
		return nil
	}
	return scanDir(filepath.Join(appdata, "PrismLauncher", "instances"), "Prism")
}

// FindCurseForgeInstances scans the standard CurseForge instances folder.
func FindCurseForgeInstances() []Info {
	home := os.Getenv("USERPROFILE")
	if home == "" {
		return nil
	}
	return scanDir(filepath.Join(home, "curseforge", "minecraft", "Instances"), "CurseForge")
}

// FindAll returns all discoverable instances across all supported launchers.
func FindAll() []Info {
	var all []Info
	all = append(all, FindPrismInstances()...)
	all = append(all, FindCurseForgeInstances()...)
	return all
}

// DefaultC2E2Path returns the expected path for the Craft to Exile 2 instance
// under Prism Launcher.
func DefaultC2E2Path() string {
	appdata := os.Getenv("APPDATA")
	if appdata == "" {
		return ""
	}
	return filepath.Join(appdata, "PrismLauncher", "instances", "Craft to Exile 2")
}

// ResolveMinecraftRoot finds the .minecraft folder within an instance,
// handling both Prism (has .minecraft subdir) and CurseForge (files at root).
func ResolveMinecraftRoot(instancePath string) string {
	dotMC := filepath.Join(instancePath, ".minecraft")
	if info, err := os.Stat(dotMC); err == nil && info.IsDir() {
		return dotMC
	}
	return instancePath
}

func scanDir(dir string, launcher string) []Info {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var results []Info
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		full := filepath.Join(dir, e.Name())
		// Only include if it looks like a Minecraft instance
		dotMC := filepath.Join(full, ".minecraft")
		if _, err := os.Stat(dotMC); err == nil {
			results = append(results, Info{
				Launcher: launcher,
				Name:     e.Name(),
				Path:     full,
			})
		}
	}
	return results
}
