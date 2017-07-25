#!/bin/sh

#########################################################################################################
#    ___________
#   /-/_"/-/_/-/|
#  /"-/-_"/-_//||
# /__________/|/|
# |"|_'='-]:+|/||
# |-+-|.|_'-"||//
# |[".[:!+-'=|//   borgsphere version 0.1.1
# |='!+|-:]|-|/    https://github.com/fti7/borgsphere
#  ----------     
#
#################

BS_VERSION="0.1.1"

# Prefer manual installed Version of Borg
PATH="/usr/local/bin:$PATH"


#
# Helper Functions
#

send_mail()
{
   local tmpfile="/tmp/sendmail-bc-$$.tmp"
   /bin/echo -e "Subject: $1\r" > "$tmpfile"
   /bin/echo -e "To: $2\r" >> "$tmpfile"
   /bin/echo -e "From: $3\r" >> "$tmpfile"
   /bin/echo -e "\r" >> "$tmpfile"
   if [ -f "$4" ]
   then
      cat "$4" >> "$tmpfile"
      /bin/echo -e "\r\n" >> "$tmpfile"
   else
      /bin/echo -e "$4\r\n" >> "$tmpfile"
   fi
   /usr/sbin/sendmail -t < "$tmpfile"
   [ $? -eq 0 ] && rm $tmpfile
   echo "OK"
}

matches() {
   input="$1"
   pattern="$2"
   echo "$input" | grep -q "$pattern"
}


#
# Main Code
#

