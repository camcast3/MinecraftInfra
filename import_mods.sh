# Exit codes 
# 1 = folderpath given doesn't exist
# 2 = unrecgonized folderpath
# 3 = filename given doesn't exist
# 4 = unrecgonized folderpath
# 5 = packwiz failed
# 6 = Unable to decide on packwiz command

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
    if [[$filename == *"curseforge"]]; then
        echo "Creating modpack from curseforge"
    elif [[$filename == *"modrinth"]]; then
        echo "Creating modpack from modrinth"
    else
        echo "Unable to determine mopdak source. Fix filepath."
        exit 1
    fi
else
    echo "File '$filename' does not exists."
    exit 1
fi

for line in $(cat "$filename"); do
    # Read the split words into an array
    # based on space delimiter
    IFS='/' read -ra newarr <<< $line
    if ["${newarr[3]}" == "both"] && [[$filename == *"modrinth"]]; then
        ~/Dev/packwiz modrinth add "${newarr[0]}" --version-filename "${newarr[1]}" || exit 5
    elif ["${newarr[3]}" == "server"] && [[$filename == *"modrinth"]] &&  [[$folderpath == *"/server"]]; then
         ~/Dev/packwiz modrinth add "${newarr[0]}" --version-filename "${newarr[1]}" || exit 5
    elif [[$filename == *"curseforge"]] &&  [[$folderpath == *"/server"]]; then
        ~/Dev/packwiz curseforge add "${newarr[0]}" || exit 5
    else
        echo "Wasnt able to decide on what packwiz command to use"
        exit 6
    if
done

exit 0