//go:build e2e

package e2e_test

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
	"time"
)

// nzBin is the path to the compiled nz.exe binary built once in TestMain.
var nzBin string

func TestMain(m *testing.M) {
	if runtime.GOOS != "windows" {
		fmt.Fprintln(os.Stderr, "e2e tests are Windows-only; skipping.")
		os.Exit(0)
	}

	clientDir := findClientRoot()
	nzBin = filepath.Join(clientDir, "nz-e2e-test.exe")

	buildCmd := exec.Command("go", "build", "-o", nzBin, "./cmd/nz/")
	buildCmd.Dir = clientDir
	buildCmd.Stdout = os.Stdout
	buildCmd.Stderr = os.Stderr
	if err := buildCmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: failed to build nz.exe: %v\n", err)
		os.Exit(1)
	}
	defer os.Remove(nzBin)

	os.Exit(m.Run())
}

// findClientRoot traverses upward from cwd until it finds a go.mod file.
func findClientRoot() string {
	dir, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			panic("could not find go.mod by traversing upward from: " + dir)
		}
		dir = parent
	}
}

// ─── Test environment ────────────────────────────────────────────────────────

type testEnv struct {
	t       *testing.T
	appdata string
	blobDir string
	srv     *httptest.Server
	mux     *http.ServeMux
}

// newTestEnv creates an isolated sandbox with its own APPDATA, blob dir, and
// HTTP server. It pre-builds zips for v1.0.0 and v1.1.0 and publishes v1.0.0
// as the default manifest.
func newTestEnv(t *testing.T) *testEnv {
	t.Helper()

	base := t.TempDir()
	appdata := filepath.Join(base, "appdata")
	blobDir := filepath.Join(base, "blob")

	if err := os.MkdirAll(filepath.Join(appdata, "PrismLauncher", "instances"), 0o755); err != nil {
		t.Fatalf("newTestEnv: create prism dir: %v", err)
	}
	if err := os.MkdirAll(blobDir, 0o755); err != nil {
		t.Fatalf("newTestEnv: create blob dir: %v", err)
	}

	mux := http.NewServeMux()
	srv := httptest.NewServer(mux)

	e := &testEnv{
		t:       t,
		appdata: appdata,
		blobDir: blobDir,
		srv:     srv,
		mux:     mux,
	}

	// Dynamic file server — reads files fresh each request so publishManifest
	// updates are immediately visible.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		rel := strings.TrimPrefix(r.URL.Path, "/")
		filePath := filepath.Join(blobDir, filepath.FromSlash(rel))
		data, readErr := os.ReadFile(filePath)
		if readErr != nil {
			http.NotFound(w, r)
			return
		}
		ext := strings.ToLower(filepath.Ext(filePath))
		switch ext {
		case ".json":
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
		case ".zip":
			w.Header().Set("Content-Type", "application/zip")
		case ".txt":
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		default:
			w.Header().Set("Content-Type", "application/octet-stream")
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(data)))
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(data)
	})

	t.Cleanup(func() { srv.Close() })

	// Pre-build both version zips and default to v1.0.0.
	e.buildZip("1.0.0")
	e.buildZip("1.1.0")
	e.publishManifest("1.0.0", false)

	return e
}

// buildZip creates the fake modpack zip for the given version in blobDir.
// Returns the zip path and its SHA-256 hex digest.
func (e *testEnv) buildZip(version string) (zipPath, sha256hex string) {
	e.t.Helper()

	const instanceName = "Craft to Exile 2"
	// Both versions use identical mmc-pack.json so nz update's hash check passes.
	const mmcPackContent = `{"components":[{"uid":"net.minecraft","version":"1.20.1"}],"formatVersion":1}`

	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)

	addZipEntry(zw, instanceName+"/instance.cfg",
		"OverrideCommands=true\nname=Craft to Exile 2 v"+version+"\n")
	addZipEntry(zw, instanceName+"/mmc-pack.json", mmcPackContent)
	addZipEntry(zw, instanceName+"/.minecraft/mods/stub-v"+version+".jar",
		"stub-mod-"+version)
	addZipEntry(zw, instanceName+"/.negativezone/preserve-list.json",
		`{"preserve":["config/test-mod-prefs.json"],"version":1}`)

	if err := zw.Close(); err != nil {
		e.t.Fatalf("buildZip close: %v", err)
	}

	zipName := "c2e2-v" + version + ".zip"
	zipPath = filepath.Join(e.blobDir, zipName)
	if err := os.WriteFile(zipPath, buf.Bytes(), 0o644); err != nil {
		e.t.Fatalf("buildZip write: %v", err)
	}

	h := sha256.Sum256(buf.Bytes())
	sha256hex = hex.EncodeToString(h[:])
	return
}

