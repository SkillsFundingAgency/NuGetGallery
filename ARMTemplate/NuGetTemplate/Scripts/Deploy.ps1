Set-StrictMode -Version 5

class PDSSubscription {
    [PDSEnvironment[]] $Environments = @();
    [string] $Name;
    [string] $TemplateFile;
    [string] $SubscriptionId;

    [string] $Location = "North Europe";
    [string] $SystemPrefix = "nuget-";
    [string] $RgName;
    [string] $StorageName;
    [string] $ClassicStorageName;

    PDSSubscription([string] $name, [string] $templateFile, [string] $subscriptionId) {
        $this.Name = $name;
        $this.TemplateFile = $templateFile;
        $this.SubscriptionId = $subscriptionId;

        $this.SetupInternal();
    }

    PDSSubscription([PDSEnvironment[]] $environments,[string] $name, [string] $templateFile, [string] $subscriptionId) {
        $this.Environments = $environments;
        $this.Name = $name;
        $this.TemplateFile = $templateFile;
        $this.SubscriptionId = $subscriptionId;

        $this.SetupInternal();
    }

    [void] SetupInternal() {
        $this.RgName = $this.SystemPrefix + $this.Name + "sub"
        $this.StorageName = $this.RgName.Replace("-", "") + "storage"
        $this.ClassicStorageName = $this.RgName.Replace("-", "") + "storagec"
    }

    [void] AddEnvironment([PDSEnvironment] $environment) {
        $environment.Subscription = $this;
        $this.Environments += $environment;
    }

    [void] Create() {
        try {
            Select-AzureRmSubscription -SubscriptionId $this.SubscriptionId -ErrorAction Stop
            Select-AzureSubscription -SubscriptionId $this.SubscriptionId -ErrorAction Stop
        }
        catch {
            return;
        }

        $subRg = $null
        try {
            $subRg = Get-AzureRmResourceGroup -Name $this.RgName -ErrorAction SilentlyContinue
        }
        catch { }

        if($subRg -eq $null) {
            New-AzureRmResourceGroup -Name $this.RgName -Location $this.Location -Force -Verbose
        }
        else {
            Write-Warning "Skipping the creation of the subscription Resource Group $($this.RgName) because it already exists"
        }

        New-AzureRmResourceGroupDeployment -Name ($this.RgName + "-deployment") -ResourceGroupName $this.RgName -Mode Complete -TemplateFile $this.TemplateFile -TemplateParameterObject @{storageName=$this.StorageName;classicstorageName=$this.ClassicStorageName} -Force -Verbose

        $this.Environments | ForEach-Object { $_.Create(); }
    }
}

class PDSEnvironment {
    [PDSSubscription] $Subscription;
    [string] $Name;
    [string] $SqlPassword;
    [string] $Configuration;
    [string] $Branch;
    [string] $TemplateFile;

    [int] $CloudServiceSleepInSeconds = 30;
    [string] $RgName;
    [string] $CloudServiceName;
    [string] $StagingRip;
    [string] $ProductionRip;

    PDSEnvironment([string] $name, [string] $sqlPassword, [string] $configuration, [string] $templateFile) {
        $this.Name = $name;
        $this.SqlPassword = $sqlPassword;
        $this.Configuration = $configuration;
        $this.TemplateFile = $templateFile;

        $this.CloudServiceName = "nuget-webui-" + $this.Name;
        $this.StagingRip = $this.CloudServiceName + "-srip"
        $this.ProductionRip = $this.CloudServiceName + "-prip"
    }

    [void] Create() {
        if($this.RgName -eq $null) {
            $this.RgName = $this.Subscription.SystemPrefix + $this.Name;
        }

        $rg = $null
        try {
            $rg = Get-AzureRmResourceGroup -Name $this.RgName -ErrorAction SilentlyContinue
        }
        catch { }

        if($rg -eq $null) {
            New-AzureRmResourceGroup -Name $this.RgName -Location $this.Subscription.Location -Force -Verbose
        }
        else {
            Write-Warning "Skipping the creation of the Resource Group $($this.RgName) because it already exists"
        }

        New-AzureRmResourceGroupDeployment -Name ($this.RgName + "-deployment") -ResourceGroupName $this.RgName -Mode Complete -TemplateFile $this.TemplateFile -TemplateParameterObject @{envName=$this.Name;sqlPassword=$this.SqlPassword;configuration=$this.Configuration} -Force -Verbose

        ##################################################################################################
        # Need to provision the stuff that ARM doesn't support, or the stuff I want to provision in a way
        # that ARM templates won't let me to because the Microsoft guy writing the schemas is slacking
        ##################################################################################################

        $cloudService = $null
        try {
            $cloudService = Get-AzureService -ServiceName $this.CloudServiceName -ErrorAction SilentlyContinue
        }
        catch { }

        if($cloudService -eq $null) {
            New-AzureService -ServiceName $this.CloudServiceName -Location $this.Subscription.Location -Verbose

            # If we don't sleep a bit, the ARM won't have time to create the RG as the New-AzureService will return as soon as the cloud service is created but not the RG
            ### TODO: Swap this to a Query/Sleep cycle to check for the existence of the default RG created by the New-AzureService
            Start-Sleep -Seconds 30 -Verbose

            try {
                Get-AzureRmResource -ResourceName $this.CloudServiceName -ResourceType "Microsoft.ClassicCompute/domainNames" -ResourceGroupName $this.CloudServiceName | Move-AzureRmResource -DestinationResourceGroupName $this.RgName -Verbose -Force -ErrorAction Stop
            }
            catch {
                return;
            }

            # Don't remove the cloud service resource group if the move failed, this way we can recover manually if needed
            Remove-AzureRmResourceGroup -Name $this.CloudServiceName -Verbose -Force
        }
        else {
            Write-Warning "Skipping the creation of the Cloud Service $($this.CloudServiceName) because it already exists"
        }

        $this.CreateReservedIp($this.StagingRip);
        $this.CreateReservedIp($this.ProductionRip);
    }

    [void] CreateReservedIp([string] $name) {
        $rip = $null
        try {
            $rip = Get-AzureReservedIP -ReservedIPName $name -ErrorAction SilentlyContinue
        }
        catch { }

        if($rip -eq $null) {
            New-AzureReservedIP -ReservedIPName $name -Location $this.Subscription.Location -Verbose
        }
        else {
            Write-Warning "Skipping the creation of the Reserved IP $name because it already exists"
        }
    }
}

try {
  [Microsoft.Azure.Common.Authentication.AzureSession]::ClientFactory.AddUserAgent("VSAzureTools-$UI$($host.name)".replace(" ","_"), "2.7.1")
} catch { }

$SubscriptionTemplateFile = [System.IO.Path]::Combine($PSScriptRoot, '..\Templates\Subscription.json')
$EnvironmentTemplateFile = [System.IO.Path]::Combine($PSScriptRoot, '..\Templates\Environment.json')

$devSubscription = [PDSSubscription]::new("live", $SubscriptionTemplateFile, "af56e6f8-65ba-4875-a862-466a6a81c7e7");
$devSubscription.AddEnvironment([PDSEnvironment]::new("live", "TDAPwd2570e5c1b198", "release", $EnvironmentTemplateFile));
$devSubscription.Create();
