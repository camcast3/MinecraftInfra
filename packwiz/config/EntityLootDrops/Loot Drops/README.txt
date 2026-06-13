Entity Loot Drops Configuration Guide
===================================

This directory contains all entity loot drop configurations.

FILE MANAGEMENT SYSTEM:
======================
ON FIRST LOAD: All example files and directories are created automatically.

AUTO-REGENERATING FILES:
- Global_Hostile_Drops.json: ALWAYS regenerates if deleted (contains your main config)

EXAMPLE FILES:
- Clean, simple examples for learning the basic format
- Safe to delete - will NOT regenerate automatically
- Can be renamed, edited, or replaced with custom files

COMPREHENSIVE REFERENCE:
- Global_Hostile_Drops.example: Complete reference with ALL possible fields
- Use as template for advanced configurations
- Safe to delete - will NOT regenerate automatically

REGENERATE EXAMPLES:
- Delete entire folders (like 'Loot Drops' or 'Mobs') to regenerate examples
- Individual example files will NOT regenerate
- Folder deletion triggers complete example recreation

Directory Structure:
-------------------
Loot Drops/
  ??? Normal Drops/           # Always active drops
  ?   ??? Global_Hostile_Drops.json        # Main config (AUTO-REGENERATES)
  ?   ??? Global_Hostile_Drops.example      # Comprehensive reference
  ?   ??? Mobs/               # Entity-specific drops
  ?       ??? Zombie_Example.json    # Basic examples (safe to delete)
  ?       ??? Skeleton_Example.json  # Basic examples (safe to delete)
  ?       ??? custom_folder/  # ? Nested folders supported!
  ?       ?   ??? your_drops.json
  ?       ??? organized/      # ? Any depth of nesting works
  ?           ??? subfolder/
  ?               ??? special_drops.json
  ??? Event Drops/            # Event-specific drops
      ??? Winter/             # Winter event drops
      ?   ??? Winter_Event_Drops_Example.json  # Basic examples
      ?   ??? Mobs/
      ??? Summer/             # Summer event drops
      ?   ??? Summer_Event_Drops_Example.json
      ?   ??? Mobs/
      ??? Easter/             # Easter event drops
      ?   ??? Easter_Event_Drops_Example.json
      ?   ??? Mobs/
      ??? Halloween/          # Halloween event drops
          ??? Halloween_Event_Drops_Example.json
          ??? Mobs/

Configuration Format:
--------------------
All drop configurations use JSON format.

BASIC FORMAT (used in example files):
- itemId: Item to drop (e.g., "minecraft:diamond")
- dropChance: Percentage chance to drop (0-100)
- minAmount: Minimum amount to drop
- maxAmount: Maximum amount to drop
- requirePlayerKill: If true, only drops when killed by a player

ADVANCED PROPERTIES (see Global_Hostile_Drops.example):
- nbtData: Custom NBT data for the item
- requiredAdvancement: Required advancement for drop
- requiredEffect: Required potion effect for drop
- requiredEquipment: Required equipment for drop
- requiredDimension: Required dimension for drop
- command: Command to execute on drop
- commandChance: Chance for command execution
- _comment: Documentation comment

NESTED FOLDER ORGANIZATION:
==========================
? FEATURE: Organize your Mobs configurations using nested folders!

Examples of valid organization:
- Mobs/vanilla_mobs/zombie_drops.json
- Mobs/modded_mobs/thermal_expansion/machines.json
- Mobs/boss_mobs/twilight_forest/bosses.json
- Mobs/by_biome/desert/desert_mobs.json
- Mobs/by_difficulty/hard/elite_drops.json

Benefits of nested folders:
- Organize drops by mod, biome, difficulty, or any system you prefer
- Keep related configurations together
- Easier to manage large numbers of entity configurations
- Works in both Normal Drops and Event Drops

Example Basic Drop Configuration:
[
  {
    "itemId": "minecraft:diamond",
    "dropChance": 5.0,
    "minAmount": 1,
    "maxAmount": 1,
    "requirePlayerKill": true
  }
]

Example Entity-Specific Drop Configuration:
[
  {
    "entityId": "minecraft:zombie",
    "itemId": "minecraft:emerald",
    "dropChance": 10.0,
    "minAmount": 1,
    "maxAmount": 2,
    "requirePlayerKill": false
  }
]

CUSTOM FILE LOADING:
===================
- ANY .json file in the correct directory will be loaded
- Rename, edit, or create new files freely
- Use /lootdrops reload to apply changes
- No server restart required!

HOW TO DISABLE DROPS:
====================
Option 1 - Empty the file: Replace all content with []
Option 2 - Set drop chances to 0: Change "dropChance": [value] to "dropChance": 0
Option 3 - Rename file extension: Change .json to .json.disabled

DON'T DELETE Global_Hostile_Drops.json - it will just regenerate!
Use the disable methods above instead.

Tips:
----
- Use Global_Hostile_Drops.json for drops that apply to all hostile mobs
- Use Mobs/ folder for entity-specific drops
- Create nested folders in Mobs/ to organize your configurations
- Create custom .json files for organized drop categories
- Event drops only activate when the event is enabled
- Reference Global_Hostile_Drops.example for all possible configuration options
- Use /lootdrops reload to apply changes without restarting
- Delete entire folders to regenerate all example files
- Nested folders are scanned recursively - any .json file will be found
- Folder names don't affect functionality - organize however you prefer
