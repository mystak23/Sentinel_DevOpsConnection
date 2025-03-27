# 1. Načtení config file
$generalConfigPath = "values/DevOps.json"
$generalConfig = Get-Content $generalConfigPath | ConvertFrom-Json
$serviceConnectionConfigPath = "values/ServiceConnection.json"

# 2. Informace o zákazníkovi

# Ze souboru
$customerApplicationName = $generalConfig.applicationName

# Input
$customer = "TEST" #Read-Host "Zadej název zákazníka"
$customerTenantId = "fec3a0fa-64ae-446f-a3a6-2b0eeae14c73" #Read-Host "Zadej Tenant ID zákazníka"
$customerSubscriptionId = "66a13036-966e-4910-83ec-b28bc1a66923" # Read-Host "Zadej Subscription ID zákazníka"
$customerResourceGroupName = "RG-Test1828" #Read-Host "Zadej název Resource Group zákazníka"
$customerWorkspaceName = "RG-Test1828" #Read-Host "Zadej název Log Analytics Workspace"

# 3. DevOps

# Ze souboru
$pat = $generalConfig.pat
$projectName = $generalConfig.projectName
$repoName = "$($generalConfig.repoName)-$customer"
$devOpsOrg = $generalConfig.devOpsOrg
$devOpsOrgUrl = $generalConfig.devOpsOrgUrl
$sourcePipelineFolder = $generalConfig.sourcePipelineFolder
$issuer = $generalConfig.issuer
$audience = $generalConfig.audience
$subClaim = $generalConfig.subClaim

