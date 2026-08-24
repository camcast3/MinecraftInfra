// Package download provides HTTP download with progress reporting and hash verification.
package download

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"github.com/camcast3/MinecraftInfra/client/internal/ui"
)

// File downloads a URL to a local path, showing a progress bar.
// Returns the SHA-256 hex digest of the downloaded content.
func File(url, dest string, expectedSize int64) (string, error) {
	client := &http.Client{Timeout: 10 * time.Minute}
	resp, err := client.Get(url)
	if err != nil {
		return "", fmt.Errorf("HTTP GET: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d from %s", resp.StatusCode, url)
	}

	size := resp.ContentLength
	if size <= 0 && expectedSize > 0 {
		size = expectedSize
	}

	f, err := os.Create(dest)
	if err != nil {
		return "", fmt.Errorf("creating file: %w", err)
	}
	defer f.Close()

	hasher := sha256.New()
	writer := io.MultiWriter(f, hasher)

	if size > 0 {
		bar := ui.NewProgressBar(size, "Downloading")
		buf := make([]byte, 32*1024)
		var written int64
		for {
			n, err := resp.Body.Read(buf)
			if n > 0 {
				_, wErr := writer.Write(buf[:n])
				if wErr != nil {
					return "", fmt.Errorf("writing: %w", wErr)
				}
				written += int64(n)
				bar.Update(written)
			}
			if err == io.EOF {
				break
			}
			if err != nil {
				return "", fmt.Errorf("reading: %w", err)
			}
		}
		bar.Finish()
	} else {
		spin := ui.NewSpinner("Downloading...")
		spin.Start()
		_, err = io.Copy(writer, resp.Body)
		spin.Stop()
		if err != nil {
			return "", fmt.Errorf("downloading: %w", err)
		}
	}

	return hex.EncodeToString(hasher.Sum(nil)), nil
}

// VerifyHash computes SHA-256 of a file and compares to expected (lowercase hex).
func VerifyHash(path, expected string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return err
	}
	actual := hex.EncodeToString(h.Sum(nil))
	if actual != expected {
		return fmt.Errorf("SHA-256 mismatch: expected %s, got %s", expected, actual)
	}
	return nil
}
