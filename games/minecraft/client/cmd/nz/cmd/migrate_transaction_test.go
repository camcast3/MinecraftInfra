package cmd

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRunMigrateUsesAtomicInstanceTransaction(t *testing.T) {
	root := t.TempDir()
	oldInstance := filepath.Join(root, "Old")
	newInstance := filepath.Join(root, "New")
	writeFileForTest(t, filepath.Join(oldInstance, ".minecraft", "options.txt"), "old-settings")
	writeFileForTest(t, filepath.Join(newInstance, ".minecraft", "options.txt"), "new-default")
	writeFileForTest(t, filepath.Join(newInstance, "instance.cfg"), "name=New")

	previousOld, previousNew := migrateOld, migrateNew
	migrateOld, migrateNew = oldInstance, newInstance
	defer func() {
		migrateOld, migrateNew = previousOld, previousNew
	}()

	readEnd, writeEnd, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writeEnd.WriteString("y\n"); err != nil {
		t.Fatal(err)
	}
	_ = writeEnd.Close()
	previousStdin := os.Stdin
	os.Stdin = readEnd
	defer func() {
		os.Stdin = previousStdin
		_ = readEnd.Close()
	}()

	if err := runMigrate(migrateCmd, nil); err != nil {
		t.Fatalf("runMigrate: %v", err)
	}
	assertFileForTest(t, filepath.Join(newInstance, ".minecraft", "options.txt"), "old-settings")
	assertFileForTest(t, filepath.Join(newInstance, "instance.cfg"), "name=New")

	backupRoot := filepath.Join(root, ".negativezone-backups", "New")
	entries, err := os.ReadDir(backupRoot)
	if err != nil || len(entries) != 1 {
		t.Fatalf("expected one off-instance backup, entries=%v err=%v", entries, err)
	}
	assertFileForTest(t,
		filepath.Join(backupRoot, entries[0].Name(), "payload", ".minecraft", "options.txt"),
		"new-default",
	)
}
