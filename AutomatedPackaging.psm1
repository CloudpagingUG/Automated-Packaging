<#
.SYNOPSIS
    For Copying to/from a network share to/from a local VM.
.DESCRIPTION
    This function uses copy-item, attempts to do a direct copy first, but if that fails will 
    fallback and copy to TempLocalPath first, then to the desired destination.
.NOTES
    Initially set up for Automated Packaging of Cloudpaging packages 2026-Mar-03
.PARAMETER Path
    Passed along to Copy-Item | from Copy-Item help:
    Specifies, as a string array, the path to the items to copy. Wildcard characters are permitted.
.PARAMETER Destination
    Passed along to Copy-Item | from Copy-Item help:
    Specifies the path to the new location.
.PARAMETER ToSession
    Passed along to Copy-Item | from Copy-Item help:
    This is a dynamic parameter made available by the **FileSystem** provider.

    Specify the **PSSession** object to which a remote file is being copied. When you use this
    parameter, the **Destination** parameter refers to the local path on the remote machine.

    For more information, see
    [about_FileSystem_Provider](../Microsoft.PowerShell.Core/About/about_FileSystem_Provider.md).
.PARAMETER FromSession
    Passed along to Copy-Item | from Copy-Item help:
    This is a dynamic parameter made available by the **FileSystem** provider.

    Specify the **PSSession** object from which a remote file is being copied. When you use this
    parameter, the **Path** and **LiteralPath** parameters refer to the local path on the remote
    machine.

    For more information, see
    [about_FileSystem_Provider](../Microsoft.PowerShell.Core/About/about_FileSystem_Provider.md).
.PARAMETER TempLocalPath
    Specifies the path to a location where files can be copied locally before being copied to the
    specified destination.
.PARAMETER Recurse
    Passed along to Copy-Item | from Copy-Item help:
    Indicates that this cmdlet does a recursive copy.
.PARAMETER Force
    Passed along to Copy-Item | from Copy-Item help:
    Indicates that this cmdlet copies items that can't otherwise be changed, such as copying over a
    read-only file or alias.
.PARAMETER NoCleanup
    Indicates that if files are copied to TempLocalPath, they should not be removed.
.EXAMPLE
    $session = New-PSSession -VMName <VM-Name> -Credential $vmSessionCredential
    Copy-ItemWithFallback -Path '\\shareFQDN\AppFolder\VersionFolder' -Destination 'C:\temp' -Force
      -ToSession $session -Recurse  -Verbose

    This will copy directly from '\\shareFQDN\AppFolder\VersionFolder' to 'C:\temp' on <VM-Name>, 
    but if that fails it will attempt to copy first to '$env:temp\Fallback' and then from there to
    'C:\temp' on <VM-Name>.
.EXAMPLE
    $session = New-PSSession -VMName <VM-Name> -Credential $vmSessionCredential
    Copy-ItemWithFallback -Path 'C:\temp\output' -Destination '\\shareFQDN\AppFolder\VersionFolder'
      -FromSession $session -Recurse -Force -Verbose

    This will copy directly to '\\shareFQDN\AppFolder\VersionFolder' from 'C:\temp\output' on
    <VM-Name>, but if that fails it will attempt to copy first to '$env:temp\Fallback' and then
    from there to '\\shareFQDN\AppFolder\VersionFolder'.
.EXAMPLE
    $session1 = New-PSSession -VMName <VM-Name1> -Credential $vmSessionCredential1
    $session2 = New-PSSession -VMName <VM-Name2> -Credential $vmSessionCredential2
    Copy-ItemWithFallback -Path 'C:\temp\output\' -Destination 'C:\temp\' -Recurse -Force -Verbose
      -FromSession $session1 -ToSession $session2

    This will fail to directly copy since Copy-Item doesn't support using both -FromSession and
    -ToSession, but it will fallback and copy 'C:\temp\output\' on <VM-Name1> to the specified
    TempLocalPath, then copy from there to 'C:\temp\' on <VM-Name2>.
