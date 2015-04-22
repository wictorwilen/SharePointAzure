# Load Azure Cmdlets
Import-Module Azure

# Version > 0.8. required for RM
Get-Module -Name Azure 


# Parameters
$subscriptionName = "<Your subscription>"
$StorageAccount = "<a storage account name>"
$StorageContainer = 'scripts'


# AuthN
Add-AzureAccount

# Choose Azure sub
Select-AzureSubscription -SubscriptionName $subscriptionName

# Create Storage Account for provisioning files
Switch-AzureMode -Name AzureServiceManagement
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
Set-AzureStorageBlobContent -File .\SP-Dev-Environment.json -Blob SP-Dev-Environment.json -Context $StorageContext -Container $StorageContainer -Force | Out-Null


# Create Resource Group
Switch-AzureMode -Name AzureResourceManager
$ResourceGroupName = "<resource group name - LOWERCASE>"
$Location = "East US"
$rg = Get-AzureResourceGroup -Name $ResourceGroupName -EA 0
if($rg -eq $null) {
    $rg = New-AzureResourceGroup -Name $ResourceGroupName -Location $Location
}

# Credentials
$creds = Get-Credential -Message "Enter Crendetials"

# Build the parameters
$params = @{
       ServiceName ="$ResourceGroupName";
       administratorAccount="$($creds.UserName)";
       administratorPassword="$($creds.GetNetworkCredential().Password)";
       servicePassword="$($creds.GetNetworkCredential().Password)";
       domainName="$($ResourceGroupName).com";
       domainNetBiosName="$($ResourceGroupName)";
       resourceLocation="East US";

}


New-AzureResourceGroupDeployment -Name $ResourceGroupName -ResourceGroupName $ResourceGroupName `
    -TemplateParameterObject $params `
    -TemplateUri "https://wwprovisioningfiles.blob.core.windows.net/scripts/SP-Dev-Environment.json"