func addZipEntry(zw *zip.Writer, name, content string) {
	w, err := zw.Create(name)
	if err != nil {
		panic(fmt.Sprintf("addZipEntry %s: %v", name, err))
	}
	if _, err := io.WriteString(w, content); err != nil {
		panic(fmt.Sprintf("addZipEntry write %s: %v", name, err))
	}
}

// publishManifest writes latest.json and latest-version.txt to blobDir,
// reading the zip at c2e2-v<version>.zip for size and SHA-256.
func (e *testEnv) publishManifest(version string, allowDowngrade bool) {
	e.t.Helper()

	zipPath := filepath.Join(e.blobDir, "c2e2-v"+version+".zip")
	data, err := os.ReadFile(zipPath)
	if err != nil {
		e.t.Fatalf("publishManifest: zip not found for v%s: %v", version, err)
	}

	h := sha256.Sum256(data)
	sha256hex := hex.EncodeToString(h[:])

	type manifest struct {
		Version        string `json:"version"`
		Instance       string `json:"instance"`
		URL            string `json:"url"`
		SHA256         string `json:"sha256"`
		SizeBytes      int64  `json:"sizeBytes"`
		AllowDowngrade bool   `json:"allowDowngrade,omitempty"`
		PackwizURL     string `json:"packwizUrl"`
	}

	m := manifest{
		Version:        version,
		Instance:       "Craft to Exile 2",
		URL:            e.srv.URL + "/c2e2-v" + version + ".zip",
		SHA256:         sha256hex,
		SizeBytes:      int64(len(data)),
		AllowDowngrade: allowDowngrade,
		PackwizURL:     "http://127.0.0.1/pack.toml",
	}

	jsonData, err := json.Marshal(m)
	if err != nil {
		e.t.Fatalf("publishManifest: json marshal: %v", err)
	}
	if err := os.WriteFile(filepath.Join(e.blobDir, "latest.json"), jsonData, 0o644); err != nil {
		e.t.Fatalf("publishManifest: write latest.json: %v", err)
	}
	if err := os.WriteFile(filepath.Join(e.blobDir, "latest-version.txt"), []byte(version+"\n"), 0o644); err != nil {
		e.t.Fatalf("publishManifest: write latest-version.txt: %v", err)
	}
}

// bumpVersionPointer rewrites latest-version.txt without touching latest.json.
// Used in prelaunch tests to simulate "pointer ahead/behind of manifest".
func (e *testEnv) bumpVersionPointer(version string) {
	e.t.Helper()
	if err := os.WriteFile(filepath.Join(e.blobDir, "latest-version.txt"), []byte(version+"\n"), 0o644); err != nil {
		e.t.Fatalf("bumpVersionPointer: %v", err)
	}
}

// instanceDir returns the expected Prism instance path in the sandboxed APPDATA.
func (e *testEnv) instanceDir() string {
	return filepath.Join(e.appdata, "PrismLauncher", "instances", "Craft to Exile 2")
}

// dotMC returns the .minecraft path inside the instance.
func (e *testEnv) dotMC() string {
	return filepath.Join(e.instanceDir(), ".minecraft")
}

// backupsDir returns the .negativezone/backups path inside the instance.
func (e *testEnv) backupsDir() string {
	return filepath.Join(e.instanceDir(), ".negativezone", "backups")
}

