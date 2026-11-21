#!/bin/bash

# The script must be executed with two arguments, otherwise it throws an error and exits 
if [[ ! $# -eq  2 ]]; then
        echo "Error: Number of arguments passed is wrong. 2 arguments should be passed, a directory and a size in KB" >&2
        exit 1
fi

directory=$1
size=$2

# Check if the directory passed in the argument is a valid directory
if [[ ! -d "$directory" ]]; then
    echo "Error: $directory is not a valid directory or does not exist" >&2
    exit 1
fi

#Check if the user running the script can list the directory
if [[ ! -r "$directory" || ! -x "$directory" ]]; then
    echo "Error: You don't have permission to list the $directory" >&2
    exit 1
fi

# Check if the size passed in the argument is a valid integer
if [[ ! "$size" =~ ^[0-9]+$ ]]; then
        echo "Error: The size $size is not a valid number" >&2
	exit 1
fi

found=0

for file in "$directory"/*; do

    # Skip subdirectories, only files matter
    [[ -f "$file" ]] || continue

    # Size of the file in KB (hint)
    file_size=$(du -k "$file" | cut -f1)

    # Skip files that are not larger than the given size
    [[ "$file_size" -gt "$size" ]] || continue

    found=$((found + 1))
    echo
    echo "File: $file ($file_size KB)"

    while true; do
        read -r -p "[d]elete, [c]ompress or [k]eep? " answer < /dev/tty

        case "$answer" in
            d|D) rm -- "$file" && echo "Deleted."; break ;;
            c|C) gzip -- "$file" && echo "Compressed to $file.gz"; break ;;
            k|K) echo "Kept."; break ;;
            *)   echo "Invalid option, type d, c or k." >&2 ;;
        esac
    done
done

echo
if [[ "$found" -eq 0 ]]; then
    echo "No files larger than $size KB in $directory."
else
    echo "Done: $found file(s) processed."
fi

