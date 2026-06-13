// ========= CONFIGURATION ========= //
// Spawn Coords
const SPAWN_COORDS = { x: 1802, y: 66, z: -423 };
const SPAWN_DIMENSION = "minecraft:overworld";

// Mapping of entry devices to their target dimension
const INPUT_DEVICES = {
  "dungeon_realm:map_device": "dungeon_realm:dungeon",
  "the_harvest:harvest": "the_harvest:harvest",
  "ancient_obelisks:obelisk": "ancient_obelisks:obelisk",
  "dungeon_realm:reward_teleport": "dungeon_realm:reward_teleport",
  "dungeon_realm:boss_teleport": "dungeon_realm:boss_teleport",
  "dungeon_realm:uber_teleport": "dungeon_realm:uber_teleport"
};

// All chat messages sent to player:
const MESSAGES = {
  NO_LOCATION:          "§cNo saved location! Sending you to spawn…",
  TELEPORT_TO_SPAWN:    "§aTeleported to spawn!",
  ERROR_TELEPORT_SPAWN: "§cError teleporting to spawn!",
  SAME_DIMENSION:       "§cYou can not return to the same dimension!",
  NO_TAG:               "§cNo tag associated with player!",
  NO_MAP:               "§cYou must be in a map to use this!",
  TELEPORT_SUCCESS:     "§aTeleported you back to your last location!",
  TELEPORT_ERROR:       "§cError teleporting to saved location!",
  DEBUG_SAVE:           "§e[Debug] Saved coords: ",
  DEBUG_PREFIX:         "§e[Debug] Current storage prefix: "
};
// ========== END CONFIGURATION ========= //

// ID of the teleport block
const TELEPORT_BLOCK_ID = "library_of_exile:teleport_back";
// ID of the treasure tp block
const TREASURE_BLOCK_ID = "dungeon_realm:reward_teleport";
// ID of boss tp block
const BOSS_BLOCK_ID = "dungeon_realm:boss_teleport";
// ID of Uber Boss tp block
const U_BOSS_BLOCK_ID = "dungeon_realm:uber_teleport";
// ID of the map tp block
const MAP_BLOCK_ID = "dungeon_realm:map_device";
// Map return item ID
const MAP_RETURN_ITEM = "dungeon_realm:home_pearl";

// Block interaction handler
BlockEvents.rightClicked(event => {
    const player = event.player;
    const block = event.block;
    if (!player || !block) return;

    let storagePrefix = "";

    // Handle teleport block interactions
    if (block.id === TELEPORT_BLOCK_ID) {
        // Check if player has any valid dimension tags
        const hasHarvest = player.tags.contains("Harvest");
        const hasObelisk = player.tags.contains("Obelisk");
        const hasBoss = player.tags.contains("Boss");
        const hasUBoss = player.tags.contains("UBoss");
        const hasTreasure = player.tags.contains("Treasure");

        if (!hasHarvest && !hasObelisk && !hasBoss && !hasTreasure && !hasUBoss) {
            player.tell(MESSAGES.NO_TAG);
            event.cancel();
            return;
        }

        // Get the most recent dimension tag with priority handling
        storagePrefix = ""; // Reset prefix
        if (hasBoss) storagePrefix = "boss";
        if (hasUBoss) storagePrefix = "uboss";
        if (hasTreasure) storagePrefix = "treasure";
        if (hasObelisk) storagePrefix = "obelisk";
        if (hasHarvest) storagePrefix = "harvest";

        // Get saved coordinates for this dimension
        const savedDim = player.persistentData.getString(`${storagePrefix}_dim`);
        const x = player.persistentData.getDouble(`${storagePrefix}_x`);
        const y = player.persistentData.getDouble(`${storagePrefix}_y`);
        const z = player.persistentData.getDouble(`${storagePrefix}_z`);

        // Execute teleport
        const cmdReturn = `execute in ${savedDim} run tp ${player.name.string} ${x} ${y} ${z}`;
        const successReturn = event.server.runCommandSilent(cmdReturn);

        if (successReturn) {
            player.tell(MESSAGES.TELEPORT_SUCCESS);
            // Add teleport effects
            event.server.runCommandSilent(`execute as ${player.name.string} at @s run playsound minecraft:entity.enderman.teleport player @s ~ ~ ~ 1 1`);
            event.server.runCommandSilent(`execute as ${player.name.string} at @s run particle minecraft:portal ~ ~1 ~ 0.5 0.5 0.5 0.1 30`);
            
            // Remove the dimension tag after teleporting
            if (storagePrefix === "treasure") player.tags.remove("Treasure");
            else if (storagePrefix === "boss") player.tags.remove("Boss");
            else if (storagePrefix === "uboss") player.tags.remove("UBoss");
            else if (storagePrefix === "obelisk") player.tags.remove("Obelisk");
            else if (storagePrefix === "harvest") player.tags.remove("Harvest");

            // Clear saved coordinates
            player.persistentData.remove(`${storagePrefix}_dim`);
            player.persistentData.remove(`${storagePrefix}_x`);
            player.persistentData.remove(`${storagePrefix}_y`);
            player.persistentData.remove(`${storagePrefix}_z`);
        } else {
            player.tell(MESSAGES.TELEPORT_ERROR);
        }
        event.cancel();
        return;
    }

    // Handle dimension entry block interactions (store coordinates)
    const targetDimension = INPUT_DEVICES[block.id];
    if (!targetDimension) {
         return;
    };

    // Determine storage prefix based on block type
    // Handle Treasure block
    storagePrefix = ""; // Reset prefix
    
    // Debug the block ID being checked
     console.log(`[Debug] Checking block ID: ${block.id}`);
    
     if (block.id === MAP_BLOCK_ID) {
        // If player has Map tag, treat as return portal
        if (player.tags.contains("Map")) {
            const storagePrefix = "map";
            const savedDim = player.persistentData.getString(`${storagePrefix}_dim`);
            const x = player.persistentData.getDouble(`${storagePrefix}_x`);
            const y = player.persistentData.getDouble(`${storagePrefix}_y`);
            const z = player.persistentData.getDouble(`${storagePrefix}_z`);

            // Execute teleport
            const cmdReturn = `execute in ${savedDim} run tp ${player.name.string} ${x} ${y} ${z}`;
            const successReturn = event.server.runCommandSilent(cmdReturn);

            if (successReturn) {
                player.tell(MESSAGES.TELEPORT_SUCCESS);
                // Add teleport effects
                event.server.runCommandSilent(`execute as ${player.name.string} at @s run playsound minecraft:entity.enderman.teleport player @s ~ ~ ~ 1 1`);
                event.server.runCommandSilent(`execute as ${player.name.string} at @s run particle minecraft:portal ~ ~1 ~ 0.5 0.5 0.5 0.1 30`);
                
                // Remove the Map tag after teleporting
                player.tags.remove("Map");

                // Clear saved coordinates
                player.persistentData.remove(`${storagePrefix}_dim`);
                player.persistentData.remove(`${storagePrefix}_x`);
                player.persistentData.remove(`${storagePrefix}_y`);
                player.persistentData.remove(`${storagePrefix}_z`);
            } else {
                player.tell(MESSAGES.TELEPORT_ERROR);
            }
            event.cancel();
            return;
        }
        // If no Map tag, this is entry point
        storagePrefix = "map";
    }
    if (block.id === TREASURE_BLOCK_ID) {
        storagePrefix = "treasure";
        player.tags.add("Treasure");
    }
    if (block.id === BOSS_BLOCK_ID) {
        storagePrefix = "boss";
        player.tags.add("Boss");
    }
    if (block.id === U_BOSS_BLOCK_ID) {
        storagePrefix = "uboss";
        player.tags.add("UBoss");
    }
    if (block.id.includes("obelisk")) {
        storagePrefix = "obelisk";
    }
    if (block.id.includes("harvest")) {
        storagePrefix = "harvest";
    }

    // Save entry coordinates with additional debug info
    if (storagePrefix) {
        player.persistentData.putDouble(`${storagePrefix}_x`, player.x);
        player.persistentData.putDouble(`${storagePrefix}_y`, player.y);
        player.persistentData.putDouble(`${storagePrefix}_z`, player.z);
        player.persistentData.putString(`${storagePrefix}_dim`, player.level.dimension.toString());
    }
});