// runNZ executes the nz binary with the given args.
// It inherits os.Environ() then overrides sandboxed APPDATA and the
// NEGATIVEZONE_* URLs, and merges in any extraEnv.
// Returns (exitCode, combinedOutput).
func (e *testEnv) runNZ(extraEnv map[string]string, args ...string) (int, string) {
	e.t.Helper()

	cmd := exec.Command(nzBin, args...)

	overrides := map[string]string{
		"APPDATA":                         e.appdata,
		"NEGATIVEZONE_NONINTERACTIVE":     "1",
		"NEGATIVEZONE_SKIP_PRISM_CHECK":   "1",
		"NEGATIVEZONE_MANIFEST_URL":       e.srv.URL + "/latest.json",
		"NEGATIVEZONE_LATEST_VERSION_URL": e.srv.URL + "/latest-version.txt",
	}
	for k, v := range extraEnv {
		overrides[k] = v
	}

	cmd.Env = buildEnv(os.Environ(), overrides)

	out, err := cmd.CombinedOutput()
	code := 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			code = exitErr.ExitCode()
		} else {
			e.t.Logf("runNZ non-exit error: %v", err)
		}
	}
	return code, string(out)
}

// buildEnv merges base env slice with overrides (case-insensitive on Windows).
func buildEnv(base []string, overrides map[string]string) []string {
	upperOverrides := make(map[string]string, len(overrides))
	for k, v := range overrides {
		upperOverrides[strings.ToUpper(k)] = v
	}

	result := make([]string, 0, len(base)+len(overrides))
	seen := make(map[string]bool, len(overrides))

	for _, entry := range base {
		idx := strings.IndexByte(entry, '=')
		if idx < 0 {
			result = append(result, entry)
			continue
		}
		upperKey := strings.ToUpper(entry[:idx])
		if val, ok := upperOverrides[upperKey]; ok {
			if !seen[upperKey] {
				result = append(result, entry[:idx]+"="+val)
				seen[upperKey] = true
			}
		} else {
			result = append(result, entry)
		}
	}

	// Append overrides whose keys were not in base.
	for k, v := range overrides {
		if !seen[strings.ToUpper(k)] {
			result = append(result, k+"="+v)
		}
	}
	return result
}

// countSnapshots returns the number of timestamp-named snapshot dirs.
func (e *testEnv) countSnapshots() int {
	e.t.Helper()
	entries, err := os.ReadDir(e.backupsDir())
	if os.IsNotExist(err) {
		return 0
	}
	if err != nil {
		e.t.Fatalf("countSnapshots: %v", err)
	}
	count := 0
	for _, entry := range entries {
		if entry.IsDir() && isTimestampName(entry.Name()) {
			count++
		}
	}
	return count
}

// newestSnapshot returns the full path of the most recent snapshot dir.
func (e *testEnv) newestSnapshot() string {
	e.t.Helper()
	bd := e.backupsDir()
	entries, err := os.ReadDir(bd)
	if err != nil {
		e.t.Fatalf("newestSnapshot readdir: %v", err)
	}
	var names []string
	for _, entry := range entries {
		if entry.IsDir() && isTimestampName(entry.Name()) {
			names = append(names, entry.Name())
		}
	}
	if len(names) == 0 {
		e.t.Fatal("newestSnapshot: no snapshots found")
	}
	sort.Strings(names)
	return filepath.Join(bd, names[len(names)-1])
}

// isTimestampName returns true for names matching yyyyMMdd-HHmmss(-N)?.
func isTimestampName(name string) bool {
	if len(name) < 15 {
		return false
	}
	for _, c := range name[:8] {
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

// ─── Assertion helpers ───────────────────────────────────────────────────────

func assertExists(t *testing.T, path, msg string) {
	t.Helper()
	if _, err := os.Stat(path); err != nil {
		t.Errorf("FAIL %s: expected to exist: %s", msg, path)
	}
}

func assertNotExists(t *testing.T, path, msg string) {
	t.Helper()
	if _, err := os.Stat(path); err == nil {
		t.Errorf("FAIL %s: expected NOT to exist: %s", msg, path)
	}
}

func assertContains(t *testing.T, path, substr, msg string) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Errorf("FAIL %s: cannot read %s: %v", msg, path, err)
		return
	}
	if !strings.Contains(string(data), substr) {
		t.Errorf("FAIL %s: %q not found in %s\ncontent: %s", msg, substr, path, string(data))
	}
}

