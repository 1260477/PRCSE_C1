#!/bin/bash

# If the script is executed with any number of arguments it should print an error message and exit 
if [[ $# -gt 0 ]]; then
	echo "Error: This script has no arguments" >&2
	exit 1
fi

#check if the /etc/group file is available
if [[ ! -f "/etc/group" ]]; then
    echo "Error: The /etc/group file is not available" >&2
    exit 1
fi

#Check if the user runnign the script can read the /etc/group file
if [[ ! -r "/etc/group" ]]; then
    echo "Error: You don't have permission to read the /etc/group file" >&2
    exit 1
fi

#Declare the associative array
declare -A groups

#Read each line of the /etc/group file, delimit by ':' and extract all fieds and save in the array, where the key is the GID and the value is the group name
while IFS=: read -r group_name password gid group_list; do
	groups[$gid]=$group_name
done < /etc/group

printf "%s %s\n" "GID" "GROUP"

#For each key of the array, print the key (GID) and the value (group name) per line
for gid in "${!groups[@]}"; do
	printf "%s %s\n" "$gid" "${groups[$gid]}"
done | sort -n
