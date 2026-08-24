package cmd

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/camcast3/MinecraftInfra/client/internal/compatibility"
	"github.com/camcast3/MinecraftInfra/client/internal/scope"
	"github.com/camcast3/MinecraftInfra/client/internal/transaction"
)

func TestRunUpdatePackwizFailureRollsBackStagedMutation(t *testing.T) {
	root := t.TempDir()
	live := filepath.Join(root, "instance")
	writeFileForTest(t, filepath.Join(live, ".negativezone-version"), "1.0.0")
	writeFileForTest(t, filepath.Join(live, ".minecraft", "managed.txt"), "old-managed")
	writeFileForTest(t, filepath.Join(live, ".minecraft", "options.txt"), "player-setting")

	manifest := compatibleUpdateManifest("2.0.0")
	server := serveUpdateManifest(t, &manifest, `{"version":1,"preserve":[]}`)
	defer server.Close()

	oldSync := packwizSync
	defer func() { packwizSync = oldSync }()
	packwizSync = func(mcDir, _ string, _ string) error {
		if filepath.Clean(mcDir) == filepath.Clean(filepath.Join(live, ".minecraft")) {
			t.Fatal("packwiz was pointed at the live instance")
		}
		writeFileForTest(t, filepath.Join(mcDir, "managed.txt"), "partial-new")
		writeFileForTest(t, filepath.Join(mcDir, "options.txt"), "pack-default")
		return fmt.Errorf("fake packwiz process failed")
	}

	t.Setenv("INST_DIR", live)
	t.Setenv("NEGATIVEZONE_MANIFEST_URL", server.URL)
	err := runUpdate(updateCmd, nil)
	if err == nil || !strings.Contains(err.Error(), "fake packwiz process failed") {
		t.Fatalf("expected propagated packwiz failure, got %v", err)
	}

	assertFileForTest(t, filepath.Join(live, ".minecraft", "managed.txt"), "old-managed")
	assertFileForTest(t, filepath.Join(live, ".minecraft", "options.txt"), "player-setting")
	assertFileForTest(t, filepath.Join(live, ".negativezone-version"), "1.0.0")

	backupRoot := filepath.Join(root, ".negativezone-backups", "instance")
	entries, readErr := os.ReadDir(backupRoot)
	if readErr != nil || len(entries) != 1 {
		t.Fatalf("expected one immutable backup, entries=%v err=%v", entries, readErr)
	}
	if _, statErr := os.Stat(filepath.Join(backupRoot, entries[0].Name(), "complete.json")); statErr != nil {
		t.Fatalf("backup completion metadata missing: %v", statErr)
	}
}

func TestRunUpdateCorruptMarkerRepeatLoaderAndDowngrade(t *testing.T) {
	root := t.TempDir()
	live := filepath.Join(root, "instance")
	writeFileForTest(t, filepath.Join(live, ".negativezone-version"), "corrupt-marker")
	writeFileForTest(t, filepath.Join(live, ".minecraft", "managed.txt"), "old")

	manifest := compatibleUpdateManifest("2.0.0")
	server := serveUpdateManifest(t, &manifest, `{"version":1,"preserve":[]}`)
	defer server.Close()

	oldSync := packwizSync
	defer func() { packwizSync = oldSync }()
	calls := 0
	packwizSync = func(mcDir, _ string, _ string) error {
		calls++
		writeFileForTest(t, filepath.Join(mcDir, "managed.txt"), manifest.Version)
		writeFileForTest(t, filepath.Join(filepath.Dir(mcDir), "mmc-pack.json"), manifest.Version)
		return nil
	}

	t.Setenv("INST_DIR", live)
	t.Setenv("NEGATIVEZONE_MANIFEST_URL", server.URL)
	if err := runUpdate(updateCmd, nil); err != nil {
		t.Fatalf("update corrupt marker: %v", err)
	}
	assertFileForTest(t, filepath.Join(live, ".negativezone-version"), "2.0.0")
	assertFileForTest(t, filepath.Join(live, "mmc-pack.json"), "2.0.0")

	if err := runUpdate(updateCmd, nil); err != nil {
		t.Fatalf("repeat update: %v", err)
	}
	if calls != 1 {
		t.Fatalf("repeat update called packwiz: %d", calls)
	}

	manifest.Version = "1.0.0"
	if err := runUpdate(updateCmd, nil); err != nil {
		t.Fatalf("refused downgrade: %v", err)
	}
	assertFileForTest(t, filepath.Join(live, ".negativezone-version"), "2.0.0")
	if calls != 1 {
		t.Fatalf("refused downgrade called packwiz: %d", calls)
	}

	manifest.AllowDowngrade = true
	if err := runUpdate(updateCmd, nil); err != nil {
		t.Fatalf("allowed downgrade: %v", err)
	}
	assertFileForTest(t, filepath.Join(live, ".negativezone-version"), "1.0.0")
	if calls != 2 {
		t.Fatalf("allowed downgrade calls=%d, want 2", calls)
	}
}