#>
function Copy-ItemWithFallback {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Destination,  # e.g., "C:\VM\Destination\Folder" (path inside VM)
        [Parameter(Mandatory = $false)]
        [string[]]$Exclude,
        [Parameter(Mandatory = $true, ParameterSetName = 'to')]
        [Parameter(Mandatory = $true, ParameterSetName = 'both')]
        [System.Management.Automation.Runspaces.PSSession]$ToSession,  # Your established PSSession to the VM
        [Parameter(Mandatory = $true, ParameterSetName = 'from')]
        [Parameter(Mandatory = $true, ParameterSetName = 'both')]
        [System.Management.Automation.Runspaces.PSSession]$FromSession,  # Your established PSSession to the VM
        [Parameter(Mandatory = $false)]
        [string]$TempLocalPath = (Join-Path $env:TEMP "Fallback"),  # Temp staging on host
        [switch]$Recurse,  # If copying folders recursively
        [switch]$Force,  # Overwrite if needed
        [switch]$NoCleanup # Doesn't cleanup files after copy
    )

    foreach ($item in $Path) {
        $Leaf = Split-Path -Leaf $item
        if (($Destination.EndsWith($leaf))) {
            Write-Verbose "Removing ($Leaf) from the end of ($Destination)"
            $Destination = $Destination.TrimEnd($Leaf)
        }
    
        try {
            Write-Verbose "Attempting direct copy from ($item) to ($Destination)"
            $params = @{
                Path = $item
                Destination = $Destination
            }
            if ($ToSession) { $params['ToSession'] = $ToSession }
            if ($FromSession) { $params['FromSession'] = $FromSession }
            if ($Recurse) { $params['Recurse'] = $true }
            if ($Exclude) { $params['Exclude'] = $Exclude }
            if ($Force) { $params['Force'] = $true }
    
            Copy-Item @params -ErrorAction Stop
            Write-Verbose "Direct copy succeeded."
            continue  # Move on if successful
        }
        catch {
            Write-Warning "Direct copy failed: $($_.Exception.Message). Attempting fallback."
        }
    
        try {
            Initialize-Path -Path $TempLocalPath
            Remove-Item -Recurse -Force -Path "$TempLocalPath\*"
            # Don't need toSession to start
            $params.Remove('ToSession')
            
            Write-Verbose "Starting local copy from ($item) to ($TempLocalPath)"
            Write-Verbose "Param Keys: ($($params.Keys))`nValues: ($($params.values))"
            $params.Destination = $TempLocalPath
            copy-item @params -ErrorAction Stop
            
            # Don't need fromSession to finish
            $params.Remove('FromSession')
            if ($ToSession) { $params['ToSession'] = $ToSession }
    
            $params.Path = Join-Path $TempLocalPath $Leaf
            Write-Verbose "Starting local copy from ($($params.Path)) to ($Destination)"
            $params.Destination = $Destination
            copy-item @params -ErrorAction Stop
            Write-Verbose "Fallback copy succeeded."
        }
        catch {
            throw "Fallback copy failed: $($_.Exception.Message)"
        }
        finally {
            if ((Test-Path "$TempLocalPath\*") -and (-not $NoCleanup)) {
                Write-Verbose "Cleaning up ($TempLocalPath)"
                Remove-Item "$TempLocalPath\*" -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

<#
.SYNOPSIS
    Get-CloudpagingServerData queries Cloudpaging Admin and returns application and license policy
    information.
.DESCRIPTION
    Get-CloudpagingServerData queries the Cloudpaging Admin specified by ServerURL, authenticating
    with the specified WebServiceKey and returns a pscustomobject that contains each application
    and the license policies that are associated with that application.
.NOTES
    Initially set up for Automated Packaging of Cloudpaging packages 2026-Jul-02
.PARAMETER WebServiceKey
    Passed along to Set-CloudpagingWebService | from Set-CloudpagingWebService help:
    Mandatory string that identifies the Web Service key
.PARAMETER ServerURL
    Passed along to Set-CloudpagingWebService | from Set-CloudpagingWebService help:
    Mandatory string of the subdomain of the Cloudpaging Server
    Format: "https://[host]"
.EXAMPLE
    $CloudpagingServerData = Get-CloudpagingServerData -ServerUrl $env:ADM_URL -WebServiceKey $env:WEB_SERV_KEY

    Queries the Cloudpaging Admin server specified by $env:ADM_URL using the WebServiceKey specified
    by $env:WEB_SERV_KEY and stores the results in $CloudpagingServerData
#>
function Get-CloudpagingServerData {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$WebServiceKey,
        [parameter(mandatory = $true)]
        [string]$ServerURL
    )
    # depends on cloudpaging server module
    if (-not (Get-InstalledModule -Name 'CloudpagingServer')){
        throw "Get-CloudpagingServerData depends on the CloudpagingServer powershell module. Install the module and try again."
    }

    # what to do in PS5
    $scriptBlock = {
        [CmdletBinding()]
        param(
            [string]$Web_Service_Key,
            [string]$Server_URL
        )
        Import-Module -Name 'CloudpagingServer' -Force -verbose:$false
        Set-CloudpagingWebService -WebServiceKey $Web_Service_Key -ServerUrl $Server_URL
        $apps = Get-CloudpagingApplication
        $data = foreach ($app in $apps){
            [pscustomobject]@{
                Application = $app
                LicensePolicy = $app | Get-CloudpagingLicensePolicy
            }
        }
        return $data
    }

    if ($PSEdition -eq 'Desktop'){
        Write-Verbose "PSEdition is 'Desktop', running command directly"
        . $scriptBlock -Web_Service_Key $WebServiceKey -Server_URL $ServerURL
    }
    else {
        Write-Verbose "PSEdition is not 'Desktop', running command through powershell.exe"
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $scriptBlock -ArgumentList ($WebServiceKey, $ServerURL)
    }
}

<#
.SYNOPSIS
    Get-ResetVMStatus is used check if the VM under VMFolder needs to be reset.
.DESCRIPTION
    Get-ResetVMStatus looks for 'ResetVM.txt' under the specified VMFolder to see if the VM needs
    to be reset. Returns $true if 'ResetVM.txt' exists and $false if it doesn't.
    To be used with Set-ResetVMStatus.
.NOTES
    Initially set up for Automated Packaging of Cloudpaging packages 2026-Jun-24
.PARAMETER VMFolder
    Specifies the path to the folder where the VM's vagrantfile resides.
.EXAMPLE
    Get-ResetVMStatus -VMFolder $PackagerVMFolder
    
    Checks if the PackagerVM needs to be reset.
#>
function Get-ResetVMStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMFolder
    )
    Write-Verbose "Checking for 'ResetVM.txt' under VMFolder ($VMFolder)"
    Test-Path -Path (Join-Path -Path $VMFolder -ChildPath 'ResetVM.txt')
}

<#
.SYNOPSIS
    Get-VagrantVMs returns information about vagrant VMs for the current user.
.DESCRIPTION
    Get-VagrantVMs uses 'vagrant global-status --prune' to get the vagrant vms for the current user and returns an
    array list containing hash tables with each VM's information (id, name, provider, state, & directory).
.NOTES
    Initially set up for Automated Packaging of Cloudpaging packages 2026-May-07
.EXAMPLE
    $vms = Get-VagrantVMs
    $vms | ForEach-Object {$_ | out-string }

    Name                           Value
    ----                           -----
    id                             207f738
    name                           win11_Player_s2
    provider                       hyperv
    state                          running
    directory                      D:/VMs/AP/PlayerVM


    Name                           Value
    ----                           -----
    id                             db8f339
    name                           win11_Packager_s2
    provider                       hyperv
    state                          running
    directory                      D:/VMs/AP/PackagerVM

    In this example, the result from Get-VagrantVMs is stored in $vms then displayed to the console.
#>
function Get-VagrantVMs {
    $ignoreText = @'
The above shows information about all known Vagrant environments
on this machine. This data is cached and may not be completely
up-to-date (use "vagrant global-status --prune" to prune invalid
entries). To interact with any of the machines, you can go to that
directory and run Vagrant, or you can use the ID directly with
Vagrant commands from any directory. For example:
"vagrant destroy 1a2b3c4d"
'@
    $globalStatus = vagrant global-status --prune | Where-Object {!($ignoreText.contains($_))} | Out-String
    $regex = [regex]::new('^(?<id>(?:\d|\w){7})\s+(?<name>\S+)\s+(?<provider>\w+)\s+(?<state>\w+)\s+(?<directory>\S+)\s*$','multiline')
    $allMatches = $regex.Matches($globalStatus)
    $allResults = [System.Collections.ArrayList]::new()
    foreach ($group in $allMatches) {
        $captureGroups = $group.groups | Where-Object {$null -eq $_.Groups}
        $all =$captureGroups | ForEach-Object { @{ $_.name = $_.value } }
        $allResults.Add([PSCustomObject]$all) | Out-Null
    }
    return $allResults
}

