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
  exit 2
fi

if [ $# -lt 3 ] ; then
  echo "Please call me with three parameters."
  echo "a) The directory inside the bucket, e.g. 'hostname/rpool/backup/dump',"
  echo "b) The name of the (compressed) vma-file, e.g. 'vzdump-qemu-100-2016_02_11-12_15_02.vma.lzo' and"
  echo "c) a directory where I can work."
  echo "vzdump-b2-verify.sh hostname/rpool/backup/dump vzdump-qemu-100-2016_02_11-12_15_02.vma.lzo /rpool/backup/restoretest"
  exit 3
fi

B2_PATH=$1
FILENAME=$2
DIR=$3

if [ ! -d "$DIR" ] ; then
  echo "Can's find $DIR or it is not a directory. Please create it."
  exit 4
fi

echo "AUTHORIZING AGAINST B2"
$B2_BINARY authorize_account $B2_ACCOUNT_ID $B2_APPLICATION_KEY
if [ $? -ne 0 ] ; then
  echo "Something went wrong authorizing."
  exit 5
fi

echo "LISTING ALL THE FILES"
B2_FILENAMES=$($B2_BINARY list_file_names $B2_BUCKET "$B2_PATH/$FILENAME" 1000)
B2_FILTERED=$(echo "$B2_FILENAMES" | $JQ_BINARY --arg fn "$FILENAME" --arg b2binary "$B2_BINARY" --arg localdir "$DIR" --arg bucket "$B2_BUCKET" '.files[]|select(.fileName|test(".*/"+$fn+".*"))|""+$b2binary+" download_file_by_name "+$bucket+" "+.fileName+" "+$localdir+"/"+(.fileName|capture("^.*/(?<basename>.+)$")|.basename)')

if [ -z "$B2_FILTERED" ] ; then
  echo "No files after filtering. Result from B2 was:\n$B2_FILENAMES"
  exit 6
fi

echo "DOWNLOADING ALL THE FILES"
xargs -n 1 -L 1 -r -P $NUM_PARALLEL_UPLOADS --verbose -I % bash -c "%" <<< "$B2_FILTERED"
if [ $? -ne 0 ] ; then
  echo "Something went wrong downloading the files."
  exit 6
fi

SHA="$DIR/$FILENAME.sha1sums"
echo "CHECKING encrypted split sums"
sed -r "s/ .*\/(.+)/  \1/g" < $SHA | grep "gpg$" | bash -c "cd $DIR;sha1sum -c -"
if [ $? -ne 0 ] ; then
  echo "Encrypted split sums did not successfully verify."
  exit 7
fi

echo "OK: encrypted split sums"

echo "DECRYPTING"
ls -1 "$DIR/$FILENAME.split."*.gpg | xargs -n 1 -L 1 -r -I % -P $NUM_PARALLEL_GPG $GPG_BINARY --batch --passphrase-file $GPG_PASSPHRASE_FILE "%"
if [ $? -ne 0 ] ; then
  echo "Decrypting failed."
  exit 8
fi

echo "CHECKING decrypted split sums"
sed -r "s/ .*\/(.+)/  \1/g" < $SHA | egrep ".split.[0-9]+$" | bash -c "cd $DIR;sha1sum -c -"
if [ $? -ne 0 ] ; then
  echo "Decrypted split sums did not successfully verify."
  exit 9
fi

echo "DELETING encrypted splits"
ls -1 "$DIR/$FILENAME.split."*.gpg | xargs rm

echo "JOINING splits"
cat "$DIR/$FILENAME.split."* > "$DIR/$FILENAME"
if [ $? -ne 0 ] ; then
  echo "Joining failed."
  exit 10
fi

echo "CHECKING original file"
sed -r "s/ .*\/(.+)/  \1/g" < $SHA | egrep ".vma.(lzo|gz|bz2)$" | bash -c "cd $DIR;sha1sum -c -"
if [ $? -ne 0 ] ; then
  echo "Original file did not successfully verify."
  exit 11
fi

echo "DELETING decrypted splits"
rm "$DIR/$FILENAME.split."*