// writeFile creates a file (and any missing parents) with the given content.
func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("writeFile mkdir %s: %v", path, err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("writeFile %s: %v", path, err)
	}
}

func fakePackwizCmd(t *testing.T, version string, exitCode int) string {
	t.Helper()
	scriptPath := filepath.Join(t.TempDir(), "fake-packwiz.cmd")
	var content string
	if exitCode == 0 {
		content = fmt.Sprintf("@echo off\r\nif not exist mods mkdir mods\r\necho synced-%s> mods\\packwiz-synced.txt\r\nexit /b 0\r\n", version)
	} else {
		content = fmt.Sprintf("@echo off\r\nexit /b %d\r\n", exitCode)
	}
	if err := os.WriteFile(scriptPath, []byte(content), 0o755); err != nil {
		t.Fatalf("fakePackwizCmd write: %v", err)
	}
	return scriptPath
}

// ─── Tests ───────────────────────────────────────────────────────────────────

// 1. fresh-install: nz setup v1.0.0 creates instance, hooks, version file.
func TestFreshInstall(t *testing.T) {
	e := newTestEnv(t)

	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("setup exit %d:\n%s", code, out)
	}

	inst := e.instanceDir()
	assertExists(t, filepath.Join(inst, "instance.cfg"), "instance.cfg created")
	assertExists(t, filepath.Join(inst, ".minecraft", "mods", "stub-v1.0.0.jar"), "mod jar present")
	assertExists(t, filepath.Join(inst, ".negativezone-version"), "version file created")
	assertContains(t, filepath.Join(inst, ".negativezone-version"), "1.0.0", "version file content")
	assertContains(t, filepath.Join(inst, "instance.cfg"), "OverrideCommands=true", "OverrideCommands set")
	assertContains(t, filepath.Join(inst, "instance.cfg"), "nz.exe", "nz binary referenced")
	assertContains(t, filepath.Join(inst, "instance.cfg"), "check", "PreLaunchCommand wired")
	assertContains(t, filepath.Join(inst, "instance.cfg"), "backup", "PostExitCommand wired")
	assertExists(t, filepath.Join(inst, "Update Craft to Exile 2.cmd"), "update launcher created")
	assertContains(t, filepath.Join(inst, "Update Craft to Exile 2.cmd"), "update", "launcher runs nz update")
	assertNotExists(t, inst+".bak", "no .bak on fresh install")
}

// 2. heal-broken-install: re-run nz setup same version re-installs cleanly.
func TestHealBrokenInstall(t *testing.T) {
	e := newTestEnv(t)

	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("first install exit %d:\n%s", code, out)
	}

	vf := filepath.Join(e.instanceDir(), ".negativezone-version")
	if err := os.WriteFile(vf, []byte("corrupt"), 0o644); err != nil {
		t.Fatalf("corrupt version file: %v", err)
	}

	code, out = e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("re-run setup exit %d:\n%s", code, out)
	}

	assertContains(t, vf, "1.0.0", "version file repaired to 1.0.0")
}

