# Agri Catalogue Service - Infrastructure and Deployment

## Overview

This repository contains the infrastructure-as-code and deployment scaffolding for the Agri Catalogue Service (internal codename VERG). It provides a standardized mechanism to provision cloud resources, bootstrap a Kubernetes cluster, and deploy the application alongside its required data services for User Acceptance Testing (UAT).

**Note:** This repository handles infrastructure and deployment only. The application source code is maintained in a separate repository.

## Architecture

The target architecture is a single-node Kubernetes cluster running on an AWS EC2 instance, fronted by Kong API Gateway.

```text
                    Internet
                       │
              AWS Security Group
        (TCP 22: Jenkins, TCP 30080: Open)
                       │
              EC2 Instance (Elastic IP)
   ┌───────────────────────────────────────────────┐
   │        Kubernetes (Kubespray, single node)    │
   │                                               │
   │   namespace: platform                         │
   │     └── Kong (NodePort :30080) ──────────────┐│
   │                                              ││
   │   namespace: app                             ▼│
   │     └── catalogue-service (ClusterIP :8080) ◄─┘
   │              │                                │
   │   namespace: data                             │
   │     ├── postgresql (ClusterIP :5432)          │
   │     ├── redis (ClusterIP :6379)               │
   │     └── elasticsearch (ClusterIP :9200)       │
   │                                               │
   │   storageClass: local-path (PVCs on local)    │
   └───────────────────────────────────────────────┘

Jenkins CI/CD ──SSH──> EC2 ──> helm upgrade
              └──push──> ECR ──> containerd pulls image
```

## Repository Structure

- `service.config.yaml`: The single source of truth for application deployment configuration (ports, health paths, environment variables).
- `terraform/`: Reusable infrastructure modules (`modules/k8s-node/`) and environment-specific instantiations (`environments/agri-catalogue/`).
- `helm/`: Parameterized Helm charts for deploying the application to Kubernetes.
- `jenkins/`: CI/CD pipeline definitions (`Jenkinsfile`).
- `scripts/`: Operational scripts for cluster setup, Kong route generation, and ECR token refresh.

## Prerequisites

- Terraform >= 1.5.0
- AWS CLI (configured with appropriate IAM permissions)
- `kubectl`
- Jenkins server (with `aws-credentials`, `docker-workflow`, and `ssh-agent` plugins)

## Setup and Deployment Guide

### 1. Infrastructure Provisioning

Navigate to the target environment and define your allowed IP ranges (e.g., restricting SSH access to your Jenkins server):

```bash
cd terraform/environments/agri-catalogue
terraform init
terraform apply
```

### 2. Cluster Bootstrapping

The orchestrator script handles the Kubespray installation and the deployment of the required data services (PostgreSQL, Redis, Elasticsearch).

```bash
./scripts/setup-cluster.sh agri-catalogue
```

### 3. Secrets Management

To maintain security, no sensitive credentials are stored in this repository.
1. Store your database and Elasticsearch passwords in your Jenkins credential manager as "Secret Text".
2. The Jenkins pipeline is responsible for securely reading these credentials and executing a script on the EC2 host to generate a Kubernetes Secret (`catalogue-service-secrets`).
3. The Helm chart dynamically mounts this Secret into the application container.

### 4. CI/CD Configuration

1. Create a Pipeline job in Jenkins pointing to the `jenkins/Jenkinsfile` in this repository.
2. Configure Jenkins to trigger upon pushes to the application repository.
3. Upon execution, Jenkins will:
   - Build the Docker image and push it to AWS ECR.
   - Inject the Kubernetes Secrets on the target host.
   - Execute `helm upgrade` over SSH to deploy the new image.

### 5. API Gateway Configuration

Kong is deployed in DB-less declarative mode. If the application's API surface changes, regenerate the Kong routing configuration based on the live OpenAPI specifications:

```bash
export KUBECONFIG=$PWD/scratch_kubeconfig
kubectl port-forward svc/catalogue-service -n app 8080:8080 &
./scripts/generate-kong-routes.sh http://localhost:8080
```

Deploy the updated configuration to Kong:
```bash
kubectl create configmap kong-config --from-file=kong.yml=kong/kong.yml -n platform -o yaml --dry-run=client | kubectl apply -f -
kubectl rollout restart deployment kong -n platform
```
