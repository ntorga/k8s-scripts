#!/bin/bash
#
# @description  Synchronize ECR repos
# @author       Northon Torga <northontorga+github@gmail.com>
# @license      Apache License 2.0
# @requires     bash v4+, aws-cli v2, docker v20+
# @version      0.0.2
# @crontab      0 * * * * bash /opt/ecr-synchronizer/EcrSynchronizer.sh >/dev/null 2>&1
#

#
# Global Variables
#
export PATH="${PATH}:/usr/local/sbin:/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin:/root/bin"

scriptDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
export scriptDir

mainPid=$$
export mainPid

#
# Bootstrap Methods
#
function makeDirectories() {
    dirName="${1}"
    if [[ -d "${scriptDir}/${dirName}" ]]; then
        return 0
    fi
    mkdir "${scriptDir}/${dirName}"
}

function logAction() {
    echo "[$(date -u +%FT%TZ)] ${1}" >>"${scriptDir}/logs/$(date -u +%F).log"
}

trap "exit 1" TERM

function missingParam() {
    message="[FATAL] Missing param(s): ${*}"
    echo "${message}"
    logAction "${message}"
    kill -s TERM "${mainPid}"
}

function getEnvVar() {
    keyName="${1}"
    keyValue=$(grep -oP "(?<=^${keyName}\=)(.*)$" "${scriptDir}/.env" | tr -d "'\"")
    if [[ -z "${keyValue}" ]]; then
        missingParam ".env variable '${keyName}'"
    fi
    echo "${keyValue}"
}

#
# Bootstrap
#
makeDirectories "logs"
makeDirectories "locks"

ecrRepos=$(getEnvVar ECR_REPOS)

sourceAwsAccessKeyId=$(getEnvVar SOURCE_AWS_ACCESS_KEY_ID)
export sourceAwsAccessKeyId

sourceAwsSecretAccessKey=$(getEnvVar SOURCE_AWS_SECRET_ACCESS_KEY)
export sourceAwsSecretAccessKey

sourceAwsAccountId=$(getEnvVar SOURCE_AWS_ACCOUNT_ID)
export sourceAwsAccountId

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
    awsRegion="${2}"
    if [[ -z "${awsAccount}" ]]; then
        missingParam "[awsCli] awsAccount"
    fi

    if [[ -z "${awsRegion}" ]]; then
        missingParam "[awsCli] awsRegion"
    fi

    awsAccessKeyId="${sourceAwsAccessKeyId}"
    awsSecretAccessKey="${sourceAwsSecretAccessKey}"

    if [[ "${awsAccount}" = "target" ]]; then
        awsAccessKeyId="${targetAwsAccessKeyId}"
        awsSecretAccessKey="${targetAwsSecretAccessKey}"
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
    ecrRegion="${3}"
    ecrPassword=$(awsCli "${awsAccount}" "${ecrRegion}" ecr get-login-password)
    docker login --username AWS --password "${ecrPassword}" "${ecrRepository}"
}

function listEcrImages() {
    awsAccount="${1}"
    ecrRepositoryName="${2}"
    ecrRegion="${3}"

    awsAccountId="${sourceAwsAccountId}"
    if [[ "${awsAccount}" != "source" ]]; then
        awsAccountId="${targetAwsAccountId}"
    fi

    awsCli "${awsAccount}" "${ecrRegion}" \
        ecr list-images \
        --registry-id "${awsAccountId}" \
        --repository-name "${ecrRepositoryName}"
}

function getEcrImagesIds() {
    awsAccount="${1}"
    ecrRepositoryName="${2}"
    ecrRegion="${3}"
    listEcrImages "${awsAccount}" "${ecrRepositoryName}" "${ecrRegion}" | grep "IMAGEIDS"
}

function isThereNewEcrImage() {
    awsAccount="${1}"
    ecrRepositoryName="${2}"
    ecrRegion="${3}"
    imagesIds=$(getEcrImagesIds "${awsAccount}" "${ecrRepositoryName}" "${ecrRegion}")
    currentImagesIdsHash=$(echo "${imagesIds}" | md5sum)
    lockFilePath="${scriptDir}/locks/${awsAccount}-${ecrRepositoryName}-${ecrRegion}.hash"
    previousImagesIdsHash=$(cat "${lockFilePath}" 2>/dev/null || echo "0")

    if [[ "${currentImagesIdsHash}" -eq "${previousImagesIdsHash}" ]]; then
        return 1
    fi

    echo "${currentImagesIdsHash}" >"${lockFilePath}"
    return 0
}

#
# Runtime
#
for ecrRepo in ${ecrRepos[*]}; do
    ecrRepoRegion=$(echo "${ecrRepo}" | awk -F'|' '{print $1}')
    ecrRepoName=$(echo "${ecrRepo}" | awk -F'|' '{print $2}')

    sourceEcrDomain="${sourceAwsAccountId}.dkr.ecr.${ecrRepoRegion}.amazonaws.com"
    sourceEcrRepoUrl="${sourceEcrDomain}/${ecrRepoName}"

    if ! isThereNewEcrImage "source" "${ecrRepoName}" "${ecrRepoRegion}"; then
        continue
    fi

    if ! ecrLogin "source" "${sourceEcrDomain}" "${ecrRepoRegion}" 2>/dev/null; then
        logAction "[WARN] Unable to login into source repository: ${ecrRepoName}."
        continue
    fi

    logAction "[INFO] New image found for '${ecrRepoName}' repository, synching..."

    docker pull "${sourceEcrRepoUrl}"

    targetEcrDomain="${targetAwsAccountId}.dkr.ecr.${targetAwsRegion}.amazonaws.com"
    targetEcrRepoUrl="${targetEcrDomain}/${ecrRepoName}"

    docker tag "${sourceEcrRepoUrl}" "${targetEcrRepoUrl}"

    if ! ecrLogin "target" "${targetEcrDomain}" "${targetAwsRegion}" 2>/dev/null; then
        logAction "[WARN] Unable to login into target repository: ${ecrRepoName}."
        continue
    fi

    docker push "${targetEcrRepoUrl}"
done
