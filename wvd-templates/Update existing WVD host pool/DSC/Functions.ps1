<#

.SYNOPSIS
Functions/Common variables file to be used by both Script-FirstRdsh.ps1 and Script-AdditionalRdshServers.ps1

#>

# Variables

# Setting to Tls12 due to Azure web app security requirements
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

class PsRdsSessionHost {
    [string]$TenantName = [string]::Empty
    [string]$HostPoolName = [string]::Empty
    [string]$SessionHostName = [string]::Empty
    [int]$TimeoutInSec = 900
    [bool]$CheckForAvailableState = $false

    PsRdsSessionHost() { }

    PsRdsSessionHost([string]$TenantName, [string]$HostPoolName, [string]$SessionHostName) {
        $this.TenantName = $TenantName
        $this.HostPoolName = $HostPoolName
        $this.SessionHostName = $SessionHostName
    }

    PsRdsSessionHost([string]$TenantName, [string]$HostPoolName, [string]$SessionHostName, [int]$TimeoutInSec) {
        
        if ($TimeoutInSec -gt 1800) {
            throw "TimeoutInSec is too high, maximum value is 1800"
        }

        $this.TenantName = $TenantName
        $this.HostPoolName = $HostPoolName
        $this.SessionHostName = $SessionHostName
        $this.TimeoutInSec = $TimeoutInSec
    }

    hidden [object] _trySessionHost([string]$operation) {
        if ($operation -ne "get" -and $operation -ne "set") {
            throw "PsRdsSessionHost: Invalid operation: $operation. Valid Operations are get or set"
        }

        $specificToSet = @{$true = "-AllowNewSession `$true"; $false = "" }[$operation -eq "set"]
        $commandToExecute = "$operation-RdsSessionHost -TenantName `"`$(`$this.TenantName)`" -HostPoolName `"`$(`$this.HostPoolName)`" -Name `$this.SessionHostName -ErrorAction SilentlyContinue $specificToSet"

        $sessionHost = (Invoke-Expression $commandToExecute )

        $StartTime = Get-Date
        while ($sessionHost -eq $null) {
            Start-Sleep -Seconds 30

            $sessionHost = (Invoke-Expression $commandToExecute)
    
            if ((get-date).Subtract($StartTime).TotalSeconds -gt $this.TimeoutInSec) {
                if ($sessionHost -eq $null) {

                    return $null
                }
            }
        }

        if (($operation -eq "get") -and $this.CheckForAvailableState) {
            $StartTime = Get-Date

            while ($sessionHost.Status -ine "Available") {
                Start-Sleep -Seconds 60
                $sessionHost = (Invoke-Expression $commandToExecute)
        
                if ((get-date).Subtract($StartTime).TotalSeconds -gt $this.TimeoutInSec) {
                    if ($sessionHost.Status -ine "Available") {
                        $this.CheckForAvailableState = $false
                        return $null
                    }
                }
            }
        }

        $this.CheckForAvailableState = $false
        return $sessionHost
    }

    [object] SetSessionHost() {

        if ([string]::IsNullOrEmpty($this.TenantName) -or [string]::IsNullOrEmpty($this.HostPoolName) -or [string]::IsNullOrEmpty($this.HostPoolName)) {
            return $null
        }
        else {
            
            return ($this._trySessionHost("set"))
        }
    }
    
    [object] GetSessionHost() {

        if ([string]::IsNullOrEmpty($this.TenantName) -or [string]::IsNullOrEmpty($this.HostPoolName) -or [string]::IsNullOrEmpty($this.HostPoolName)) {
            return $null
        }
        else {
            return ($this._trySessionHost("get"))
        }
    }

    [object] GetSessionHostWhenAvailable() {

        if ([string]::IsNullOrEmpty($this.TenantName) -or [string]::IsNullOrEmpty($this.HostPoolName) -or [string]::IsNullOrEmpty($this.HostPoolName)) {
            return $null
        }
        else {
            $this.CheckForAvailableState = $true
            return ($this._trySessionHost("get"))
        }
    }
}

function Write-Log {
    [CmdletBinding()] 
    param
    ( 
        [Parameter(Mandatory = $false)] 
        [string]$Message,
        [Parameter(Mandatory = $false)] 
        [string]$Error 
    ) 
     
    try {
        $DateTime = Get-Date -Format "MM-dd-yy HH:mm:ss"
        $Invocation = "$($MyInvocation.MyCommand.Source):$($MyInvocation.ScriptLineNumber)" 
        if ($Message) {
            Add-Content -Value "$DateTime - $Invocation - $Message" -Path "$([environment]::GetEnvironmentVariable('TEMP', 'Machine'))\ScriptLog.log" 
        }
        else {
            Add-Content -Value "$DateTime - $Invocation - $Error" -Path "$([environment]::GetEnvironmentVariable('TEMP', 'Machine'))\ScriptLog.log" 
        }
    }
    catch {
        Write-Error $_.Exception.Message 
    }
}

function ValidateServicePrincipal {
    param
    ( 
        [Parameter(Mandatory = $true)] 
        [string]$isServicePrincipal,

        [Parameter(Mandatory = $false)] 
        [AllowEmptyString()]
        [string]$AadTenantId = ""
    ) 

    if ($isServicePrincipal -eq "True") {
        if ([string]::IsNullOrEmpty($AadTenantId)) {
            throw "When IsServicePrincipal = True, AadTenant ID is mandatory. Please provide a valid AadTenant ID."
        }
    }
}

function Is1809OrLater {
    $OSVersionInfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    if ($OSVersionInfo -ne $null) {
        if ($OSVersionInfo.ReleaseId -ne $null) {
            Write-Log -Message "Build: $($OSVersionInfo.ReleaseId)"
            $rdshIs1809OrLaterBool = @{$true = $true; $false = $false }[$OSVersionInfo.ReleaseId -ge 1809]
        }
    }
    return $rdshIs1809OrLaterBool
}

function ExtractDeploymentAgentZipFile {
    param
    ( 
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [Parameter(Mandatory = $true)]
        [string]$DeployAgentLocation
    )

    if (Test-Path $DeployAgentLocation) {
        Remove-Item -Path $DeployAgentLocation -Force -Confirm:$false -Recurse
    }
    
    New-Item -Path "$DeployAgentLocation" -ItemType directory -Force
    
    # Locating and extracting DeployAgent.zip
    Write-Log -Message "Locating DeployAgent.zip within Custom Script Extension folder structure: $ScriptPath"
    $DeployAgentFromRepo = (Get-ChildItem $ScriptPath\ -Filter DeployAgent.zip -Recurse | Select-Object).FullName
    if ((-not $DeployAgentFromRepo) -or (-not (Test-Path $DeployAgentFromRepo))) {
        throw "DeployAgent.zip file not found at $ScriptPath"
    }
    
    Write-Log -Message "Extracting 'Deployagent.zip' file into '$DeployAgentLocation' folder inside VM"
    Expand-Archive $DeployAgentFromRepo -DestinationPath "$DeployAgentLocation"
}

function isRdshServer {
    $rdshIsServer = $true

    $OSVersionInfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    
    if ($null -ne $OSVersionInfo) {
        if ($null -ne $OSVersionInfo.InstallationType) {
            $rdshIsServer = @{$true = $true; $false = $false }[$OSVersionInfo.InstallationType -eq "Server"]
        }
    }

    return $rdshIsServer
}

function AuthenticateRdsAccount {
    param(
        [Parameter(mandatory = $true)]
        [string]$DeploymentUrl,
    
        [Parameter(mandatory = $true)]
        [pscredential]$Credential,
    
        [switch]$ServicePrincipal,
    
        [Parameter(mandatory = $false)]
        [AllowEmptyString()]
        [string]$TenantId = ""
    )
    
    if ($ServicePrincipal) {
        Write-Log -Message "Authenticating using service principal $Credential.username and Tenant id: $TenantId "
    }
    else {
        $PSBoundParameters.Remove('ServicePrincipal')
        $PSBoundParameters.Remove('TenantId')
        Write-Log -Message "Authenticating using user $($Credential.username) "
    }

    $authentication = $null
    try {
        $authentication = Add-RdsAccount @PSBoundParameters
        if (!$authentication) {
            throw $authentication
        }
    }
    catch {
        $errMsg = "Windows Virtual Desktop Authentication Failed, Error:`n$($_ | Out-String)"
        Write-Log -Error "$errMsg"
        throw "$errMsg"
    }
    Write-Log -Message "Windows Virtual Desktop Authentication successfully Done. Result:`n$($authentication | Out-String)"
}