// 3. upgrade-with-state-restore: plant sentinels, upgrade to v1.1.0, all sentinels survive.
func TestUpgradeWithStateRestore(t *testing.T) {
	e := newTestEnv(t)

	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("install v1.0.0 exit %d:\n%s", code, out)
	}

	mc := e.dotMC()
	writeFile(t, filepath.Join(mc, "saves", "my-world", "region", "r.0.0.mca"), "world-bytes")
	writeFile(t, filepath.Join(mc, "options.txt"), "mouseSensitivity:0.4")
	writeFile(t, filepath.Join(mc, "XaeroWorldMap", "sp", "waypoint.json"), "waypoint")
	writeFile(t, filepath.Join(mc, "journeymap", "data", "sp", "waypoints.json"), "jm-waypoint")
	writeFile(t, filepath.Join(mc, "shaderpacks", "MyShaderpacks.zip"), "shaderdata")
	writeFile(t, filepath.Join(mc, "config", "test-mod-prefs.json"), "preserve-list-sentinel")

	e.publishManifest("1.1.0", false)

	code, out = e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("upgrade to v1.1.0 exit %d:\n%s", code, out)
	}

	inst := e.instanceDir()
	assertExists(t, inst+".bak", ".bak created from old instance")
	assertExists(t, filepath.Join(mc, "saves", "my-world", "region", "r.0.0.mca"), "saves RESTORED")
	assertContains(t, filepath.Join(mc, "options.txt"), "mouseSensitivity:0.4", "options.txt RESTORED")
	assertExists(t, filepath.Join(mc, "XaeroWorldMap", "sp", "waypoint.json"), "XaeroWorldMap RESTORED")
	assertExists(t, filepath.Join(mc, "journeymap", "data", "sp", "waypoints.json"), "journeymap RESTORED")
	assertExists(t, filepath.Join(mc, "shaderpacks", "MyShaderpacks.zip"), "shaderpacks RESTORED")
	assertContains(t, filepath.Join(mc, "config", "test-mod-prefs.json"), "preserve-list-sentinel", "preserve-list entry RESTORED")
	assertContains(t, filepath.Join(inst, ".negativezone-version"), "1.1.0", "version bumped to 1.1.0")
	assertExists(t, filepath.Join(mc, "mods", "stub-v1.1.0.jar"), "v1.1.0 mod installed")
	assertNotExists(t, filepath.Join(mc, "mods", "stub-v1.0.0.jar"), "v1.0.0 mod removed")
}

// 4. prelaunch-happy-path: nz check exits 0 when installed == latest.
func TestPrelaunchHappyPath(t *testing.T) {
	e := newTestEnv(t)

	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("install exit %d:\n%s", code, out)
	}

	code, out = e.runNZ(map[string]string{"INST_DIR": e.instanceDir()}, "check")
	if code != 0 {
		t.Errorf("check should exit 0 when installed==latest, got %d\n%s", code, out)
	}
}

// 5. prelaunch-blocks-when-stale: nz check exits 1 when installed < latest.
func TestPrelaunchBlocksWhenStale(t *testing.T) {
	e := newTestEnv(t)

	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("install exit %d:\n%s", code, out)
	}

	e.bumpVersionPointer("1.1.0")

	code, out = e.runNZ(map[string]string{"INST_DIR": e.instanceDir()}, "check")
	if code != 1 {
		t.Errorf("check should exit 1 when stale, got %d\n%s", code, out)
	}
	if !strings.Contains(out, "MISMATCH") {
		t.Errorf("output should contain MISMATCH:\n%s", out)
	}
	if !strings.Contains(out, "behind") {
		t.Errorf("output should contain 'behind':\n%s", out)
	}
}

// 6. prelaunch-blocks-when-ahead: nz check exits 1 when installed > latest.
func TestPrelaunchBlocksWhenAhead(t *testing.T) {
	e := newTestEnv(t)

	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("install exit %d:\n%s", code, out)
	}

	e.bumpVersionPointer("0.9.0")

	code, out = e.runNZ(map[string]string{"INST_DIR": e.instanceDir()}, "check")
	if code != 1 {
		t.Errorf("check should exit 1 when ahead, got %d\n%s", code, out)
	}
	if !strings.Contains(out, "MISMATCH") {
		t.Errorf("output should contain MISMATCH:\n%s", out)
	}
	if !strings.Contains(out, "ahead") {
		t.Errorf("output should contain 'ahead':\n%s", out)
	}
}

