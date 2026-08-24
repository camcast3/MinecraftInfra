// Package transaction provides crash-safe directory replacement for managed
// Minecraft instances.
package transaction

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/camcast3/MinecraftInfra/client/internal/lock"
)

const (
	JournalVersion = 1
	BackupVersion  = 1
)

type Phase string

const (
	phasePreflight      Phase = "preflight"
	phaseBackupComplete Phase = "backup-complete"
	phaseStaging        Phase = "staging"
	phaseStageReady     Phase = "stage-ready"
	phaseLiveMoved      Phase = "live-moved"
	phaseLivePromoted   Phase = "live-promoted"
	phaseCommitted      Phase = "committed"
)

// PreserveRule declaratively copies selected paths from the old live tree into
// the prepared stage. Version makes rule format changes explicit.
type PreserveRule struct {
	Version           int
	SourceSubdir      string
	DestinationSubdir string
	Paths             []string
}

// MigrationHook is an explicitly version-bounded transformation applied to a
// prepared stage before it is validated and promoted.
type MigrationHook struct {
	Name        string
	FromVersion string
	ToVersion   string
	Apply       func(oldLive, stage string) error
}

// Plan describes one atomic replacement.
type Plan struct {
	Name           string
	LiveDir        string
	BackupRoot     string
	RequireLive    bool
	SeedFromLive   bool
	TargetVersion  string
	MarkerRelative string
	SkipIfCurrent  bool
	Preserve       []PreserveRule
	Migrations     []MigrationHook
	Prepare        func(stage string) error
	Validate       func(stage string) error
}

// Result describes the durable artifacts produced by a transaction.
type Result struct {
	ID        string
	BackupDir string
	Changed   bool
}

type journal struct {
	Version       int       `json:"version"`
	ID            string    `json:"id"`
	Name          string    `json:"name"`
	LiveDir       string    `json:"liveDir"`
	StageDir      string    `json:"stageDir"`
	RollbackDir   string    `json:"rollbackDir"`
	BackupDir     string    `json:"backupDir,omitempty"`
	HadLive       bool      `json:"hadLive"`
	TargetVersion string    `json:"targetVersion,omitempty"`
	Phase         Phase     `json:"phase"`
	UpdatedAt     time.Time `json:"updatedAt"`
}

type checksum struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

type backupCompletion struct {
	Version       int        `json:"version"`
	Complete      bool       `json:"complete"`
	Immutable     bool       `json:"immutable"`
	TransactionID string     `json:"transactionId"`
	Source        string     `json:"source"`
	TargetVersion string     `json:"targetVersion,omitempty"`
	CompletedAt   time.Time  `json:"completedAt"`
	TreeSHA256    string     `json:"treeSha256"`
	Files         []checksum `json:"files"`
}

// Ops contains injectable filesystem operations used by failure-path tests.
type Ops struct {
	Rename      func(string, string) error
	RemoveAll   func(string) error
	WriteAtomic func(string, []byte, fs.FileMode) error
	Now         func() time.Time
	NewID       func() string
}

// Engine runs transactions.
type Engine struct {
	Ops Ops
}

