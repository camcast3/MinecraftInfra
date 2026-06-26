// Package cmd defines the root CLI command and all subcommands.
package cmd

import (
	"github.com/spf13/cobra"
)

var rootCmd = &cobra.Command{
	Use:   "nz",
	Short: "NegativeZone Minecraft client manager",
	Long: `nz is the NegativeZone Minecraft client CLI.

It handles modpack backups, updates, initial setup, version checks,
and settings migration — all from a single binary.`,
}

func Execute() error {
	return rootCmd.Execute()
}

func init() {
	rootCmd.AddCommand(backupCmd)
	rootCmd.AddCommand(updateCmd)
	rootCmd.AddCommand(setupCmd)
	rootCmd.AddCommand(checkCmd)
	rootCmd.AddCommand(migrateCmd)
}