<#
.SYNOPSIS
    Initialize-Path initializes the Path specified.
.DESCRIPTION
    Initialize-Path finds the part of the path specified if Path that already exists and
    creates all missing folders until the specified Path exists.
.NOTES
    Initially set up for Automated Packaging of Cloudpaging packages 2026-Jun-16
.PARAMETER Path
    The Path to check for and create if it does not exist.
.PARAMETER Session
    Passed along to Invoke-Command | from Invoke-Command help:
    This is a dynamic parameter made available by the **FileSystem** provider.

    Specify the **PSSession** object to which a remote file is being copied. When you use this
    parameter, the **Destination** parameter refers to the local path on the remote machine.

    For more information, see
    [about_FileSystem_Provider](../Microsoft.PowerShell.Core/About/about_FileSystem_Provider.md).
.EXAMPLE
    Initialize-Path -Path 'E:\VMs\AP\PackagerVM\' 

    Initialize-Path will check for 'E:\VMs\AP\Packager\' and create the path if it does not exist.
.EXAMPLE
    Initialize-Path -Path 'C:\AP_Work' -Session $packagerSession

    Initialize-Path will check for 'C:\AP_Work' and create the path if it does not exist on the
    Windows system specified in $packagerSession
#>
function Initialize-Path {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession[]]$Session
    )

    $scriptBlock = {
        [CmdletBinding()]
        param(
            $fullPath
        )
        # $VerbosePreference = $Using:VerbosePreference
        # Ensure that path doesn't end with '\' for consistency
        if ($fullPath.EndsWith('\')){ $fullPath = $fullPath.Substring(0,($fullPath.Length-1)) }
        if (Test-Path $fullPath) {
            Write-Verbose "Path ($fullPath) exists"
        }
        else {
            $folderStack = New-Object System.Collections.Stack
            $folderStack.Push((Split-Path $fullPath -Leaf))
            $tempPath = Split-Path $fullPath -Parent
            while (-not (Test-Path $tempPath)){
                # push leafs until temp path exists
                $folderStack.Push((Split-Path $tempPath -Leaf))
                $tempPath = Split-Path $tempPath -Parent
                # catch if tempPath is empty - that means we couldn't find a place to start making folders from.
                if ($tempPath -eq '') { throw "The path passed in ($fullPath) cannot be created. This is likely because the root of the path specified ($($folderStack.Pop())) doesn't exist."}
            }
            Write-Verbose "Creating path, starting from ($tempPath)"
            while ($folderStack.Count) {
                $folder = $folderStack.Pop()
                Write-Verbose "Creating folder ($folder) under ($tempPath)"
                New-Item -Type Directory -Path $tempPath -Name $folder | Out-Null
                $tempPath = Join-Path -Path $tempPath -ChildPath $folder
            }
            Write-Host "Path ($fullPath) initialized"
        }
    }

    if ($Session) {
        Invoke-Command -Session $Session -ScriptBlock $scriptBlock -ArgumentList $Path
    }
    else {
        & $scriptBlock $Path
    }
}

<#
.SYNOPSIS
    Invoke-CommandAsScheduledTask creates a scheduled task on a system to execute the specified command.
.DESCRIPTION
    Invoke-CommandAsScheduledTask is for creating a scheduled task to execute the specified command
    on another system and can be used to mimic running the command as if logged onto the system.
.NOTES
    Initially set up for Automated Packaging of Cloudpaging packages 2026-Jun-11
.PARAMETER TaskName
    Passed along to Register-ScheduledTask | from NRegister-ScheduledTask help:
    Specifies the name of a scheduled task.
.PARAMETER Execute
    Passed along to New-ScheduledTaskAction | from New-ScheduledTaskAction help:
    Specifies the path to an executable file.
.PARAMETER Argument
    Passed along to New-ScheduledTaskAction | from New-ScheduledTaskAction help:
    Specifies arguments for the command-line operation.
.PARAMETER UserId
    Passed along to New-ScheduledTaskPrincipal | from New-ScheduledTaskPrincipal help:
    Specifies the user ID that Task Scheduler uses to run the tasks that are associated with the principal.
.PARAMETER LogonType
    Passed along to New-ScheduledTaskPrincipal [Default: Interactive] | from New-ScheduledTaskPrincipal help:
    Specifies the security logon method that Task Scheduler uses to run the tasks that are associated with the
    principal. The acceptable values for this parameter are:
    
    - None
    
    - Password
    
    - S4U
    
    - Interactive
    
    - Group
    
    - ServiceAccount
    
    - InteractiveOrPassword
.PARAMETER RunLevel
    Passed along to New-ScheduledTaskPrincipal [Default: Highest] | from New-ScheduledTaskPrincipal help:
    Specifies the level of user rights that Task Scheduler uses to run the tasks that are associated with the
    principal. The acceptable values for this parameter are:

    - Highest. Tasks run by using the highest privileges. - Limited. Tasks run by using the least-privileged user
    account (LUA).
.PARAMETER Session
    Passed along to Invoke-Command | from Invoke-Command help:
    This is a dynamic parameter made available by the **FileSystem** provider.

    Specify the **PSSession** object to which a remote file is being copied. When you use this
    parameter, the **Destination** parameter refers to the local path on the remote machine.

    For more information, see
    [about_FileSystem_Provider](../Microsoft.PowerShell.Core/About/about_FileSystem_Provider.md).
.EXAMPLE
    $script = 'start-studio-extract.ps1'
    $command = @(
        "& 'C:\Program Files\Numecent\Cloudpaging Studio\CloudpagingStudio.exe'",
        "-x:f '$current_tok_path"
    ) -join ' '
    $command | Out-File -FilePath ".\$script"
    Copy-Item -ToSession $packagerSession -Path ".\$script" -Destination $VMWorkingFolder

    $extractParams = @{
        TaskName = "Extract-$appName"
        Execute = 'Powershell.exe'
        Argument = "$(Join-Path -Path $VMWorkingFolder -ChildPath $script) -noexit"
        UserId = 'packager_s2\vagrant'
        Session = $packagerSession
    }
    Invoke-CommandAsScheduledTask @extractParams

    Creates the 'start-studio-extract.ps1' script, copies it to the packagerVM, and executes the
    script as the logged in vagrant account (with Highest run level).
#>
function Invoke-CommandAsScheduledTask {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$TaskName,
        [Parameter(Mandatory = $true)]
        [string]$Execute,
        [Parameter(Mandatory = $false)]
        [string]$Argument = '',
        [Parameter(Mandatory = $true)]
        [string]$UserId,
        [Parameter(Mandatory = $false)]
        [ValidateSet('None', 'Password', 'S4U', 'Interactive', 'Group', 'ServiceAccount', 'InteractiveOrPassword')]
        [string]$LogonType = 'Interactive',
        [Parameter(Mandatory = $false)]
        [ValidateSet('Highest', 'Limited')]
        [string]$RunLevel = 'Highest',
        [parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession]$Session,  # Your established PSSession to the VM
        [switch]$NoCleanup # Doesn't cleanup the scheduled task after running
    )
    
    $scriptBlock = {
        [CmdletBinding()]
        # set up Scheduled Task
        $action = New-ScheduledTaskAction -Execute $using:Execute -Argument $using:Argument
        Write-Verbose "Action set up with Execute ($using:Execute) and Argument ($using:Argument)"
        $principal = New-ScheduledTaskPrincipal -UserId $using:UserId -LogonType $using:LogonType -RunLevel $using:RunLevel
        Write-Verbose "Principal set up with UserId ($using:UserId), LogonType ($using:LogonType), and RunLevel ($using:RunLevel)"
        $task = New-ScheduledTask -Action $action -Principal $principal
        Register-ScheduledTask -TaskName $using:TaskName -InputObject $task -Force -Verbose:$false | Out-Null
        Write-Verbose "Task ($using:TaskName) created"
        # Start Scheduled Task
        Write-Verbose "Starting task ($using:TaskName)..."
        Start-ScheduledTask -TaskName $using:TaskName
        # Remove Scheduled Task
        if ($using:NoCleanup) {
            write-host "No Cleanup"
        } else {
            Write-Verbose "Removing task ($using:TaskName)"
            Unregister-ScheduledTask -TaskName $using:TaskName -Confirm:$false
        }
    }
    Invoke-Command -Session $Session -ScriptBlock $scriptBlock
}