// Run recovers any interrupted prior transaction, creates and verifies an
// immutable backup, prepares a sibling stage, and atomically swaps it live.
func (e Engine) Run(plan Plan) (Result, error) {
	ops := e.ops()
	if err := validatePlan(plan); err != nil {
		return Result{}, err
	}

	live, err := filepath.Abs(plan.LiveDir)
	if err != nil {
		return Result{}, fmt.Errorf("resolve live directory: %w", err)
	}
	plan.LiveDir = filepath.Clean(live)
	parent := filepath.Dir(plan.LiveDir)
	base := filepath.Base(plan.LiveDir)
	journalPath := filepath.Join(parent, "."+base+".nz-transaction.json")
	lockPath := filepath.Join(parent, "."+base+".nz-transaction.lock")
	lk, err := lock.Acquire(lockPath, 2*time.Hour)
	if err != nil {
		return Result{}, fmt.Errorf("acquire transaction lock: %w", err)
	}
	if lk == nil {
		return Result{}, fmt.Errorf("another transaction is already running for %s", plan.LiveDir)
	}
	defer lk.Release()

	if err := recoverInterrupted(journalPath, plan.LiveDir, ops); err != nil {
		return Result{}, fmt.Errorf("recover interrupted transaction: %w", err)
	}

	liveInfo, statErr := os.Stat(plan.LiveDir)
	liveExists := statErr == nil
	if statErr != nil && !os.IsNotExist(statErr) {
		return Result{}, fmt.Errorf("inspect live directory: %w", statErr)
	}
	if liveExists && !liveInfo.IsDir() {
		return Result{}, fmt.Errorf("live path is not a directory: %s", plan.LiveDir)
	}
	if plan.RequireLive && !liveExists {
		return Result{}, fmt.Errorf("live directory does not exist: %s", plan.LiveDir)
	}

	if plan.SkipIfCurrent && liveExists && plan.MarkerRelative != "" {
		data, err := os.ReadFile(filepath.Join(plan.LiveDir, filepath.FromSlash(plan.MarkerRelative)))
		if err == nil && strings.TrimSpace(string(data)) == plan.TargetVersion {
			return Result{}, nil
		}
	}

	if err := preflightParent(parent, base, ops); err != nil {
		return Result{}, err
	}

	id := ops.NewID()
	stage := filepath.Join(parent, "."+base+".nz-stage-"+id)
	rollback := filepath.Join(parent, "."+base+".nz-rollback-"+id)
	backupRoot := plan.BackupRoot
	if backupRoot == "" {
		backupRoot = filepath.Join(parent, ".negativezone-backups", base)
	}
	backupRoot, err = filepath.Abs(backupRoot)
	if err != nil {
		return Result{}, fmt.Errorf("resolve backup root: %w", err)
	}
	if pathWithin(backupRoot, plan.LiveDir) {
		return Result{}, fmt.Errorf("backup root must be outside the live directory: %s", backupRoot)
	}
	backupDir := ""
	if liveExists {
		backupDir = filepath.Join(backupRoot, id)
	}

	j := journal{
		Version: JournalVersion, ID: id, Name: plan.Name, LiveDir: plan.LiveDir,
		StageDir: stage, RollbackDir: rollback, BackupDir: backupDir,
		HadLive: liveExists, TargetVersion: plan.TargetVersion, Phase: phasePreflight,
	}
	if err := writeJournal(journalPath, &j, ops); err != nil {
		return Result{}, err
	}

	cleanupBeforeSwap := func(runErr error) (Result, error) {
		removeErr := ops.RemoveAll(stage)
		journalErr := os.Remove(journalPath)
		return Result{ID: id, BackupDir: backupDir}, errors.Join(runErr, removeErr, ignoreNotExist(journalErr))
	}

	if liveExists {
		if err := createBackup(plan.LiveDir, backupDir, id, plan.TargetVersion, ops); err != nil {
			_ = ops.RemoveAll(backupDir)
			return cleanupBeforeSwap(fmt.Errorf("create immutable backup: %w", err))
		}
		j.Phase = phaseBackupComplete
		if err := writeJournal(journalPath, &j, ops); err != nil {
			return cleanupBeforeSwap(err)
		}
	}

	if err := os.Mkdir(stage, 0o755); err != nil {
		return cleanupBeforeSwap(fmt.Errorf("create sibling stage: %w", err))
	}
	j.Phase = phaseStaging
	if err := writeJournal(journalPath, &j, ops); err != nil {
		return cleanupBeforeSwap(err)
	}

	if plan.SeedFromLive && liveExists {
		if _, err := copyTree(plan.LiveDir, stage, true); err != nil {
			return cleanupBeforeSwap(fmt.Errorf("seed stage from live: %w", err))
		}
	}
	if plan.Prepare != nil {
		if err := plan.Prepare(stage); err != nil {
			return cleanupBeforeSwap(fmt.Errorf("prepare stage: %w", err))
		}
	}
	if liveExists {
		for _, rule := range plan.Preserve {
			if err := applyPreserveRule(plan.LiveDir, stage, rule); err != nil {
				return cleanupBeforeSwap(fmt.Errorf("apply preservation rule: %w", err))
			}
		}
	}
	for _, hook := range plan.Migrations {
		if hook.Name == "" || hook.Apply == nil {
			return cleanupBeforeSwap(fmt.Errorf("invalid migration hook"))
		}
		if err := hook.Apply(plan.LiveDir, stage); err != nil {
			return cleanupBeforeSwap(fmt.Errorf("migration %q (%s -> %s): %w",
				hook.Name, hook.FromVersion, hook.ToVersion, err))
		}
	}
	if plan.Validate != nil {
		if err := plan.Validate(stage); err != nil {
			return cleanupBeforeSwap(fmt.Errorf("validate stage: %w", err))
		}
	}
	j.Phase = phaseStageReady
	if err := writeJournal(journalPath, &j, ops); err != nil {
		return cleanupBeforeSwap(err)
	}

	if liveExists {
		if err := ops.Rename(plan.LiveDir, rollback); err != nil {
			return cleanupBeforeSwap(fmt.Errorf("move live to rollback: %w", err))
		}
		j.Phase = phaseLiveMoved
		if err := writeJournal(journalPath, &j, ops); err != nil {
			return Result{ID: id, BackupDir: backupDir}, rollbackIncomplete(journalPath, &j, ops, err)
		}
	}

	if err := ops.Rename(stage, plan.LiveDir); err != nil {
		return Result{ID: id, BackupDir: backupDir}, rollbackIncomplete(
			journalPath, &j, ops, fmt.Errorf("promote stage: %w", err))
	}
	j.Phase = phaseLivePromoted
	if err := writeJournal(journalPath, &j, ops); err != nil {
		return Result{ID: id, BackupDir: backupDir}, rollbackIncomplete(journalPath, &j, ops, err)
	}

	if plan.MarkerRelative != "" {
		marker := filepath.Join(plan.LiveDir, filepath.FromSlash(plan.MarkerRelative))
		if !pathWithin(marker, plan.LiveDir) {
			return Result{ID: id, BackupDir: backupDir}, rollbackIncomplete(
				journalPath, &j, ops, fmt.Errorf("marker escapes live directory"))
		}
		if err := ops.WriteAtomic(marker, []byte(plan.TargetVersion), 0o644); err != nil {
			return Result{ID: id, BackupDir: backupDir}, rollbackIncomplete(
				journalPath, &j, ops, fmt.Errorf("write version marker: %w", err))
		}
	}

	j.Phase = phaseCommitted
	if err := writeJournal(journalPath, &j, ops); err != nil {
		return Result{ID: id, BackupDir: backupDir, Changed: true}, err
	}
	if err := ops.RemoveAll(rollback); err != nil {
		return Result{ID: id, BackupDir: backupDir, Changed: true},
			fmt.Errorf("remove rollback directory: %w", err)
	}
	if err := os.Remove(journalPath); err != nil && !os.IsNotExist(err) {
		return Result{ID: id, BackupDir: backupDir, Changed: true},
			fmt.Errorf("remove transaction journal: %w", err)
	}
	return Result{ID: id, BackupDir: backupDir, Changed: true}, nil
}

