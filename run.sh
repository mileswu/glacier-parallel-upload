PART_SIZE=1048576

UPLOAD_ID=$(aws glacier initiate-multipart-upload --account-id - --vault-name test  --archive-description "test1" --part-size $PART_SIZE | jq -r .uploadId)

UPLOAD_FILE="upload.data"
FILE_SIZE=$(wc -c < $UPLOAD_FILE)

LAST_PART_NUM=$(($FILE_SIZE / $PART_SIZE));
if [ $(($FILE_SIZE % $PART_SIZE)) -eq 0 ]; then
  LAST_PART_NUM=$(expr $LAST_PART_NUM - 1)
fi

for PART_NUM in `seq 0 $LAST_PART_NUM`; do
  START_BYTES=$(($PART_NUM * $PART_SIZE))
  PART_SHA256=$(tail -c +$(($START_BYTES + 1)) $UPLOAD_FILE | head -c $PART_SIZE | openssl dgst -sha256 | cut -d ' ' -f 2)
  TREEHASH[$PART_NUM]=$PART_SHA256
done

while [ ${#TREEHASH[@]} -gt 1 ]; do
  TREE_LENGTH=${#TREEHASH[@]}
  NUM_PAIRS=$(($TREE_LENGTH / 2))
  for i in `seq 0 $(($NUM_PAIRS - 1))`; do
    NEWTREEHASH[$i]="$(echo -n ${TREEHASH[$(($i*2))]}${TREEHASH[$(($i*2 + 1))]} | xxd -r -p | openssl dgst -sha256 | cut -d ' ' -f 2)"
  done
  if [ $((TREE_LENGTH % 2)) -eq 1 ]; then
    NEWTREEHASH+=("${TREEHASH[-1]}")
  fi
  TREEHASH=("${NEWTREEHASH[@]}")
  unset NEWTREEHASH
done

TREEHASH=$(echo -n "${TREEHASH[0]}")

do_upload() {
  PART_NUM=$1
  START_BYTES=$(($PART_NUM * $PART_SIZE))
  END_BYTES=$(($START_BYTES + $PART_SIZE - 1))
  if [ $END_BYTES -ge $(($FILE_SIZE - 1)) ]; then
    END_BYTES=$(($FILE_SIZE - 1))
  fi
  TMPFILE=$(mktemp)

  echo $START_BYTES-$END_BYTES

  tail -c +$(($START_BYTES + 1)) $UPLOAD_FILE | head -c $PART_SIZE > $TMPFILE
  aws glacier upload-multipart-part  --account-id - --vault-name test --upload-id $UPLOAD_ID --body $TMPFILE --range "bytes ${START_BYTES}-${END_BYTES}/*" > /dev/null

  rm $TMPFILE
}
export -f do_upload
export PART_SIZE
export FILE_SIZE
export UPLOAD_FILE
export UPLOAD_ID

parallel --no-notice -j 10 --bar do_upload ::: $(seq 0 $LAST_PART_NUM)

echo $UPLOAD_ID
echo $FILE_SIZE
echo $TREEHASH

aws glacier complete-multipart-upload --account-id - --vault-name test --upload-id $UPLOAD_ID --checksum $TREEHASH --archive-size $FILE_SIZE