function SetTenantContextAndValidate {
    param(
        [Parameter(mandatory = $true)]
        [string]$definedTenantGroupName,

        [Parameter(mandatory = $true)]
        [string]$TenantName
    )
    #//todo refactor
    #//todo try catch ?
    # Set context to the appropriate tenant group
    $currentTenantGroupName = (Get-RdsContext).TenantGroupName
    if ($definedTenantGroupName -ne $currentTenantGroupName) {
        Write-Log -Message "Running switching to the $definedTenantGroupName context"
        Set-RdsContext -TenantGroupName $definedTenantGroupName
    }
    try {
        $tenants = Get-RdsTenant -Name "$TenantName"
        if (!$tenants) {
            Write-Log "No tenants exist or you do not have proper access."
            #//todo throw ?
        }
    }
    catch {
        #//todo refactor msg ?
        Write-Log -Message $_
        throw $_
    }
}

function ExtractAndImportPSRDModule {
    param(
        [Parameter(mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(mandatory = $false)]
        [string]$DeployAgentLocation = 'C:\DeployAgent'
    )

    Write-Log -Message "Creating a folder inside rdsh vm for extracting deployagent zip file"
    ExtractDeploymentAgentZipFile -ScriptPath $ScriptPath -DeployAgentLocation $DeployAgentLocation
    
    Write-Log -Message "Changing current folder to Deployagent folder: $DeployAgentLocation"
    Set-Location "$DeployAgentLocation"
    
    # Importing Windows Virtual Desktop PowerShell module
    #//todo confirm
    # Import-Module .\PowershellModules\Microsoft.RDInfra.RDPowershell.dll
    Install-Module Microsoft.RDInfra.RDPowershell -Scope 'Local'
    Write-Log -Message "Imported Windows Virtual Desktop PowerShell modules successfully"
}