func TestRunUpdateRejectsIncompatibleReleaseBeforePackwiz(t *testing.T) {
	root := t.TempDir()
	live := filepath.Join(root, "instance")
	writeFileForTest(t, filepath.Join(live, ".negativezone-version"), "1.0.0")
	writeFileForTest(t, filepath.Join(live, ".minecraft", "managed.txt"), "old")

	manifest := compatibleUpdateManifest("2.0.0")
	manifest.Compatibility.TransactionSchema++
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if err := json.NewEncoder(w).Encode(manifest); err != nil {
			t.Errorf("encode manifest: %v", err)
		}
	}))
	defer server.Close()

	oldSync := packwizSync
	defer func() { packwizSync = oldSync }()
	packwizSync = func(_, _, _ string) error {
		t.Fatal("packwiz ran for an incompatible release")
		return nil
	}

	t.Setenv("INST_DIR", live)
	t.Setenv("NEGATIVEZONE_MANIFEST_URL", server.URL)
	err := runUpdate(updateCmd, nil)
	if err == nil || !strings.Contains(err.Error(), "unsupported transaction schema") {
		t.Fatalf("expected compatibility rejection, got %v", err)
	}
	assertFileForTest(t, filepath.Join(live, ".negativezone-version"), "1.0.0")
	assertFileForTest(t, filepath.Join(live, ".minecraft", "managed.txt"), "old")
}

func TestRunUpdateUnionsInstalledAndTargetPreservationRules(t *testing.T) {
	root := t.TempDir()
	live := filepath.Join(root, "instance")
	writeFileForTest(t, filepath.Join(live, ".negativezone-version"), "1.0.0")
	writeFileForTest(t, filepath.Join(live, ".minecraft", "config", "installed.json"), "installed-value")
	writeFileForTest(t, filepath.Join(live, ".minecraft", "config", "target.json"), "target-value")
	writeFileForTest(t, filepath.Join(live, ".negativezone", "preserve-list.json"),
		`{"version":1,"preserve":["config/installed.json"]}`)

	manifest := compatibleUpdateManifest("2.0.0")
	server := serveUpdateManifest(t, &manifest,
		`{"version":1,"preserve":["config/target.json"]}`)
	defer server.Close()

	oldSync := packwizSync
	defer func() { packwizSync = oldSync }()
	packwizSync = func(mcDir, _ string, _ string) error {
		writeFileForTest(t, filepath.Join(mcDir, "config", "installed.json"), "new-default")
		writeFileForTest(t, filepath.Join(mcDir, "config", "target.json"), "new-default")
		return nil
	}

	t.Setenv("INST_DIR", live)
	t.Setenv("NEGATIVEZONE_MANIFEST_URL", server.URL+"/manifest")
	if err := runUpdate(updateCmd, nil); err != nil {
		t.Fatalf("update with target preserve list: %v", err)
	}

	assertFileForTest(t, filepath.Join(live, ".minecraft", "config", "installed.json"), "installed-value")
	assertFileForTest(t, filepath.Join(live, ".minecraft", "config", "target.json"), "target-value")
	persisted, err := os.ReadFile(filepath.Join(live, ".negativezone", "preserve-list.json"))
	if err != nil {
		t.Fatalf("read installed target preserve list: %v", err)
	}
	var got scope.PreserveManifest
	if err := json.Unmarshal(persisted, &got); err != nil {
		t.Fatalf("decode installed target preserve list: %v", err)
	}
	if len(got.Preserve) != 1 || got.Preserve[0] != "config/target.json" {
		t.Fatalf("installed preserve list = %#v, want target release rules", got.Preserve)
	}
}

