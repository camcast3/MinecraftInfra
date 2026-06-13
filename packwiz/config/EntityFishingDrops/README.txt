================================================================================
                        ENTITY FISHING DROPS MOD
                           Complete Guide
================================================================================

OVERVIEW:
This mod allows server administrators to configure custom drops, commands, and
effects that trigger when players catch fish or other fishing items. Perfect
for adding rewards, events, and custom fishing mechanics to your server.

The mod uses a clean JSON format that only includes the fields you actually need,
making configuration files easier to read and maintain.

================================================================================
                            FOLDER STRUCTURE
================================================================================

config/EntityFishingDrops/
??? README.txt (this file)
??? Active_Events.json (tracks enabled events)
??? Normal Drops/
?   ??? Global_Fishing_Drops.json (always active global drops)
?   ??? Global_Fishing_Drops.example (documentation)
?   ??? Custom_Global_File.json (your custom global files)
?   ??? Drops/
?       ??? minecraft_cod.json (item-specific drops)
?       ??? minecraft_salmon.json
??? Event Drops/
    ??? Easter/
    ?   ??? Global_Easter_Drops.json (easter global drops)
    ?   ??? Drops/
    ?       ??? minecraft_salmon.json (easter item drops)
    ??? Winter/
    ??? Summer/
    ??? Halloween/
    ??? Christmas/

================================================================================
                              COMMANDS
================================================================================

/fishingdrops reload
  - Reloads all configuration files
  - Use after making changes to JSON files
  - Requires operator permissions

/fishingdrops event <event_name> <true/false>
  - Enable/disable fishing events
  - Example: /fishingdrops event Winter true
  - Available events: Easter, Winter, Summer, Halloween, Christmas
  - Loads all JSON files from Event Drops/<event_name>/ folder
  - Sends notification to all online players
  - Events persist through server restarts

================================================================================
                         CONFIGURATION FIELDS
================================================================================

The mod uses a clean JSON format - only fields you specify will appear in the
generated JSON files. All fields are optional unless otherwise noted.

CORE FIELDS:
- catchId: What item must be caught to trigger this entry
  - If specified: only triggers when catching this item
  - If omitted: triggers on ANY fishing catch
- itemId: What item to drop
- dropChance: Percentage chance for drop to occur (0-100)
- minAmount: Minimum number of items to drop
- maxAmount: Maximum number of items to drop
- nbtData: Custom NBT data for the dropped item

COMMAND FIELDS:
- command: Command to run on fishing catch (global trigger)
- commandChance: Percentage chance for command to execute (0-100)
- commandCooldown: Cooldown in seconds before command can run again
- dropCommand: Command to run when itemId actually drops
- dropCommandChance: Percentage chance for dropCommand to execute
- dropCommandCooldown: Cooldown in seconds for dropCommand

CONDITION FIELDS:
- requiredDimensions: List of dimensions where this works
  Example: ["minecraft:overworld", "minecraft:nether"]
- requiredBiomes: List of biomes where this works
  Example: ["minecraft:ocean", "minecraft:river"]
- requiredWeather: Weather condition required
  Options: "clear", "rain", "thunder"
- requiredTimeOfDay: Time of day required
  Options: "day", "night"

EXTRA DROP FIELDS:
- extraDropChance: Chance for bonus items (0-100)
- extraAmountMin: Minimum bonus items
- extraAmountMax: Maximum bonus items

OTHER FIELDS:
- comment: Description for your reference (not used by mod)

================================================================================
                           COMMAND PLACEHOLDERS
================================================================================

Use these placeholders in your commands:
- {player} - Player's username
- {x} - Player's X coordinate
- {y} - Player's Y coordinate
- {z} - Player's Z coordinate
- {world} - World/dimension name
- {biome} - Current biome

Examples:
- "give {player} minecraft:diamond 1"
- "tellraw {player} {"text":"You're at {x}, {y}, {z}!","color":"green"}"
- "effect give {player} minecraft:luck 60 1"

================================================================================
                              EXAMPLES
================================================================================

GLOBAL COMMAND ONLY (triggers on any catch):
{
  "command": "effect give {player} minecraft:luck 30 0",
  "commandChance": 10.0,
  "commandCooldown": 300,
  "comment": "10% chance to give luck effect on any fishing catch"
}

GLOBAL DROP (drops on any catch):
{
  "itemId": "minecraft:experience_bottle",
  "dropChance": 5.0,
  "minAmount": 1,
  "maxAmount": 1,
  "dropCommand": "tellraw {player} {"text":"Bonus XP bottle!","color":"green"}",
  "dropCommandChance": 100.0,
  "comment": "5% chance for XP bottle on any fishing catch"
}

ITEM-SPECIFIC DROP (only when catching cod):
{
  "catchId": "minecraft:cod",
  "itemId": "minecraft:gold_nugget",
  "dropChance": 25.0,
  "minAmount": 1,
  "maxAmount": 3,
  "dropCommand": "tellraw {player} {"text":"Gold found in cod!","color":"gold"}",
  "dropCommandChance": 100.0,
  "comment": "25% chance for gold when catching cod"
}

COMBINED GLOBAL + SPECIFIC (global command + specific drop):
{
  "catchId": "minecraft:salmon",
  "command": "effect give {player} minecraft:regeneration 10 0",
  "commandChance": 100.0,
  "commandCooldown": 60,
  "itemId": "minecraft:iron_nugget",
  "dropChance": 15.0,
  "minAmount": 1,
  "maxAmount": 2,
  "dropCommand": "tellraw {player} {"text":"Iron from salmon!","color":"gray"}",
  "dropCommandChance": 100.0,
  "comment": "Always gives regen on any catch, 15% iron when catching salmon"
}

