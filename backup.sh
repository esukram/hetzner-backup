#!/usr/bin/env bash

set -euo pipefail

function usage() {
  echo "Usage: $0 -t TYPE -d DIR -h HOST" 1>&2
  exit 1
}

TYPE=''
DIR=''
HOST=''
while getopts 't:d:h:' opt; do
  case "${opt}" in
    t)
      TYPE=${OPTARG}
      ;;
    d)
      DIR=${OPTARG}
      [[ -d "${DIR}" ]] || ( echo "Directory '${DIR}' does not exist - abort!" && exit 2 )
      ;;
    h)
      HOST=${OPTARG}
      ;;
    *)
      usage
      ;;
  esac
done

[[ "${TYPE}x" = "x" || "${DIR}x" = "x" || "${HOST}x" = "x" ]] && usage

CUR_DIR=$(dirname $0)
PASS_FILE="${CUR_DIR}/.pass-file"

lib_file='library.sh'
lib_path="${CUR_DIR}/${lib_file}"
[[ ! -e "${lib_path}" ]] && \
  (echo "Library (${lib_path}) does not exist!"; exit 1)
source "${lib_path}"

SNAR_FILE=$(handle_snar "${TYPE}")

upload_hetzner "${TYPE}" "${HOST}" <(
    ( encrypt "${PASS_FILE}" <(
      (archive "${SNAR_FILE}" "${DIR}") || kill_usr1 $$ )
    ) || kill_usr1 $$
  ) || kill_usr1 $$