<#
.SYNOPSIS
    Limit-PackageFolders cleans up excess _pkg and _pf folders that were made during AP runs.
.DESCRIPTION
    Limit-PackageFolders queries folders under the specified path, determines the amount of unique
    versions for which _pkg and/or _pf folders exist, then removes the lowest versions down to the
    number specified by Count.
.NOTES
    Initially set up for Automated Packaging of Cloudpaging packages 2026-Jul-02
.PARAMETER Path
    Passed along to Get-ChildItem
    Specifies the path to the folder where _pkg and _pf folders are created during AP runs.
.PARAMETER WhatIf
    Passed along to Remove-Item | from Remove-Item help:
    Shows what would happen if the cmdlet runs. The cmdlet is not run.
.PARAMETER Count
    Specifies the number of unique versions, for which _pkg and _pf folders exist, under the path
    specified that should remain after execution of Limit-PackageFolders completes
.EXAMPLE
    Limit-PackageFolders -Verbose -Path $yamlInfo.AppSettings.PkgStagingDirectory -Count $yamlInfo.RetentionSettings.PackageCount
    Removes excess _pkg & _pf folders under $yamlInfo.AppSettings.PkgStagingDirectory based on the
    count specified with $yamlInfo.RetentionSettings.PackageCount
#>
function Limit-PackageFolders {
    [CmdletBinding()]
    param(
        [parameter(Mandatory=$true)]
        [string]$Path,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,
        [Parameter(Mandatory = $false)]
        [int]$Count = 2
    )
    if ( -not (test-path -Path $Path -PathType Container) ) {
        throw "`$Path ($Path) does not exist."
    }
    $allFolders = Get-ChildItem -Path $Path -Directory
    $versions = $allFolders.Name | ForEach-Object {($_ -split '_')[0]} | Select-Object -Unique | Sort-Object @{Expression = {[version]$_}}
    Write-Verbose "Found ($($versions.count)) version folders under '$Path': ('$($allFolders.Name -join "', '")')"
    if ($versions.count -le $Count) {
        Write-Verbose "Path ($Path) does not exceed a count of '$Count' package folders per version."
        return
    }
    $versionsToRemove = $versions | Select-Object -First ($versions.count - $Count)
    foreach ($version in $versionsToRemove) {
        Write-Host "Removing package folders for version ($version)"
        $allFolders | Where-Object {$_.name.StartsWith($version)} | Remove-Item -Recurse -Force -WhatIf:$WhatIf
    }
}

<#
.SYNOPSIS
    Limit-STPBackupFolders cleans up excess version folders that were made and STPs were backed up to
    during AP runs.
.DESCRIPTION
    Limit-STPBackupFolders queries the version folders under the specified path then removes the lowest
    versions down to the number specified by Count.
.NOTES
    Initially set up for Automated Packaging of Cloudpaging packages 2026-Jul-02
.PARAMETER Path
    Passed along to Get-ChildItem
    Specifies the path to the folder where version folders are created and finished STPs are backed
    up to during AP runs.
.PARAMETER WhatIf
    Passed along to Remove-Item | from Remove-Item help:
    Shows what would happen if the cmdlet runs. The cmdlet is not run.
.PARAMETER Count
    Specifies the number of version folders under the path specified that should remain after
    execution of Limit-STPBackupFolders completes
.EXAMPLE
    Limit-STPBackupFolders -Verbose -Path $yamlInfo.AppSettings.STPBackupDirectory -Count $yamlInfo.RetentionSettings.STPCount
    Removes excess version folders under $yamlInfo.AppSettings.STPBackupDirectory based on the
    count specified with $yamlInfo.RetentionSettings.STPCount