// 7. prelaunch-bypass-env: NEGATIVEZONE_SKIP_VERSION_CHECK=1 allows stale launch.
func TestPrelaunchBypassEnv(t *testing.T) {
	e := newTestEnv(t)

	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("install exit %d:\n%s", code, out)
	}

	e.bumpVersionPointer("1.1.0")

	code, out = e.runNZ(map[string]string{
		"INST_DIR":                        e.instanceDir(),
		"NEGATIVEZONE_SKIP_VERSION_CHECK": "1",
	}, "check")
	if code != 0 {
		t.Errorf("check with bypass should exit 0, got %d\n%s", code, out)
	}
}

// 8. prelaunch-fails-open-offline: unreachable version URL → exits 0.
func TestPrelaunchFailsOpenOffline(t *testing.T) {
	e := newTestEnv(t)

	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("install exit %d:\n%s", code, out)
	}

	code, out = e.runNZ(map[string]string{
		"INST_DIR":                        e.instanceDir(),
		"NEGATIVEZONE_LATEST_VERSION_URL": "http://127.0.0.1:1/404",
	}, "check")
	if code != 0 {
		t.Errorf("check should fail-open (exit 0) when offline, got %d\n%s", code, out)
	}
}

// 9. postexit-snapshot-captures-directories: nz backup snapshots dirs correctly.
func TestPostexitSnapshotCapturesDirectories(t *testing.T) {
	e := newTestEnv(t)

	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("install exit %d:\n%s", code, out)
	}

	mc := e.dotMC()
	writeFile(t, filepath.Join(mc, "shaderpacks", "MyShaderpacks.zip.txt"), "shaderdata")
	writeFile(t, filepath.Join(mc, "XaeroWaypoints", "dim0.txt"), "waypoint")
	writeFile(t, filepath.Join(mc, "config", "jei", "bookmarks.ini"), "bookmarks")

	code, out = e.runNZ(map[string]string{
		"INST_DIR":                 e.instanceDir(),
		"NEGATIVEZONE_BACKUP_DAYS": "0",
	}, "backup")
	if code != 0 {
		t.Fatalf("backup exit %d:\n%s", code, out)
	}

	snap := e.newestSnapshot()
	assertExists(t, filepath.Join(snap, "shaderpacks", "MyShaderpacks.zip.txt"), "shaderpacks in snapshot")
	assertExists(t, filepath.Join(snap, "XaeroWaypoints", "dim0.txt"), "XaeroWaypoints in snapshot")
	assertExists(t, filepath.Join(snap, "config", "jei", "bookmarks.ini"), "config/jei in snapshot")
}

// 10. postexit-cadence-skip: second nz backup within window skips.
func TestPostexitCadenceSkip(t *testing.T) {
	e := newTestEnv(t)

	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("install exit %d:\n%s", code, out)
	}

	writeFile(t, filepath.Join(e.dotMC(), "options.txt"), "sentinel")

	code, out = e.runNZ(map[string]string{
		"INST_DIR":                 e.instanceDir(),
		"NEGATIVEZONE_BACKUP_DAYS": "0",
	}, "backup")
	if code != 0 {
		t.Fatalf("first backup exit %d:\n%s", code, out)
	}

	snaps1 := e.countSnapshots()

	// Second run with 3-day cadence — last backup was just now, should skip.
	code, out = e.runNZ(map[string]string{
		"INST_DIR":                 e.instanceDir(),
		"NEGATIVEZONE_BACKUP_DAYS": "3",
	}, "backup")
	if code != 0 {
		t.Fatalf("second backup exit %d:\n%s", code, out)
	}

	snaps2 := e.countSnapshots()
	if snaps1 != snaps2 {
		t.Errorf("cadence skip failed: expected %d snapshots after second run, got %d", snaps1, snaps2)
	}
}

