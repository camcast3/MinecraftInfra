// nz is the NegativeZone Minecraft client CLI.
//
// Subcommands:
//
//	nz backup   - Snapshot user state (Xaero maps, settings, etc.)
//	nz update   - Auto-update the modpack from the server manifest
//	nz setup    - First-time install / upgrade of the Prism instance
//	nz check    - Pre-launch version gate (blocks stale clients)
//	nz migrate  - Copy settings between instances interactively
package main

import (
	"os"

	"github.com/camcast3/MinecraftInfra/client/cmd/nz/cmd"
)

func main() {
	if err := cmd.Execute(); err != nil {
		os.Exit(1)
	}
}