// Add this new event handler after the BlockEvents handler
ItemEvents.rightClicked(event => {
    const player = event.player;
    const item = event.item;
    
    if (!player || item.id !== MAP_RETURN_ITEM) return;

    // Check for Map tag
    if (!player.tags.contains("Map")) {
        player.tell(MESSAGES.NO_MAP);
        event.cancel();
        return;
    }

    // Get saved coordinates for Map dimension
    const storagePrefix = "map";
    const savedDim = player.persistentData.getString(`${storagePrefix}_dim`);
    const x = player.persistentData.getDouble(`${storagePrefix}_x`);
    const y = player.persistentData.getDouble(`${storagePrefix}_y`);
    const z = player.persistentData.getDouble(`${storagePrefix}_z`);

    // Execute teleport
    const cmdReturn = `execute in ${savedDim} run tp ${player.name.string} ${x} ${y} ${z}`;
    const successReturn = event.server.runCommandSilent(cmdReturn);

    if (successReturn) {
        player.tell(MESSAGES.TELEPORT_SUCCESS);
        // Add teleport effects
        event.server.runCommandSilent(`execute as ${player.name.string} at @s run playsound minecraft:entity.enderman.teleport player @s ~ ~ ~ 1 1`);
        event.server.runCommandSilent(`execute as ${player.name.string} at @s run particle minecraft:portal ~ ~1 ~ 0.5 0.5 0.5 0.1 30`);
        
        // Remove the Map tag after teleporting
        player.tags.remove("Map");
        item.count--;

        // Clear saved coordinates
        player.persistentData.remove(`${storagePrefix}_dim`);
        player.persistentData.remove(`${storagePrefix}_x`);
        player.persistentData.remove(`${storagePrefix}_y`);
        player.persistentData.remove(`${storagePrefix}_z`);
    } else {
        player.tell(MESSAGES.TELEPORT_ERROR);
    }

    // Cancel the vanilla item behavior
    event.cancel();
});

EntityEvents.death(event => {
    const entity = event.entity;
    if (!entity.isPlayer()) return;
    // Remove all dimension tags on death
    entity.tags.remove("Map");
    entity.tags.remove("Treasure");
    entity.tags.remove("Boss");
    entity.tags.remove("UBoss");
    entity.tags.remove("Obelisk");
    entity.tags.remove("Harvest");
});