// 11. postexit-force-bypasses-cadence: nz backup --force runs anyway.
func TestPostexitForceBypassesCadence(t *testing.T) {
	e := newTestEnv(t)

	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("install exit %d:\n%s", code, out)
	}

	writeFile(t, filepath.Join(e.dotMC(), "options.txt"), "sentinel")

	code, out = e.runNZ(map[string]string{
		"INST_DIR":                 e.instanceDir(),
		"NEGATIVEZONE_BACKUP_DAYS": "0",
	}, "backup")
	if code != 0 {
		t.Fatalf("first backup exit %d:\n%s", code, out)
	}

	// Wait so the second snapshot gets a distinct timestamp.
	time.Sleep(1100 * time.Millisecond)

	code, out = e.runNZ(map[string]string{
		"INST_DIR": e.instanceDir(),
	}, "backup", "--force")
	if code != 0 {
		t.Fatalf("force backup exit %d:\n%s", code, out)
	}

	if snaps := e.countSnapshots(); snaps != 2 {
		t.Errorf("expected 2 snapshots after --force, got %d", snaps)
	}
}

// 12. postexit-prunes-old-snapshots: excess snapshots pruned to RETAIN count.
func TestPostexitPrunesOldSnapshots(t *testing.T) {
	e := newTestEnv(t)

	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("install exit %d:\n%s", code, out)
	}

	writeFile(t, filepath.Join(e.dotMC(), "options.txt"), "sentinel")

	backupEnv := map[string]string{
		"INST_DIR":                   e.instanceDir(),
		"NEGATIVEZONE_BACKUP_DAYS":   "0",
		"NEGATIVEZONE_BACKUP_RETAIN": "3",
	}

	for i := 0; i < 5; i++ {
		if i > 0 {
			time.Sleep(1100 * time.Millisecond)
		}
		code, out = e.runNZ(backupEnv, "backup")
		if code != 0 {
			t.Fatalf("backup %d exit %d:\n%s", i+1, code, out)
		}
	}

	if snaps := e.countSnapshots(); snaps != 3 {
		t.Errorf("expected 3 snapshots after pruning to RETAIN=3, got %d", snaps)
	}
}

// 13. postexit-preserve-list-extends-scope: pack-author preserve-list entries appear in snapshot.
func TestPostexitPreserveListExtendsScope(t *testing.T) {
	e := newTestEnv(t)

	// Install v1.0.0 — zip includes preserve-list with "config/test-mod-prefs.json".
	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("install exit %d:\n%s", code, out)
	}

	writeFile(t, filepath.Join(e.dotMC(), "config", "test-mod-prefs.json"), "sentinel-value")

	code, out = e.runNZ(map[string]string{
		"INST_DIR":                 e.instanceDir(),
		"NEGATIVEZONE_BACKUP_DAYS": "0",
	}, "backup")
	if code != 0 {
		t.Fatalf("backup exit %d:\n%s", code, out)
	}

	snap := e.newestSnapshot()
	assertContains(t, filepath.Join(snap, "config", "test-mod-prefs.json"), "sentinel-value",
		"preserve-list entry captured in snapshot")
}

// 14. update-happy-path: nz update packwiz-syncs and preserves user state.
func TestUpdateHappyPath(t *testing.T) {
	e := newTestEnv(t)

	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("install v1.0.0 exit %d:\n%s", code, out)
	}
	t.Logf("installed synthetic modpack version 1.0.0")

	mc := e.dotMC()
	writeFile(t, filepath.Join(mc, "options.txt"), "saved-setting")
	writeFile(t, filepath.Join(mc, "XaeroWorldMap", "sp", "wp.json"), "xaero")

	e.publishManifest("1.1.0", false)

	code, out = e.runNZ(map[string]string{
		"INST_DIR":                  e.instanceDir(),
		"NEGATIVEZONE_MANIFEST_URL": e.srv.URL + "/latest.json",
		"NEGATIVEZONE_PACKWIZ_CMD":  fakePackwizCmd(t, "1.1.0", 0),
	}, "update")
	if code != 0 {
		t.Fatalf("update exit %d:\n%s", code, out)
	}

	versionFile := filepath.Join(e.instanceDir(), ".negativezone-version")
	assertContains(t, versionFile, "1.1.0", "version bumped to 1.1.0")
	assertContains(t, filepath.Join(mc, "mods", "packwiz-synced.txt"), "synced-1.1.0", "packwiz fake synced")
	assertContains(t, filepath.Join(mc, "options.txt"), "saved-setting", "options.txt preserved")
	assertExists(t, filepath.Join(mc, "XaeroWorldMap", "sp", "wp.json"), "XaeroWorldMap preserved")
	versionBytes, err := os.ReadFile(versionFile)
	if err != nil {
		t.Fatalf("read version file after update: %v", err)
	}
	t.Logf("updated synthetic modpack version 1.0.0 -> %s; preserved options.txt and XaeroWorldMap state", strings.TrimSpace(string(versionBytes)))
}

