/bin/bash

filename="../mods.txt"

for line in $(cat "$filename"); do
    # Read the split words into an array
    # based on space delimiter
    IFS='/' read -ra newarr <<< $line
    ~/Dev/packwiz modrinth add "${newarr[0]}" --version-filename "${newarr[1]}"
    echo
done