#!/bin/bash
#
# @description  Update ECR Secret on K8s
# @author       Northon Torga <northontorga+github@gmail.com>
# @license      Apache License 2.0
# @requires     bash v4+
# @version      0.0.3
# @crontab      0 */12 * * * root bash /opt/ecr-secret-updater/EcrSecretUpdater.sh >/dev/null 2>&1
#

#
# Global Variables
#
export PATH="${PATH}:/usr/local/sbin:/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin:/root/bin"

scriptDirectory=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
export scriptDirectory

mainPid=$$
export mainPid

kubectlBinary='kubectl'

#
# Bootstrap Methods
#
trap "exit 1" TERM

function missingParam() {
    echo "[FATAL] Missing param(s):" "${@}"
    kill -s TERM "${mainPid}"
}

function getEnvVar() {
    requestedVar="${1}"
    requestedVarValue=$(grep "${requestedVar}" "${scriptDirectory}/.env" | awk -F'"' '{print $2}')
    if [[ -z "${requestedVarValue}" ]]; then
        missingParam ".env variable '${requestedVar}'"
    fi
    echo "${requestedVarValue}"
}

#
# Bootstrap
#
awsAccountId=$(getEnvVar AWS_ACCOUNT_ID)

awsRegion=$(getEnvVar AWS_REGION)

projectName=$(getEnvVar PROJECT_NAME)

dockerMail=$(getEnvVar DOCKER_MAIL)

#
# Runtime
#
secretName="${projectName}-aws-ecr-${awsRegion}"

if ${kubectlBinary} get secret "${secretName}" >/dev/null 2>&1; then
    echo "Secret exists, deleting..."
    ${kubectlBinary} delete secrets "${secretName}"
fi

ecrPassword=$(aws ecr get-login-password --region "${awsRegion}")
${kubectlBinary} create secret docker-registry "${secretName}" \
    --docker-server="${awsAccountId}.dkr.ecr.${awsRegion}.amazonaws.com" \
    --docker-username=AWS \
    --docker-password="${ecrPassword}" \
    --docker-email="${dockerMail}"
