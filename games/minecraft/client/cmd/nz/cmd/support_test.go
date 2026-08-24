package cmd

import (
	"archive/zip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteSupportZip(t *testing.T) {
	dir := t.TempDir()
	srcA := filepath.Join(dir, "a.log")
	if err := os.WriteFile(srcA, []byte("log-a-content"), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	out := filepath.Join(dir, "bundle", "nz-support.zip")

	files := map[string]string{
		"nz.log":  srcA,
		"missing": filepath.Join(dir, "does-not-exist"), // skipped, best-effort
	}
	if err := writeSupportZip(out, "summary-body", files); err != nil {
		t.Fatalf("writeSupportZip: %v", err)
	}

	r, err := zip.OpenReader(out)
	if err != nil {
		t.Fatalf("open zip: %v", err)
	}
	defer r.Close()

	names := map[string]string{}
	for _, f := range r.File {
		rc, _ := f.Open()
		data := make([]byte, f.UncompressedSize64)
		_, _ = rc.Read(data)
		rc.Close()
		names[f.Name] = string(data)
	}

	if _, ok := names["summary.txt"]; !ok {
		t.Errorf("zip missing summary.txt; entries: %v", names)
	}
	if names["summary.txt"] != "summary-body" {
		t.Errorf("summary.txt = %q, want %q", names["summary.txt"], "summary-body")
	}
	if names["nz.log"] != "log-a-content" {
		t.Errorf("nz.log = %q, want %q", names["nz.log"], "log-a-content")
	}
	if _, ok := names["missing"]; ok {
		t.Errorf("missing source should have been skipped, but was included")
	}
}

func TestBuildSupportSummary(t *testing.T) {
	items := []supportItem{{name: "nz.log", path: `C:\x\nz.log`}}
	got := buildSupportSummary("", items)
	for _, want := range []string{"NegativeZone support bundle", "nz version:", "os/arch:", "nz.log"} {
		if !strings.Contains(got, want) {
			t.Errorf("summary missing %q; got:\n%s", want, got)
		}
	}
}
