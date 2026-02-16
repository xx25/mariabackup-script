# mariabackup-script
## Full and incremental script along with prepare script to uncompress and apply incremental backups to full backup ##

Parts of the scripts are standard to Redhat/yum distros which means you may find that you need to change tools used in the script to better suit your OS. You may need to install pigz, or change it to gzip and gunzip.

### This script has the following features: ###

* Full and incremental backups (compressed with gzip)
* Configurable full backup cycle (e.g. every N days)
* Retention policy (date-based, safe for NFS)
* Email on failure (mailx)
* Auto removal of failed incremental backups
* Debug mode (`--debug` flag)
* Prepare script that loops through incremental backups to apply new changes to full backup
* Optional local working directory for prepare — avoids slow random I/O on NFS mounts

### How to use ###

```bash
bash mariabackup.bash

# run with debug output
bash mariabackup.bash --debug

bash prepare.bash /media/backups/dateofback
```

### Create the backup user: ###

```SQL

create user 'backup'@'localhost' identified by 'password';
grant reload,process,lock tables,binlog monitor,connection admin,slave monitor on *.* to 'backup'@'localhost';

```

### Main script settings: ###


```bash
# Define the backup directory
backup_dir=/media/backups/

# Define the mariadb user and password
user=backup
password=password

#emaillist, spaces in-between, no commas
emails="email@emaildomain.com"
fromemail="mariabackup@emaildomain.com"

#number of days to keep backups
#0= just today's backup | 1= today and yesterday | 2=today,yesterday,day before etc
backupdays=0

#full backup cycle in days (a new full backup is taken every N days)
full_backup_cycle=3

#dump table sturture per for single database restores (full innodb databases only)
dumpstructure='n'
```

### Prepare script settings: ###

```bash
# Local working directory (optional). Set to a fast local path to avoid
# random I/O over slow NFS during prepare. Leave empty for in-place behavior.
# NOTE: Needs enough free space for compressed + uncompressed backup
# (e.g., 157 GB compressed + 500 GB+ uncompressed = ~700 GB+).
work_dir=""
# Example: work_dir="/var/tmp/mariabackup-prepare"
```

### Add, remove or change variables in the mariabackup options ###
Do not change, will break script|
----------------|
"--backup"|
"--user=$user"|
"--password=$password"|
"--target-dir=$fullbackuplocation"|
"--extra-lsndir=$extra_lsndir"|
"--stream=xbstream"|


#### options: ####

You have options for full and incremental backups. Having two sets of options allows you to have lots of parallel threads for the full backup early in the morning and a few in working hours to stop the database becoming slow during the day as incremental backups shouldn't take long to complete

```bash
#----------define backup options------------
#incremental options
declare -a backup_options_inc=(
	"--backup"
	"--user=$user"
	"--password=$password"
	"--extra-lsndir=$extra_lsndir"
	"--incremental-basedir=$extra_lsndir"
	"--stream=xbstream"
	"--slave-info"
	"--parallel=1"
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
	"--parallel=1"
        )

```
