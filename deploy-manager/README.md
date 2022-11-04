# Deploy Manager

The DeployManager is a simple bash CI/CD utility designed to restart Kubernetes services automatically based on new available AWS ECR image.

It is able to do 3 specific taks:

1. Restart Kubernetes deployments whenever there is a new ECR image for a service;
2. Housekeep ECR repositories leaving only the last image available;
3. Execute pre and post commands/scripts before restarting the service.

## Environment Variables

You must create a `.env` file before executing it. Here's the explaination of each env variable:

```
STAGE="" # => [optional] Used as a suffix of a service name (for example: hom, prod, dev).
APP_DOMAIN="" # => [optional] The application domain name.
AWS_REGION=""
AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""
KUBE_DEPLOYMENTS="" # => Spaced-separated name of the K8s deployments.
KUBE_NAMESPACE="" # => [optional] Namespace of the services.
SLACK_WEBHOOK="" # => [optional] Slack Webhook URL.
```

## ECR Repository Name & K8s Namespace

The ECR repository name must match the service name precisely. If in your case it does not, you need to provide the deployment name on "KUBE_DEPLOYMENTS" variable with a pipe, i.e: `k8s-deployment-name|ecr-repo-name`.

The "KUBE_NAMESPACE" is optional because the script will try to find the namespace based on the service name. However, in case of different namespaced services with the exact same name, you must provide the deployment name on "KUBE_DEPLOYMENTS" variable afte the ECR name, i.e.: `ks8-deployment-name|ecr-repo-name|k8s-namespace`.

Both of these pipe-separated-workaround are performed on a service-base, so you can have a variable such as:

```
KUBE_DEPLOYMENTS="service1 service2|service2-crazy-ecr-name service3 service4|service4|different-namespace"
```

## Pre & Post Scripts

These kind of scripts are useful when you need to run end2end tests, allow an IP, notify a channel, etc.

To configure them, you must provide the following env variables:

```
PRE_SCRIPT="deployment-name|script-you-want-to-run-base64-encoded"
POST_SCRIPT="deployment-name|script-you-want-to-run-base64-encoded"
```

PRE_SCRIPTS are run before a restart and POST_SCRIPTS after the restart.

Let's say you want to run "bash /opt/endtest/EndtestStarter.sh" BEFORE a service named "users-api" gets restarted. Therefore you would have:

```
PRE_SCRIPT="users-api|YmFzaCAvb3B0L2VuZHRlc3QvRW5kdGVzdFN0YXJ0ZXIuc2g="
```

We encode the command in base64 format so you can pass multiple args without breaking the script.

By default, the timeout for executing scripts is 300 seconds, but you can change this by using the following variable on `.env`:

```
SCRIPTS_TIMEOUT=600
```