RARE DROP WITH CONDITIONS:
{
  "catchId": "minecraft:salmon",
  "itemId": "minecraft:diamond",
  "dropChance": 5.0,
  "minAmount": 1,
  "maxAmount": 1,
  "nbtData": "{display:{Name:'{"text":"Lucky Diamond","color":"aqua"}'}}",
  "dropCommand": "tellraw @a {"text":"{player} found a Lucky Diamond!","color":"aqua"}",
  "dropCommandChance": 100.0,
  "requiredWeather": "rain",
  "requiredTimeOfDay": "night",
  "comment": "Rare diamond only during rain at night"
}

MODDED ITEM SUPPORT:
{
  "catchId": "minecraft:cod",
  "itemId": "thermal:silver_ingot",
  "dropChance": 15.0,
  "minAmount": 1,
  "maxAmount": 2,
  "comment": "Works with any modded items"
}

CLEAN MINIMAL EXAMPLE (only necessary fields):
{
  "itemId": "minecraft:emerald",
  "dropChance": 2.0,
  "comment": "Simple 2% emerald drop"
}

================================================================================
                            ACTIVE EVENTS
================================================================================

Events allow you to create seasonal or special fishing rewards:

AVAILABLE EVENTS:
- Easter: Spring-themed rewards
- Winter: Cold weather bonuses
- Summer: Warm weather rewards
- Halloween: Spooky seasonal drops
- Christmas: Holiday celebration items

HOW TO USE EVENTS:
1. Create event folder: Event Drops/Halloween/
2. Add JSON files with special drops
3. Enable with: /fishingdrops event Halloween true
4. Event stays active until disabled
5. Active events are saved in Active_Events.json

When events are active:
- Normal Drops are ALWAYS loaded
- Event Drops are ADDED to normal drops
- Players get more rewards during events
- Multiple events can be active simultaneously

================================================================================
                            BEST PRACTICES
================================================================================

ORGANIZATION:
- Use descriptive file names (minecraft_cod.json, rare_drops.json)
- Group related drops in same files
- Use comments to document your configurations
- Keep Global_Fishing_Drops.json for server-wide effects
- Only include fields you actually need (cleaner JSON)

BALANCING:
- Start with low drop chances (1-10%) for rare items
- Use cooldowns on powerful commands
- Test with dropChance: 100.0 during development
- Consider server economy when adding valuable drops

PERFORMANCE:
- Avoid too many complex conditions
- Use reasonable cooldowns on commands
- Don't create hundreds of drop entries
- Group similar drops in single files

PLAYER EXPERIENCE:
- Use tellraw commands to notify players of special drops
- Create themed events for holidays
- Balance rewards with server progression
- Provide variety in drop types and commands

JSON FORMATTING:
- Only include fields you need (mod ignores null/default values)
- Use proper JSON syntax validation
- Keep comments descriptive but concise
- Organize entries logically within files

================================================================================
                           TROUBLESHOOTING
================================================================================

DROPS NOT WORKING:
1. Check server console for error messages
2. Verify JSON syntax (use online JSON validator)
3. Ensure mod is installed and loaded
4. Use /fishingdrops reload after changes
5. Test with dropChance: 100.0 for guaranteed triggers
6. Check that required conditions are met (weather, biome, etc.)

COMMANDS NOT EXECUTING:
1. Check command syntax and permissions
2. Verify placeholder usage ({player}, etc.)
3. Test commands manually in server console
4. Check cooldowns aren't preventing execution
5. Ensure commandChance is set appropriately

MODDED ITEMS NOT WORKING:
1. Verify correct mod:item format (e.g., "thermal:silver_ingot")
2. Check if mod is installed and loaded
3. Use /give command to test item IDs
4. Check mod's documentation for correct item names
5. Ensure mod is loaded before EntityFishingDrops

JSON SYNTAX ERRORS:
1. Use online JSON validator
2. Check for missing commas, quotes, brackets
3. Ensure proper escaping of quotes in NBT data
4. Remove trailing commas from last entries
5. Verify all strings are properly quoted

EVENT ISSUES:
1. Check Active_Events.json for enabled events
2. Verify event folder exists and has JSON files
3. Use /fishingdrops event <name> false then true to reset
4. Check server logs for loading errors
5. Ensure event names match folder names exactly

CLEAN JSON NOT GENERATING:
1. Ensure you're using the latest version
2. Delete existing files to regenerate clean versions
3. Check that only needed fields are being set in code
4. Verify Gson configuration excludes null values

================================================================================
                              SUPPORT
================================================================================

For additional help:
- Check server console logs for detailed error messages
- Test configurations in creative mode for faster iteration
- Start with simple examples and add complexity gradually
- Use /fishingdrops reload frequently during testing
- Backup configurations before making major changes

The mod generates clean, minimal JSON files that only include the fields you
actually use, making them easier to read and maintain.

DEBUGGING TIPS:
- Enable debug logging for detailed information
- Test one configuration at a time
- Use simple drop chances (like 100.0) during testing
- Verify item IDs with /give commands first
- Check that events are properly enabled

Remember: Always backup your configurations before making major changes!

================================================================================
