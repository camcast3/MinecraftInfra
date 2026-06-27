package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestConfigurePrismHooksUsesForwardSlashes guards the regression where
// configurePrismHooks wrote Windows paths with raw backslashes into
// instance.cfg. Prism reads instance.cfg through Qt's INI parser, which treats
// backslash as an escape character, so "\Users\...\nz.exe" gets mangled on read
// (e.g. "\n" becomes a real newline) and the PreLaunchCommand process fails to
// start. The written command must use forward slashes and contain no backslash.
func TestConfigurePrismHooksUsesForwardSlashes(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "instance.cfg")

	configurePrismHooks(cfgPath)

	data, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatalf("read instance.cfg: %v", err)
	}
	content := string(data)

	for _, key := range []string{"PreLaunchCommand", "PostExitCommand"} {
		val := valueForKey(t, content, key)
		if strings.Contains(val, `\`) {
			t.Errorf("%s contains a raw backslash (Qt INI parser will mangle it): %q", key, val)
		}
		if !strings.Contains(val, "/.negativezone/"+nzBinaryName) {
			t.Errorf("%s missing forward-slash nz binary path: %q", key, val)
		}
	}

	if pre := valueForKey(t, content, "PreLaunchCommand"); !strings.HasSuffix(pre, `" check`) {
		t.Errorf("PreLaunchCommand should end with the quoted binary + check: %q", pre)
	}
	if post := valueForKey(t, content, "PostExitCommand"); !strings.HasSuffix(post, `" backup`) {
		t.Errorf("PostExitCommand should end with the quoted binary + backup: %q", post)
	}
	if oc := valueForKey(t, content, "OverrideCommands"); oc != "true" {
		t.Errorf("OverrideCommands = %q, want true", oc)
	}
}

func valueForKey(t *testing.T, content, key string) string {
	t.Helper()
	for _, line := range strings.Split(content, "\n") {
		if strings.HasPrefix(line, key+"=") {
			return strings.TrimPrefix(line, key+"=")
		}
	}
	t.Fatalf("key %q not found in instance.cfg:\n%s", key, content)
	return ""
}