if ([string]::IsNullOrWhiteSpace($subClaim)) {
    Write-Error "❌ Proměnná 'subClaim' nesmí být prázdná. Zkontroluj konfiguraci v DevOps.json."
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

# 4. Aplikace

$roles = @(
    "Microsoft Sentinel Contributor",
    "Logic App Contributor",
    "Monitoring Contributor"
)

# ===============================================================================

# === PŘIHLÁŠENÍ DO TENANTU ZÁKAZNÍKA ===
az login --tenant $customerTenantId

# === VYTVOŘENÍ APLIKACE ===
$app = az ad app create --display-name $customerApplicationName | ConvertFrom-Json
$appId = $app.appId
$appObjectId = $app.id

# === FEDERATED CREDENTIAL ===
$federatedCredentialFile = "federated.json"
$federatedCredentialContent = @{
    name = "DevOpsFederatedLogin"
    issuer = "$issuer"
    subject = $subClaim
    audiences = @("$audience")
}

$federatedCredentialContent | ConvertTo-Json -Depth 10 | Out-File -Encoding utf8 $federatedCredentialFile

az ad app federated-credential create `
    --id $appObjectId `
    --parameters $federatedCredentialFile

Write-Host "✅ Federated credential vytvořen a připojen k aplikaci"

Remove-Item $federatedCredentialFile

# === VYTVOŘENÍ SERVICE PRINCIPALU ===
$sp = az ad sp create --id $appId | ConvertFrom-Json

# === PŘIŘAZENÍ ROLÍ ===
foreach ($role in $roles) {
    az role assignment create `
        --assignee-object-id $sp.id `
        --assignee-principal-type ServicePrincipal `
        --role $role `
        --scope "/subscriptions/$customerSubscriptionId"
}

# === PŘIHLÁŠENÍ ZPĚT DO TVÉHO TENANTU ===
az login --allow-no-subscriptions

# === DEVOPS NASTAVENÍ ===
az devops configure --defaults organization=$devOpsOrgUrl project=$projectName

# === VYTVOŘENÍ REPOZITÁŘE ===
az repos create --name $repoName

# === ZÍSKÁNÍ ID PROJEKTU ===
$projectId = az devops project show --project $projectName --query id -o tsv

# === VYTVOŘENÍ SERVICE CONNECTION ===
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

az devops service-endpoint create `
    --service-endpoint-configuration $devOpsJsonPath `
    --org $devOpsOrgUrl `
    --project $projectName

Remove-Item $devOpsJsonPath

# === KLONOVÁNÍ REPOZITÁŘE ===
Write-Host "ℹ️ Cloning from: $gitUrl"
git clone $gitUrl $clonePath

# === PŘESUN SLOŽKY .devops-pipeline ===
$targetPipelineFolder = Join-Path -Path $clonePath -ChildPath ".devops-pipeline"

if (Test-Path $sourcePipelineFolder) {
    Copy-Item -Path $sourcePipelineFolder -Destination $targetPipelineFolder -Recurse -Force
} else {
    Write-Error "❌ .devops-pipeline folder not found"
    exit 1
}

# === PŘESUN pipeline.yml DO ROOT SLOŽKY ===
$pipelineFile = Join-Path -Path $targetPipelineFolder -ChildPath "pipeline.yml"
$targetPipelineFile = Join-Path -Path $clonePath -ChildPath "pipeline.yml"

if (Test-Path $pipelineFile) {
    Move-Item -Path $pipelineFile -Destination $targetPipelineFile -Force
} else {
    Write-Error "❌ pipeline.yml not found in .devops-pipeline"
    exit 1
}

# === ÚPRAVA pipeline.yml PROMĚNNÝCH ===
$pipelineFilePath = Join-Path -Path $clonePath -ChildPath "pipeline.yml"
(Get-Content $pipelineFilePath) -replace 'value: RG-', "value: $($customerResourceGroupName)" `
                                   -replace 'value: Sentinel-', "value: $serviceConnectionName" `
                                   -replace 'value: LA-', "value: $($customerWorkspaceName)" |
    Set-Content $pipelineFilePath

# === GIT COMMIT A PUSH ===
Set-Location $clonePath
git add .
git commit -m "Add DevOps pipeline configuration"
git push
Set-Location $PSScriptRoot

# === ZÍSKÁNÍ REPOSITORY ID ZOZNAMEM ===
$reposUri = "https://dev.azure.com/$devOpsOrg/$projectName/_apis/git/repositories?api-version=7.1-preview.1"
$reposResponse = Invoke-RestMethod -Uri $reposUri -Headers $headers -Method Get

$repo = $reposResponse.value | Where-Object { $_.name -eq $repoName }

if (-not $repo) {
    Write-Error "❌ Repozitář '$repoName' nebyl nalezen v projektu '$projectName'"
    Write-Host "ℹ️ Dostupné repozitáře:"
    $reposResponse.value.name
    exit 1
}

$repoId = $repo.id
Write-Host "✅ Repository ID: $repoId"

# === VYTVOŘENÍ PIPELINE ===
$branch = "main"  # přizpůsob podle skutečné větve

$body = @{
    name = $pipelineName
    configuration = @{
        type = "yaml"
        path = "pipeline.yml"
        repository = @{
            id = $repoId
            name = $repoName
            type = "azureReposGit"
            defaultBranch = "refs/heads/$branch"
        }
    }
} | ConvertTo-Json -Depth 10

$uri = "https://dev.azure.com/$devOpsOrg/$projectName/_apis/pipelines?api-version=7.1-preview.1"

Write-Host "ℹ️ Creating pipeline '$pipelineName'..."
$response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ContentType "application/json"

if ($response.id) {
    Write-Host "✅ Pipeline '$pipelineName' created successfully (ID: $($response.id))"
} else {
    Write-Error "❌ Pipeline creation failed"
}

# === SPUŠTĚNÍ PIPELINE ===
if ($response.id) {
    $runUri = "https://dev.azure.com/$devOpsOrg/$projectName/_apis/pipelines/$($response.id)/runs?api-version=7.1-preview.1"
    $runBody = @{
        resources = @{ repositories = @{ self = @{ refName = "refs/heads/$branch" } } }
    } | ConvertTo-Json -Depth 10

    $runResponse = Invoke-RestMethod -Uri $runUri -Method Post -Headers $headers -Body $runBody -ContentType "application/json"
    Write-Host "🚀 Pipeline spuštěna (Run ID: $($runResponse.id))"
}

# === SMAZÁNÍ LOKÁLNÍ KOPIE REPOZITÁŘE ===
if (Test-Path $clonePath) {
    Remove-Item -Path $clonePath -Recurse -Force
    Write-Host "🧹 Lokální složka '$repoName' byla odstraněna."
}