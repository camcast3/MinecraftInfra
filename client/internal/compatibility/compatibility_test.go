package compatibility

import (
	"strings"
	"testing"
)

func TestValidate(t *testing.T) {
	if err := Validate(LegacyVersion, nil); err != nil {
		t.Fatalf("legacy manifest rejected: %v", err)
	}
	if err := Validate("0.4.3", nil); err == nil ||
		!strings.Contains(err.Error(), "missing compatibility metadata") {
		t.Fatalf("modern manifest without metadata accepted: %v", err)
	}
	valid := &Metadata{
		Minecraft:          MinecraftVersion,
		JavaMajor:          JavaMajor,
		ManifestSchema:     ManifestSchema,
		PreserveListSchema: PreserveListSchema,
		TransactionSchema:  TransactionSchema,
	}
	if err := Validate("1.0.0", valid); err != nil {
		t.Fatalf("valid metadata rejected: %v", err)
	}
	invalid := *valid
	invalid.TransactionSchema++
	if err := Validate("1.0.0", &invalid); err == nil {
		t.Fatal("unsupported transaction schema accepted")
	}
}
