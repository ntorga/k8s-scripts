#!/bin/bash
#
# @description  Synchronize an external registry with ECR
# @author       Northon Torga <northontorga+github@gmail.com>
# @license      Apache License 2.0
# @requires     bash v4+
# @version      0.0.1
# @crontab      0 * * * * bash /opt/ecr-synchronizer/EcrSynchronizer.sh >/dev/null 2>&1
#

#
# Global Variables
#
export PATH="${PATH}:/usr/local/sbin:/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin:/root/bin"

scriptDirectory=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
export scriptDirectory

mainPid=$$
export mainPid

#
# Bootstrap Methods
#
function createLogsDir() {
    if [[ -d "${scriptDirectory}/logs" ]]; then
        return 0
    fi
    mkdir "${scriptDirectory}/logs"
}

function logAction() {
    echo "[$(date -u +%FT%TZ)] ${1}" >>"${scriptDirectory}/logs/$(date -u +%F).log"
}

trap "exit 1" TERM

function missingParam() {
    message="[FATAL] Missing param(s): ${*}"
    echo "${message}"
    logAction "${message}"
    kill -s TERM "${mainPid}"
}

function getEnvVar() {
    requestedVar="${1}"
    requestedVarValue=$(grep -P "^${requestedVar}(?=\=)" "${scriptDirectory}/.env" | awk -F'=' '{print $2}')
    if [[ -z "${requestedVarValue}" ]]; then
        missingParam ".env variable '${requestedVar}'"
    fi
    echo "${requestedVarValue}"
}

#
# Bootstrap
#
createLogsDir

ecrRepoNames=$(getEnvVar ECR_REPO_NAMES)

sourceAwsAccessKeyId=$(getEnvVar SOURCE_AWS_ACCESS_KEY_ID)
export sourceAwsAccessKeyId

sourceAwsSecretAccessKey=$(getEnvVar SOURCE_AWS_SECRET_ACCESS_KEY)
export sourceAwsSecretAccessKey

sourceAwsAccountId=$(getEnvVar SOURCE_AWS_ACCOUNT_ID)
export sourceAwsAccountId

sourceAwsRegion=$(getEnvVar SOURCE_AWS_REGION)
export sourceAwsRegion

targetAwsAccessKeyId=$(getEnvVar TARGET_AWS_ACCESS_KEY_ID)
export targetAwsAccessKeyId

targetAwsSecretAccessKey=$(getEnvVar TARGET_AWS_SECRET_ACCESS_KEY)
export targetAwsSecretAccessKey

targetAwsAccountId=$(getEnvVar TARGET_AWS_ACCOUNT_ID)
export targetAwsAccountId

targetAwsRegion=$(getEnvVar TARGET_AWS_REGION)
export targetAwsRegion

#
# General Methods
#
function awsCli() {
    awsAccount="${1}"
    if [[ -z "${awsAccount}" ]]; then
        missingParam "[awsCli] awsAccount"
    fi

    awsAccessKeyId="${sourceAwsAccessKeyId}"
    awsSecretAccessKey="${sourceAwsSecretAccessKey}"
    awsRegion="${sourceAwsRegion}"

    if [[ "${awsAccount}" = "target" ]]; then
        awsAccessKeyId="${targetAwsAccessKeyId}"
        awsSecretAccessKey="${targetAwsSecretAccessKey}"
        awsRegion="${targetAwsRegion}"
    fi

    AWS_ACCESS_KEY_ID="${awsAccessKeyId}" \
        AWS_SECRET_ACCESS_KEY="${awsSecretAccessKey}" \
        aws --region "${awsRegion}" \
        --color off \
        --output text \
        "${@:3}"
}

#
# ECR Methods
#
function ecrLogin() {
    awsAccount="${1}"
    ecrRepository="${2}"
    ecrPassword=$(awsCli "${awsAccount}" ecr get-login-password)
    docker login --username AWS --password "${ecrPassword}" "${ecrRepository}"
}

function listEcrImages() {
    awsAccount="${1}"
    ecrRepository="${2}"
    awsCli "${awsAccount}" ecr list-images --repository-name "${ecrRepository}"
}

function getEcrImagesCount() {
    awsAccount="${1}"
    ecrRepository="${2}"
    listEcrImages "${awsAccount}" "${ecrRepository}" | grep -c "IMAGEIDS"
}
function isThereNewEcrImage() {
    awsAccount="${1}"
    ecrRepository="${2}"
    imageCount=$(getEcrImagesCount "${awsAccount}" "${ecrRepository}")
    if [[ "${imageCount}" -eq 1 ]]; then
        return 1
    fi
    return 0
}

#
# Runtime
#
for ecrRepoName in ${ecrRepoNames[*]}; do
    sourceEcrDomain="${sourceAwsAccountId}.dkr.ecr.${sourceAwsRegion}.amazonaws.com"
    sourceEcrRepoUrl="${sourceEcrDomain}/${ecrRepoName}"

    if ! isThereNewEcrImage "source" "${sourceEcrRepoUrl}"; then
        continue
    fi

    if ! ecrLogin "source" "${sourceEcrDomain}" 2>/dev/null; then
        logAction "[WARN] Unable to login into source repository: ${ecrRepoName}."
        continue
    fi

    logAction "[INFO] New image found for '${ecrRepoName}' repository, synching..."

    docker pull "${sourceEcrRepoUrl}"

    targetEcrDomain="${targetAwsAccountId}.dkr.ecr.${targetAwsRegion}.amazonaws.com"
    targetEcrRepoUrl="${targetEcrDomain}/${ecrRepoName}"

    docker tag "${sourceEcrRepoUrl}" "${targetEcrRepoUrl}"

    if ! ecrLogin "target" "${sourceEcrDomain}" 2>/dev/null; then
        logAction "[WARN] Unable to login into target repository: ${ecrRepoName}."
        continue
    fi

    docker push "${targetEcrRepoUrl}"
done
