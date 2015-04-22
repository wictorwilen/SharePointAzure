# Load ADAL stuff
$path = [Environment]::GetFolderPath("MyDocuments") + "\WindowsPowerShell\Modules\ARM"
mkdir $path -ea 0 | Out-Null
mkdir "$($path)\Nuget\" -ea 0 | Out-Null
$wc = New-Object System.Net.WebClient 
$wc.DownloadFile("http://www.nuget.org/nuget.exe",$path + "\Nuget\nuget.exe"); 
$expression = $path + "\Nuget\nuget.exe install Microsoft.IdentityModel.Clients.ActiveDirectory  -OutputDirectory " + $path + "\Nuget | out-null" 
Invoke-Expression $expression 
$items = (Get-ChildItem -Path ($path+"\Nuget") -Filter "Microsoft.IdentityModel.Clients.ActiveDirectory*" -Directory) 
$adal = (Get-ChildItem "Microsoft.IdentityModel.Clients.ActiveDirectory.dll" -Path $items[$items.length-1].FullName -Recurse) 
$adalforms = (Get-ChildItem "Microsoft.IdentityModel.Clients.ActiveDirectory.WindowsForms.dll" -Path $items[$items.length-1].FullName -Recurse) 
[System.Reflection.Assembly]::LoadFrom($adal[0].FullName) | out-null 
[System.Reflection.Assembly]::LoadFrom($adalforms.FullName) | out-null 


# Function definitions
function Get-AuthenticationResult($subscription){
  # You should replace the following with your own Azure AD stuff - I might remove that client id whenever I need...
  $clientId = "56abf1ab-57bd-4156-aec0-553808ca15cc" #"1950a258-227b-4e31-a9cf-717495945fc2"
  $redirectUri = new-object "System.Uri" -ArgumentList "http://myapp1" #"urn:ietf:wg:oauth:2.0:oob"
  $resourceClientId = "00000002-0000-0000-c000-000000000000"
  $resourceAppIdURI = "https://management.azure.com/" #CHECK DIS

  $authority = "https://login.windows.net/$($subscription.TenantId)"
 
  $authContext = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext" -ArgumentList $authority,$false
  $authResult = $authContext.AcquireToken( $resourceAppIdURI, $clientId, $redirectUri)
  return $authResult
}
function Run-RMCommand ($json, $subscription, $rg) {
    $auth = Get-AuthenticationResult -subscription $subscription
    $headers = @{
        Authorization = "Bearer " + $auth.AccessToken;
        Accept ="application/json";
        "Content-Type" = "application/json"
    } 
    $result = Invoke-RestMethod `
        -Uri "https://management.azure.com$($rg.ResourceId)/providers/microsoft.resources/deployments/$($rg.ResourceGroupName)Deployment?api-version=2015-01-01" `
        -Headers $headers `
        -Method Put `
        -Body $json

    do {   
        Sleep 10

        if($auth.ExpiresOn -le [DateTime]::Now) {
            $auth = Get-AuthenticationResult -subscription $subscription
            $headers = @{
                Authorization = "Bearer " + $auth.AccessToken;
                Accept ="application/json";
                "Content-Type" = "application/json"
            } 
        }
        $status = Invoke-RestMethod `
            -Uri "https://management.azure.com$($result.id)?api-version=2015-01-01" `
            -Headers $headers `
            -Method Get
        Write-Host "." -NoNewline 

    } while($status.properties.provisioningState -eq 'Running')
    Write-Host "."
    return $status.properties.provisioningState
}

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
$sub = (Get-AzureSubscription -SubscriptionName $subscriptionName)
$subid = $sub.SubscriptionId


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
$templateJson = "{
  'properties': {
    'templateLink': {
      'uri': 'https://wwprovisioningfiles.blob.core.windows.net/scripts/SP-Dev-Environment.json',
      'contentVersion': '1.0.0.0',
    },
    'mode': 'Incremental',
    'parameters': {
       'ServiceName': { 'value': '$ResourceGroupName' }, 
       'administratorAccount': { 'value': '$($creds.UserName)' },
       'administratorPassword': {'value':'$($creds.GetNetworkCredential().Password)'},
       'servicePassword': { 'value': '$($creds.GetNetworkCredential().Password)' },
       'domainName': { 'value': '$($ResourceGroupName).com' },
       'domainNetBiosName': { 'value': '$($ResourceGroupName)' },
       'resourceLocation': {'value':'East US'}
    }
  }
}"


# Start the ARM job
Run-RMCommand -json $templateJson -rg $rg -subscription $sub




