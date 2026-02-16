#!/bin/bash
#Only to be run if an incremental backup has been taken, if no incremental then prepare backup manually
#To run do 
#bash prepare.bash /path/to/backup/directory 
#include --export for single table restores ($2 variable)
#script will then look for fullbackup folder and loop through the incremental backups in order
#do not run if no incremental backups have been taken, run prepare manually

#------load configuration-------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/backup.conf"

# Set variables for the full backup folder and the incremental backup folder

orig_backupdir="$1"
backupdir="$1"
exportoption="$2"
FULL_BACKUP_DIR=$backupdir/fullbackup/
restartfulldir=$FULL_BACKUP_DIR/*
INCREMENTAL_BACKUP_DIR=$backupdir/incr/*
incrementaldir=$backupdir/incr/
preparelog=$backupdir/prepare.log

# If work_dir is set, copy compressed backups to fast local storage
use_local=0
if [[ -n "$work_dir" ]]; then
    backup_date=$(basename "$orig_backupdir")
    local_backupdir="$work_dir/$backup_date"

    if [[ ! -d "$local_backupdir" ]]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') Copying compressed backups from NFS to local working directory $local_backupdir"
        mkdir -p "$local_backupdir/fullbackup"
        mkdir -p "$local_backupdir/incr"

        # Copy full backup (may be in fullbackup/ or parent dir if previously prepared)
        if [[ -f "$orig_backupdir/fullbackup/full_backup.gz" ]]; then
            cp "$orig_backupdir/fullbackup/full_backup.gz" "$local_backupdir/fullbackup/"
        elif [[ -f "$orig_backupdir/full_backup.gz" ]]; then
            cp "$orig_backupdir/full_backup.gz" "$local_backupdir/"
        fi

        # Copy incremental backups
        for incdir in "$orig_backupdir"/incr/*/; do
            if [[ -d "$incdir" ]]; then
                incname=$(basename "$incdir")
                mkdir -p "$local_backupdir/incr/$incname"
                cp "$incdir/incremental.backup.gz" "$local_backupdir/incr/$incname/" 2>/dev/null
            fi
        done

        # Copy prepare.log if it exists (for re-run detection)
        [[ -f "$orig_backupdir/prepare.log" ]] && cp "$orig_backupdir/prepare.log" "$local_backupdir/"

        echo "$(date +'%Y-%m-%d %H:%M:%S') Copy complete"
    else
        echo "$(date +'%Y-%m-%d %H:%M:%S') Local working directory $local_backupdir already exists, using existing copy"
    fi

    # Redirect all paths to local working directory
    backupdir="$local_backupdir"
    FULL_BACKUP_DIR="$local_backupdir/fullbackup/"
    restartfulldir="$FULL_BACKUP_DIR*"
    INCREMENTAL_BACKUP_DIR="$local_backupdir/incr/*"
    incrementaldir="$local_backupdir/incr/"
    preparelog="$local_backupdir/prepare.log"
    use_local=1
fi

#reset backup directory if prepare script has been ran before


full_backup_file=$backupdir/full_backup.gz
echo $full_backup_file 
if [ -f $full_backup_file ]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') Prepare script has been ran before. resetting directory for next prepare run"
    echo "$(date +'%Y-%m-%d %H:%M:%S') Emptying the $FULL_BACKUP_DIR directory"
    rm -rf $restartfulldir
    echo "$(date +'%Y-%m-%d %H:%M:%S') Moving full backup zip file back to $FULL_BACKUP_DIR"
    mv $backupdir/full_backup.gz $FULL_BACKUP_DIR
    echo "$(date +'%Y-%m-%d %H:%M:%S') Archiving prepare file"
    archivelog=$backupdir/old-prepare-$(date +'%H:%M:%S').log
    mv $preparelog $archivelog
    echo "$(date +'%Y-%m-%d %H:%M:%S') Directory reset, starting prepare process as normal"   
    
else

    echo "$(date +'%Y-%m-%d %H:%M:%S') First time running prepare. running process as normal"
fi

# Change directory, unzip file and prepare fullbackup
cd $FULL_BACKUP_DIR
unpigz -c $FULL_BACKUP_DIR/* | mbstream -x
mariabackup --prepare --target-dir=$FULL_BACKUP_DIR 2>> $preparelog
mv $FULL_BACKUP_DIR/full_backup.gz ..

# Loop through incremental backup folders, unzip and apply them to the full backup

for DIR in $INCREMENTAL_BACKUP_DIR
do
    checkstatus=$(tail -n 2 $preparelog | grep -c "completed OK")
    
    if [[ $checkstatus -eq 1 ]]; then
        cd $DIR
        gunzip -c $DIR/* | mbstream -x
        echo "$(date +'%Y-%m-%d %H:%M:%S') Applying $DIR incremental updates to fullbackup"
        mariabackup --prepare --target-dir=$FULL_BACKUP_DIR --incremental-dir=$DIR 2>> $preparelog
    
    else
        echo "$(date +'%Y-%m-%d %H:%M:%S') Last incremental failed to run, please check $preparelog for more details"
        echo "$(date +'%Y-%m-%d %H:%M:%S') Check incremental folder for compressed file. Backup might be corrpted, prepare to last good incremental" >> $preparelog
    fi
done



#delete incrmental uncompressed files after they are appiled to fullbackup to save space
for DIR in $INCREMENTAL_BACKUP_DIR
do
    cd $DIR
    find $DIR/* ! -name 'incremental.backup.gz' | xargs rm -rf
    echo "$(date +'%Y-%m-%d %H:%M:%S') Deleted uncompressed files for incremental $DIR" >> $preparelog
    echo "$(date +'%Y-%m-%d %H:%M:%S') Deleting uncompressed $DIR leaveing zipped file alone"
done

lastcheckstatus=$(grep -c "completed OK" $preparelog)

incbackups=$(find $incrementaldir -mindepth 1 -maxdepth 1 -type d | wc -l)
includefull=$(($incbackups + 1))

#if number of prepared backups = number of backups process was succesfully
if [[ $lastcheckstatus -eq $includefull ]]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') Prepare completed successfully and ready to restore from backup directory $FULL_BACKUP_DIR"
    if [[ $use_local -eq 1 ]]; then
        echo "Prepared backup is on local disk (source NFS: $orig_backupdir)"
    fi
    echo "Restore with either command:"
    echo "mariabackup --copy-back --target-dir=$FULL_BACKUP_DIR"
    echo "mariabackup --move-back --target-dir=$FULL_BACKUP_DIR"
else
    echo "$(date +'%Y-%m-%d %H:%M:%S') Prepare failed, check $preparelog for more details. number of backups did not equal number of prepared backups"
    if [[ $use_local -eq 1 ]]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') Local working directory preserved for inspection: $backupdir"
    fi
fi
 

if [[ $2 == "--export" ]]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') Export option select, preparing the full backup with .cfg files for tablespace import"
    mariabackup --prepare --export --target-dir=$FULL_BACKUP_DIR 2>> $preparelog
fi
