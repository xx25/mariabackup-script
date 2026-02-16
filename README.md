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

### Configuration ###

All settings live in `backup.conf`, which is sourced by both `mariabackup.bash` and `prepare.bash`. The file is gitignored so pulling updated scripts will not overwrite your production values.

To set up on a new server, copy the example file and edit it:

```bash
cp backup.conf.example backup.conf
vi backup.conf
```

See `backup.conf.example` for all available settings and their defaults:
`backup_dir`, `user`, `password`, `emails`, `fromemail`, `backupdays`, `full_backup_cycle`, `dumpstructure`, and `work_dir`.

When `dumpstructure='y'`, the script automatically discovers all databases (excluding `information_schema`, `performance_schema`, and `sys`) and dumps their schema via `mariadb-dump --no-data`. The dumps are stored under `tablestructure/` in the backup date folder and are needed for single-table restores with `--export`.

### Mariabackup options ###

The script defines two option arrays in `mariabackup.bash` — one for full and one for incremental backups. They automatically use `user` and `password` from `backup.conf`. To add extra mariabackup flags (e.g. `--parallel`, `--compress`), edit the arrays directly in the script:

```bash
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
```
