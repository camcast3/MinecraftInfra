package compatibility

import "fmt"

const (
	ManifestSchema     = 1
	PreserveListSchema = 1
	TransactionSchema  = 1
	MinecraftVersion   = "1.20.1"
	JavaMajor          = 17
	LegacyVersion      = "0.4.2"
)

// Metadata describes the client/runtime contract attached to a modpack
// release manifest.
type Metadata struct {
	Minecraft          string `json:"minecraft"`
	JavaMajor          int    `json:"javaMajor"`
	ManifestSchema     int    `json:"manifestSchema"`
	PreserveListSchema int    `json:"preserveListSchema"`
	TransactionSchema  int    `json:"transactionSchema"`
}

func Validate(version string, metadata *Metadata) error {
	if metadata == nil {
		if version == LegacyVersion {
			return nil
		}
		return fmt.Errorf("release %q is missing compatibility metadata", version)
	}
	if metadata.Minecraft != MinecraftVersion {
		return fmt.Errorf("unsupported Minecraft version %q", metadata.Minecraft)
	}
	if metadata.JavaMajor != JavaMajor {
		return fmt.Errorf("unsupported Java major %d", metadata.JavaMajor)
	}
	if metadata.ManifestSchema != ManifestSchema {
		return fmt.Errorf("unsupported manifest schema %d", metadata.ManifestSchema)
	}
	if metadata.PreserveListSchema != PreserveListSchema {
		return fmt.Errorf("unsupported preserve-list schema %d", metadata.PreserveListSchema)
	}
	if metadata.TransactionSchema != TransactionSchema {
		return fmt.Errorf("unsupported transaction schema %d", metadata.TransactionSchema)
	}
	return nil
}
