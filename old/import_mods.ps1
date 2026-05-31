$content = Get-Content -Path "cobblemonextended\modrinth_mods.txt"

Set-Location -Path "cobblemonextended"

foreach($line in $content){
    $data = $line -split "/"
    ."C:\Users\carlt\Downloads\packwiz.exe" modrinth add $data[0]
}

."C:\Users\carlt\Downloads\packwiz.exe" modrinth add "fabricproxy-lite" 
."C:\Users\carlt\Downloads\packwiz.exe" modrinth add "crossstitch"
."C:\Users\carlt\Downloads\packwiz.exe" curseforge add "https://www.curseforge.com/minecraft/mc-mods/worldedit/download/4586218"