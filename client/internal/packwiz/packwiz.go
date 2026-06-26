package packwiz

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const (
	bootstrapJarName = "packwiz-installer-bootstrap.jar"
	installerJarName = "packwiz-installer.jar"

	bootstrapURL = "https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/v0.0.3/packwiz-installer-bootstrap.jar"
	installerURL = "https://github.com/packwiz/packwiz-installer/releases/download/v0.5.14/packwiz-installer.jar"
)

// Logger is the logging surface used by Sync.
type Logger interface {
	Info(string)
	Warn(string)
	Error(string)
}

// Sync runs packwiz-installer against packTomlURL with mcDir as CWD, side "client".
func Sync(mcDir, nzDir, packTomlURL string, log Logger) error {
	if override := strings.TrimSpace(os.Getenv("NEGATIVEZONE_PACKWIZ_CMD")); override != "" {
		return runOverride(mcDir, override, log)
	}

	java, err := findJava()
	if err != nil {
		return err
	}

	bootstrapJar, err := resolveJar(mcDir, nzDir, bootstrapJarName, bootstrapURL, log)
	if err != nil {
		return err
	}
	installerJar, err := resolveJar(mcDir, nzDir, installerJarName, installerURL, log)
	if err != nil {
		return err
	}

	args := []string{
		"-jar", bootstrapJar,
		"--bootstrap-no-update",
		"--bootstrap-main-jar", installerJar,
		"-g",
		"-s", "client",
		packTomlURL,
	}
	if log != nil {
		log.Info("Running packwiz-installer-bootstrap (--side client)")
	}
	cmd := exec.Command(java, args...)
	cmd.Dir = mcDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("packwiz-installer-bootstrap failed: %w", err)
	}
	return nil
}

func runOverride(mcDir, override string, log Logger) error {
	if log != nil {
		log.Warn("Using NEGATIVEZONE_PACKWIZ_CMD override")
	}
	var cmd *exec.Cmd
	if runtime.GOOS == "windows" {
		cmd = exec.Command("cmd", "/c", override)
	} else {
		cmd = exec.Command("sh", "-c", override)
	}
	cmd.Dir = mcDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("NEGATIVEZONE_PACKWIZ_CMD failed: %w", err)
	}
	return nil
}

func findJava() (string, error) {
	if java, err := exec.LookPath("java"); err == nil {
		return java, nil
	}
	if javaHome := os.Getenv("JAVA_HOME"); javaHome != "" {
		candidate := filepath.Join(javaHome, "bin", "java.exe")
		if runtime.GOOS != "windows" {
			candidate = filepath.Join(javaHome, "bin", "java")
		}
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("Java 17+ required; install Temurin 17")
}

func resolveJar(mcDir, nzDir, name, url string, log Logger) (string, error) {
	bundled := filepath.Join(mcDir, name)
	if fileExists(bundled) {
		if log != nil {
			log.Info("Using bundled " + name)
		}
		return bundled, nil
	}

	if err := os.MkdirAll(nzDir, 0o755); err != nil {
		return "", fmt.Errorf("creating packwiz cache directory: %w", err)
	}
	cached := filepath.Join(nzDir, name)
	if fileExists(cached) {
		if log != nil {
			log.Info("Using cached " + name)
		}
		return cached, nil
	}

	if log != nil {
		log.Info("Downloading " + name)
	}
	if err := downloadFile(url, cached); err != nil {
		return "", fmt.Errorf("downloading %s: %w", name, err)
	}
	return cached, nil
}

func downloadFile(url, dest string) error {
	client := &http.Client{Timeout: 2 * time.Minute}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	out, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, resp.Body); err != nil {
		return err
	}
	return nil
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}
