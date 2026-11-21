#!/bin/bash

# The script must be executed with one argument, otherwise it throws an error and exits 
if [[ ! $# -eq  1 ]]; then
        echo "Error: Number of arguments passed is wrong. 1 arguments should be passed, a target file" >&2
        exit 1
fi

file=$1

# Check if the target file is not the script
if [[ "$file" -ef "$0" ]]; then
    echo "Error: You cannot write into the script itself" >&2
    exit 1
fi

if [[ -d "$file" ]]; then
    echo "Error: $file is a directory" >&2
    exit 1
fi

tac "$0" > "$file" 