func TestRunUpdateRejectsMissingCompatibilityExceptLegacy(t *testing.T) {
	tests := []struct {
		name    string
		version string
		wantErr bool
	}{
		{name: "modern rejected", version: "0.4.3", wantErr: true},
		{name: "legacy allowed", version: compatibility.LegacyVersion},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			root := t.TempDir()
			live := filepath.Join(root, "instance")
			writeFileForTest(t, filepath.Join(live, ".negativezone-version"), "0.4.1")
			writeFileForTest(t, filepath.Join(live, ".minecraft", "managed.txt"), "old")

			manifest := updateManifest{
				Version:    tt.version,
				PackwizURL: "https://example.invalid/pack.toml",
			}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				if err := json.NewEncoder(w).Encode(manifest); err != nil {
					t.Errorf("encode manifest: %v", err)
				}
			}))
			defer server.Close()

			oldSync := packwizSync
			defer func() { packwizSync = oldSync }()
			calls := 0
			packwizSync = func(mcDir, _ string, _ string) error {
				calls++
				writeFileForTest(t, filepath.Join(mcDir, "managed.txt"), tt.version)
				return nil
			}

			t.Setenv("INST_DIR", live)
			t.Setenv("NEGATIVEZONE_MANIFEST_URL", server.URL)
			err := runUpdate(updateCmd, nil)
			if tt.wantErr {
				if err == nil || !strings.Contains(err.Error(), "missing compatibility metadata") {
					t.Fatalf("expected missing metadata rejection, got %v", err)
				}
				if calls != 0 {
					t.Fatalf("packwiz ran for rejected manifest: %d", calls)
				}
				return
			}
			if err != nil {
				t.Fatalf("legacy manifest rejected: %v", err)
			}
			if calls != 1 {
				t.Fatalf("legacy manifest packwiz calls=%d, want 1", calls)
			}
		})
	}
}

type corpusManifest struct {
	SchemaVersion int `json:"schemaVersion"`
	Sanitized     bool
	Immutable     bool
	Files         []struct {
		Path   string `json:"path"`
		Size   int64  `json:"size"`
		SHA256 string `json:"sha256"`
	} `json:"files"`
}

func TestCorpusCompatibility(t *testing.T) {
	caseDir := os.Getenv("NEGATIVEZONE_INSTANCE_CORPUS_CASE")
	if caseDir == "" {
		t.Skip("set NEGATIVEZONE_INSTANCE_CORPUS_CASE via build-instance-corpus.ps1")
	}

	payload := filepath.Join(caseDir, "payload")
	manifest := loadAndVerifyCorpus(t, caseDir, payload)
	if manifest.SchemaVersion != 1 || !manifest.Sanitized || !manifest.Immutable {
		t.Fatalf("unsafe corpus manifest: %#v", manifest)
	}

	work := t.TempDir()
	live := filepath.Join(work, "instance")
	if err := transaction.CopyTree(payload, live); err != nil {
		t.Fatalf("clone immutable corpus snapshot: %v", err)
	}
	writeFileForTest(t, filepath.Join(live, ".minecraft", "options.txt"), "synthetic-player-setting")
	versionPath := filepath.Join(live, ".negativezone-version")
	if _, err := os.Stat(versionPath); os.IsNotExist(err) {
		writeFileForTest(t, versionPath, "1.0.0")
	}

	currentManifest := compatibleUpdateManifest("9999.0.0")
	server := serveUpdateManifest(t, &currentManifest, `{"version":1,"preserve":[]}`)
	defer server.Close()

	oldSync := packwizSync
	defer func() { packwizSync = oldSync }()
	syncCalls := 0
	packwizSync = func(mcDir, _ string, _ string) error {
		if filepath.Clean(mcDir) == filepath.Clean(filepath.Join(payload, ".minecraft")) {
			t.Fatal("packwiz was pointed at the immutable corpus snapshot")
		}
		syncCalls++
		writeFileForTest(t, filepath.Join(mcDir, "managed-corpus-probe.txt"), currentManifest.Version)
		writeFileForTest(t, filepath.Join(mcDir, "options.txt"), "pack-default")
		stageRoot := filepath.Dir(mcDir)
		writeFileForTest(t, filepath.Join(stageRoot, "mmc-pack.json"),
			fmt.Sprintf(`{"components":[{"uid":"net.minecraftforge","version":%q}]}`, currentManifest.Version))
		return nil
	}

	t.Setenv("INST_DIR", live)
	t.Setenv("NEGATIVEZONE_MANIFEST_URL", server.URL)

	if err := runUpdate(updateCmd, nil); err != nil {
		t.Fatalf("corpus upgrade: %v", err)
	}
	assertFileForTest(t, versionPath, "9999.0.0")
	assertFileForTest(t, filepath.Join(live, ".minecraft", "options.txt"), "synthetic-player-setting")
	assertFileForTest(t, filepath.Join(live, ".minecraft", "managed-corpus-probe.txt"), "9999.0.0")
	if loader, err := os.ReadFile(filepath.Join(live, "mmc-pack.json")); err != nil ||
		!strings.Contains(string(loader), `"version":"9999.0.0"`) {
		t.Fatalf("loader change was not promoted: %q, %v", loader, err)
	}

	if err := runUpdate(updateCmd, nil); err != nil {
		t.Fatalf("repeat update: %v", err)
	}
	if syncCalls != 1 {
		t.Fatalf("repeat update invoked packwiz: calls=%d", syncCalls)
	}

	currentManifest.Version = "0.0.1"
	if err := runUpdate(updateCmd, nil); err != nil {
		t.Fatalf("refused downgrade: %v", err)
	}
	assertFileForTest(t, versionPath, "9999.0.0")
	if syncCalls != 1 {
		t.Fatalf("refused downgrade invoked packwiz: calls=%d", syncCalls)
	}

	currentManifest.AllowDowngrade = true
	if err := runUpdate(updateCmd, nil); err != nil {
		t.Fatalf("allowed rollback/downgrade: %v", err)
	}
	assertFileForTest(t, versionPath, "0.0.1")
	assertFileForTest(t, filepath.Join(live, ".minecraft", "managed-corpus-probe.txt"), "0.0.1")
	if syncCalls != 2 {
		t.Fatalf("allowed downgrade did not invoke packwiz: calls=%d", syncCalls)
	}

	loadAndVerifyCorpus(t, caseDir, payload)
}

