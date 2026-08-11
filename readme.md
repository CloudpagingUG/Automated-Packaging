# Automated Packaging

This pipeline is for automating the creation of Cloudpaging Packages (STPs) utilizing Cloudpaging Studio's Non-Interactive packaging commands.

## High level overview

[Start-Package.ps1](Start-Package.ps1) is the main script for Automated Packaging.<br>
It determines if it needs to run for the specified application by checking the most recent version held in the *InstallerDirectory*, specified in the application's Packaging_Config_File, against the latest version currently available in the specified *ProductionSTPRepository*.

It depends on the [Powershell-Yaml module](https://www.powershellgallery.com/packages/powershell-yaml/) being installed on the computer running start-package.ps1<br>
It utilizes functions from the local AutomatedPackaging.psm1 module to complete the packaging process.<br>
If environment variables are not set up for Slack messaging or Jira integration, the relevant code will not run.<br>
The Slack and Jira code is an example of functional code, if you want to utilize it replace any \<>'d sections with the appropriate information for your environment.

Outline of steps taken by Start-Package.ps1:
1. Prepare environment
    * Initalize variables
    * Prepare Slack and Jira setting
        * If needed, create Jira issue
        * Archive old Jira issues
    * Check for completed STP
        * If the STP exists ensure it's copied to *ProductionSTPRepository*
            * Set captureNeeded, prefetchNeeded, and stpNeeded variables to $false
            * Transition Jira issue to the appropriate status
    * Check for prefetch 
        * If precetch exists, set captureNeeded and prefetchNeeded variables to $false
    * Check for captured package 
        * If all package files exist the \_pkg folder, set captureNeeded variables to $false
    * If using Vagrant VMs, ensure they're ready for packaging
    * Ensure packaging folders & files are set up on VMs.
2. If captureNeeded, complete initial capture
    * Verify it hasn't already been completed
    * Perform capture
        * Set up script
        * Copy to packagerSession
        * Execute with Invoke-CommandAsScheduledTask
        * Monitor for install then Cloudpaging Studio completion
    * Verify package files
        * If successful, copy files to `<version>_pkg` folder under *PkgStagingDirectory*
3. If prefetchNeeded, capture prefetch (or notify that manual prefetch is required)
    * Verify it hasn't already been completed
    * Perform prefetch capture
        * Set up script
        * Copy to playerSession
        * Execute with Invoke-CommandAsScheduledTask
        * Monitor for Cloudpaging Player completion
    * If successful copy file to `<version>_pf` folder under *PkgStagingDirectory*
4. If stpNeeded, cloudify final STP with prefetch
    * Verify it hasn't already been completed
    * If inital capture wasn't needed, extract package onto packagerSession
        * Set up script
        * Copy to packagerSession
        * Execute with Invoke-CommandAsScheduledTask
        * Monitor for Cloudpaging Studio completion
    * Perform final cloudify
        * Set up script
        * Copy to packagerSession
        * Execute with Invoke-CommandAsScheduledTask
        * Monitor for Cloudpaging Studio completion
    * If successful
        * Backup to `<version>` folder *STPBackupDirectory*
        * Copy file to *ProductionSTPRepository*
5. Remove excess STPBackup & PkgStaging folders (based on *RetentionSettings*)

## How to run Start-Package.ps1

> The example code below is using `-packagerVMFolder` and `-playerVMFolder`, for a system configured with vagrant VMs (automatically manages snapshot/checkpoint reverting as needed). If you don't have vagrant VMs, use `-packagerSession` and `-playerSession` instead (manual snapshot/checkpoint and reverting required).

### PowerShell terminal variable initalization

```powershell
$env:SLACK_BOT_TOKEN = '<Slack API Token>'
$env:CHANNEL = '<slack channel>'
$env:JIRA_CREDS_USR = '<Jira User>'
$env:JIRA_CREDS_TKN = '<Jira PAT>'
$env:WEB_SERV_KEY = '<Cloudpaging Server WebServiceKey>'
$env:ADM_URL = '<Cloudpaging Admin URL>'
net use <network share> /persist:no
Register-PSRepository -SourceLocation '<network share>\ps_modules' -Name '<PS Repo Name>' -InstallationPolicy 'Trusted' -ErrorAction SilentlyContinue
Install-Module JiraPS -Scope AllUsers -Verbose:$false -Force -Repository <PS Repo Name>
Install-Module CloudpagingServer -Scope AllUsers -Verbose:$false -Force -Repository <PS Repo Name>
Import-Module JiraPS, CloudpagingServer -Force
$initialize = {
$rootPath = <full path to local copy of Automated-Packaging repo>
$allYamls = (Get-ChildItem -Path "$rootPath\YAMLs\*.yaml" -Exclude "Template*").FullName
$packagerVMFolder = 'D:\VMs\AP\PackagerVM\' # full path to packager vm folder
$playerVMFolder = 'D:\VMs\AP\PlayerVM\'}; # full path to player vm folder
. $initialize
```

### Full run

```powershell
. "<full path to local copy of this repo>\Start-Package.ps1" -SourceDirectory $rootPath -PackagerVMFolder $packagerVMFolder -PlayerVMFolder $playerVMFolder -Verbose -YamlFilePath ($allYamls | Where-Object {$_ -like "*<Search Text>*"})
```

### Adding or testing a new yaml config file

> Using the `-LocalTest` flag we overwrite the check for a completed capture in the *PkgStagingDirectory*.
> When useing `-LocalTest`, if you want the VMs to be reset then `-ResetVMs $true` must be specified

```powershell
# Only capture the install - so we can verify the FileExclusions & RegistryExclusions under CaptureSettings are properly configured and that the CaptureTimeoutSec gives the install enough time to finish
. "<full path to local copy of this repo>\Start-Package.ps1" -SourceDirectory $rootPath -PackagerVMFolder $packagerVMFolder -PlayerVMFolder $playerVMFolder -Prefetch $false -Finalize $false -Verbose -YamlFilePath ($allYamls | Where-Object {$_ -like "*<Search Text>*"}) -LocalTest
# Only capture the prefetch - so we can verify the PrefetchSettings are properly configured and to verify the application can be prefetch on a VM or if a manual prefetch is required
. "<full path to local copy of this repo>\Start-Package.ps1" -SourceDirectory $rootPath -PackagerVMFolder $packagerVMFolder -PlayerVMFolder $playerVMFolder -Capture $false -Finalize $false -Verbose -YamlFilePath ($allYamls | Where-Object {$_ -like "*<Search Text>*"}) -LocalTest
# Only finalize the completed STP
. "<full path to local copy of this repo>\Start-Package.ps1" -SourceDirectory $rootPath -PackagerVMFolder $packagerVMFolder -PlayerVMFolder $playerVMFolder -Capture $false -Prefetch $false -Verbose -YamlFilePath ($allYamls | Where-Object {$_ -like "*<Search Text>*"}) -LocalTest
```

## AutomatedPackaging.psm1 functions

|Function|SYNOPSIS|
|:--|:--|
|[Copy-ItemWithFallback](AutomatedPackaging.psm1#L72)|For Copying to/from a network share to/from a local VM.|
|[Get-CloudpagingServerData](AutomatedPackaging.psm1#L177)|Get-CloudpagingServerData queries Cloudpaging Admin and returns application and license policy information.|
|[Get-ResetVMStatus](AutomatedPackaging.psm1#L235)|Get-ResetVMStatus is used check if the VM under VMFolder needs to be reset.|
|[Get-VagrantVMs](AutomatedPackaging.psm1#L276)|Get-VagrantVMs returns information about vagrant VMs for the current user.|
|[Initialize-Path](AutomatedPackaging.psm1#L327)|Initialize-Path initializes the Path specified.|
|[Invoke-CommandAsScheduledTask](AutomatedPackaging.psm1#L452)|Invoke-CommandAsScheduledTask creates a scheduled task on a system to execute the specified command.|
|[Limit-PackageFolders](AutomatedPackaging.psm1#L523)|Limit-PackageFolders cleans up excess \_pkg and \_pf folders that were made during AP runs.|
|[Limit-STPBackupFolders](AutomatedPackaging.psm1#L574)|Limit-STPBackupFolders cleans up excess version folders that were made and STPs were backed up to during AP runs.|
|[Reset-VMEnvironment](AutomatedPackaging.psm1#L631)|Reset-VMEnvironment prepares packager and player vms using vagrant for automated packaging.|
|[Set-ResetVMStatus](AutomatedPackaging.psm1#L745)|Set-ResetVMStatus is used to mark that the VM under VMFolder needs to be reset.|
|[Test-DetectionMethod](AutomatedPackaging.psm1#L766)|A function for testing detection methods.|
|[Wait-ForProcessWithLogging](AutomatedPackaging.psm1#L937)|For monitoring a process with helpful output to the command window.|

## Config_File list

|Application|Added by|
|:--|:--|
|7-Zip|mbparis|
|Audacity|mbparis|
|Bentley Connection Client|mbparis|
|FileZilla|mbparis|
|FreeCAD|mbparis|
|Autodesk Fusion|mbparis|
|GIMP|mbparis|
|GIT|mbparis|
|Google Earth Pro|mbparis|
|iClicker Cloud|mbparis|
|Inkscape|mbparis|
|Notepad++|mbparis|
|Panopto recorder|mbparis|
|PuTTY|mbparis|
|Python|mbparis|
|R|mbparis|
|Ultimaker Cura|mbparis|
|Visual Studio Code|mbparis|
|VLC|mbparis|
|Zoom|mbparis|

## Future features to implement

* Add Yaml parameter to specify physical system for prefetch
    * Should execute directly on the computer that is running the code (if the cloudpaging player is installed).
* Allow for passing in PackagerSession and PlayerSession so that VMs other than vagrant managed can be used.
* Add Find|Get-PackageFile (path, appName, AppVersion, extension)
* Add dependencies support
    * For prefetch: if dependency - verify the dependency stp has been created -le 28 days ago, otherwise do a manual prefetch
* Add prerequisites support
* Add Update-ConfigFile (For quickly applying updates to existing config files)
* Add Test-ForNewVersion (New Version check script that returns Boolean - to determine if start-package needs to be called)
* Add Test-ForPackageFiles
* Update to latest studio-nip.ps1 file w/yaml & json support
* Update Wait-ForProcessWithLogging to have a TimeoutSeconds parameter
* Cleanup of old auto packaged STPs using Cloudpaging Server module
* Add FilterScipt parameter to Wait-ForProcessWithLogging

## Notes

* See [Numecent's Automated Packaging repo](https://github.com/Numecent/Automated-Packaging) readme for more information on studio-nip.ps1.
* Our studio-nip is currently an updated local copy of a version from 2022.
* Utilizes CloudpagingServer, JiraPS, & powershell-yaml powershell modules.
* New-Prefetch.ps1 is currently a powershell script and not a function because that makes it easier to run on a VM or remote system.
* Send-Slack.ps1 will likely stay a powershell script since it's used in azure-pipelines.yml
