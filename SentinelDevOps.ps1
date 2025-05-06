# ===============================================================================
# PARAMETERS 
# ===============================================================================
# Load configuration files
$generalConfigPath = "values/DevOps.json"
$generalConfig = Get-Content $generalConfigPath | ConvertFrom-Json
$serviceConnectionConfigPath = "values/ServiceConnection.json"

# Customer information
$customer = Read-Host "Enter customer name" #"TEST" 
$customerTenantId = Read-Host "Enter customer Tenant ID" #fec3a0fa-64ae-446f-a3a6-2b0eeae14c73
$customerSubscriptionId = Read-Host "Enter customer Subscription ID" #66a13036-966e-4910-83ec-b28bc1a66923
$customerResourceGroupName = Read-Host "Enter customer Resource Group name" # "RG-Test1828" 
$customerWorkspaceName = Read-Host "Enter customer Log Analytics Workspace name" #"RG-Test1828" 

# DevOps information
$customerApplicationName = $generalConfig.applicationName
$pat = $generalConfig.pat
$projectName = $generalConfig.projectName
$repoName = "$($generalConfig.repoName)-$customer"
$devOpsOrg = $generalConfig.devOpsOrg
$devOpsOrgUrl = $generalConfig.devOpsOrgUrl
$devOpsTenantId = $generalConfig.devOpsTenantId
$sourcePipelineFolder = $generalConfig.sourcePipelineFolder
$issuer = "$generalConfig.issuer/" + "$customerTenantId/v2.0"
$audience = $generalConfig.audience
$subClaim = $generalConfig.subClaim

if ([string]::IsNullOrWhiteSpace($subClaim)) {
    Write-Error "❌ The variable 'subClaim' cannot be empty. Check the configuration in DevOps.json."
    exit 1
}

# Input
$serviceConnectionName = "Sentinel-$customer"
$pipelineName = $repoName
$gitUrl = "git@ssh.dev.azure.com:v3/$devOpsOrg/$projectName/$repoName"
$clonePath = Join-Path -Path $PWD -ChildPath $repoName
$targetPipelineFolder = Join-Path -Path $clonePath -ChildPath ".devops-pipeline"
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers = @{ Authorization = "Basic $base64AuthInfo" }

# Roles
$roles = @(
    "Microsoft Sentinel Contributor",
    "Logic App Contributor",
    "Monitoring Contributor",
    "Reader"
)

# ===============================================================================

# -----------------------------------------
# 1. Microsoft Entra ID Application Registration
# -----------------------------------------
Write-Host "[START] 🏢 Registering Entra ID application..." -ForegroundColor Blue

# === LOGIN TO CUSTOMER TENANT ===
Write-Host "`n[INSTRUCTION] 🟡 1. Login to the customer tenant" -ForegroundColor Yellow
Read-Host "Press Enter to continue with customer tenant login!"
az login --tenant $customerTenantId --allow-no-subscriptions *> $null