#>
function Limit-STPBackupFolders {
    [CmdletBinding()]
    param(
        [parameter(Mandatory=$true)]
        [string]$Path,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,
        [Parameter(Mandatory = $false)]
        [int]$Count = 3
    )
    if ( -not (test-path -Path $Path -PathType Container) ) {
        throw "`$Path ($Path) does not exist."
    }
    $folders = Get-ChildItem -Path $Path -Directory | Sort-Object @{Expression = {[version]$_.name}} | Select-Object -Property Name, fullname
    $foldersCount = ($folders | Measure-Object).Count
    Write-Verbose "Found ($foldersCount) folders under '$Path': ('$($folders.Name -join "', '")')"
    if ($foldersCount -le $Count) {
        Write-Verbose "Path ($Path) does not exceed a count of '$Count'."
        return
    }
    $toRemove = $folders | Select-Object -First ($foldersCount - $Count) -ExpandProperty FullName
    foreach ($item in $toRemove) {
        Write-Host "Removing '$item'"
        Remove-Item -Path $item -Recurse -Force -WhatIf:$WhatIf
    }
}

<#
.SYNOPSIS
    Reset-VMEnvironment prepares packager and player vms using vagrant for automated packaging.
.DESCRIPTION
    Reset-VMEnvironment uses vagrant "box update", "box prune", "up", and "snapshot push" to start
    packager and player vms if they are not yet running, OR "snapshot pop --no-delete", and
    "resume" if they are. Reset-VMEnvironment will also destroy the VMs if it's the weekend or if
    the -Force flag is used.
.NOTES
    Initially set up for Automated Packaging of Cloudpaging packages 2026-May-07
.PARAMETER Force
    Indicates that "vagrant box destroy" should be run.
.PARAMETER PackagerVMFolder
    Specifies the path to the folder where the packager VM's vagrantfile resides.
.PARAMETER PlayerVMFolder
    Specifies the path to the folder where the player VM's vagrantfile resides.
.PARAMETER PackagerOnly
    Indicates that this function should only reset the packager VM
.PARAMETER PlayerOnly
    Indicates that this function should only reset the player VM
.EXAMPLE
    Reset-VMEnvironment -PackagerVMFolder D:\VMs\AP\PackagerVM\ -PackagerOnly -Force

    In this example, the packager VM will be destroyed before starting it up fresh
.EXAMPLE
    Reset-VMEnvironment -PlayerVMFolder D:\VMs\AP\PlayerVM\ -PlayerOnly

    In this example, the player VM will be started if it's not loaded or it will revert to it's
    snapshot and then resume if it is loaded.
#>
function Reset-VMEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$PackagerVMFolder,
        [Parameter(Mandatory = $false)]
        [string]$PlayerVMFolder,
        [switch]$Force,
        [switch]$PackagerOnly,
        [switch]$playerOnly
    )

    $ignoreText = @'
Timed out while waiting for the machine to boot. This means that
Vagrant was unable to communicate with the guest machine within
the configured ("config.vm.boot_timeout" value) time period.

If you look above, you should be able to see the error(s) that
Vagrant had when attempting to connect to the machine. These errors
are usually good hints as to what may be wrong.

If you're using a custom box, make sure that networking is properly
working and you're able to connect to the machine. It is a common
problem that networking isn't setup properly in these boxes.
Verify that authentication configurations are also setup properly,
as well.

If the box appears to be booting properly, you may want to increase
the timeout ("config.vm.boot_timeout") value.
'@

    if (-not $playerOnly) {
        if ('' -eq $PackagerVMFolder){ throw "PackagerVMFolder not specified!" }

        Write-Verbose "Setting up Packager VM"
        Push-Location -Path $PackagerVMFolder
        Write-Verbose "location set to '$((Get-Location).Path)'"
        if ( (("Saturday","Sunday") -contains (Get-Date).DayOfWeek) -or $Force ) {
            Write-Verbose "(('Saturday','Sunday') -contains $((Get-Date).DayOfWeek)) -or $Force)"
            Write-Verbose "Destroying Packager"
            vagrant destroy -f
        }

        Write-Verbose "Gathering vm info"
        $vms = Get-VagrantVMs
        $packagerID = ($vms | Where-Object {$_.directory -like '*packagerVM*'}).id
        
        if (-not $packagerID){
            Write-Verbose "No packager vm started, attempting to start..."
            vagrant box update
            vagrant box prune
            vagrant up
            vagrant snapshot push
        }
        else {
            Write-Verbose "VM id for Packager ($packagerID)"
            Write-Verbose "Starting Packager VM from snapshot"
            vagrant snapshot pop --no-delete $packagerID 2>&1 | Where-Object {!($ignoreText.contains($_))}
            vagrant resume $packagerID 2>&1 | Where-Object {!($ignoreText.contains($_))}
        }
        if (Test-Path -Path '.\ResetVM.txt') { Remove-Item -Path '.\ResetVM.txt' -Force }
        Pop-Location
        Write-Verbose "location set to '$((Get-Location).Path)'"
    }
    if (-not $PackagerOnly) {
        if ('' -eq $PlayerVMFolder){ throw "PackagerVMFolder not specified!" }

        Write-Verbose "Setting up Player VM"
        Push-Location -Path $PlayerVMFolder
        Write-Verbose "location set to '$((Get-Location).Path)'"
        if ( (("Saturday","Sunday") -contains (Get-Date).DayOfWeek) -or $Force ) {
            Write-Verbose "('Saturday','Sunday') -contains ($((Get-Date).DayOfWeek) -or $Force)"
            Write-Verbose "Destroying Player"
            vagrant destroy -f
        }

        Write-Verbose "Gathering vm info"
        $vms = Get-VagrantVMs
        $PlayerID = ($vms | Where-Object {$_.directory -like '*PlayerVM*'}).id
        
        if (-not $PlayerID){
            Write-Verbose "No Player vm started, attempting to start..."
            vagrant box update
            vagrant box prune
            vagrant up
            vagrant snapshot push
        }
        else {
            Write-Verbose "VM id for Player ($PlayerID)"
            Write-Verbose "Starting Player VM from snapshot"
            vagrant snapshot pop --no-delete $PlayerID 2>&1 | Where-Object {!($ignoreText.contains($_))}
            vagrant resume $PlayerID 2>&1 | Where-Object {!($ignoreText.contains($_))}
        }
        if (Test-Path -Path '.\ResetVM.txt') { Remove-Item -Path '.\ResetVM.txt' -Force }
        Pop-Location
        Write-Verbose "location set to '$((Get-Location).Path)'"
    }
}

<#
.SYNOPSIS
    Set-ResetVMStatus is used to mark that the VM under VMFolder needs to be reset.
