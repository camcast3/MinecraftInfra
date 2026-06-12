EntityLootDrops Mod Configuration Guide
=======================================

This mod allows you to customize entity drops, block drops, fishing drops, and crafting recipes.

Directory Structure:
-------------------
config/EntityLootDrops/
  ??? Loot Drops/         # Entity loot drop configurations
  ?   ??? Normal Drops/   # Always active drops
  ?   ?   ??? Global_Hostile_Drops.json (AUTO-REGENERATES if deleted)
  ?   ?   ??? Global_Hostile_Drops.example (comprehensive reference)
  ?   ?   ??? Custom_Drops_Example.json
  ?   ?   ??? Mobs/       # Entity-specific drops
  ?   ?       ??? Zombie_Example.json
  ?   ?       ??? Skeleton_Example.json
  ?   ??? Event Drops/    # Event-specific drops
  ?       ??? Winter/     # Winter event drops
  ?       ?   ??? Winter_Event_Drops_Example.json
  ?       ?   ??? Mobs/
  ?       ??? Summer/     # Summer event drops
  ?       ??? Easter/     # Easter event drops
  ?       ??? Halloween/  # Halloween event drops
  ??? Blocks/         # Block drop configurations
  ?   ??? Global_Block_Drops.json
  ?   ??? Block Types/   # Block-specific drops
  ?   ??? Event Drops/    # Event-specific drops
  ??? Fishing/         # Fishing drop configurations
  ?   ??? Global_Fishing_Rewards.json
  ?   ??? Conditional Drops/  # Weather/time-based drops
  ?   ??? Biome Drops/        # Biome-specific drops
  ?   ??? Dimension Drops/    # Dimension-specific drops
  ??? messages.json       # Custom event messages

FILE MANAGEMENT SYSTEM:
======================
ON FIRST LOAD: All example files and directories are created automatically.

EXAMPLE FILES:
- Clean, simple examples for learning
- Safe to delete - will NOT regenerate automatically
- Can be renamed, edited, or replaced with custom files

.example FILES:
- Comprehensive reference files with ALL possible fields
- Use as templates for advanced configurations
- Safe to delete - will NOT regenerate automatically

MAIN CONFIG FILES (Auto-Regenerating):
- Global_Hostile_Drops.json: ONLY this file regenerates if deleted
- Other main config files vary by feature

CUSTOM FILE LOADING:
- ANY .json file in the correct directory will be loaded
- Rename, edit, or create new files freely
- Use /lootdrops reload to apply changes
- No server restart required!

REGENERATE EXAMPLES:
- Delete entire folders (like 'Loot Drops' or 'Mobs') to regenerate examples
- Individual example files will NOT regenerate

Entity Loot Drops:
-----------------
The main feature of this mod. Configure custom drops when entities are killed.

Key Features:
- Global drops for all hostile mobs
- Entity-specific drops
- Event-based seasonal drops
- Command execution on kill/drop
- Advanced conditions (biome, dimension, player requirements)
- Extra drop chances and bonus amounts
- NBT data support for custom items

Commands:
--------
Entity Loot Drops:
  /lootdrops reload - Reload all configurations (loads ANY .json files)
  /lootdrops event <name> <true|false> - Toggle event
  /lootdrops event dropchance <true|false> - Toggle double drop chance
  /lootdrops event doubledrops <true|false> - Toggle double drops
  /lootdrops active_events - List active events
  /lootdrops listall - List all available events
  /lootdrops debug <true|false> - Toggle debug logging

Other Features:
  /blockdrops - Block drop commands
  /recipes - Recipe commands
  /fishingdrops - Fishing drop commands

UNDERSTANDING 'GLOBAL' FILES:
============================
Files with 'Global' in the name apply to ALL entities/blocks/fishing of that type:
- Global_Hostile_Drops.json: ALL hostile mobs
- Global_Block_Drops.json: ALL blocks
- Global_Fishing_Rewards.json: ALL fishing attempts

More specific files (like individual mob files) take priority over global files.

IMPORTANT - HOW TO DISABLE DROPS:
=================================
Many users ask how to disable drops without deleting files.
Here are the methods that work for ALL drop types:

Method 1 - Empty Array (Disables ALL drops in a file):
Replace the entire file content with: []

Method 2 - Set Drop Chance/Chance to 0 (and Command Chance):
- For entity drops: Set "dropChance": 0 AND "commandChance": 0
- For fishing drops: Set "chance": 0
- For block drops: Set "dropChance": 0 AND "commandChance": 0
(This disables both item drops AND command execution)

Method 3 - Set Amounts to 0 (Alternative):
Set "minAmount": 0 and "maxAmount": 0

Method 4 - Rename the file extension:
Change .json to .json.disabled or .json.backup
(File will be ignored but preserved)

WHY NOT DELETE THE MAIN CONFIG FILES?
====================================
- Global_Hostile_Drops.json will regenerate automatically
- You'll lose your custom configurations
- Example files are safe to delete (won't regenerate)
- Use disable methods above instead

Configuration Tips:
------------------
1. Start with Global_Hostile_Drops.json for drops that apply to all hostile mobs
2. Use the Mobs/ folders for entity-specific configurations
3. Create custom .json files to organize your drops by theme
4. Use events for seasonal or temporary drops
5. Test with debug logging enabled: /lootdrops debug true
6. Use /lootdrops reload to apply changes without restarting
7. Reference the .example files for all possible configuration options
8. Rename files to .json.disabled to temporarily disable them
9. Delete entire folders to regenerate example files

Each directory contains its own README file with detailed instructions.