func validatePlan(plan Plan) error {
	if strings.TrimSpace(plan.LiveDir) == "" {
		return fmt.Errorf("live directory is required")
	}
	if plan.MarkerRelative != "" {
		if strings.TrimSpace(plan.TargetVersion) == "" {
			return fmt.Errorf("target version is required when a marker is configured")
		}
		if err := validateRelative(plan.MarkerRelative); err != nil {
			return fmt.Errorf("invalid marker path: %w", err)
		}
	}
	for _, rule := range plan.Preserve {
		if rule.Version != 1 {
			return fmt.Errorf("unsupported preservation rule version %d", rule.Version)
		}
		for _, rel := range rule.Paths {
			if err := validateRelative(rel); err != nil {
				return fmt.Errorf("invalid preserved path %q: %w", rel, err)
			}
		}
	}
	return nil
}

func applyPreserveRule(live, stage string, rule PreserveRule) error {
	srcBase := filepath.Join(live, filepath.FromSlash(rule.SourceSubdir))
	dstBase := filepath.Join(stage, filepath.FromSlash(rule.DestinationSubdir))
	if !pathWithin(srcBase, live) || !pathWithin(dstBase, stage) {
		return fmt.Errorf("preservation base escapes transaction tree")
	}
	for _, rel := range rule.Paths {
		src := filepath.Join(srcBase, filepath.FromSlash(rel))
		dst := filepath.Join(dstBase, filepath.FromSlash(rel))
		info, err := os.Lstat(src)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("symbolic links are not supported: %s", src)
		}
		if err := os.RemoveAll(dst); err != nil {
			return err
		}
		if info.IsDir() {
			if _, err := copyTree(src, dst, true); err != nil {
				return err
			}
		} else if _, err := copyFileHashed(src, dst, true); err != nil {
			return err
		}
	}
	return nil
}

