# Exit codes 
# 1 = folderpath given doesn't exist
# 2 = unrecgonized folderpath
# 3 = filename given doesn't exist
# 4 = packwiz failed

filename=$1
folderpath=$2
packwizpath = $3

if [-d "$folderpath"]; then
    echo "Folder Path '$folderpath' exists."
    exit 1
else
    echo "Folder Path '$folderpath' does not exists."
    exit 2
fi

cd $folderpath

if [-f "$filename"]; then
    echo "File '$filename' exists."
else
    echo "File '$filename' does not exists."
    exit 3
fi

if [-d "$packwizpath"]; then
    echo "Folder Path '$packwizpath' exists."
    exit 1
else
    echo "Folder Path '$packwizpath' does not exists."
    exit 2
fi

for line in $(cat "$filename"); do
    # Read the split words into an array
    # based on space delimiter
    IFS='/' read -ra newarr <<< $line
    "$packwizpath" modrinth add "${newarr[0]}" --version-filename "${newarr[1]}" || exit 4
done

"$packwizpath" modrinth add "fabricproxy-lite" --version-filename "v2.6.0" || exit 4
"$packwizpath" curseforge add "https://www.curseforge.com/minecraft/mc-mods/worldedit/download/4586218" || exit 4


exit 0