.DESCRIPTION
    Set-ResetVMStatus creates 'ResetVM.txt' under the specified VMFolder to signify that the VM
    needs to be reset. To be used with Get-ResetVMStatus.
.PARAMETER VMFolder
    Specifies the path to the folder where the VM's vagrantfile resides.
.NOTES
    Initially set up for Automated Packaging of Cloudpaging packages 2026-Jun-24
.EXAMPLE
    Set-ResetVMStatus -VMFolder $PackagerVMFolder

    Marks that the PackagerVM needs to be reset.
#>
function Set-ResetVMStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMFolder
    )
    New-Item -Path (Join-Path -Path $VMFolder -ChildPath 'ResetVM.txt') -Force -ErrorAction SilentlyContinue | Out-Null
    Write-Verbose "'ResetVM.txt' created under VMFolder ($VMFolder)"
}

<#
.SYNOPSIS
    A function for testing detection methods.
.DESCRIPTION
    Checks for path/product code and property + value based on specified flags.
.NOTES
    Initially set up for Automated Packaging of Cloudpaging packages 2026-Mar-09
.EXAMPLE
    Test-DetectionMethod -Verbose
    Explanation of the function or its result. You can include multiple examples with additional .EXAMPLE lines
#>
function Test-DetectionMethod {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,ParameterSetName='MSI-value')]
        [Parameter(Mandatory=$true,ParameterSetName='Path-value')]
        [string]$Value,
        [Parameter(Mandatory=$true,ParameterSetName='Path-exists')]
        [Parameter(Mandatory=$true,ParameterSetName='Path-value')]
        [string]$Path,
        [Parameter(Mandatory=$true,ParameterSetName='MSI-value')]
        [Parameter(Mandatory=$true,ParameterSetName='Path-value')]
        [ValidateSet('eq', 'ne', 'gt', 'ge', 'lt','le','like','notlike','match','notmatch','contains','notcontains')]
        [string]$Operator,
        [Parameter(Mandatory=$true,ParameterSetName='MSI-value')]
        [Parameter(Mandatory=$true,ParameterSetName='MSI-exists')]
        [string]$ProductCode,
        [Parameter(Mandatory=$true,ParameterSetName='Path-value')]
        [string]$Property,
        [Parameter(Mandatory=$true,ParameterSetName='Path-value')]
        [ValidateSet('Integer', 'String', 'Version')]
        [string]$PropertyType
    )

    if ($PSCmdlet.ParameterSetName -like "Path*") {
        Write-Verbose "Checking for path ($Path)"
        if ($PSCmdlet.ParameterSetName -like "*exists") { return (Test-Path -Path $Path) }
        if (Test-Path -Path $Path) {
            $propertyValue = Get-ItemProperty -Path $Path | Select-Object -ExpandProperty $Property -ErrorAction SilentlyContinue
            Write-Verbose "And that Property ($Property) -$Operator value ($Value)`n([$PropertyType]$propertyValue -$Operator [$PropertyType]$Value)"
        }
        else { return $false }
    }
    if ($PSCmdlet.ParameterSetName -like "MSI*") {
        $uninstall64 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode"
        $uninstall32 = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode"
        Write-Verbose "Checking for product code ($ProductCode)"
        if ($PSCmdlet.ParameterSetName -like "*exists") { return ((test-path $uninstall64) -or (Test-Path $uninstall32)) }
        if (test-path $uninstall64) {
            $propertyValue = Get-ItemProperty -Path $uninstall64 | Select-Object -ExpandProperty 'DisplayVersion' -ErrorAction SilentlyContinue
        }
        elseif (Test-Path $uninstall32) {
            $propertyValue = Get-ItemProperty -Path $uninstall32 | Select-Object -ExpandProperty 'DisplayVersion' -ErrorAction SilentlyContinue
        }
        else { return $false }
        $PropertyType = 'Version' # CMDetectionClauseWindowsInstaller only supports property version
        Write-Verbose "And that ProductVersion $Operator value`n([$PropertyType]$propertyValue -$Operator [$PropertyType]$Value)"
    }

    # type casting based on $PropertyType
    switch ($PropertyType) {
        'Integer' {
            $castedValue = $Value -as [int]
            $castedPropertyValue = $propertyValue -as [int]
            if (($null -eq $castedValue) -and ($null -ne $Value)) {
                throw "Casting value ($Value) as [int] resulted in `$null"
            }
            if (($null -eq $castedPropertyValue) -and ($null -ne $propertyValue)) {
                throw "Casting propertyValue ($propertyValue) as [int] resulted in `$null"
            }
        }
        'String' {
            $castedValue = $Value -as [string]
            $castedPropertyValue = $propertyValue -as [string]
            if (($null -eq $castedValue) -and ($null -ne $Value)) {
                throw "Casting value ($Value) as [string] resulted in `$null"
            }
            if (($null -eq $castedPropertyValue) -and ($null -ne $propertyValue)) {
                throw "Casting propertyValue ($propertyValue) as [string] resulted in `$null"
            }
        }
        'Version' {
            $castedValue = $Value -as [version]
            $castedPropertyValue = $propertyValue -as [version]
            if (($null -eq $castedValue) -and ($null -ne $Value)) {
                throw "Casting value ($Value) as [version] resulted in `$null"
            }
            if (($null -eq $castedPropertyValue) -and ($null -ne $propertyValue)) {
                throw "Casting propertyValue ($propertyValue) as [version] resulted in `$null"
            }
        }
        Default { throw "Property Type ($PropertyType) is not valid" }
    }
    Write-Verbose "Casted: ($castedPropertyValue) -$Operator ($castedValue)"
    switch ($Operator) {
        'eq' { return $castedPropertyValue -eq $castedValue }
        'ne' { return $castedPropertyValue -ne $castedValue }
        'gt' { return $castedPropertyValue -gt $castedValue }
        'ge' { return $castedPropertyValue -ge $castedValue }
        'lt' { return $castedPropertyValue -lt $castedValue }
        'le' { return $castedPropertyValue -le $castedValue }
        'like' { return $castedPropertyValue -like $castedValue }
        'notlike' { return $castedPropertyValue -notlike $castedValue }
        'match' { return $castedPropertyValue -match $castedValue }
        'notmatch' { return $castedPropertyValue -notmatch $castedValue }
        'contains' { return $castedPropertyValue -contains $castedValue }
        'notcontains' { return $castedPropertyValue -notcontains $castedValue }
        Default { throw "Unsupported operator: $Operator" }
    }
}