func createBackup(live, backupDir, id, targetVersion string, ops Ops) error {
	if _, err := os.Stat(backupDir); err == nil {
		return fmt.Errorf("backup already exists: %s", backupDir)
	} else if !os.IsNotExist(err) {
		return err
	}
	payload := filepath.Join(backupDir, "payload")
	if err := os.MkdirAll(backupDir, 0o755); err != nil {
		return err
	}
	files, err := copyTree(live, payload, false)
	if err != nil {
		return err
	}
	sort.Slice(files, func(i, k int) bool { return files[i].Path < files[k].Path })
	if err := verifyChecksums(payload, files); err != nil {
		return err
	}
	tree := sha256.New()
	for _, file := range files {
		fmt.Fprintf(tree, "%s\x00%d\x00%s\n", file.Path, file.Size, file.SHA256)
	}
	meta := backupCompletion{
		Version: BackupVersion, Complete: true, Immutable: true, TransactionID: id, Source: live,
		TargetVersion: targetVersion, CompletedAt: ops.Now().UTC(),
		TreeSHA256: hex.EncodeToString(tree.Sum(nil)), Files: files,
	}
	data, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return err
	}
	// Completion metadata is deliberately written last.
	if err := ops.WriteAtomic(filepath.Join(backupDir, "complete.json"), data, 0o444); err != nil {
		return err
	}
	return makeReadOnly(backupDir)
}

func verifyChecksums(root string, files []checksum) error {
	for _, want := range files {
		path := filepath.Join(root, filepath.FromSlash(want.Path))
		got, err := hashFile(path)
		if err != nil {
			return fmt.Errorf("verify %s: %w", want.Path, err)
		}
		if got != want.SHA256 {
			return fmt.Errorf("checksum mismatch for %s", want.Path)
		}
	}
	return nil
}

func copyTree(src, dst string, writable bool) ([]checksum, error) {
	info, err := os.Lstat(src)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("source is not a directory: %s", src)
	}
	if err := os.MkdirAll(dst, dirMode(info.Mode(), writable)); err != nil {
		return nil, err
	}
	var files []checksum
	err = filepath.WalkDir(src, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == src {
			return nil
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("symbolic links are not supported: %s", path)
		}
		if entry.IsDir() {
			return os.MkdirAll(target, dirMode(info.Mode(), writable))
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("unsupported file type: %s", path)
		}
		sum, err := copyFileHashed(path, target, writable)
		if err != nil {
			return err
		}
		files = append(files, checksum{
			Path: filepath.ToSlash(rel), Size: info.Size(), SHA256: sum,
		})
		return nil
	})
	return files, err
}

// CopyTree copies a directory without accepting links or special files.
func CopyTree(src, dst string) error {
	_, err := copyTree(src, dst, true)
	return err
}

func copyFileHashed(src, dst string, writable bool) (string, error) {
	in, err := os.Open(src)
	if err != nil {
		return "", err
	}
	defer in.Close()
	info, err := in.Stat()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return "", err
	}
	mode := info.Mode().Perm()
	if writable {
		mode |= 0o200
	}
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return "", err
	}
	h := sha256.New()
	_, copyErr := io.Copy(io.MultiWriter(out, h), in)
	closeErr := out.Close()
	if copyErr != nil {
		return "", copyErr
	}
	if closeErr != nil {
		return "", closeErr
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func hashFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func dirMode(mode fs.FileMode, writable bool) fs.FileMode {
	perm := mode.Perm()
	if writable {
		perm |= 0o700
	}
	return perm
}

func makeReadOnly(root string) error {
	// Windows read-only directory attributes prevent reliable cleanup and do
	// not provide meaningful recursive immutability. There, uniqueness plus
	// completion checksums is the enforceable contract.
	if runtime.GOOS == "windows" {
		return nil
	}
	return filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if !entry.IsDir() {
			info, err := entry.Info()
			if err != nil {
				return err
			}
			return os.Chmod(path, info.Mode().Perm()&^0o222)
		}
		return nil
	})
}

func recoverInterrupted(journalPath, expectedLive string, ops Ops) error {
	data, err := os.ReadFile(journalPath)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var j journal
	if err := json.Unmarshal(data, &j); err != nil {
		return fmt.Errorf("parse journal: %w", err)
	}
	if j.Version != JournalVersion {
		return fmt.Errorf("unsupported journal version %d", j.Version)
	}
	if filepath.Clean(j.LiveDir) != filepath.Clean(expectedLive) {
		return fmt.Errorf("journal live path mismatch")
	}
	if j.Phase == phaseCommitted {
		if err := ops.RemoveAll(j.StageDir); err != nil {
			return err
		}
		if err := ops.RemoveAll(j.RollbackDir); err != nil {
			return err
		}
		return ignoreNotExist(os.Remove(journalPath))
	}
	return rollbackIncomplete(journalPath, &j, ops, nil)
}

