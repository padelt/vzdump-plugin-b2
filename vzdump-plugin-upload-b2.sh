#!/bin/bash
CONFIG_FILE=$(dirname $0)/upload-b2.config

. "$CONFIG_FILE"

if [ ! -r "$CONFIG_FILE" ] ; then
  echo "Where is my config file? Looked in $CONFIG_FILE."
  echo "If you have none, copy the template and enter your information."
  echo "If it is somewhere else, change the second line of this script."
  exit 1
fi
if [ ! -x "$GPG_BINARY" ] || [ ! -x "$B2_BINARY" ] || [ ! -x "$JQ_BINARY" ] || [ ! -r "$GPG_PASSPHRASE_FILE" ] ; then
  echo "Missing one of $GPG_BINARY, $B2_BINARY, $JQ_BINARY or $GPG_PASSPHRASE_FILE."
  echo "Or one of the binaries is not executable."
  echo 2
fi

# Eliminate duplicate slashes. B2 does not accept those in file paths.
TARFILE=$(sed 's#//#/#g' <<< "$TARFILE")
TARBASENAME=$(basename "$TARFILE")
VMID=$3

#echo "PHASE: $1"
#echo "MODE: $2"
#echo "VMID: $3"
#echo "VMTYPE: $VMTYPE"
#echo "DUMPDIR: $DUMPDIR"
#echo "HOSTNAME: $HOSTNAME"
#echo "TARFILE: $TARFILE"
#echo "TARBASENAME: $TARBASENAME"
#echo "LOGFILE: $LOGFILE"
#echo "USER: `whoami`"

if [ "$1" == "backup-end" ]; then
  if [ ! -f $TARFILE ] ; then
    echo "Where is my tarfile?"
    exit 3
  fi

  echo "CHECKSUMMING whole tar."
  sha1sum -b "$TARFILE" >> "$TARFILE.sha1sums"
  if [ $? -ne 0 ] ; then
    echo "Something went wrong checksumming."
    exit 4
  fi

  echo "SPLITTING into chunks sized <=$B2_SPLITSIZE_BYTE byte"
  time split --bytes=$B2_SPLITSIZE_BYTE --suffix-length=3 --numeric-suffixes "$TARFILE" "$TARFILE.split."
  if [ $? -ne 0 ] ; then
    echo "Something went wrong splitting."
    exit 5
  fi

  echo "CHECKSUMMING splits"
  sha1sum -b $TARFILE.split.* >> "$TARFILE.sha1sums"
  if [ $? -ne 0 ] ; then
    echo "Something went wrong checksumming."
    exit 6
  fi

  echo "Deleting whole file"
  rm "$TARFILE"

  echo "ENCRYPTING"
  ls -1 $TARFILE.split.* | time xargs --verbose -I % -n 1 -P $NUM_PARALLEL_GPG $GPG_BINARY --no-tty --compress-level 0 --passphrase-file $GPG_PASSPHRASE_FILE -c --output "%.gpg" "%"
  if [ $? -ne 0 ] ; then
    echo "Something went wrong encrypting."
    exit 7
  fi

  echo "Checksumming encrypted splits"
  sha1sum -b $TARFILE.split.*.gpg >> "$TARFILE.sha1sums"
  if [ $? -ne 0 ] ; then
    echo "Something went wrong checksumming."
    exit 8
  fi

  echo "Deleting cleartext splits"
  rm $TARFILE.split.???

  echo "AUTHORIZING AGAINST B2"
  $B2_BINARY authorize_account $B2_ACCOUNT_ID $B2_APPLICATION_KEY
  if [ $? -ne 0 ] ; then
    echo "Something went wrong authorizing."
    exit 9
  fi

  echo "UPLOADING to B2 with up to $NUM_PARALLEL_UPLOADS parallel uploads."
  ls -1 $TARFILE.sha1sums $TARFILE.split.* | xargs --verbose -I % -n 1 -P $NUM_PARALLEL_UPLOADS $B2_BINARY upload_file $B2_BUCKET "%" "$B2_PATH%"
  if [ $? -ne 0 ] ; then
    echo "Something went wrong uploading."
    exit 10
  fi

  echo "REMOVING older remote backups."
  DELIMITER="//" # safe since B2 does not allow double slash in filenames
  ALLFILES=$(set -e;next="" ; while [ "$next" != "null" ] ; do echo "Getting more files starting at: $next" 1>&2; OUT=$(b2 list_file_names "$B2_BUCKET" "$next") ; next=$(echo "$OUT" | jq -r ".nextFileName") ; files=$(echo "$OUT" | jq -r '.files[]|.fileName+"'$DELIMITER'"+.fileId'); echo "$files"; done)
  VMIDFILES=$(echo -n "$ALLFILES" |grep "vzdump-qemu-$VMID")
  echo -n $(echo "$VMIDFILES" | wc -l)
  echo " Files from backups with VMID $VMID:"
  echo "$VMIDFILES"
  OTHERVMIDFILES=$(echo -n "$VMIDFILES" | grep -v "$TARBASENAME")
  OTHERVMIDFILESCOUNT=$(echo "$OTHERVMIDFILES" | wc -l)
  echo "$OTHERVMIDFILESCOUNT Files from backups with VMID $VMID but not from current backup $TARBASENAME:"
  echo "$OTHERVMIDFILES"
  echo "Will delete $OTHERVMIDFILESCOUNT files from older backups."
  COMMANDS=$(echo -n "$OTHERVMIDFILES" | sed -E 's#^(.+)//(.+)$#'$B2_BINARY' delete_file_version \1 \2#')
  echo "$COMMANDS" | tr '\n' '\0' | xargs -0 -n1 -I % bash -c "%"
  if [ $? -ne 0 ] ; then
    echo "Something went wrong deleting old remote backups."
    exit 11
  fi

  echo "DELETING local encrypted splits"
  rm $TARFILE.split.*.gpg
    
fi
