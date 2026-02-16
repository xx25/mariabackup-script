#!/bin/bash
set -o pipefail
#Only to be run if a incremental backup is taken, if not then run prepare script manually
#To run do
#bash prepare.bash /path/to/backup/directory
#script will then look for fullbackup folder and loop through the incremental backups in order
#do not run if no incremental backups have been taken, run prepare manually

#------load configuration-------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/backup.conf"

# Set variables for the full backup folder and the incremental backup folder

#if variable = testrestore, then the script will prepare the backups and then preform a restore with the --move-back option
testrestore="testrestore"

# Validate base backup directory exists
if [[ ! -d "$backup_dir" ]]; then
    echo "ERROR: Base backup directory $backup_dir does not exist"
    exit 1
fi

for backup_date in "$backup_dir"/*
do
        #variables for prepare part of the script
        backupdir=$backup_date
        FULL_BACKUP_DIR=$backup_date/fullbackup/
        incrementaldir=$backupdir/incr/
        preparelog=$backupdir/prepare.log
        backupday=$backup_date

        #variables for automted logs and checks
        automated_dir=/media/automatedrestores/
        automatedchecklog=$automated_dir/automated_checks.log
        failedlog=$automated_dir/automated_failed.log
        automated_log=$automated_dir/automated_full.log
        completedrestores=$(grep -c "$backup_date" "$automatedchecklog")

            if [[ $completedrestores -eq 0 ]] && [[ -d "$incrementaldir" ]]; then
                full_backup_file=$backupdir/full_backup.gz
                #echo $full_backup_file
                if [ -f "$full_backup_file" ]; then
                    echo "$(date +'%Y-%m-%d %H:%M:%S') Prepare script has been ran before. resetting directory for next prepare run" >>"$automated_log"
                    echo "$(date +'%Y-%m-%d %H:%M:%S') Emptying the $FULL_BACKUP_DIR directory" >>"$automated_log"
                    rm -rf "$FULL_BACKUP_DIR"/*
                    echo "$(date +'%Y-%m-%d %H:%M:%S') Moving full backup zip file back to $FULL_BACKUP_DIR" >>"$automated_log"
                    mv "$backupdir/full_backup.gz" "$FULL_BACKUP_DIR"
                    echo "$(date +'%Y-%m-%d %H:%M:%S') Archiving prepare file" >>"$automated_log"
                    archivelog=$backupdir/old-prepare-$(date +'%H:%M:%S').log
                    mv "$preparelog" "$archivelog"
                    echo "$(date +'%Y-%m-%d %H:%M:%S') Directory reset, starting prepare process as normal" >>"$automated_log"

                else

                    echo "$(date +'%Y-%m-%d %H:%M:%S') First time running prepare. running process as normal" >>"$automated_log"
                fi

                # Change directory, unzip file and run prepare fullbackup
                cd "$FULL_BACKUP_DIR"
                unpigz -c "$FULL_BACKUP_DIR"/* | mbstream -x
                if [[ ${PIPESTATUS[0]} -ne 0 || ${PIPESTATUS[1]} -ne 0 ]]; then
                    echo "$(date +'%Y-%m-%d %H:%M:%S') ERROR: decompression/extraction failed for full backup $backup_date" >> "$automated_log"
                    continue
                fi
                mariabackup --prepare --target-dir="$FULL_BACKUP_DIR" 2>> "$preparelog"
                mv "$FULL_BACKUP_DIR/full_backup.gz" ..

                # Loop through incremental backup folders, unzip and apply them to the full backup

                for DIR in "$incrementaldir"/*
                do
                    checkstatus=$(tail -n 2 "$preparelog" | grep -c "completed OK")

                    if [[ $checkstatus -eq 1 ]]; then
                        cd "$DIR"
                        unpigz -c "$DIR"/* | mbstream -x
                        if [[ ${PIPESTATUS[0]} -ne 0 || ${PIPESTATUS[1]} -ne 0 ]]; then
                            echo "$(date +'%Y-%m-%d %H:%M:%S') ERROR: decompression/extraction failed for $DIR" >> "$automated_log"
                            continue 2
                        fi
                        echo "$(date +'%Y-%m-%d %H:%M:%S') Applying $DIR incremental updates to fullbackup" >>"$automated_log"
                        mariabackup --prepare --target-dir="$FULL_BACKUP_DIR" --incremental-dir="$DIR" 2>> "$preparelog"

                    else
                        echo "$(date +'%Y-%m-%d %H:%M:%S') Last incremental failed to run, please check $preparelog for more details"
                        echo "$(date +'%Y-%m-%d %H:%M:%S') Check incremental folder for compressed file. Backup might be corrpted, prepare to last good incremental" >> "$preparelog"
                    fi
                done



                #delete incrmental uncompressed files after they are appiled to fullbackup to save space
                for DIR in "$incrementaldir"/*
                do
                    cd "$DIR"
                    find "$DIR"/* ! -name 'incremental.backup.gz' | xargs rm -rf
                    echo "$(date +'%Y-%m-%d %H:%M:%S') Deleted uncompressed files for incremental $DIR" >> "$preparelog"
                    echo "$(date +'%Y-%m-%d %H:%M:%S') Deleting uncompressed $DIR leaveing zipped file alone" >> "$automated_log"
                done

                lastcheckstatus=$(grep -c "completed OK" "$preparelog")

                incbackups=$(find "$incrementaldir" -mindepth 1 -maxdepth 1 -type d | wc -l)

                includefull=$(($incbackups + 1))

                #if number of prepared backups = number of backups process was succesfully
                if [[ $lastcheckstatus -eq $includefull ]]; then
                    echo "prepare script ran succesfully for $backup_date" >> "$automated_log"

                    if [[ "$testrestore" == "testrestore" ]]; then

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
                        mariabackup --move-back --target-dir="$FULL_BACKUP_DIR" 2>>"$automated_log"

                        #change datadir ownership
                        chown -R mysql:mysql "$restore_dir"

                        #comment this out if you want to do this manually
                        systemctl start mariadb.service

                    fi



                    if [ -f "$backupdir/full_backup.gz" ]; then
                            echo "returning backup dir to orginal state as test was successful" >> "$automated_log"

                            rm "$backupdir/prepare.log"

                            rm -rf "$backupdir/fullbackup/"*

                            mv "$backupdir/full_backup.gz" "$backupdir/fullbackup/"
                    else
                        echo "cannot find fullbackup zip file, not resetting full backup folder encase zip file is there" >> "$automated_log"
                    fi
                    #echo $backup_date >> $automatedchecklog

                else
                    echo "$(date +'%Y-%m-%d %H:%M:%S') Prepare failed, check $preparelog for more details. number of backups did not equal number of prepared backups" >> "$automated_log"

                    #reset backup dir
                        if [ -f "$backupdir/full_backup.gz" ]; then
                            echo "returning backup dir to orginal state, renaming prepare.log to failed-prepare.log for you to check" >> "$automated_log"

                            mv "$backupdir/prepare.log" "$backupdir/failed-prepare.log"

                            rm -rf "$backupdir/fullbackup/"*

                            mv "$backupdir/full_backup.gz" "$backupdir/fullbackup/"
                        else
                        echo "cannot find fullbackup zip file, not resetting full backup folder encase zip file is there" >> "$automated_log"
                        fi
                fi


            fi
done
