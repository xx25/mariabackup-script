#!/bin/bash
set -o pipefail
#v1.0 written by Harry Pask
#Mariabackup tool for full and incremental backups for non-encrypted tables
#Built in backup retention, email on backup failure and easy to change Mariabackup options

#------debug mode: pass --debug flag to enable-------
debug=0
if [[ "$1" == "--debug" ]]; then
	debug=1
	set -x
fi

debug_log() {
	if [[ $debug -eq 1 ]]; then
		echo "[DEBUG $(date +'%H:%M:%S')] $*" >&2
	fi
}

#------load configuration-------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/backup.conf"

#------lock file: prevent concurrent runs-------
lock_file="${lock_file:-/tmp/mariabackup.lock}"
exec 200>"$lock_file"
if ! flock -n 200; then
	echo "Another instance is already running (lock: $lock_file). Exiting." >&2
	exit 1
fi
debug_log "Acquired lock: $lock_file"

#------------variables------------

# Get the current date
# Group days into cycles of $full_backup_cycle days so a full backup is only taken
# when a new cycle starts (i.e. a new date folder is created without the sentinel file)
epoch_days=$(( $(date +%s) / 86400 ))
cycle_start=$(( epoch_days - (epoch_days % full_backup_cycle) ))
current_date=$(date -d "@$((cycle_start * 86400))" +"%Y-%m-%d")
current_datetime=$(date +"%Y-%m-%d-%T")
current_date_folder=$backup_dir/$current_date

# Define the extra lsdir for incremental backups
extra_lsndir=$current_date_folder

# Define the full backup file
full_backup_file=$current_date_folder/full.backup

# Create the current date folder
incremental_folder=$current_date_folder/incr/$current_datetime
fullbackuplocation=$current_date_folder/fullbackup
mkdir -p "$current_date_folder"

#table struture variables
dumpstructurefolder=$current_date_folder/tablestructure/
currenttimedatastructure=$(date +"%Y-%m-%d-%T"-no-data.sql)

#----------define backup options (must be after variable definitions)------------
#incremental options
declare -a backup_options_inc=(
		"--backup"
		"--user=$user"
		"--password=$password"
		"--extra-lsndir=$extra_lsndir"
		"--incremental-basedir=$extra_lsndir"
		"--stream=xbstream"
		"--slave-info"
		)

#full backup options
declare -a backup_options_full=(
        "--backup"
        "--user=$user"
        "--password=$password"
        "--target-dir=$fullbackuplocation"
        "--extra-lsndir=$extra_lsndir"
        "--stream=xbstream"
		"--slave-info"
        )

#------raise open files limit for large databases-------
ulimit -n 65535

debug_log "backup_dir=$backup_dir"
debug_log "current_date_folder=$current_date_folder"
debug_log "extra_lsndir=$extra_lsndir"
debug_log "fullbackuplocation=$fullbackuplocation"
debug_log "full_backup_file=$full_backup_file (exists: $([ -f "$full_backup_file" ] && echo yes || echo no))"
debug_log "incremental_folder=$incremental_folder"
debug_log "ulimit nofile=$(ulimit -n)"
debug_log "full backup options: ${backup_options_full[*]}"
debug_log "incremental options: ${backup_options_inc[*]}"

#------backup process-------
cd "$current_date_folder"
# Check if full backup file exists
if [ -f "$full_backup_file" ]; then
	# Perform incremental backup if $full_backup_file exists
	debug_log "Running INCREMENTAL backup to $incremental_folder"
	mkdir -p "$incremental_folder"
	mariabackup "${backup_options_inc[@]}" 2>> "$current_date_folder/backup.log" | pigz > "$incremental_folder/incremental.backup.gz"
	debug_log "Incremental backup exit code: ${PIPESTATUS[0]}, pigz exit code: ${PIPESTATUS[1]}"
else
	# Perform full backup
	debug_log "Running FULL backup to $fullbackuplocation"
	mkdir -p "$fullbackuplocation"
	mariabackup "${backup_options_full[@]}" 2>> "$current_date_folder/backup.log" | pigz > "$fullbackuplocation/full_backup.gz"
	debug_log "Full backup exit code: ${PIPESTATUS[0]}, pigz exit code: ${PIPESTATUS[1]}"
fi

#dump table structure
if [[ $dumpstructure == "y" ]];then
	mkdir -p "$dumpstructurefolder"

	mapfile -t databasenames < <(mariadb -u "$user" -p"$password" -BNe "SHOW DATABASES" 2>/dev/null | grep -Ev '^(information_schema|performance_schema|sys)$')
	debug_log "Databases to dump: ${databasenames[*]}"

	for dbname in "${databasenames[@]}"
	do
		mkdir -p "$dumpstructurefolder/$dbname/"
		mariadb-dump -u "$user" -p"$password" -R --no-data "$dbname" > "$dumpstructurefolder/$dbname/$currenttimedatastructure"
	done
fi

#-----Check backup was successful-------

#check backup log
checkstatus=$(tail -n 2 "$current_date_folder/backup.log" | grep -c "completed OK")

#if completed OK! is at the end of the backup log file then add status to backup_status.log
#if not then send backup.log to email address and delete failed incremental backup folder so prepare script doesn't break
#If full backup is successful then make $full_backup_file, if fullbackup fails then file is not created so on next run a fullbackup is tried again

debug_log "checkstatus=$checkstatus (1=OK)"

if [[ $checkstatus -eq 1 ]]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') mariabackup completed okay" >> "$current_date_folder/backup_status.log"
	touch "$full_backup_file"
	#retention cleanup based on folder name (date), not filesystem mtime (unreliable on NFS)
	cutoff_date=$(date -d "-${backupdays} days" +"%Y-%m-%d")
	for dir in "$backup_dir"/20*; do
		[ -d "$dir" ] || continue
		dirname=$(basename "$dir")
		if [[ "$dirname" < "$cutoff_date" ]]; then
			debug_log "Retention: removing old backup $dir (before $cutoff_date)"
			rm -rf "$dir"
		fi
	done
else
    log_content=$(tail -n 200 "$current_date_folder/backup.log") 
    read -r -a recipients <<< "$emails"
    echo "$log_content" | mailx -r "$fromemail" -s "MariaBackup task for $HOSTNAME failed" "${recipients[@]}"
		#checks if full backup completed, if it has then failed incremental backup is removed
		if [[ -f "$full_backup_file" ]]; then
			rm -rf "$incremental_folder"
			echo "$(date +'%Y-%m-%d %H:%M:%S') mariabackup failed - file $incremental_folder deleted" >> "$current_date_folder/backup_status.log"
		else
			echo "$(date +'%Y-%m-%d %H:%M:%S') Full backup failed, please resolve issue and rerun backup" >> "$current_date_folder/backup_status.log"
		fi
fi	