<#
.SYNOPSIS
    For monitoring a process with helpful output to the command window.
.DESCRIPTION
    Monitors a process and will keep track of how long this function has been monitoring for and output that
    to the command window. If Path is specified it will also monitor the log file mentioned and output any updates
    to that file in the command window also.
.NOTES
    Initially set up for Automated Packaging of Cloudpaging packages 2026-Mar-04
.PARAMETER Name
    Passed along to Get-Process and only supports 1 name | from Get-Process help:
    Specifies one or more processes by process ID (PID). You can specify multiple IDs separated by
    commas. To get the PID of a process, use `Get-Process`. To get the PID of the current PowerShell
    session, use `$PID`.
.PARAMETER Id
    Passed along to Get-Process and only supports 1 id | from Get-Process help:
    Specifies one or more processes by process ID (PID). You can specify multiple IDs separated by
    commas. To get the PID of a process, use `Get-Process`. To get the PID of the current PowerShell
    session, use `$PID`.
.PARAMETER Path
    The full path to a log file that Wait-ForProcessWithLogging will monitor for changes and output
    any to the terminal.
.PARAMETER UpdateFrequency
    How often (in seconds) to output updates to the terminal window.
.PARAMETER Session
    Passed along to Invoke-Command | from Invoke-Command help:
    Specifies an array of sessions in which this cmdlet runs the command. Enter a variable that contains
    **PSSession** objects or a command that creates or gets the **PSSession** objects, such as a
    `New-PSSession` or `Get-PSSession` command.

    When you create a **PSSession**, PowerShell establishes a persistent connection to the remote
    computer. Use a **PSSession** to run a series of related commands that share data. To run a single
    command or a series of unrelated commands, use the **ComputerName** parameter. For more information,
    see [about_PSSessions](./About/about_PSSessions.md).
.PARAMETER WaitForStart
    Indicates that this function will wait for the process specified by Name or Id to start before
    waiting for the process to no longer be running.
.PARAMETER WaitForStartTimeout
    Specifies how long this function will wait for the process specified by Name to start before
    moving on and verifying the process is no longer running.
.PARAMETER NoNewLine
    Specifies if Wait-ForProcessWithLogging should or should not write on a new line when writing
    the elapsed time to the terminal window. True by default
.EXAMPLE
    Wait-ForProcessWithLogging -Name 'deploy-application' -Session $session -WaitForStart -Path 
    'C:\Windows\Logs\Software\*<appName>*'
    
    In this example Wait-ForProcessWithLogging will wait for the deploy-application process to
    start, then will monitor the process to end on the computer set up in the $session variable.
    The PSADT log file is also specified, so updates to that log file will be output to the command
    window.
.EXAMPLE
    Wait-ForProcessWithLogging -Name 'excel' -NoNewLine $false -Path
    'C:\ProgramData\MTU\excel-running.log'

    Sample output:
    Monitoring (C:\ProgramData\MTU\excel-running.log) for updates...
    Waiting for process ('excel') to exit...
    Elapsed time: 00:00:00
    [05/11/2026 11:52:22]Excel still running
    Elapsed time: 00:00:05
    Elapsed time: 00:00:10
    [05/11/2026 11:52:32]Excel still running
    Elapsed time: 00:00:15
    [ END ] time: 00:00:20
    Process ('excel') ended
    
    This will monitor that excel is running on the local system. The excel-running.log file and
    -NoNewLine are also specified, so updates to that log file will be output to the command window
    and the Elapsed time messages will be written to a new line.
