# Exit codes 
# 1 = folderpath given doesn't exist
# 2 = unrecgonized folderpath
# 3 = filename given doesn't exist
# 4 = packwiz failed

filename=$1
folderpath=$2

if [-d "$folderpath"]; then
    echo "Folder Path '$folderpath' exists."
    if [[$folderpath == *"/client"]]; then
        echo "Creating modpack for client"
    elif [[$folderpath == *"/server"]]; then
        echo "Creating modpack for server"
    else
        echo "Unable to determine mopdak type. Fix folderpath."
        exit 1
    fi
else
    echo "Folder Path '$folderpath' does not exists."
    exit 2

cd $folderpath

if [-f "$filename"]; then
    echo "File '$filename' exists."
else
    echo "File '$filename' does not exists."
    exit 3
fi

for line in $(cat "$filename"); do
    # Read the split words into an array
    # based on space delimiter
    IFS='/' read -ra newarr <<< $line
    ~/Dev/packwiz modrinth add "${newarr[0]}" --version-filename "${newarr[1]}" || exit 4
done

if [[$folderpath == *"/server"]]
    ~/Dev/packwiz modrinth add "fabricproxy-lite" --version-filename "v2.6.0" || exit 4
    ~/Dev/packwiz curseforge add "https://www.curseforge.com/minecraft/mc-mods/worldedit/download/4586218" || exit 4
fi

exit 0