# === CREATE APPLICATION ===
try {
    $appJsonRaw = az ad app create --display-name $customerApplicationName
    $app = $appJsonRaw | ConvertFrom-Json
    $appId = $app.appId
    $appObjectId = $app.id

    if (-not $appId) {
        Write-Host "[ERROR] ❌ App ID was not retrieved correctly. Full response:" -ForegroundColor Red
        Write-Host $appJsonRaw -ForegroundColor Red
        exit 1
    }
    Write-Host "[SUCCESS] ✅ Microsoft Entra ID application created." -ForegroundColor Green
} catch {
    Write-Host "[ERROR] ❌ Failed to create Entra ID application: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# === CREATE SERVICE PRINCIPAL ===
try {
    $spJsonRaw = az ad sp create --id $appId
    $sp = $spJsonRaw | ConvertFrom-Json
    if (-not $sp.id) {
        Write-Host "[ERROR] ❌ Service principal was not created properly. Full response:" -ForegroundColor Red
        Write-Host $spJsonRaw -ForegroundColor Red
        exit 1
    }
    Write-Host "[SUCCESS] ✅ Service Principal created." -ForegroundColor Green
} catch {
    Write-Host "[ERROR] ❌ Failed to create service principal: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# === FEDERATED CREDENTIAL ===
$federatedCredentialFile = "federated.json"
$federatedCredentialContent = @{
    name = "DevOpsFederatedLogin"
    issuer = "$issuer"
    subject = "$subClaim/Sentinel-$customer"
    audiences = @("$audience")
}

$federatedCredentialContent | ConvertTo-Json -Depth 10 | Out-File -Encoding utf8 $federatedCredentialFile

try {
    az ad app federated-credential create `
        --id $appObjectId `
        --parameters $federatedCredentialFile *> $null
    Write-Host "[SUCCESS] ✅ Federated credential created and attached to the application" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] ❌ Failed to create federated credential: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Remove-Item $federatedCredentialFile

Write-Host "[SUCCESS] ✅ Microsoft Entra ID federated credential configured." -ForegroundColor Green

# === ASSIGN ROLES ===
foreach ($role in $roles) {
    try {
        az role assignment create `
            --assignee-object-id $sp.id `
            --assignee-principal-type ServicePrincipal `
            --role $role `
            --scope "/subscriptions/$customerSubscriptionId" *> $null
        Write-Host "[SUCCESS] ✅ Role '$role' assigned." -ForegroundColor Green
    } catch {
        Write-Host "[ERROR] ❌ Failed to assign role '$role': $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# === LOGIN BACK TO YOUR TENANT ===
Write-Host "`n[INSTRUCTION] 🟡 2. Login to the DevOps tenant" -ForegroundColor Yellow
Read-Host "Press Enter to continue with DevOps tenant login!"
az login --tenant $devOpsTenantId --allow-no-subscriptions *> $null

# -----------------------------------------
# 2. Service Connection Creation
# -----------------------------------------
Write-Host "[START] 🔗 Creating Service Connection..." -ForegroundColor Blue

# === DEVOPS CONFIGURATION ===
try {
    az devops configure --defaults organization=$devOpsOrgUrl project=$projectName *> $null
} catch {
    Write-Host "[ERROR] ❌ Failed to configure DevOps: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# === CREATE REPOSITORY ===
try {
    az repos create --name $repoName *> null
    Write-Host "[SUCCESS] ✅ Azure DevOps repository $repoName was created." -ForegroundColor Green
}
catch {
    Write-Host "[ERROR] ❌ Azure DevOps repository was not created." -ForegroundColor Red
}

# === GETTING PROJECT ID ===
try {
    $projectId = az devops project show --project $projectName --query id -o tsv
    Write-Host "[SUCCESS] ✅ Azure DevOps repository $repoName project ID was retrieved." -ForegroundColor Green
}
catch {
    Write-Host "[ERROR] ❌ Azure DevOps repository project ID was not retrieved." -ForegroundColor Red
}
# === CREATE SERVICE CONNECTION ===
if (-not $appId) {
    Write-Host "[ERROR] ❌ App ID is empty." -ForegroundColor Red
    exit 1
}

$devOpsJson = @{
    data = @{
        subscriptionId = $customerSubscriptionId
        subscriptionName = "Customer Subscription"
        environment = "AzureCloud"
        scopeLevel = "Subscription"
    }
    name = $serviceConnectionName
    type = "azurerm"
    url = "https://management.azure.com/"
    authorization = @{
        scheme = "WorkloadIdentityFederation"
        parameters = @{
            tenantid = $customerTenantId
            serviceprincipalid = $appId
        }
    }
    isShared = $false
    isReady = $true
    projectReferences = @(@{
        id = $projectId
        name = $projectName
    })
}

$devOpsJsonPath = "temp-serviceconnection.json"
$devOpsJson | ConvertTo-Json -Depth 10 | Out-File -Encoding utf8 $devOpsJsonPath

try {
    az devops service-endpoint create `
        --service-endpoint-configuration $devOpsJsonPath `
        --org $devOpsOrgUrl `
        --project $projectName *> $null
    Write-Host "[SUCCESS] ✅ Service Connection created successfully." -ForegroundColor Green
} catch {
    Write-Host "[ERROR] ❌ Failed to create service connection: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Remove-Item $devOpsJsonPath

# === CLONING REPOSITORY ===
if (Test-Path $clonePath) {
    Remove-Item -Path $clonePath -Recurse -Force
}

try {
    git clone $gitUrl $clonePath *> $null
} catch {
    Write-Host "[ERROR] ❌ Failed to clone repository: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# === MOVE .devops-pipeline FOLDER ===
$targetPipelineFolder = Join-Path -Path $clonePath -ChildPath ".devops-pipeline"

if (Test-Path $sourcePipelineFolder) {
    Copy-Item -Path $sourcePipelineFolder -Destination $targetPipelineFolder -Recurse -Force
} else {
    Write-Error "❌ .devops-pipeline folder not found"
    exit 1
}

# === MOVE pipeline.yml TO ROOT FOLDER ===
$pipelineFile = Join-Path -Path $targetPipelineFolder -ChildPath "pipeline.yml"
$targetPipelineFile = Join-Path -Path $clonePath -ChildPath "pipeline.yml"

if (Test-Path $pipelineFile) {
    Move-Item -Path $pipelineFile -Destination $targetPipelineFile -Force
} else {
    Write-Error "❌ pipeline.yml not found in .devops-pipeline"
    exit 1
}

# === MODIFY pipeline.yml VARIABLES ===
$pipelineFilePath = Join-Path -Path $clonePath -ChildPath "pipeline.yml"
(Get-Content $pipelineFilePath) -replace 'value: RG-', "value: $($customerResourceGroupName)" `
                                   -replace 'value: Sentinel-', "value: $serviceConnectionName" `
                                   -replace 'value: LA-', "value: $($customerWorkspaceName)" |
    Set-Content $pipelineFilePath

# -----------------------------------------
# 3. Repository Creation
# -----------------------------------------
Write-Host "[START] 📦 Creating Repository..." -ForegroundColor Blue

# === GIT COMMIT AND PUSH ===
Set-Location $clonePath
try {
    git add . *> $null
    git commit -m "Add DevOps pipeline configuration" *> $null
    git push *> $null
    Write-Host "[SUCCESS] ✅ Changes pushed to repository." -ForegroundColor Green
} catch {
    Write-Host "[ERROR] ❌ Failed to commit and push changes: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Set-Location $PSScriptRoot

# === GET REPOSITORY ID LIST ===
$reposUri = "https://dev.azure.com/$devOpsOrg/_apis/git/repositories?api-version=7.1-preview.1"
$reposResponse = Invoke-RestMethod -Uri $reposUri -Headers $headers -Method Get
$repo = $reposResponse.value | Where-Object { $_.name -eq $repoName }

if (-not $repo) {
    Write-Error "❌ Repository '$repoName' not found in project '$projectName."
    Write-Error "❌ reposUri: $reposUri'"
    Write-Error "❌ reposResponse: $reposResponse'"
    Write-Error "❌ repo: $repo'"
    exit 1
}

$repoId = $repo.id

# -----------------------------------------
# 4. Pipeline Creation and Execution
# -----------------------------------------
Write-Host "[START] 🚀 Creating and executing Pipeline..." -ForegroundColor Blue

# === CREATE PIPELINE ===
$branch = "main"  # adjust according to the actual branch

$body = @{
    name = $pipelineName
    configuration = @{
        type = "yaml"
        path = "pipeline.yml"
        repository = @{
            id = $repoId
            name = $repoNamef
            type = "azureReposGit"
            defaultBranch = "refs/heads/$branch"
        }
    }
} | ConvertTo-Json -Depth 10

$uri = "https://dev.azure.com/$devOpsOrg/$projectName/_apis/pipelines?api-version=7.1-preview.1"

Write-Host "ℹ️ Creating pipeline '$pipelineName'..." -ForegroundColor Blue
try {
    $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ContentType "application/json"
    if ($response.id) {
        Write-Host "✅ Pipeline '$pipelineName' created successfully (ID: $($response.id))" -ForegroundColor Green
    } else {
        Write-Error "❌ Pipeline creation failed"
    }
} catch {
    Write-Host "[ERROR] ❌ Failed to create pipeline: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# === RUN PIPELINE ===
if ($response.id) {
    $runUri = "https://dev.azure.com/$devOpsOrg/$projectName/_apis/pipelines/$($response.id)/runs?api-version=7.1-preview.1"
    $runBody = @{
        resources = @{ repositories = @{ self = @{ refName = "refs/heads/$branch" } } }
    } | ConvertTo-Json -Depth 10

    try {
        $runResponse = Invoke-RestMethod -Uri $runUri -Method Post -Headers $headers -Body $runBody -ContentType "application/json" *> $null
        Write-Host "🚀 Pipeline started" -ForegroundColor Green
    } catch {
        Write-Host "[ERROR] ❌ Failed to run pipeline: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# === DELETE LOCAL COPY OF REPOSITORY ===
if (Test-Path $clonePath) {
    try {
        Remove-Item -Path $clonePath -Recurse -Force
        Write-Host "🧹 Local folder '$repoName' has been removed." -ForegroundColor Green
    } catch {
        Write-Host "[ERROR] ❌ Failed to delete local repository copy: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# === 3. LOGIN TO CUSTOMER TENANT ===
Write-Host "`n[INSTRUCTION] 🟡 1. Login to the customer tenant" -ForegroundColor Yellow
Read-Host "Press Enter to continue with customer tenant login!"
az login --tenant $customerTenantId --allow-no-subscriptions *> $null