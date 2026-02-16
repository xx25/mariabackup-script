#!/bin/bash
set -o pipefail
#WARNING it would be best to restore manully
#This was included if you are test backups as it can be annoying to type out the same commands over and over

#location of fullbackup with incremental changes applied
backup_dir="$1"

# Validate input
if [[ -z "$1" ]] || [[ ! -d "$1" ]]; then
    echo "Usage: bash restore.bash /path/to/prepared/fullbackup/"
    exit 1
fi

#Define restore location (datadir for mariadb)
restore_dir="/var/lib/mysql/"


#comment this out if you want to do this manually
systemctl stop mariadb.service

#set up restore location
rm -rf "$restore_dir"
mkdir "$restore_dir"

#change directory to restore location
cd "$restore_dir"

#perform move back process
#can be changed --move-back to "cut and paste" instead of "copy and paste"
mariabackup --copy-back --target-dir="$backup_dir"

if [[ $? -ne 0 ]]; then
    echo "ERROR: mariabackup --copy-back failed. Not starting MariaDB."
    exit 1
fi

#change datadir ownership

chown -R mysql:mysql "$restore_dir"

#comment this out if you want to do this manually
systemctl start mariadb.service