func compatibleUpdateManifest(version string) updateManifest {
	return updateManifest{
		Version:    version,
		PackwizURL: "https://example.invalid/pack.toml",
		Compatibility: &compatibility.Metadata{
			Minecraft:          compatibility.MinecraftVersion,
			JavaMajor:          compatibility.JavaMajor,
			ManifestSchema:     compatibility.ManifestSchema,
			PreserveListSchema: compatibility.PreserveListSchema,
			TransactionSchema:  compatibility.TransactionSchema,
		},
	}
}

func serveUpdateManifest(
	t *testing.T,
	manifest *updateManifest,
	preserveJSON string,
) *httptest.Server {
	t.Helper()
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/preserve-list.json" {
			_, _ = fmt.Fprint(w, preserveJSON)
			return
		}
		manifest.PreserveListURL = server.URL + "/preserve-list.json"
		if err := json.NewEncoder(w).Encode(manifest); err != nil {
			t.Errorf("encode manifest: %v", err)
		}
	}))
	return server
}

func loadAndVerifyCorpus(t *testing.T, caseDir, payload string) corpusManifest {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(caseDir, "manifest.json"))
	if err != nil {
		t.Fatalf("read corpus manifest: %v", err)
	}
	var manifest corpusManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatalf("decode corpus manifest: %v", err)
	}
	for _, file := range manifest.Files {
		relative := filepath.FromSlash(file.Path)
		if filepath.IsAbs(relative) || relative == ".." ||
			strings.HasPrefix(relative, ".."+string(os.PathSeparator)) {
			t.Fatalf("manifest path escapes payload: %q", file.Path)
		}
		lower := strings.ToLower(filepath.ToSlash(relative))
		for _, forbidden := range []string{
			"/logs/", "/crash-reports/", "/screenshots/", "/saves/", "/backups/",
			"/.env", "/servers.dat", "/usercache.json", "/usernamecache.json",
			"/options.txt", "/optionsof.txt", "/optionsshaders.txt",
		} {
			if strings.Contains("/"+lower, forbidden) {
				t.Fatalf("personal/runtime path entered corpus: %q", file.Path)
			}
		}
		path := filepath.Join(payload, relative)
		info, err := os.Stat(path)
		if err != nil {
			t.Fatalf("stat corpus file %q: %v", file.Path, err)
		}
		if info.Size() != file.Size {
			t.Fatalf("corpus size mismatch for %q: got %d want %d", file.Path, info.Size(), file.Size)
		}
		contents, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read corpus file %q: %v", file.Path, err)
		}
		sum := sha256.Sum256(contents)
		if got := hex.EncodeToString(sum[:]); got != file.SHA256 {
			t.Fatalf("corpus checksum mismatch for %q", file.Path)
		}
	}
	return manifest
}

func writeFileForTest(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func assertFileForTest(t *testing.T, path, want string) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if string(data) != want {
		t.Fatalf("%s = %q, want %q", path, data, want)
	}
}
