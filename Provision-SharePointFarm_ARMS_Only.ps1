# Load Azure Cmdlets
Import-Module Azure

# Version > 0.8. required for RM
Get-Module -Name Azure 


# Parameters
$subscriptionName = "<SUBSCRIPTION>"
$StorageAccount = "<STORAGE ACCOUNT>"
$StorageContainer = 'scripts'


# AuthN
Add-AzureAccount
Switch-AzureMode -Name AzureServiceManagement

# Choose Azure sub
Select-AzureSubscription -SubscriptionName $subscriptionName

# Create Storage Account for provisioning files
New-AzureStorageAccount -StorageAccountName $StorageAccount -Type "Standard_LRS" -Location "East US" -ea 0 
$StorageKey = (Get-AzureStorageKey -StorageAccountName $StorageAccount).Primary
$StorageContext = New-AzureStorageContext -StorageAccountName $StorageAccount -StorageAccountKey $StorageKey
New-AzureStorageContainer -Name $StorageContainer -Context $StorageContext -ea 0
$AzureBlobContainer = Get-AzureStorageContainer -Name $StorageContainer -Context $StorageContext 
Set-AzureStorageContainerAcl -Name $StorageContainer -Context $StorageContext -Permission Blob

# Upload files
Switch-AzureMode -Name AzureServiceManagement
Get-ChildItem .\Extensions | %{
    Set-AzureStorageBlobContent -File $_.FullName -Blob $_.Name -Container $StorageContainer -Context $StorageContext -Force
}
Switch-AzureMode -Name AzureServiceManagement
Set-AzureStorageBlobContent -File .\SP-Dev-Environment.json -Blob SP-Dev-Environment.json -Context $StorageContext -Container $StorageContainer -Force | Out-Null


# Create Resource Group
Switch-AzureMode -Name AzureResourceManager
$ResourceGroupName = "<RESOURCE GROUP NAME>"
$Location = "East US"
$rg = Get-AzureResourceGroup -Name $ResourceGroupName -EA 0
if($rg -eq $null) {
    $rg = New-AzureResourceGroup -Name $ResourceGroupName -Location $Location
}

# Credentials
$domain = $ResourceGroupName
$domainfqdn = "$($domain).com"
$domaadmin = Get-Credential -Message "Enter Admin Credentials (no domain)" -UserName "wwadmin"
$sqlsvc = Get-Credential -Message "Enter SQL Server Credentials" -UserName "$domain\sqlserver"
$farmadmin = Get-Credential -Message "Enter Farm Admin Credentials" -UserName "$domain\spfarm"
$setup = Get-Credential -Message "Enter Setup Account Credentials" -UserName "$domain\spsetup"
$webpool = Get-Credential -Message "Enter Web Pool Credentials" -UserName "$domain\spwebapp"
$service = Get-Credential -Message "Enter Service App Credentials" -UserName "$domain\spservice"

# Build the parameters
$params = @{
       ServiceName ="$ResourceGroupName";
       DomainAdminAccount="$($domaadmin.UserName)";
       DomainAdminAccountPassword=$domaadmin.Password;
       DomainNameFQDN = $domainfqdn;
       DomainName = $domain;
       SQLServiceAccount=$sqlsvc.UserName;
       SQLServiceAccountPassword=$sqlsvc.Password;
       FarmAccount=$farmadmin.UserName;
       FarmAccountPassword=$farmadmin.Password;
       InstallAccount=$setup.UserName;
       InstallAccountPassword=$setup.Password;
       WebPoolManagedAccount=$webpool.UserName;
       WebPoolManagedAccountPassword=$webpool.Password;
       ServicePoolManagedAccount=$service.UserName;
       ServicePoolManagedAccountPassword=$service.Password;
       resourceLocation="East US";
       FarmPassPhrase = "pass@word1";
       SharePointProductKey = "<PID>";
       WebAppUrl = "http://localhost";
       TeamSiteUrl = "http://teams";
       MySiteHostUrl = "http://my";
       DevSiteUrl = "http://dev";
}


Switch-AzureMode -Name AzureServiceManagement
Set-AzureStorageBlobContent -File .\SP-Dev-Environment.json -Blob SP-Dev-Environment.json `
    -Context $StorageContext -Container $StorageContainer -Force | Out-Null

Switch-AzureMode -Name AzureResourceManager

New-AzureResourceGroupDeployment -Name $ResourceGroupName -ResourceGroupName $ResourceGroupName `
    -TemplateParameterObject $params `
    -TemplateUri "https://wwazprst.blob.core.windows.net/scripts/SP-Dev-Environment.json" -Verbose
