Event Drops Configuration
========================

This directory contains drops that are only active during specific events.

FILES CREATED ON FIRST LOAD:
============================
Each event folder contains:
- [Event]_Event_Drops_Example.json: Clean basic example (safe to delete)
- Mobs/ folder: For entity-specific event drops

Built-in Events:
- Winter/: Winter season drops
- Summer/: Summer season drops
- Easter/: Easter holiday drops
- Halloween/: Halloween holiday drops

Custom Events:
You can create your own event folders with any name.
Each event folder can contain:
- Custom .json files: Your event-specific drop configurations
- Mobs/: Entity-specific drops during this event
  * ? Supports nested folders for organization!
  * Example: Mobs/event_bosses/special_halloween_boss.json

REGENERATE EVENT EXAMPLES:
=========================
To regenerate examples for a specific event:
1. Delete the entire event folder (e.g., 'Winter/')
2. Use /lootdrops reload or restart the server
3. The event folder and examples will be recreated

Event Management:
Events are controlled through Active_Events.json in the main config directory.
Use the /lootdrops event [name] [on/off] command to toggle events.

Event drops are checked IN ADDITION to normal drops when active.

ADVANCED CONFIGURATION:
======================
For advanced event drop configurations, reference:
- Normal Drops/Global_Hostile_Drops.example for all possible properties
- Event drops use the same JSON format as normal drops
- All advanced features (NBT, commands, conditions) work in events
