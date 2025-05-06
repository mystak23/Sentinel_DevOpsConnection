# Note

Since the Microsoft updated Service Connection creation in Azure DevOps, the script does NOT generate fully functioning Service Principal with Federated Credential. Manual Issuer and Claims insertion is needed after the script is executed. The script will be fixed.

# Author

Matěj Hrabálek -- https://www.linkedin.com/in/matejhrabalek/

# 📌 Sentinel DevOps Connection

This repository contains script for automatic Microsoft Sentinel deployment.

## 📂 Repository Structure

- **`./SentinelDevOps.ps1`** – Contains export templates and files related to Logic Apps.

## 📌 What the script is doing

The `SentinelDevops.ps1` script performs a full Microsoft Sentinel - Azure DevOps integration.

These parameters are general and might be modified in the script:
   - **Location:** North Europe
   - **Tier:** Pay-as-you-go

The script is working in **two** tenants -- the customer, in which the Microsoft Sentinel is located, and the DevOps tenant, in which the Azure DevOps will be deployed. 

1. 🚀 **Create the Microsoft Entra ID application**  
   - Creates the Microsoft Entra ID application in the customer tenant
   - Creates the federated credential

2. 🛠️ **Create the DevOps**  
   - Creates the DevOps repository
   - Creates the DevOps service connection connected to the application federated credential
   - Creates the DevOps pipeline 

# 🚀 Deployment Guide

## 1️⃣ Prerequisites

Ensure you have the following:
- **Microsoft Sentinel** with appropriate permissions.
- **Owner** permissions on the target Azure subscription
- **PowerShell 7+** (for executing `.ps1` scripts).
- **Azure DevOps** license
-  **`./DevOps.json`** file for customer-specific values - or change the script
-  **`./.devops-pipeline`** folder, which contains `pipeline.yml` pipeline file
- **PAT** (Personal Access Token) in Azure DevOps

## 2️⃣ Deployment Steps

### 1️⃣ Run the script

Run the script

`./SentinelDevOps.ps1`

### 2️⃣ Manage the logins

#### 1️⃣ Execute the customer-part script
- Log in in the **customer** tenant, where the Microsoft Entra ID will be deployed.

#### 2️⃣ Execute the DevOps-part script
- Log in in the tenant, where the DevOps repository, Service Connection and pipeline will be created.

### 3️⃣ Run the pipeline

#### 1️⃣ Grant pipeline the permission
- Click on the pipeline and grant the permission

#### 2️⃣ Move all content to the customer repository with the following structure
- **`1-Watchlists\`** – Watchlists
- **`2-Parsers\`** – Parsers
- **`3-HuntingQueries\`** – HuntingQueries
- **`4-AnalyticRules\`** – AnalyticRules
- **`5-AutomationRules\`** – AutomationRules
- **`6-Playbooks\`** – Playbooks
- **`7-Workbooks\`** – Workbooks
- **`8-DataCollectionRules\`** – DataCollectionRules