#>
function Wait-ForProcessWithLogging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ParameterSetName='Name')]
        [string]$Name,
        [Parameter(Mandatory = $true, ParameterSetName='Id')]
        [int]$Id,
        [Parameter(Mandatory = $false)]
        [string]$Path,
        [Parameter(Mandatory = $false)]
        [int]$UpdateFrequency = 5,
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory = $false, ParameterSetName='Name')]
        [switch]$WaitForStart,
        [Parameter(Mandatory = $false, ParameterSetName='Name')]
        [int]$WaitForStartTimeout = 40,
        [Parameter(Mandatory = $false)]
        [bool]$NoNewLine = $true
    )

    if ($null -ne $Name) {
        $displayProcesses = "'$($Name -join "', & '")'"
        $processParams = @{
            Name = $Name
            IncludeUserName = $true
        }
    }
    else {
        $displayProcesses = "'$($Name -join "', & '")'"
        $processParams = @{
            Id = $Id
        }
    }
    
    if ($Path) {
        Write-Host "Monitoring ($Path) for updates..."
    }
    if ($WaitForStart){ Write-Host "Waiting for process ($displayProcesses) to start with timeout of ($WaitForStartTimeout) seconds..." }
    else { Write-Host "Waiting for process ($displayProcesses) to exit..." }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $timeMessage = "Elapsed time: $((New-TimeSpan -Seconds $stopwatch.Elapsed.TotalSeconds).ToString())"
    $timeMessageLength = $timeMessage.Length
    Write-Host -NoNewline:$NoNewLine $timeMessage
    if ($Session){
        $running = Invoke-Command -Session $session -ScriptBlock {
            $params = $using:processParams
            Get-Process @params -ErrorAction SilentlyContinue
        }
        if ($WaitForStart) {
            while ((-not $running) -and ($stopwatch.Elapsed.TotalSeconds -lt $WaitForStartTimeout)) {
                # sleep
                Start-Sleep -Seconds $UpdateFrequency
                $running = Invoke-Command -Session $session -ScriptBlock {
                    $params = $using:processParams
                    Get-Process @params -ErrorAction SilentlyContinue
                }

                # clear time message
                if ($NoNewLine) { Write-Host ("`b" * $timeMessageLength) -NoNewline }
                
                # write time message
                $timeMessage = "Elapsed time: $((New-TimeSpan -Seconds $stopwatch.Elapsed.TotalSeconds).ToString())"
                if (-not $running) { Write-Host -NoNewline:$NoNewLine $timeMessage }
            }
            # clear time message
            if ($NoNewLine) { Write-Host ("`b" * $timeMessageLength) -NoNewline }
            if ((-not $running) -and ($stopwatch.Elapsed.TotalSeconds -lt $WaitForStartTimeout)){
                Write-Host "The timeout of ($WaitForStartTimeout) seconds was reached while waiting for process ($Name) to start."
            }
            else {
                Write-Host "[START] time: $((New-TimeSpan -Seconds $stopwatch.Elapsed.TotalSeconds).ToString())"
                Write-Host "Waiting for process ($displayProcesses) to exit..."
            }
        }
        
        if ($path) {
            $fileExists = Invoke-Command -Session $Session -ScriptBlock { Test-Path $using:path }
            if ($fileExists){
                # if the file exists already, start reading from the current end of the log
                $lastLineIndex = (Invoke-Command -Session $Session -ScriptBlock { Get-Content $using:Path -ReadCount 0 }).Count
            }
            else { $lastLineIndex = 0 }
        }
        else {
            $lastLineIndex = 0
        }
        while ($running) {
            # sleep
            Start-Sleep -Seconds $UpdateFrequency
            $running = Invoke-Command -Session $session -ScriptBlock {
                $params = $using:processParams
                Get-Process @params -ErrorAction SilentlyContinue
            }

            # get lines of log file to display
            if ($Path) {
                $fileExists = Invoke-Command -Session $Session -ScriptBlock { Test-Path $using:path }
                if ($fileExists) {
                    $currentLineCount = (Invoke-Command -Session $Session -ScriptBlock { Get-Content $using:Path -ReadCount 0 }).Count
                    if ($currentLineCount -gt $lastLineIndex){
                        $toDisplay = Invoke-Command -Session $Session -ScriptBlock { Get-Content $using:Path -Tail ($using:currentLineCount - $using:lastLineIndex) }
                        $lastLineIndex = $currentLineCount
                    }
                    else { $toDisplay = '' }
                }
            }
            
            # clear time message
            if ($NoNewLine) { Write-Host ("`b" * $timeMessageLength) -NoNewline }
            
            # write log output
            if (($null -ne $toDisplay) -and ($toDisplay -ne '')) {
                if (($toDisplay | Measure-Object).count -gt 1){
                    Write-Host "$($toDisplay -join "`n")"
                }
                elseif (($toDisplay.Length -lt $timeMessageLength) -and $NoNewLine) {
                    $padCount = $timeMessageLength - $toDisplay.Length
                    $toDisplay += ' ' * $padCount
                    Write-Host $toDisplay
                }
                else { Write-Host $toDisplay }
            }
            
            # write time message
            $timeMessage = "Elapsed time: $((New-TimeSpan -Seconds $stopwatch.Elapsed.TotalSeconds).ToString())"
            if ($running) { Write-Host -NoNewline:$NoNewLine $timeMessage }
        }
    }
    else {
        $running = Get-Process @processParams -ErrorAction SilentlyContinue
        if ($WaitForStart) {
            while (-not $running){
                # sleep
                Start-Sleep -Seconds $UpdateFrequency
                $running = Get-Process @processParams -ErrorAction SilentlyContinue

                # clear time message
                if ($NoNewLine) { Write-Host ("`b" * $timeMessageLength) -NoNewline }
                
                # write time message
                $timeMessage = "Elapsed time: $((New-TimeSpan -Seconds $stopwatch.Elapsed.TotalSeconds).ToString())"
                if (-not $running) { Write-Host -NoNewline:$NoNewLine $timeMessage }
            }
            # clear time message
            if ($NoNewLine) { Write-Host ("`b" * $timeMessageLength) -NoNewline }
            Write-Host "[START] time: $((New-TimeSpan -Seconds $stopwatch.Elapsed.TotalSeconds).ToString())"
            Write-Host "Waiting for process ($displayProcesses) to exit..."
        }

        if ($path) {
            Write-Verbose "Path ($path) specified"
            $fileExists = Test-Path $Path 
            if ($fileExists){
                # if the file exists already, start reading from the current end of the log
                $lastLineIndex = (Get-Content $Path -ReadCount 0).Count
            }
        }
        else {
            $lastLineIndex = 0
        }
        Write-Verbose "lastLineIndex: $lastLineIndex"
        while ($running) {
            # sleep
            Start-Sleep -Seconds $UpdateFrequency
            $running = Get-Process @processParams -ErrorAction SilentlyContinue

            # get lines of log file to display
            if ($Path) {
                $fileExists = Test-Path $Path
                if ($fileExists) {
                    $currentLineCount = (Get-Content $Path -ReadCount 0).Count
                    if ($currentLineCount -gt $lastLineIndex){
                        $toDisplay = Get-Content $Path -Tail ($currentLineCount - $lastLineIndex)
                        $lastLineIndex = $currentLineCount
                    }
                    else { $toDisplay = '' }
                }
            }

            # clear time message
            if ($NoNewLine) { Write-Host ("`b" * $timeMessageLength) -NoNewline }
            
            # write log output
            if (($null -ne $toDisplay) -and ($toDisplay -ne '')) {
                if (($toDisplay | Measure-Object).count -gt 1){
                    Write-Host "$($toDisplay -join "`n")"
                }
                elseif (($toDisplay.Length -lt $timeMessageLength) -and $NoNewLine) {
                    $padCount = $timeMessageLength - $toDisplay.Length
                    $toDisplay += ' ' * $padCount
                    Write-Host $toDisplay
                }
                else { Write-Host $toDisplay }
            }
            
            # write time message
            $timeMessage = "Elapsed time: $((New-TimeSpan -Seconds $stopwatch.Elapsed.TotalSeconds).ToString())"
            if ($running) { Write-Host -NoNewline:$NoNewLine $timeMessage }
        }
    }
    # clear time message
    if ($NoNewLine) { Write-Host ("`b" * $timeMessageLength) -NoNewline }
    Write-Host "[ END ] time: $((New-TimeSpan -Seconds $stopwatch.Elapsed.TotalSeconds).ToString())"
    Write-Host "Process ($displayProcesses) ended"
}

Export-ModuleMember -Function @(
    'Copy-ItemWithFallback',
    'Get-CloudpagingServerData',
    'Get-ResetVMStatus',
    'Get-VagrantVMs',
    'Initialize-Path',
    'Invoke-CommandAsScheduledTask',
    'Limit-PackageFolders',
    'Limit-STPBackupFolders',
    'Reset-VMEnvironment',
    'Set-ResetVMStatus',
    'Test-DetectionMethod',
    'Wait-ForProcessWithLogging'
)

### Soli Deo Gloria -mbparis