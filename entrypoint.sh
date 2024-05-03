#!/bin/bash -l

set -e

validate() {
  # mandatory params
  : DEPLOY_SSHG_KEY_PRIVATE="${DEPLOY_SSHG_KEY_PRIVATE:?'DEPLOY_SSHG_KEY_PRIVATE variable missing from Repo or Workspace variables.'}"
  : DEPLOY_SSH_HOST="${DEPLOY_SSH_HOST:?'Missing deployment ssh host'}"
  : DEPLOY_SSH_USER="${DEPLOY_SSH_USER:?'Missing deployment ssh user'}"
  : DEPLOY_SITE_DIR="${DEPLOY_SITE_DIR:?'Missing deployment project directory'}"
  # optional params
  : DEPLOY_SSH_PORT="${DEPLOY_SSH_PORT:="22"}"
  : REMOTE_PATH="${REMOTE_PATH:=""}"
  : SRC_PATH="${SRC_PATH:="."}"
  : FLAGS="${FLAGS:="-azvr --inplace --exclude=".*""}"
  : PHP_LINT="${PHP_LINT:="FALSE"}"
  : CACHE_CLEAR="${CACHE_CLEAR:="FALSE"}"
  : SCRIPT="${SCRIPT:=""}"
  : PREDEPLOY_SCRIPT="${PREDEPLOY_SCRIPT:=""}"
}

setup_env() {
  if [[ -n ${GITHUB_ACTIONS} ]]; then
      CICD_VENDOR="wpe_gha";
    elif [[ -n ${BITBUCKET_BUILD_NUMBER} ]]; then
      CICD_VENDOR="wpe_bb";
    else CICD_VENDOR="wpe_cicd"
  fi

  echo "Deploying your code to:"
  echo "${DEPLOY_SITE_DIR}"

  DIR_PATH="${REMOTE_PATH}"

  # Set up host and path
  DEPLOY_FULL_HOST="${DEPLOY_SSH_USER}"@"${DEPLOY_SSH_HOST}"
  DEPLOY_DESTINATION="${DEPLOY_FULL_HOST}:~/${DEPLOY_SITE_DIR}"/"${DIR_PATH}"
}

setup_ssh_dir() {
  echo "setup ssh path"

  SSH_PATH="${HOME}/.ssh"
  if [ ! -d "${HOME}/.ssh" ]; then
      mkdir "${HOME}/.ssh"
      mkdir "${SSH_PATH}/ctl/"
      # Set Key Perms
      chmod -R 700 "$SSH_PATH"
    else
      echo "using established SSH KEY path...";
      mkdir -p "${HOME}/.ssh/ctl"
  fi

  # Check if control directory exists
  if [ ! -d "${HOME}/.ssh/ctl" ]; then
    echo "Creating control directory..."
    mkdir -p "${HOME}/.ssh/ctl"
  fi

  #Copy secret keys to container
  DEPLOY_SSHG_KEY_PRIVATE_PATH="${SSH_PATH}/deploy_id_rsa"

  if [ "${CICD_VENDOR}" == "wpe_bb" ]; then
    # Only Bitbucket keys require base64 decode
    umask  077 ; echo "${DEPLOY_SSHG_KEY_PRIVATE}" | base64 -d > "${DEPLOY_SSHG_KEY_PRIVATE_PATH}"
    else umask  077 ; echo "${DEPLOY_SSHG_KEY_PRIVATE}" > "${DEPLOY_SSHG_KEY_PRIVATE_PATH}"
  fi

  chmod 600 "${DEPLOY_SSHG_KEY_PRIVATE_PATH}"
  #establish knownhosts
  KNOWN_HOSTS_PATH="${SSH_PATH}/known_hosts"
  ssh-keyscan -p "${DEPLOY_SSH_PORT}" -t rsa "${DEPLOY_SSH_HOST}" >> "${KNOWN_HOSTS_PATH}"
  chmod 644 "${KNOWN_HOSTS_PATH}"
}

check_lint() {
  if [ "${PHP_LINT^^}" == "TRUE" ]; then
      echo "Begin PHP Linting."
      find "$SRC_PATH"/ -name "*.php" -type f -print0 | while IFS= read -r -d '' file; do
          php -l "$file"
          status=$?
          if [[ $status -ne 0 ]]; then
              echo "FAILURE: Linting failed - $file :: $status" && exit 1
          fi
      done
      echo "PHP Lint Successful! No errors detected!"
  else
      echo "Skipping PHP Linting."
  fi
}

