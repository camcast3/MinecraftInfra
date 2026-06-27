// Package cmd defines the root CLI command and all subcommands.
package cmd

import (
	"fmt"
	"os"
	"strings"

	"github.com/camcast3/MinecraftInfra/client/internal/logging"
	"github.com/spf13/cobra"
)

// version is the nz binary version, overridable at build time via:
//
//	-ldflags "-X github.com/camcast3/MinecraftInfra/client/cmd/nz/cmd.version=<sha>"
var version = "dev"

var (
	flagVerbose bool
	flagQuiet   bool
	flagLogFile string
)

var rootCmd = &cobra.Command{
	Use:     "nz",
	Version: version,
	Short:   "NegativeZone Minecraft client manager",
	Long: `nz is the NegativeZone Minecraft client CLI.

It handles modpack backups, updates, initial setup, version checks,
and settings migration — all from a single binary.

Global flags:
  -v, --verbose    Show DEBUG detail on the console (nz.log always has it)
  -q, --quiet      Only show errors on the console
      --log-file   Write the log to an explicit path instead of nz.log`,
	SilenceUsage:  true,
	SilenceErrors: true,
	PersistentPreRun: func(cmd *cobra.Command, args []string) {
		level := logging.LevelInfo
		if flagVerbose {
			level = logging.LevelDebug
		} else if flagQuiet {
			level = logging.LevelError
		}
		logging.Init(
			level,
			flagLogFile,
			"nz "+version,
			"command: "+strings.TrimSpace(strings.Join(os.Args[1:], " ")),
			fmt.Sprintf("pid: %d", os.Getpid()),
		)
	},
}

// Execute runs the root command, ensuring the logger is flushed/closed on any
// return path (normal or error). Note: subcommands that call os.Exit bypass
// this, but by then all post-attach lines have already been written to nz.log.
func Execute() error {
	defer logging.Close()
	return rootCmd.Execute()
}

func init() {
	rootCmd.PersistentFlags().BoolVarP(&flagVerbose, "verbose", "v", false, "Show DEBUG detail on the console")
	rootCmd.PersistentFlags().BoolVarP(&flagQuiet, "quiet", "q", false, "Only show errors on the console")
	rootCmd.PersistentFlags().StringVar(&flagLogFile, "log-file", "", "Write the log to an explicit path")

	rootCmd.AddCommand(backupCmd)
	rootCmd.AddCommand(updateCmd)
	rootCmd.AddCommand(setupCmd)
	rootCmd.AddCommand(checkCmd)
	rootCmd.AddCommand(migrateCmd)
	rootCmd.AddCommand(supportCmd)
}