// 15. no-downgrade-by-default: nz update refuses downgrade without opt-in.
func TestNoDowngradeByDefault(t *testing.T) {
	e := newTestEnv(t)

	// Install v1.1.0 first.
	e.publishManifest("1.1.0", false)
	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("install v1.1.0 exit %d:\n%s", code, out)
	}

	// Publish v1.0.0 — a downgrade — without allowDowngrade.
	e.publishManifest("1.0.0", false)

	code, out = e.runNZ(map[string]string{
		"INST_DIR":                  e.instanceDir(),
		"NEGATIVEZONE_MANIFEST_URL": e.srv.URL + "/latest.json",
		"NEGATIVEZONE_PACKWIZ_CMD":  fakePackwizCmd(t, "1.0.0", 0),
	}, "update")
	if code != 0 {
		t.Fatalf("update exit %d:\n%s", code, out)
	}

	assertContains(t, filepath.Join(e.instanceDir(), ".negativezone-version"), "1.1.0",
		"version unchanged — downgrade refused")
	assertNotExists(t, filepath.Join(e.dotMC(), "mods", "packwiz-synced.txt"),
		"packwiz not run when downgrade refused")
}

// 16. allow-downgrade: nz update downgrades when allowDowngrade:true.
func TestAllowDowngrade(t *testing.T) {
	e := newTestEnv(t)

	// Install v1.1.0 first.
	e.publishManifest("1.1.0", false)
	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("install v1.1.0 exit %d:\n%s", code, out)
	}

	// Publish v1.0.0 with allowDowngrade=true.
	e.publishManifest("1.0.0", true)

	code, out = e.runNZ(map[string]string{
		"INST_DIR":                  e.instanceDir(),
		"NEGATIVEZONE_MANIFEST_URL": e.srv.URL + "/latest.json",
		"NEGATIVEZONE_PACKWIZ_CMD":  fakePackwizCmd(t, "1.0.0", 0),
	}, "update")
	if code != 0 {
		t.Fatalf("update exit %d:\n%s", code, out)
	}

	assertContains(t, filepath.Join(e.instanceDir(), ".negativezone-version"), "1.0.0",
		"downgraded to 1.0.0")
	assertContains(t, filepath.Join(e.dotMC(), "mods", "packwiz-synced.txt"), "synced-1.0.0",
		"packwiz fake synced downgrade")
}

// 17. update-packwiz-failure-keeps-version: failed sync leaves version marker unchanged.
func TestUpdatePackwizFailureKeepsVersion(t *testing.T) {
	e := newTestEnv(t)

	code, out := e.runNZ(nil, "setup")
	if code != 0 {
		t.Fatalf("install v1.0.0 exit %d:\n%s", code, out)
	}

	e.publishManifest("1.1.0", false)

	code, out = e.runNZ(map[string]string{
		"INST_DIR":                  e.instanceDir(),
		"NEGATIVEZONE_MANIFEST_URL": e.srv.URL + "/latest.json",
		"NEGATIVEZONE_PACKWIZ_CMD":  fakePackwizCmd(t, "1.1.0", 1),
	}, "update")
	if code == 0 {
		t.Fatalf("update should fail when packwiz fails:\n%s", out)
	}

	assertContains(t, filepath.Join(e.instanceDir(), ".negativezone-version"), "1.0.0",
		"version unchanged after packwiz failure")
}
