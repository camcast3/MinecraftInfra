const $RangedAttribute = Java.loadClass("net.minecraft.world.entity.ai.attributes.RangedAttribute")

StartupEvents.registry("attribute", e => {
    e.createCustom("kubejs:move_speed", () => new $RangedAttribute("MnS Move Speed", 1, 0, 10).setSyncable(true));
    e.createCustom("kubejs:critical_hit", () => new $RangedAttribute("MnS Critical Hit", 1, 0, 10).setSyncable(true));
    e.createCustom("kubejs:magic_find", () => new $RangedAttribute("MnS Magic Find", 1, 0, 10).setSyncable(true));
    e.createCustom("kubejs:plus_lvl_all_spells", () => new $RangedAttribute("MnS Plus Level All Skills", 1, 0, 10).setSyncable(true));
    e.createCustom("kubejs:weapon_damage", () => new $RangedAttribute("MnS Perc Wep Damage", 1, 0, 20).setSyncable(true));
    e.createCustom("kubejs:armor", () => new $RangedAttribute("MnS Perc Armor", 1, 0, 20).setSyncable(true));
    e.createCustom("kubejs:magic_shield", () => new $RangedAttribute("MnS Perc Magic Shield", 1, 0, 20).setSyncable(true));
    e.createCustom("kubejs:dodge", () => new $RangedAttribute("MnS Perc Dodge Rating", 1, 0, 20).setSyncable(true));
    e.createCustom("kubejs:all_attributes", () => new $RangedAttribute("MnS All Attributes", 1, 0, 20).setSyncable(true));
    e.createCustom("kubejs:increase_healing", () => new $RangedAttribute("MnS Heal Strength", 1, 0, 20).setSyncable(true));
    e.createCustom("kubejs:health_per_perc_of_intelligence", () => new $RangedAttribute("MnS Health Per Perc Int", 1, 0, 100).setSyncable(true));
    e.createCustom("kubejs:total_damage_per_perc_of_health", () => new $RangedAttribute("MnS Damage Per Perc Health", 1, 0, 20).setSyncable(true));
});

EntityJSEvents.attributes(event => {
    event.modify('minecraft:player', attribute => {
        attribute.add("kubejs:move_speed", 0.0);
        attribute.add("kubejs:critical_hit", 0.0);
        attribute.add("kubejs:magic_find", 0.0);
        attribute.add("kubejs:plus_lvl_all_spells", 0.0);
        attribute.add("kubejs:weapon_damage", 0.0);
        attribute.add("kubejs:armor", 0.0);
        attribute.add("kubejs:magic_shield", 0.0);
        attribute.add("kubejs:dodge", 0.0);
        attribute.add("kubejs:all_attributes", 0.0);
        attribute.add("kubejs:increase_healing", 0.0);
        attribute.add("kubejs:health_per_perc_of_intelligence", 0.0);
        attribute.add("kubejs:total_damage_per_perc_of_health", 0.0);
    })
}) 