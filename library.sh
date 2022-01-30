
###
# Common backup library
##
set -Eeu
set -o pipefail

CUR_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
LOGFILE="${CUR_DIR}/backup.log"

OPENSSL_OPTS="-aes-256-ctr -e -salt -iter 1024"
TAR_OPTS="--one-file-system --warning=no-file-changed"
TAR_ARC_OPTS="-I 'xz -T4'"

LAST_PIPE=""

PID=$$

# log using own fd
exec 5> >(cat)
function outcho() {
  >&5 echo "Log: $1"
}
function errcho() {
  # log failure to log file
  echo "Error: $1" >> "${LOGFILE}"

  # write to STDERR and exit
  >&2 echo "$1"
  exit ${2:-1}
}

last_command=""
current_command=""
# keep track of the last executed command
set +u
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
set -u

# echo an error message before exiting
function last_error() {
  local EXIT_CODE=$?

  if [ "${EXIT_CODE}" -ne 0 ]; then
    errcho "\"${current_command}\" command failed(${EXIT_CODE})!."
  fi
}
trap last_error EXIT

trap 'errcho "sub-process failed!\n${current_command}"\n${last_command}"' SIGUSR1

function get_day() {
  local day=$(date +'%u')
  echo $day
}

function get_week() {
  local week=$(date +'%V')
  echo $week
}

function get_year() {
  local year=$(date +'%G')
  echo $year
}

function in_out() {
  local IN=$1
  cat < "${IN}"
}

function dev_null_sink() {
  local IN=$1

  dd of=/dev/null < $IN
  outcho "Upload done"
}

function handle_snar() {
  [[ "$#" -ne "1" ]] && errcho "'${FUNCNAME[0]}()' needs 1 arguments!" 2
  local TYPE=$1

  local SNAR_DIR="${CUR_DIR}/snar"
  [[ ! -d "${SNAR_DIR}" ]] && mkdir "${SNAR_DIR}"

  SNAR_FILE="${SNAR_DIR}/${TYPE}.snar"
  [[ ! -f "${SNAR_FILE}" ]] && \
    touch "${SNAR_FILE}" && echo "${SNAR_FILE}" && return

  # on Monday's clear snar file
  [[ "$(get_day)" -eq "1" ]] && \
    echo -n "" > "${SNAR_FILE}" && echo "${SNAR_FILE}" && return

  # check for outdated snat file
  local NOW_TS=$(date '+%s')
  local SNAR_TS=$(date -r "${SNAR_FILE}" '+%s')
  local SNAR_DIFF=$(($NOW_TS-$SNAR_TS))
  local SNAP_AGE_DAYS=$(($SNAR_DIFF/(3600*24)))
  [[ "${SNAP_AGE_DAYS}" -gt 6 ]] && echo -n "" > "${SNAR_FILE}"

  # check for same date execution
  [[ "${SNAP_AGE_DAYS}" -lt 1 ]] && errcho "Type: '${TYPE} - cannot backup multiple times per day - aborting!"

  echo "${SNAR_FILE}"
}

function kill_usr1() {
  local PID=$1
  if [ ! `ps $PID >/dev/null` ]; then
    return
  fi

  kill -SIGUSR1 $PID
}

function archive() {
  [[ "$#" -ne "2" ]] && errcho "'${FUNCNAME[0]}()' needs 2 arguments!" 2

  local SNAR_FILE=$1
  local SNAR_OPTS=''

  if [ "${SNAR_FILE}x" = "x" ]; then
    outcho "Info: No incremental backup!"
  else
    if [ ! -f "${SNAR_FILE}" ]; then
      errcho "${SNAR_FILE} does not exist - aborting!"
    fi
    SNAR_OPTS="--listed-incremental=${SNAR_FILE}"
  fi

  local DIR=$2
  [[ "${DIR}x" = "x" ]] && errcho "Empty dir - aborting"
  local dirs=''
  for archive_dir in ${DIR}; do
    [[ ! -e "${archive_dir}" ]] && errcho "${archive_dir} does not exist - aborting!"

    if [ -f "${archive_dir}" ]; then
      dirs+=" -C $(dirname ${archive_dir}) $(basename ${archive_dir})"
    else
      dirs+=" -C ${archive_dir} ."
    fi
  done

  tar ${TAR_OPTS} ${SNAR_OPTS} -I 'xz -2 -T6' -cf - $dirs
  outcho "Tar exited '$?'"
}

function encrypt() {
  if [ "$#" -ne "2" ]; then
    errcho "$0 needs 2 arguments!"
  fi

  local PASS_FILE=$1
  local IN=$2

  if [ "${PASS_FILE}x" = "x" ]; then
    errcho "No encryption password file given - aborting!"
  fi

  if [ ! -f "${PASS_FILE}" ]; then
    errcho "Encryption password file not found - aborting!"
  fi

  local PID=$$
  openssl enc ${OPENSSL_OPTS} -pass file:"${PASS_FILE}" -in - -out - <"${IN}"
}

function archive_inc() {
  echo $@
}

function upload_hetzner() {
  # clean up left-over temp dirs
  [[ -e "/tmp/bkp-*" ]] && rmdir /tmp/bkp-*

  [[ "$#" -ne "3" ]] && errcho "'${FUNCNAME[0]}()' needs 3 arguments!" 2

  local TYPE=$1
  local HOST=$2

  if [ "${TYPE}x" = "x" ]; then
    errcho 'No backup type given - aborting!'
  fi

  if [ "${HOST}x" = "x" ]; then
    errcho 'No backup host given - aborting!'
  fi

  local IN=$3

  local BKP_DIR="${TYPE}/$(get_year)/$(get_week)"
  local BKP_FILE="${TYPE}-$(get_day).tar.xz"
  local BKP_ID="${CUR_DIR}/.backup_id"
  if [ ! -f "${BKP_ID}" ]; then
    errcho "Backup SSH IdentityFile does not exist - aborting!"
  fi

  local TMP_DIR=$(mktemp -d -t bkp-XXXX)

  outcho "Mounting backup space."
  set +e
  sudo sshfs -o allow_other,IdentityFile="${BKP_ID}" ${HOST}:/ "${TMP_DIR}" || {
      rmdir "${TMP_DIR}"
      errcho "Unable to mount SSHFS - aborting!"
  }
  {
    cd "${TMP_DIR}"
    mkdir -p "./${BKP_DIR}"
    cd "./${BKP_DIR}"
    cat "${IN}" > "./${BKP_FILE}"
    cd "${CUR_DIR}"
  }
  sudo umount "${TMP_DIR}"
  set -e
  outcho "Done writing to '${BKP_DIR}/${BKP_FILE}'."
  rmdir "${TMP_DIR}"
  outcho "Remove temp-dir: '${TMP_DIR}'."
}