if [ $# -eq 0 ]; then
    echo "Usage: $0 jobfile [jobfile...]"
    exit 1
fi


for cfg in "$@"
do
    CFG_NAME=$(basename "$cfg")

    # Set Defaults
    BACKUP_ID="example"
    BACKUP_DIRS="/root"
    BACKUP_EXCLUDE="--exclude-caches"

    BORG_REPOSITORY="/path/to/repo"

    RETRIES_ON_ERROR=10
    BORG_OPTS="--list --filter=AME --lock-wait=15 --compression lz4"
    BORG_FILES_CACHE_TTL=2000

    BORG_PRUNE_ENABLED=false
    BORG_PRUNE_OPTS="--keep-hourly=24 --keep-daily=7 --keep-weekly=4 --keep-monthly=12"

    MAIL_ENABLED=false
    MAIL_FROM="collective@borg.cube"
    MAIL_TO="queen@borg.cube"

    MAIL_SUBJECT_OK="OK | BorgBackup $CFG_NAME"
    MAIL_SUBJECT_WARN="WARN | BorgBackup $CFG_NAME"
    MAIL_SUBJECT_ERROR="ERROR | BorgBackup $CFG_NAME"
    MAIL_SUBJECT_DEDUPSIZE=true

    HOOK_PRE=""
    HOOK_POST_OK=""
    HOOK_POST_ERROR=""

    LOG_FILE="/tmp/borgsphere.$BACKUP_ID.$(date +'%Y-%m-%d-%H%M%S').log"

    # Load Config
    . $cfg



    # Main Code
    echo "config: $cfg | borgsphere $BS_VERSION" >> $LOG_FILE
    echo "Backup Directories: $BACKUP_DIRS" >> $LOG_FILE
    echo "Destination Repository: $BORG_REPOSITORY" >> $LOG_FILE
    echo "------------------------------------------------------------------------------" >> $LOG_FILE
    echo "" >> $LOG_FILE

    if [ -z "$BACKUP_ID" ]
    then
        echo "BACKUP_ID not set... skipping"
        continue
    fi

    # Pre Hook
    if [ -n "$HOOK_PRE" ]
    then
        echo "## Exec Pre-Hook" >> $LOG_FILE
        echo "cmd: $HOOK_PRE" >> $LOG_FILE
        $HOOK_PRE >> $LOG_FILE 2>&1
        echo "## End Pre-Hook rc=$?" >> $LOG_FILE
        echo "" >> $LOG_FILE
    fi

    # Backup
    [ -e ${BORG_PASSPHRASE} ] && export BORG_PASSPHRASE
    export BORG_FILES_CACHE_TTL
    
    for i in `seq 1 $RETRIES_ON_ERROR`;
    do
        echo "## Backup started $(date +'%H:%M:%S %Y-%m-%d') #$i" >> $LOG_FILE
        

        BORG_CMD="borg create --verbose --stats --show-rc $BORG_OPTS $BORG_REPOSITORY::"{hostname}-${BACKUP_ID}-{now:%Y-%m-%d_%H:%M:%S}" $BACKUP_DIRS $BACKUP_EXCLUDE"
        echo "cmd: $BORG_CMD" >> $LOG_FILE
        $BORG_CMD >> $LOG_FILE 2>&1

        BORG_RC=$?
        echo "## Backup finished $(date +'%H:%M:%S %Y-%m-%d') rc=$BORG_RC" >> $LOG_FILE

        if [ $BORG_RC -lt 2 ]
        then
            break
        else
            echo "Error - Retry $i/$RETRIES_ON_ERROR" >> $LOG_FILE
            sleep 60
        fi

    done
    echo "" >> $LOG_FILE

    # Prune old Archives
    if [ "$BORG_PRUNE_ENABLED" = "true" -a $BORG_RC -lt 2 ]
    then
        echo "## Prune Repository with options: $BORG_PRUNE_OPTS" >> $LOG_FILE
        borg prune -v --list $BORG_REPOSITORY --prefix "{hostname}-${BACKUP_ID}-" $BORG_PRUNE_OPTS >> $LOG_FILE 2>&1
        echo "OK" >> $LOG_FILE
        echo "" >> $LOG_FILE
    fi

    echo "## List all Borg Archives in Repository" >> $LOG_FILE
    borg list $BORG_REPOSITORY >> $LOG_FILE
    echo "" >> $LOG_FILE

    # Post Hook
    if [ $BORG_RC -lt 2 ]
    then

        if [ -n "$HOOK_POST_OK" ]
        then
            echo "## Exec Post-Hook-OK" >> $LOG_FILE
            echo "cmd: $HOOK_POST_OK" >> $LOG_FILE
            $HOOK_POST_OK >> $LOG_FILE 2>&1
            echo "## End Post-Hook-OK rc=$?" >> $LOG_FILE
            echo "" >> $LOG_FILE
        fi

    else

        if [ -n "$HOOK_POST_ERROR" ]
        then
            echo "## Exec Post-Hook-ERROR" >> $LOG_FILE
            echo "cmd: $HOOK_POST_ERROR" >> $LOG_FILE
            $HOOK_POST_ERROR >> $LOG_FILE 2>&1
            echo "## End Post-Hook-ERROR rc=$?" >> $LOG_FILE
            echo "" >> $LOG_FILE
        fi

    fi

    if [ "$MAIL_ENABLED" = "true" ]
    then
        echo "## Send Mail Notification" >> $LOG_FILE
        SUBJ=""
        if [ $BORG_RC -eq 0 ]
        then
            SUBJ="$MAIL_SUBJECT_OK"
        elif [ $BORG_RC -eq 1 ]
        then
            SUBJ="$MAIL_SUBJECT_WARN"
        elif [ $BORG_RC -gt 1 ]
        then
            SUBJ="$MAIL_SUBJECT_ERROR"
        fi

        # Append Dedupsize?
        if [ $BORG_RC -lt 2 -a "$MAIL_SUBJECT_DEDUPSIZE" = "true" ]
        then
            DEDUP_SIZE=$(grep "This archive" $LOG_FILE | awk '{print $7, $8}')

            # Hide if just Metadata
            if ! matches "$DEDUP_SIZE" "kB"
            then
                SUBJ="$SUBJ - $DEDUP_SIZE"
            fi

        fi

        # Send Mail
        send_mail "$SUBJ" "$MAIL_TO" "$MAIL_FROM" "$LOG_FILE" >> $LOG_FILE 2>&1

    fi

done