check_cache() {
  if [ "${CACHE_CLEAR^^}" == "TRUE" ]; then
      CACHE_CLEAR="&& wp --skip-plugins --skip-themes page-cache flush && wp --skip-plugins --skip-themes cdn-cache flush"
    elif [ "${CACHE_CLEAR^^}" == "FALSE" ]; then
        CACHE_CLEAR=""
    else echo "CACHE_CLEAR value must be set as TRUE or FALSE only... Cache not cleared..."  && exit 1;
  fi
}

# Pre-deploy script
predeploy_script() {
  if [[ -n ${PREDEPLOY_SCRIPT} ]]; then
      cd "${SRC_PATH}" || { echo "Failed to change directory to ${SRC_PATH}"; exit 1; }
      echo "Running pre-deploy script: ${PREDEPLOY_SCRIPT}"
      # Execute predeploy script here not remotely, because we have node and npm installed here
      bash "${PREDEPLOY_SCRIPT}"
    else echo "No pre-deploy script to run."
  fi
}

sync_files() {
  #create multiplex connection
  echo "Attempt multiplex connection"
  ssh -nNf -v -i "${DEPLOY_SSHG_KEY_PRIVATE_PATH}" -o StrictHostKeyChecking=no -o ControlMaster=yes -o ControlPath="$SSH_PATH/ctl/%C" -p "${DEPLOY_SSH_PORT}" "$DEPLOY_FULL_HOST"
  echo "!!! MULTIPLEX SSH CONNECTION ESTABLISHED !!!"

  # shellcheck disable=SC2086
  echo "Syncing files"
  rsync --rsh="ssh -v -p ${DEPLOY_SSH_PORT} -i ${DEPLOY_SSHG_KEY_PRIVATE_PATH} -o StrictHostKeyChecking=no -o 'ControlPath=$SSH_PATH/ctl/%C'" ${FLAGS} --exclude-from='/exclude.txt' --chmod=D775,F664 "${SRC_PATH}" "${DEPLOY_DESTINATION}"

  #if script or cache is set
  if [[ -n ${SCRIPT} || -n ${CACHE_CLEAR} ]]; then

	  # Script to run post deployment
      if [[ -n ${SCRIPT} ]]; then
        if ! ssh -v -p ${DEPLOY_SSH_PORT} -i "${DEPLOY_SSHG_KEY_PRIVATE_PATH}" -o StrictHostKeyChecking=no -o ControlPath="$SSH_PATH/ctl/%C" "$DEPLOY_FULL_HOST" "test -s ${DEPLOY_SITE_DIR}/${SCRIPT}"; then
          status=1
        fi

        if [[ $status -ne 0 && -f ${SCRIPT} ]]; then
		  echo "transfer script"
          ssh -v -p ${DEPLOY_SSH_PORT} -i "${DEPLOY_SSHG_KEY_PRIVATE_PATH}" -o StrictHostKeyChecking=no -o ControlPath="$SSH_PATH/ctl/%C" "$DEPLOY_FULL_HOST" "mkdir -p ${DEPLOY_SITE_DIR}/$(dirname "${SCRIPT}")"

          rsync --rsh="ssh -v -p ${DEPLOY_SSH_PORT} -i ${DEPLOY_SSHG_KEY_PRIVATE_PATH} -o StrictHostKeyChecking=no -o 'ControlPath=$SSH_PATH/ctl/%C'" "${SCRIPT}" "$DEPLOY_FULL_HOST:$DEPLOY_SITE_DIR/$(dirname "${SCRIPT}")"
        fi
      fi

      if [[ -n ${SCRIPT} ]]; then
        SCRIPT="&& bash ${SCRIPT}"
      fi

	  echo "run script and run attempt wp cache clear"
      ssh -v -p ${DEPLOY_SSH_PORT} -i "${DEPLOY_SSHG_KEY_PRIVATE_PATH}" -o StrictHostKeyChecking=no -o ControlPath="$SSH_PATH/ctl/%C" "$DEPLOY_FULL_HOST" "cd ${DEPLOY_SITE_DIR} ${SCRIPT} ${CACHE_CLEAR}"
  fi

  #close multiplex connection
  ssh -O exit -o ControlPath="$SSH_PATH/ctl/%C" "$DEPLOY_FULL_HOST"
  echo "closing ssh connection..."
}

validate
setup_env
setup_ssh_dir
check_lint
# predeploy_script
# check_cache
sync_files
