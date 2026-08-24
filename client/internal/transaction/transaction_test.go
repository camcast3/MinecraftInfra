package transaction

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestRunBacksUpPreservesAndWritesMarkerLast(t *testing.T) {
	root := t.TempDir()
	live := filepath.Join(root, "instance")
	writeTestFile(t, filepath.Join(live, ".minecraft", "managed.txt"), "old-managed")
	writeTestFile(t, filepath.Join(live, ".minecraft", "options.txt"), "player-setting")
	writeTestFile(t, filepath.Join(live, ".negativezone-version"), "1.0.0")

	markerDuringValidation := ""
	result, err := (Engine{}).Run(Plan{
		Name:           "test-update",
		LiveDir:        live,
		RequireLive:    true,
		SeedFromLive:   true,
		TargetVersion:  "2.0.0",
		MarkerRelative: ".negativezone-version",
		Preserve: []PreserveRule{{
			Version:           1,
			SourceSubdir:      ".minecraft",
			DestinationSubdir: ".minecraft",
			Paths:             []string{"options.txt"},
		}},
		Prepare: func(stage string) error {
			writeTestFile(t, filepath.Join(stage, ".minecraft", "managed.txt"), "new-managed")
			writeTestFile(t, filepath.Join(stage, ".minecraft", "options.txt"), "pack-default")
			return nil
		},
		Validate: func(stage string) error {
			data, err := os.ReadFile(filepath.Join(stage, ".negativezone-version"))
			if err != nil {
				return err
			}
			markerDuringValidation = string(data)
			return nil
		},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if markerDuringValidation != "1.0.0" {
		t.Fatalf("marker changed before validation: %q", markerDuringValidation)
	}
	assertTestFile(t, filepath.Join(live, ".minecraft", "managed.txt"), "new-managed")
	assertTestFile(t, filepath.Join(live, ".minecraft", "options.txt"), "player-setting")
	assertTestFile(t, filepath.Join(live, ".negativezone-version"), "2.0.0")

	data, err := os.ReadFile(filepath.Join(result.BackupDir, "complete.json"))
	if err != nil {
		t.Fatalf("read backup completion: %v", err)
	}
	var completion backupCompletion
	if err := json.Unmarshal(data, &completion); err != nil {
		t.Fatalf("decode backup completion: %v", err)
	}
	if !completion.Complete || !completion.Immutable || len(completion.Files) != 3 {
		t.Fatalf("unexpected completion metadata: %#v", completion)
	}
	assertTestFile(t,
		filepath.Join(result.BackupDir, "payload", ".minecraft", "managed.txt"),
		"old-managed",
	)
	if _, err := os.Stat(filepath.Join(root, ".instance.nz-transaction.json")); !os.IsNotExist(err) {
		t.Fatalf("journal remains after commit: %v", err)
	}
}

func TestRunPrepareFailureLeavesLiveUntouched(t *testing.T) {
	root := t.TempDir()
	live := filepath.Join(root, "instance")
	writeTestFile(t, filepath.Join(live, "state.txt"), "original")

	result, err := (Engine{}).Run(Plan{
		Name:         "prepare-failure",
		LiveDir:      live,
		RequireLive:  true,
		SeedFromLive: true,
		Prepare: func(stage string) error {
			writeTestFile(t, filepath.Join(stage, "state.txt"), "mutated")
			return errors.New("fake process failed")
		},
	})
	if err == nil || !strings.Contains(err.Error(), "fake process failed") {
		t.Fatalf("expected propagated process failure, got %v", err)
	}
	assertTestFile(t, filepath.Join(live, "state.txt"), "original")
	if _, err := os.Stat(filepath.Join(result.BackupDir, "complete.json")); err != nil {
		t.Fatalf("completed backup should remain after failure: %v", err)
	}
}

func TestRunPromotionFailureRollsBack(t *testing.T) {
	root := t.TempDir()
	live := filepath.Join(root, "instance")
	writeTestFile(t, filepath.Join(live, "state.txt"), "original")

	rename := func(src, dst string) error {
		if strings.Contains(filepath.Base(src), ".nz-stage-") && filepath.Clean(dst) == filepath.Clean(live) {
			return errors.New("fake promote failure")
		}
		return os.Rename(src, dst)
	}
	_, err := (Engine{Ops: Ops{Rename: rename}}).Run(Plan{
		Name:         "promotion-failure",
		LiveDir:      live,
		RequireLive:  true,
		SeedFromLive: true,
		Prepare: func(stage string) error {
			return os.WriteFile(filepath.Join(stage, "state.txt"), []byte("new"), 0o644)
		},
	})
	if err == nil || !strings.Contains(err.Error(), "fake promote failure") {
		t.Fatalf("expected promotion failure, got %v", err)
	}
	assertTestFile(t, filepath.Join(live, "state.txt"), "original")
}

func TestRunMarkerFailureRollsBack(t *testing.T) {
	root := t.TempDir()
	live := filepath.Join(root, "instance")
	writeTestFile(t, filepath.Join(live, "state.txt"), "original")
	writeTestFile(t, filepath.Join(live, ".negativezone-version"), "1")

	write := func(path string, data []byte, mode os.FileMode) error {
		if filepath.Base(path) == ".negativezone-version" {
			return errors.New("fake marker failure")
		}
		return writeAtomic(path, data, mode)
	}
	_, err := (Engine{Ops: Ops{WriteAtomic: write}}).Run(Plan{
		Name:           "marker-failure",
		LiveDir:        live,
		RequireLive:    true,
		SeedFromLive:   true,
		TargetVersion:  "2",
		MarkerRelative: ".negativezone-version",
		Prepare: func(stage string) error {
			return os.WriteFile(filepath.Join(stage, "state.txt"), []byte("new"), 0o644)
		},
	})
	if err == nil || !strings.Contains(err.Error(), "fake marker failure") {
		t.Fatalf("expected marker failure, got %v", err)
	}
	assertTestFile(t, filepath.Join(live, "state.txt"), "original")
	assertTestFile(t, filepath.Join(live, ".negativezone-version"), "1")
}

func TestRunRecoversInterruptedPromotionBeforeStarting(t *testing.T) {
	root := t.TempDir()
	live := filepath.Join(root, "instance")
	rollback := filepath.Join(root, ".instance.nz-rollback-crash")
	stage := filepath.Join(root, ".instance.nz-stage-crash")
	writeTestFile(t, filepath.Join(live, "state.txt"), "incomplete-new")
	writeTestFile(t, filepath.Join(rollback, "state.txt"), "original")

	j := journal{
		Version: JournalVersion, ID: "crash", Name: "update", LiveDir: live,
		StageDir: stage, RollbackDir: rollback, HadLive: true,
		Phase: phaseLivePromoted, UpdatedAt: time.Now(),
	}
	data, _ := json.Marshal(j)
	journalPath := filepath.Join(root, ".instance.nz-transaction.json")
	if err := os.WriteFile(journalPath, data, 0o600); err != nil {
		t.Fatal(err)
	}

	_, err := (Engine{}).Run(Plan{
		Name:         "after-recovery",
		LiveDir:      live,
		RequireLive:  true,
		SeedFromLive: true,
		Prepare: func(stage string) error {
			data, readErr := os.ReadFile(filepath.Join(live, "state.txt"))
			if readErr != nil {
				return readErr
			}
			if string(data) != "original" {
				return errors.New("recovery did not restore original live tree")
			}
			return errors.New("stop after recovery")
		},
	})
	if err == nil || !strings.Contains(err.Error(), "stop after recovery") {
		t.Fatalf("unexpected error: %v", err)
	}
	assertTestFile(t, filepath.Join(live, "state.txt"), "original")
}

func TestRunRecoversEveryJournalPhase(t *testing.T) {
	for _, phase := range []Phase{
		phasePreflight,
		phaseBackupComplete,
		phaseStaging,
		phaseStageReady,
		phaseLiveMoved,
		phaseLivePromoted,
		phaseCommitted,
	} {
		t.Run(string(phase), func(t *testing.T) {
			root := t.TempDir()
			live := filepath.Join(root, "instance")
			rollback := filepath.Join(root, ".instance.nz-rollback-crash")
			stage := filepath.Join(root, ".instance.nz-stage-crash")

			switch phase {
			case phaseLiveMoved:
				writeTestFile(t, filepath.Join(rollback, "state.txt"), "original")
				writeTestFile(t, filepath.Join(stage, "state.txt"), "prepared")
			case phaseLivePromoted:
				writeTestFile(t, filepath.Join(live, "state.txt"), "incomplete-new")
				writeTestFile(t, filepath.Join(rollback, "state.txt"), "original")
			case phaseCommitted:
				writeTestFile(t, filepath.Join(live, "state.txt"), "committed")
				writeTestFile(t, filepath.Join(live, ".negativezone-version"), "2")
				writeTestFile(t, filepath.Join(rollback, "state.txt"), "original")
				writeTestFile(t, filepath.Join(stage, "state.txt"), "stale-stage")
			default:
				writeTestFile(t, filepath.Join(live, "state.txt"), "original")
				writeTestFile(t, filepath.Join(stage, "state.txt"), "partial-stage")
			}

			j := journal{
				Version: JournalVersion, ID: "crash", Name: "update", LiveDir: live,
				StageDir: stage, RollbackDir: rollback, HadLive: true,
				Phase: phase, UpdatedAt: time.Now(),
			}
			data, err := json.Marshal(j)
			if err != nil {
				t.Fatal(err)
			}
			journalPath := filepath.Join(root, ".instance.nz-transaction.json")
			if err := os.WriteFile(journalPath, data, 0o600); err != nil {
				t.Fatal(err)
			}

			if phase == phaseCommitted {
				result, err := (Engine{}).Run(Plan{
					Name:           "after-committed-recovery",
					LiveDir:        live,
					RequireLive:    true,
					TargetVersion:  "2",
					MarkerRelative: ".negativezone-version",
					SkipIfCurrent:  true,
				})
				if err != nil {
					t.Fatalf("recover committed transaction: %v", err)
				}
				if result.Changed {
					t.Fatal("committed recovery unexpectedly reran transaction")
				}
				assertTestFile(t, filepath.Join(live, "state.txt"), "committed")
			} else {
				_, err := (Engine{}).Run(Plan{
					Name:         "after-recovery",
					LiveDir:      live,
					RequireLive:  true,
					SeedFromLive: true,
					Prepare: func(string) error {
						assertTestFile(t, filepath.Join(live, "state.txt"), "original")
						return errors.New("stop after recovery")
					},
				})
				if err == nil || !strings.Contains(err.Error(), "stop after recovery") {
					t.Fatalf("unexpected recovery result: %v", err)
				}
			}

			if _, err := os.Stat(journalPath); !os.IsNotExist(err) {
				t.Fatalf("journal remains after recovery: %v", err)
			}
			if _, err := os.Stat(rollback); !os.IsNotExist(err) {
				t.Fatalf("rollback remains after recovery: %v", err)
			}
			if _, err := os.Stat(stage); !os.IsNotExist(err) {
				t.Fatalf("stale stage remains after recovery: %v", err)
			}
		})
	}
}

func TestRunRejectsCorruptRecoveryJournal(t *testing.T) {
	root := t.TempDir()
	live := filepath.Join(root, "instance")
	writeTestFile(t, filepath.Join(live, "state.txt"), "original")
	journalPath := filepath.Join(root, ".instance.nz-transaction.json")
	if err := os.WriteFile(journalPath, []byte(`{"version":1,"phase":`), 0o600); err != nil {
		t.Fatal(err)
	}

	_, err := (Engine{}).Run(Plan{LiveDir: live, RequireLive: true})
	if err == nil || !strings.Contains(err.Error(), "parse journal") {
		t.Fatalf("expected corrupt journal rejection, got %v", err)
	}
	assertTestFile(t, filepath.Join(live, "state.txt"), "original")
}

func TestRunDiskFullAndPermissionFailuresLeaveLiveUntouched(t *testing.T) {
	tests := []struct {
		name    string
		ops     Ops
		wantErr error
	}{
		{
			name: "initial journal disk full",
			ops: Ops{WriteAtomic: func(string, []byte, fs.FileMode) error {
				return syscall.ENOSPC
			}},
			wantErr: syscall.ENOSPC,
		},
		{
			name: "backup completion disk full",
			ops: Ops{WriteAtomic: func(path string, data []byte, mode fs.FileMode) error {
				if filepath.Base(path) == "complete.json" {
					return syscall.ENOSPC
				}
				return writeAtomic(path, data, mode)
			}},
			wantErr: syscall.ENOSPC,
		},
		{
			name: "live rename permission denied",
			ops: Ops{Rename: func(src, dst string) error {
				if filepath.Base(src) == "instance" && strings.Contains(filepath.Base(dst), ".nz-rollback-") {
					return fs.ErrPermission
				}
				return os.Rename(src, dst)
			}},
			wantErr: fs.ErrPermission,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			live := filepath.Join(root, "instance")
			writeTestFile(t, filepath.Join(live, "state.txt"), "original")

			_, err := (Engine{Ops: tc.ops}).Run(Plan{
				Name:         "injected-failure",
				LiveDir:      live,
				RequireLive:  true,
				SeedFromLive: true,
				Prepare: func(stage string) error {
					return os.WriteFile(filepath.Join(stage, "state.txt"), []byte("new"), 0o644)
				},
			})
			if err == nil || !errors.Is(err, tc.wantErr) {
				t.Fatalf("expected %v failure, got %v", tc.wantErr, err)
			}
			assertTestFile(t, filepath.Join(live, "state.txt"), "original")
		})
	}
}

func TestRunSupportsUnicodeAndLongPaths(t *testing.T) {
	root := t.TempDir()
	longPart := strings.Repeat("長", 18)
	live := filepath.Join(root, "インスタンス", longPart, longPart, longPart, longPart, "世界")
	writeTestFile(t, filepath.Join(live, "データ", "状態.txt"), "古い")

	_, err := (Engine{}).Run(Plan{
		Name:         "unicode-long-path",
		LiveDir:      live,
		RequireLive:  true,
		SeedFromLive: true,
		Prepare: func(stage string) error {
			return os.WriteFile(filepath.Join(stage, "データ", "状態.txt"), []byte("新しい"), 0o644)
		},
	})
	if err != nil {
		t.Fatalf("unicode/long path transaction: %v", err)
	}
	assertTestFile(t, filepath.Join(live, "データ", "状態.txt"), "新しい")
}

func TestRunRejectsReparseOrSymbolicLinks(t *testing.T) {
	root := t.TempDir()
	live := filepath.Join(root, "instance")
	external := filepath.Join(root, "external")
	writeTestFile(t, filepath.Join(live, "state.txt"), "original")
	writeTestFile(t, filepath.Join(external, "outside.txt"), "outside")
	if err := os.Symlink(external, filepath.Join(live, "linked")); err != nil {
		t.Skipf("symbolic links unavailable on this host: %v", err)
	}

	_, err := (Engine{}).Run(Plan{
		Name:         "reject-link",
		LiveDir:      live,
		RequireLive:  true,
		SeedFromLive: true,
	})
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "symbolic links") {
		t.Fatalf("expected link rejection, got %v", err)
	}
	assertTestFile(t, filepath.Join(external, "outside.txt"), "outside")
}

func TestRunSkipsCurrentVersionWithoutRewrite(t *testing.T) {
	root := t.TempDir()
	live := filepath.Join(root, "instance")
	writeTestFile(t, filepath.Join(live, ".negativezone-version"), "2")
	called := false

	result, err := (Engine{}).Run(Plan{
		Name:           "idempotent",
		LiveDir:        live,
		RequireLive:    true,
		TargetVersion:  "2",
		MarkerRelative: ".negativezone-version",
		SkipIfCurrent:  true,
		Prepare: func(string) error {
			called = true
			return nil
		},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Changed || called {
		t.Fatalf("current-version transaction unexpectedly rewrote live data")
	}
}

func TestRunRejectsEscapingPreservePath(t *testing.T) {
	_, err := (Engine{}).Run(Plan{
		LiveDir: t.TempDir(),
		Preserve: []PreserveRule{{
			Version: 1,
			Paths:   []string{"../outside"},
		}},
	})
	if err == nil || !strings.Contains(err.Error(), "invalid preserved path") {
		t.Fatalf("expected strict preflight failure, got %v", err)
	}
}

func writeTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func assertTestFile(t *testing.T, path, want string) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if string(data) != want {
		t.Fatalf("%s = %q, want %q", path, data, want)
	}
}