func rollbackIncomplete(journalPath string, j *journal, ops Ops, cause error) error {
	rollbackExists := isDir(j.RollbackDir)
	if rollbackExists {
		failed := j.StageDir + "-failed"
		_ = ops.RemoveAll(failed)
		if isDir(j.LiveDir) {
			if err := ops.Rename(j.LiveDir, failed); err != nil {
				return errors.Join(cause, fmt.Errorf("move incomplete live aside: %w", err))
			}
		}
		if err := ops.Rename(j.RollbackDir, j.LiveDir); err != nil {
			if isDir(failed) && !isDir(j.LiveDir) {
				_ = ops.Rename(failed, j.LiveDir)
			}
			return errors.Join(cause, fmt.Errorf("restore rollback: %w", err))
		}
		_ = ops.RemoveAll(failed)
	} else if !j.HadLive && isDir(j.LiveDir) && !isDir(j.StageDir) {
		if err := ops.RemoveAll(j.LiveDir); err != nil {
			return errors.Join(cause, fmt.Errorf("remove incomplete fresh install: %w", err))
		}
	}
	_ = ops.RemoveAll(j.StageDir)
	if err := os.Remove(journalPath); err != nil && !os.IsNotExist(err) {
		return errors.Join(cause, err)
	}
	return cause
}

func writeJournal(path string, j *journal, ops Ops) error {
	j.UpdatedAt = ops.Now().UTC()
	data, err := json.MarshalIndent(j, "", "  ")
	if err != nil {
		return err
	}
	if err := ops.WriteAtomic(path, data, 0o600); err != nil {
		return fmt.Errorf("write transaction journal: %w", err)
	}
	return nil
}

func preflightParent(parent, base string, ops Ops) error {
	info, err := os.Stat(parent)
	if err != nil {
		return fmt.Errorf("transaction parent is unavailable: %w", err)
	}
	if !info.IsDir() {
		return fmt.Errorf("transaction parent is not a directory: %s", parent)
	}
	id := ops.NewID()
	a := filepath.Join(parent, "."+base+".nz-preflight-"+id)
	b := a + "-renamed"
	if err := os.Mkdir(a, 0o700); err != nil {
		return fmt.Errorf("transaction parent is not writable: %w", err)
	}
	defer ops.RemoveAll(a)
	defer ops.RemoveAll(b)
	if err := ops.Rename(a, b); err != nil {
		return fmt.Errorf("sibling atomic rename preflight failed: %w", err)
	}
	return nil
}

func validateRelative(path string) error {
	if strings.TrimSpace(path) == "" {
		return fmt.Errorf("path is empty")
	}
	clean := filepath.Clean(filepath.FromSlash(path))
	if filepath.IsAbs(clean) || clean == "." || clean == ".." ||
		strings.HasPrefix(clean, ".."+string(os.PathSeparator)) {
		return fmt.Errorf("path must be a non-empty relative path")
	}
	return nil
}

func pathWithin(path, root string) bool {
	absPath, err1 := filepath.Abs(path)
	absRoot, err2 := filepath.Abs(root)
	if err1 != nil || err2 != nil {
		return false
	}
	rel, err := filepath.Rel(absRoot, absPath)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator))
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func ignoreNotExist(err error) error {
	if err == nil || os.IsNotExist(err) {
		return nil
	}
	return err
}

func writeAtomic(path string, data []byte, mode fs.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	if err := replaceFile(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func newID() string {
	var random [6]byte
	if _, err := rand.Read(random[:]); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return fmt.Sprintf("%d-%s", time.Now().UTC().UnixNano(), hex.EncodeToString(random[:]))
}

func (e Engine) ops() Ops {
	ops := e.Ops
	if ops.Rename == nil {
		ops.Rename = os.Rename
	}
	if ops.RemoveAll == nil {
		ops.RemoveAll = os.RemoveAll
	}
	if ops.WriteAtomic == nil {
		ops.WriteAtomic = writeAtomic
	}
	if ops.Now == nil {
		ops.Now = time.Now
	}
	if ops.NewID == nil {
		ops.NewID = newID
	}
	return ops
}
