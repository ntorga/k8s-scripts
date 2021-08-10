#!/bin/bash
#
# @description  Restart deployments when there are new ECR images
# @author       Northon Torga <northontorga+github@gmail.com>
# @license      Apache License 2.0
# @requires     bash v4+
# @version      0.0.6
# @crontab      1-59/2 * * * * root bash /opt/deploy-manager/DeployManager.sh >/dev/null 2>&1
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
function isAlreadyRunning() {
    nPids=$(pgrep -cf DeployManager)
    if [[ "${nPids}" -le 1 ]]; then
        return 1
    fi
    return 0
}

function createLogsDir() {
    if [[ -d "${scriptDirectory}/logs" ]]; then
        return 0
    fi
    mkdir "${scriptDirectory}/logs"
}

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
if isAlreadyRunning; then exit 0; fi

createLogsDir

stage=$(getEnvVar STAGE)
export stage

stageDomain=$(getEnvVar STAGE_DOMAIN)
export stageDomain

awsRegion=$(getEnvVar AWS_REGION)
export awsRegion

awsAccessKeyId=$(getEnvVar AWS_ACCESS_KEY_ID)
export awsAccessKeyId

awsSecretAccessKey=$(getEnvVar AWS_SECRET_ACCESS_KEY)
export awsSecretAccessKey

readarray -t kubeDeployments < <(getEnvVar KUBE_DEPLOYMENTS)
export kubeDeployments

kubeNamespace=$(getEnvVar KUBE_NAMESPACE)
export kubeNamespace

slackWebhookSecret=$(getEnvVar SLACK_WEBHOOK)
export slackWebhookSecret

#
# General Methods
#
function awsCli() {
    AWS_ACCESS_KEY_ID="${awsAccessKeyId}" \
        AWS_SECRET_ACCESS_KEY="${awsSecretAccessKey}" \
        aws --region "${awsRegion}" \
        --color off \
        --output text \
        "${@}"
}

function sendSlackNotification() {
    notificationMessage="${*}"
    webhookUrl="https://hooks.slack.com/services/${slackWebhookSecret}"
    curl "${webhookUrl}" \
        --header "Content-type: application/json" \
        --data "{\"text\":\"${notificationMessage}\"}"
}

function logAction() {
    echo "[$(date -u +%FT%TZ)] ${1}" >>"${scriptDirectory}/logs/$(date -u +%F).log"
}

#
# ECR Methods
#
function listEcrImages() {
    ecrRepository="${1}"
    awsCli ecr list-images --repository-name "${ecrRepository}"
}

function getEcrImagesCount() {
    ecrRepository="${1}"
    listEcrImages "${ecrRepository}" | grep -c "IMAGEIDS"
}

function isValidEcrImageId() {
    imageId="${1}"
    imageIdRegex="[a-zA-Z0-9-_+.]+:[a-fA-F0-9]+"

    if ! echo "${imageId}" | grep -qP "${imageIdRegex}"; then
        return 1
    fi

    return 0
}

function getOutdatedEcrImageIds() {
    ecrRepository="${1}"

    readarray -t imageIdsRaw < <(listEcrImages "${ecrRepository}" | awk '!/latest/ {print $2}')
    imageIds=()

    for imageId in ${imageIdsRaw[*]}; do
        if ! isValidEcrImageId "${imageId}"; then continue; fi
        imageIds+=("${imageId}")
    done

    if [[ "${#imageIds[@]}" -le 0 ]]; then
        return
    fi

    echo "${imageIds[*]}"
}

function deleteOutdatedEcrImages() {
    ecrRepository="${1}"
    IFS=' ' read -ra imageIds < <(getOutdatedEcrImageIds "${ecrRepository}")

    if [[ "${#imageIds[@]}" -le 0 ]]; then
        logAction "Cleaning job started, but no outdated image was found to be deleted from '${deployment}' repository."
        return
    fi

    logAction "Image(s) '${imageIds[*]}' from '${deployment}' repository are going to be deleted now."

    for imageId in ${imageIds[*]}; do
        awsCli ecr batch-delete-image \
            --repository-name "${ecrRepository}" \
            --image-ids "imageDigest=${imageId}"
    done

    logAction "Deleted image(s) '${imageIds[*]}' from '${deployment}' repository."
}

function isThereNewEcrImage() {
    ecrRepository="${1}"
    imageCount=$(getEcrImagesCount "${ecrRepository}")
    if [[ "${imageCount}" -eq 1 ]]; then
        return 1
    fi
    return 0
}

#
# K8s Methods
#
function restartDeployment() {
    deployment="${1}"
    if ! kubectl rollout restart "deploy/${deployment}" -n "${kubeNamespace}"; then
        errorMessage="Unable to restart '${deployment}' deployment at '${stageDomain}' platform (${stage})."
        logAction "${errorMessage}"
        sendSlackNotification "${errorMessage}"
    fi
}

#
# Runtime
#
for deployment in ${kubeDeployments[*]}; do
    sleep 1
    ecrRepositoryName="${deployment}-${stage}"

    if ! isThereNewEcrImage "${ecrRepositoryName}"; then continue; fi
    logAction "Found outdated images of '${deployment}'."

    logAction "Restarting '${deployment}'."
    restartDeployment "${deployment}"

    logAction "Deleting outdated images of '${deployment}'."
    deleteOutdatedEcrImages "${ecrRepositoryName}"
done
