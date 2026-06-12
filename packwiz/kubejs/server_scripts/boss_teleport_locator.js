// CONFIGURATION
// This script allows players to find a boss teleport block and use a special item to teleport to
const TELEPORT_ITEM_ID = "minecraft:amethyst_shard";

function findSafeTeleportLocation(level, centerX, centerY, centerZ, radius) {
    // Search in expanding rings around the boss block
    for (let r = 1; r <= radius; r++) {
        for (let dx = -r; dx <= r; dx++) {
            for (let dz = -r; dz <= r; dz++) {
                // Only check the outer ring of this radius
                if (Math.abs(dx) !== r && Math.abs(dz) !== r) continue;
                
                let x = Math.floor(centerX) + dx;
                let z = Math.floor(centerZ) + dz;
                
                // Check multiple Y levels around the boss block
                for (let yOffset = -1; yOffset <= 3; yOffset++) {
                    let y = Math.floor(centerY) + yOffset;
                    
                    if (isSafeTeleportSpot(level, x, y, z)) {
                        return { x: x, y: y, z: z };
                    }
                }
            }
        }
    }
    return null;
}

function isSafeTeleportSpot(level, x, y, z) {
    let floorBlock = level.getBlock(x, y - 1, z);
    let standBlock = level.getBlock(x, y, z);
    let headBlock = level.getBlock(x, y + 1, z);
    
    if (!floorBlock || !standBlock || !headBlock) return false;
    
    // Need solid floor, clear space to stand and for head
    let floorSolid = floorBlock.id !== "minecraft:air" && 
                     floorBlock.id !== "minecraft:lava" && 
                     floorBlock.id !== "minecraft:water";
    let standClear = standBlock.id === "minecraft:air";
    let headClear = headBlock.id === "minecraft:air";
    
    return floorSolid && standClear && headClear;
}

let playerBossCoords = {};

// Search for boss block when right-clicking grass
PlayerEvents.advancement(event => {
    const player = event.player;
    const advancement = event.advancement;
    
    if (advancement.toString() === 'harvest_fix:quests/telefix/map_port') {
        try {
            
            let radius = 128; // Search radius in blocks
            let baseY = Math.floor(player.y);
            let found = false;
            let playerUUID = player.uuid.toString();

            for (let dx = -radius; dx <= radius; dx++) {
                for (let dz = -radius; dz <= radius; dz++) {
                    if (dx*dx + dz*dz > radius*radius) continue;

                    let x = Math.floor(player.x) + dx;
                    let z = Math.floor(player.z) + dz;
                    
                    for (let dy = -10; dy <= 10; dy++) {
                    let y = baseY + dy;
    
                    let level = player.level;
                    if (!level) continue;

                    let bossBlock = level.getBlock(x, y, z);
                    if (!bossBlock || bossBlock.id === "minecraft:air") continue;

                    if (bossBlock.id === BOSS_BLOCK_ID) {
                        playerBossCoords[playerUUID] = { x: x, y: y, z: z };
                        // Debug for checking if boss teleporter is found
                        // <-- Remove "//" player.tell(`§aBoss teleport location found at (${x}, ${y}, ${z})!`);
    
                        // Give the player the Boss Teleporter Item
                        let bossTP = Item.of(TELEPORT_ITEM_ID, {
                            display: {
                                Name: '{"text":"Boss Soul Stone","color":"green"}',
                                Lore: ['{"text":"Takes you and nearby allies to","color":"gray","italic":true}','{"text":"the location of the Boss’s Teleporter.","color":"gray","italic":true}']
                            },
                            teleport: true
                        });
    
                        player.give(bossTP);
                        player.tell("§aYou received a Boss Soul Stone!");
    
                        found = true;
                        break;
                    }
                }
                if (found) break;
            }
            if (found) break;
        }

            if (!found) {
                player.tell("§cBoss block not found within 64 blocks! Contact modpack developer to increase search radius.");
            }
        } catch (e) {
            player.tell(`§cBoss search error: ${e.toString()}`);
        }
    }
});

// Teleport item handler
ItemEvents.rightClicked(event => {
    const player = event.player;
    const item = event.item;
    
    try {
        
        // Basic item check
        if (item.id !== TELEPORT_ITEM_ID) {
            return;
        }

        // NBT check
        if (!item.nbt?.teleport) {
            return;
        }

        let playerUUID = player.uuid.toString();
        let bossTeleportCoords = playerBossCoords[playerUUID];

        // Location check
        if (!bossTeleportCoords) {
           player.tell("§cNo boss teleport location saved! Leave Map and reenter.");
           return;
        }

        let targetX = bossTeleportCoords.x;
        let targetY = bossTeleportCoords.y;
        let targetZ = bossTeleportCoords.z;
        
        // Get nearby players
        let nearbyPlayers = player.level.getPlayers().filter(p => {
            const dx = p.x - player.x;
            const dy = p.y - player.y;
            const dz = p.z - player.z;
            const distanceSquared = dx*dx + dy*dy + dz*dz;
            return distanceSquared <= 100;
        });

        if (nearbyPlayers.length === 0) {
            player.tell("§cNo players found within 10 blocks!");
            return;
        }

        let teleportedCount = 0;
        
        nearbyPlayers.forEach(nearbyPlayer => {
    
            // Find a safe location around the boss block
            let safeLocation = findSafeTeleportLocation(player.level, targetX, targetY, targetZ, 8);
    
            if (safeLocation) {
                try {
                let dimensionId = player.level.dimension.toString();
                let command = `execute in ${dimensionId} run tp ${nearbyPlayer.name.string} ${safeLocation.x} ${safeLocation.y} ${safeLocation.z}`;
            
                Utils.server.runCommandSilent(command);
                nearbyPlayer.tell("§aTeleported to boss location!");
                teleportedCount++;
            } catch (teleportError) {
                player.tell(`§cTeleport failed for ${nearbyPlayer.name.string}: ${teleportError}`);
            }
        } else {
            nearbyPlayer.tell("§cNo safe teleport location found near boss teleporter!");
        }
    });
        
        
        if (teleportedCount > 0) {
            item.count -= 1;
        }

        event.cancel();
        
    } catch (e) {
        console.error(e.toString());
    }
});

PlayerEvents.tick(event => {
    const player = event.player;
    
    // Only check every 20 ticks (1 second) to avoid performance issues
    if (event.server.tickCount % 100 !== 0) return;
    
    // Check if player has the "Map" tag
    if (!player.tags.contains("Map")) {

        let playerUUID = player.uuid.toString();
        
        // Clear coordinates when leaving map
        if (playerBossCoords[playerUUID]) {
            delete playerBossCoords[playerUUID];
        }

        // Find and remove boss teleporter tomes from inventory
        player.inventory.getAllItems().forEach(item => {
            if (item.id === TELEPORT_ITEM_ID && item.nbt?.teleport) {
                player.inventory.clear(item);
            }
        });
    }
});