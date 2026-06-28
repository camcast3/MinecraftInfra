package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestConfigurePrismHooksQtSafe guards the regression where configurePrismHooks
// wrote Windows paths with raw backslashes AND bare quotes into instance.cfg.
// Prism reads/writes instance.cfg through Qt's INI parser, which (1) treats
// backslash as an escape character and (2) eats the closing-quote + space of an
// unwrapped `"..."` run on its first round-trip rewrite — gluing the subcommand
// onto the binary path (e.g. `nz.execheck`) and breaking the hook. The written
// value must use forward slashes, contain no raw backslash, and be wrapped in
// the canonical Qt escaped form (`"\"<path>\" check"`) so it survives Qt's
// round-trip unchanged.
func TestConfigurePrismHooksQtSafe(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "instance.cfg")

	configurePrismHooks(cfgPath)

	data, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatalf("read instance.cfg: %v", err)
	}
	content := string(data)

	cases := map[string]string{
		"PreLaunchCommand": "check",
		"PostExitCommand":  "backup",
	}
	for key, sub := range cases {
		val := valueForKey(t, content, key)

		// No raw Windows backslash in the value: the only backslashes allowed are
		// Qt escape sequences (\" or \\). Strip those, then assert none remain.
		stripped := strings.ReplaceAll(strings.ReplaceAll(val, `\\`, ""), `\"`, "")
		if strings.Contains(stripped, `\`) {
			t.Errorf("%s contains a raw (non-escape) backslash: %q", key, val)
		}
		if !strings.Contains(val, "/.negativezone/"+nzBinaryName) {
			t.Errorf("%s missing forward-slash nz binary path: %q", key, val)
		}
		// Canonical Qt form: whole value wrapped in quotes, inner quotes escaped.
		if !strings.HasPrefix(val, `"`) || !strings.HasSuffix(val, `"`) {
			t.Errorf("%s not wrapped in Qt quotes: %q", key, val)
		}
		if !strings.Contains(val, `\"`) {
			t.Errorf("%s inner quotes not escaped as \\\": %q", key, val)
		}
		// After Qt unescaping, the command must be `"<path>" <sub>` so that
		// Prism's QProcess::splitCommand parses program + argument correctly.
		unescaped := qtUnescape(val)
		if !strings.HasSuffix(unescaped, `" `+sub) {
			t.Errorf("%s unescaped to %q, want it to end with %q", key, unescaped, `" `+sub)
		}
	}

	if oc := valueForKey(t, content, "OverrideCommands"); oc != "true" {
		t.Errorf("OverrideCommands = %q, want true", oc)
	}
	if oja := valueForKey(t, content, "OverrideJavaArgs"); oja != "true" {
		t.Errorf("OverrideJavaArgs = %q, want true", oja)
	}

	jvm := valueForKey(t, content, "JvmArgs")
	if jvm != c2e2JvmArgs {
		t.Errorf("JvmArgs = %q, want the C2E2 flag string", jvm)
	}
	for _, flag := range []string{"-XX:+UseG1GC", "-XX:+UnlockExperimentalVMOptions", "-XX:+UseLargePages"} {
		if !strings.Contains(jvm, flag) {
			t.Errorf("JvmArgs missing expected flag %q", flag)
		}
	}
	// JvmArgs has no special chars, so it must be stored verbatim (no quote wrap).
	if strings.HasPrefix(jvm, `"`) {
		t.Errorf("JvmArgs should be stored unwrapped, got %q", jvm)
	}
}

// TestFormatQtINIValueRoundTrip verifies the escape is idempotent under Qt's
// unescape: encode -> unescape returns the original string.
func TestFormatQtINIValueRoundTrip(t *testing.T) {
	for _, in := range []string{
		`"C:/Users/me/Craft to Exile 2/.negativezone/nz.exe" check`,
		`plain value`,
		`back\slash and "quote"`,
	} {
		got := qtUnescape(formatQtINIValue(in))
		if got != in {
			t.Errorf("round-trip failed: in=%q encoded=%q unescaped=%q", in, formatQtINIValue(in), got)
		}
	}
}

// qtUnescape is a minimal model of Qt's QSettings IniFormat value reader,
// sufficient to validate our escaping: strips one layer of outer quotes and
// turns `\\` -> `\`, `\"` -> `"`.
func qtUnescape(v string) string {
	if len(v) >= 2 && strings.HasPrefix(v, `"`) && strings.HasSuffix(v, `"`) {
		v = v[1 : len(v)-1]
	}
	var b strings.Builder
	for i := 0; i < len(v); i++ {
		if v[i] == '\\' && i+1 < len(v) {
			i++
			b.WriteByte(v[i])
			continue
		}
		b.WriteByte(v[i])
	}
	return b.String()
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
