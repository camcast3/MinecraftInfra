package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// qtUnescapeINIValue is a faithful reimplementation of the subset of Qt's
// QSettings IniFormat string reader that our instance.cfg values exercise:
// outer `"..."` wrapping plus the `\\` and `\"` escape sequences. It exists so
// the test can prove that a value produced by formatQtINIValue round-trips back
// to the exact raw command Prism will hand to the shell — the real failure mode
// is Qt silently eating un-escaped backslashes/quotes (e.g. `\U`, `\c`).
func qtUnescapeINIValue(s string) string {
	var b strings.Builder
	inQuotes := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\\' && i+1 < len(s):
			next := s[i+1]
			switch next {
			case '\\':
				b.WriteByte('\\')
			case '"':
				b.WriteByte('"')
			case 'n':
				b.WriteByte('\n')
			case 'r':
				b.WriteByte('\r')
			case 't':
				b.WriteByte('\t')
			default:
				// Qt drops the backslash for an unrecognised escape and keeps
				// the following char — this is exactly what mangled `\Users`
				// into `sers` before the fix.
				b.WriteByte(next)
			}
			i++
		case c == '"':
			inQuotes = !inQuotes
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}

func TestFormatQtINIValueRoundTrip(t *testing.T) {
	cases := []string{
		`"C:\Users\carlt\AppData\Roaming\PrismLauncher\instances\Craft to Exile 2\.negativezone\nz.exe" backup`,
		`"C:\Users\carlt\AppData\Roaming\PrismLauncher\instances\Craft to Exile 2\.negativezone\nz.exe" check`,
		`"D:\path with spaces\nz.exe" backup`,
	}
	for _, raw := range cases {
		escaped := formatQtINIValue(raw)

		// Must be wrapped in quotes and contain no bare single backslash.
		if !strings.HasPrefix(escaped, `"`) || !strings.HasSuffix(escaped, `"`) {
			t.Errorf("escaped value not wrapped in quotes: %s", escaped)
		}

		// Round-trip through Qt's reader must reproduce the raw command exactly.
		got := qtUnescapeINIValue(escaped)
		if got != raw {
			t.Errorf("round-trip mismatch\n raw: %q\n esc: %q\n got: %q", raw, escaped, got)
		}

		// Escaping must be idempotent in effect: escaping the already-escaped
		// value and unescaping it twice still yields the raw command (models
		// Prism resaving the cfg on every launch).
		got2 := qtUnescapeINIValue(qtUnescapeINIValue(formatQtINIValue(escaped)))
		if got2 != raw {
			t.Errorf("double round-trip mismatch: raw=%q got2=%q", raw, got2)
		}
	}
}

func TestFormatQtINIValueExactCanonicalForm(t *testing.T) {
	raw := `"C:\Users\carlt\.negativezone\nz.exe" backup`
	want := `"\"C:\\Users\\carlt\\.negativezone\\nz.exe\" backup"`
	if got := formatQtINIValue(raw); got != want {
		t.Errorf("formatQtINIValue mismatch\n want: %s\n got:  %s", want, got)
	}
}

func TestConfigurePrismHooksEscapesAndIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "instance.cfg")
	// Seed with pre-existing unrelated keys + a stale mangled hook to prove we
	// overwrite cleanly.
	seed := "[General]\nname=Craft to Exile 2\nPostExitCommand=C:sersarltbroken\n"
	if err := os.WriteFile(cfg, []byte(seed), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	configurePrismHooks(cfg)

	data, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	content := string(data)

	for _, key := range []string{"PreLaunchCommand", "PostExitCommand"} {
		val := cfgValue(t, content, key)
		// Must be Qt-wrapped.
		if !strings.HasPrefix(val, `"`) || !strings.HasSuffix(val, `"`) {
			t.Errorf("%s not Qt-wrapped: %s", key, val)
		}
		// Unescaped command must contain the real nz binary path and end with
		// the right subcommand — never the mangled form.
		cmd := qtUnescapeINIValue(val)
		if strings.Contains(cmd, "sersarlt") {
			t.Errorf("%s still mangled after fix: %s", key, cmd)
		}
		// Robustness: the exe path must use forward slashes so Qt's INI escaper
		// can never eat a path letter. No backslashes should survive.
		if strings.Contains(cmd, `\`) {
			t.Errorf("%s contains a backslash (mangling risk): %s", key, cmd)
		}
		wantBin := filepath.ToSlash(filepath.Join(dir, ".negativezone", nzBinaryName))
		if !strings.Contains(cmd, wantBin) {
			t.Errorf("%s missing real binary path %q: %s", key, wantBin, cmd)
		}
	}
	if !strings.Contains(qtUnescapeINIValue(cfgValue(t, content, "PreLaunchCommand")), " check") {
		t.Errorf("PreLaunchCommand should invoke 'check'")
	}
	if !strings.Contains(qtUnescapeINIValue(cfgValue(t, content, "PostExitCommand")), " backup") {
		t.Errorf("PostExitCommand should invoke 'backup'")
	}
	if !strings.Contains(content, "OverrideCommands=true") {
		t.Errorf("OverrideCommands not set")
	}

	// Re-running must produce byte-identical output (idempotent).
	configurePrismHooks(cfg)
	data2, _ := os.ReadFile(cfg)
	if string(data2) != content {
		t.Errorf("configurePrismHooks not idempotent\n first:\n%s\n second:\n%s", content, string(data2))
	}
}

func cfgValue(t *testing.T, content, key string) string {
	t.Helper()
	for _, line := range strings.Split(content, "\n") {
		if strings.HasPrefix(line, key+"=") {
			return strings.TrimPrefix(line, key+"=")
		}
	}
	t.Fatalf("key %s not found in cfg:\n%s", key, content)
	return ""
}

func TestSetPrismInstanceGroupSkipsAbsentAndWritesNoBOM(t *testing.T) {
	dir := t.TempDir()
	mustMkdir(t, filepath.Join(dir, "Craft to Exile 2"))
	mustMkdir(t, filepath.Join(dir, "Craft to Exile 2.bak"))

	setPrismInstanceGroup(dir, map[string][]string{
		"Latest": {"Craft to Exile 2"},
		"Backup": {"Craft to Exile 2.bak", "Craft to Exile 2 (old)"},
	})

	data := readInstGroupsFile(t, dir)
	if hasUTF8BOM(data) {
		t.Fatalf("instgroups.json has UTF-8 BOM")
	}
	got := unmarshalInstGroups(t, data)
	if got.FormatVersion != "1" {
		t.Fatalf("formatVersion = %q, want 1", got.FormatVersion)
	}
	assertGroupInstances(t, got, "Latest", []string{"Craft to Exile 2"})
	assertGroupInstances(t, got, "Backup", []string{"Craft to Exile 2.bak"})
}

func TestSetPrismInstanceGroupPreservesPlayerGroupsAndReplacesManaged(t *testing.T) {
	dir := t.TempDir()
	mustMkdir(t, filepath.Join(dir, "Craft to Exile 2"))
	mustMkdir(t, filepath.Join(dir, "SomeOtherPack"))

	seed := `{"formatVersion":"1","groups":{"MyStuff":{"hidden":false,"instances":["SomeOtherPack","Craft to Exile 2"]},"Latest":{"hidden":false,"instances":["StaleEntry"]}}}`
	if err := os.WriteFile(filepath.Join(dir, "instgroups.json"), []byte(seed), 0o644); err != nil {
		t.Fatalf("seed instgroups.json: %v", err)
	}

	setPrismInstanceGroup(dir, map[string][]string{
		"Latest": {"Craft to Exile 2"},
	})

	got := unmarshalInstGroups(t, readInstGroupsFile(t, dir))
	assertGroupInstances(t, got, "MyStuff", []string{"SomeOtherPack"})
	assertGroupInstances(t, got, "Latest", []string{"Craft to Exile 2"})

	count := 0
	for _, group := range got.Groups {
		for _, inst := range group.Instances {
			if inst == "Craft to Exile 2" {
				count++
			}
		}
	}
	if count != 1 {
		t.Fatalf("managed instance appears in %d groups, want exactly 1", count)
	}
}

func mustMkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
}

func readInstGroupsFile(t *testing.T, instancesDir string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(instancesDir, "instgroups.json"))
	if err != nil {
		t.Fatalf("read instgroups.json: %v", err)
	}
	return data
}

func unmarshalInstGroups(t *testing.T, data []byte) prismInstGroups {
	t.Helper()
	var got prismInstGroups
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal instgroups.json: %v\n%s", err, data)
	}
	return got
}

func hasUTF8BOM(data []byte) bool {
	return len(data) >= 3 && data[0] == 0xef && data[1] == 0xbb && data[2] == 0xbf
}

func assertGroupInstances(t *testing.T, groups prismInstGroups, groupName string, want []string) {
	t.Helper()
	group, ok := groups.Groups[groupName]
	if !ok {
		t.Fatalf("group %q missing from %#v", groupName, groups.Groups)
	}
	assertStringSlice(t, group.Instances, want)
}

func assertStringSlice(t *testing.T, got, want []string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("instances = %#v, want %#v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("instances = %#v, want %#v", got, want)
		}
	}
}
