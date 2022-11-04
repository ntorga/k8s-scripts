#!/bin/bash
#
# @description  Restarts deployments when there are new ECR images
# @author       Northon Torga <northontorga+github@gmail.com>
# @license      Apache License 2.0
# @requires     bash v4+, aws cli v2.1+, curl 7.76+
# @version      1.0.0
# @crontab      1-59/2 * * * * bash /opt/deploy-manager/DeployManager.sh >/dev/null 2>&1
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
function isRunningViaCron() {
    if [[ -t 1 ]]; then
        return 1
    fi
    return 0
}

function isAlreadyRunning() {
    nPids=$(pgrep -cf "${BASH_SOURCE[0]}")
    maxPids=1
    if isRunningViaCron; then
        maxPids=2
    fi
    if [[ "${nPids}" -le "${maxPids}" ]]; then
        return 1
    fi
    return 0
}

function createLogsDir() {
    if [[ -d "${scriptDir}/logs" ]]; then
        return 0
    fi
    mkdir "${scriptDir}/logs"
}

trap "exit 1" TERM

function missingParam() {
    echo "[FATAL] Missing param(s):" "${@}"
    kill -s TERM "${mainPid}"
}

function getEnvVar() {
    keyName="${1}"
    isOptional="${2}"
    keyValue=$(grep -oP "(?<=^${keyName}\=)(.*)$" "${scriptDir}/.env" | tr -d "'\"")
    if [[ -z "${keyValue}" && -z "${isOptional}" ]]; then
        missingParam ".env variable '${keyName}'"
    fi
    echo "${keyValue}"
}

#
# Bootstrap
#
if isAlreadyRunning; then exit 0; fi

createLogsDir

stage=$(getEnvVar STAGE true)
export stage

appDomain=$(getEnvVar APP_DOMAIN true)
if [[ -z "${appDomain}" ]]; then
    appDomain=$(getEnvVar STAGE_DOMAIN true)
fi
if [[ -z "${appDomain}" ]]; then
    appDomain="KubernetesCluster"
fi
export appDomain

awsRegion=$(getEnvVar AWS_REGION)
export awsRegion

awsAccessKeyId=$(getEnvVar AWS_ACCESS_KEY_ID)
export awsAccessKeyId

awsSecretAccessKey=$(getEnvVar AWS_SECRET_ACCESS_KEY)
export awsSecretAccessKey

readarray -t kubeDeployments < <(getEnvVar KUBE_DEPLOYMENTS)
export kubeDeployments

kubeNamespace=$(getEnvVar KUBE_NAMESPACE true)
export kubeNamespace

slackWebhookSecret=$(getEnvVar SLACK_WEBHOOK true)
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
    if [[ -z "${slackWebhookSecret}" ]]; then
        return
    fi
    notificationMessage="${*}"
    webhookUrl="https://hooks.slack.com/services/${slackWebhookSecret}"
    curl "${webhookUrl}" \
        --header "Content-type: application/json" \
        --data "{\"text\":\"[DeployManager] ${notificationMessage}\"}"
}

function logAction() {
    echo "[$(date -u +%FT%TZ)] ${1}" >>"${scriptDir}/logs/$(date -u +%F).log"
}

function isDeploymentDoubleNamed() {
    deployName="${1}"

    if ! echo "${deployName}" | grep -q '|' 2>/dev/null; then
        return 1
    fi

    return 0
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

    if ! echo "${imageId}" | grep -qP "${imageIdRegex}" 2>/dev/null; then
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
        logAction "No outdated image was found on '${deploy}' repository."
        return
    fi

    logAction "Image(s) '${imageIds[*]}' from '${deploy}' repository are going to be deleted now."

    for imageId in ${imageIds[*]}; do
        awsCli ecr batch-delete-image \
            --repository-name "${ecrRepository}" \
            --image-ids "imageDigest=${imageId}"
    done

    logAction "Deleted image(s) '${imageIds[*]}' from '${deploy}' repository."
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
function restartDeploy() {
    deploy="${1}"
    kubeNamespace="${2}"
    if [[ -z "${kubeNamespace}" ]]; then
        kubeNamespace=$(kubectl get deployments --all-namespaces | awk "/${deploy}/{print \$1}")
    fi

    if ! kubectl rollout restart "deploy/${deploy}" -n "${kubeNamespace}"; then
        errorMessage="Unable to restart '${deploy}' deploy at '${appDomain}' platform (${stage})."
        logAction "${errorMessage}"
        sendSlackNotification "${errorMessage}"
    fi
}

#
# Runtime
#
for deploy in ${kubeDeployments[*]}; do
    deployName="${deploy}"
    ecrRepositoryName="${deploy}"
    if [[ -n "${stage}" ]]; then
        ecrRepositoryName="${deploy}-${stage}"
    fi

    if isDeploymentDoubleNamed "${deploy}"; then
        deployName=$(echo "${deploy}" | awk -F'|' '{print $1}')
        ecrRepositoryName=$(echo "${deploy}" | awk -F'|' '{print $2}')
        kubeNamespace=$(echo "${deploy}" | awk -F'|' '{print $3}')
    fi

    if ! isThereNewEcrImage "${ecrRepositoryName}"; then continue; fi
    logAction "Found outdated images on '${ecrRepositoryName}'."

    logAction "Restarting '${deploy}'."
    restartDeploy "${deployName}" "${kubeNamespace}"

    logAction "Deleting outdated images on '${ecrRepositoryName}'."
    deleteOutdatedEcrImages "${ecrRepositoryName}"
done
