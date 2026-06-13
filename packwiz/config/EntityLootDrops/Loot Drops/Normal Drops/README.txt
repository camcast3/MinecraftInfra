Normal Drops Configuration
=========================

This directory contains drops that are ALWAYS active.

FILES CREATED ON FIRST LOAD:
============================
- Global_Hostile_Drops.json: Main configuration (AUTO-REGENERATES if deleted)
- Global_Hostile_Drops.example: Comprehensive reference with all properties
- Mobs/Zombie_Example.json: Clean example (safe to delete)
- Mobs/Skeleton_Example.json: Clean example (safe to delete)

FILE BEHAVIOR:
- Global_Hostile_Drops.json: Contains your main configuration, regenerates if deleted
- Example files: Will NOT regenerate if individually deleted
- Custom files: Create any .json file - it will be loaded automatically
- Nested folders: ? Supports any depth of organization in Mobs/

These drops will always be checked when entities are killed,
regardless of any active events.

NESTED FOLDER ORGANIZATION:
==========================
The Mobs/ folder supports nested directories for better organization:

Suggested organization patterns:
- By mod: Mobs/thermal_expansion/machines.json
- By entity type: Mobs/undead/zombie_variants.json
- By biome: Mobs/nether/nether_mobs.json
- By difficulty: Mobs/boss_mobs/raid_bosses.json
- Mixed: Mobs/custom/my_server/special_drops.json

All .json files in any subfolder will be automatically loaded.

REGENERATE ALL EXAMPLES:
=======================
To regenerate all example files:
1. Delete the entire 'Mobs' folder
2. Use /lootdrops reload or restart the server
3. All examples will be recreated

HOW TO DISABLE DROPS:
====================
To disable drops without losing your configuration:

Option 1 - Empty the file:
Replace all content with: []

Option 2 - Set drop chances to 0:
Change "dropChance": [value] to "dropChance": 0

Option 3 - Rename file extension:
Change .json to .json.disabled (file will be ignored)

Remember: Global_Hostile_Drops.json will regenerate if deleted!
Use the methods above instead of deleting the file.
