<#
.SYNOPSIS
    Main script for Automated packaging of STPs
.DESCRIPTION
    Start-Package utilizes functions from AutomatedPackaging, CloudpagingServer, powershell-yaml, &
    JiraPS powershell modules along with Numecent's studio-nip.ps1 script to capture, prefetch, and
    finalize Cloudpaging packages
.NOTES
    Initially set up for Automated Packaging of Cloudpaging packages 2026-Jun-02.
.PARAMETER YamlFilePath
    Specifies the full path to the yaml config file for the application to be packaged.
.PARAMETER SourceDirectory
    Specifies where the code from this repository resides. Set to $PSScriptRoot by default.
.PARAMETER Installer
    Specifies the name of the executable (including extension) to execute during the capture step.
.PARAMETER LocalTest
    Indicates that the code is being run locally for testing. This disables Cloudpaging Server
    checks, Jira check/work, and slack messaging. The LocalTest flag also allows for your VM
    environment to not be reset when ResetVMs is set to $false, even if the VM was marked as
    needing to be reset using Set-ResetVMStatus.
.PARAMETER PackagerSession
    Specifies a **PSSession** object for the windows system that has Cloudpaging Studio installed
    (typically a VM) that will be used to capture an application installation for creation of an
    STP.
.PARAMETER PlayerSession
    Specifies a **PSSession** object for the windows system that has Cloudpaging Player installed
    (typically a VM) that will be used to capture a prefetch file to be used in the final cloudify
    of the application's STP.
.PARAMETER PackagerVMFolder
    Specifies the path to the folder where the packager VM's vagrantfile resides.
    Passed along to Get-ResetVMStatus, Reset-VMEnvironment and Set-ResetVMStatus.
.PARAMETER PlayerVMFolder
    Specifies the path to the folder where the player VM's vagrantfile resides.
    Passed along to Get-ResetVMStatus, Reset-VMEnvironment and Set-ResetVMStatus.
.PARAMETER DestroyVMs
    Passed along to Reset-VMEnvironment's -Force parameter | From Reset-VMEnvironment help:
    Indicates that "vagrant box destroy" should be run.
.PARAMETER ResetVMs
    Indicates that the Vagrant VMs specified with PackagerVMFolder and PlayerVMFolder parameters
    should be checked to see if they have been marked as needing to be reset back to their snapshot
    using Set-ResetVMStatus.
.PARAMETER Capture
    Indicates that an initial capture of the install media is being requested. Unless -LocalTest is
    specified, it will first check to see if a <version>_pkg folder exists for this version with all the
    required files before capturing the install.
.PARAMETER Prefetch
    Indicates that a prefetch using the captured package in the <version>_pkg folder is being
    requested. Unless -LocalTest is specified, it will first check to see if a <version>_pf folder
    exists and contains a .pf file before capturing the prefetch.

    If a manual prefetch is required (based on the config file) the Jira Issue for this version
    will be moved to in-progress and a manual prefetch message will be sent in slack.
.PARAMETER Finalize
    Indicates that a final STP using the captured package in the <version>_pkg folder and the
    prefetch in the <version>_pf folder is being requested. Unless -LocalTest is specified, it will
    first check to see if an STP exists in the backup location before the application is Cloudified
    into the final STP.
.PARAMETER NoNewLine
    Passed along to Wait-ForProcessWithLogging | from Wait-ForProcessWithLogging help:
    Specifies if Wait-ForProcessWithLogging should or should not write on a new line when writing
    the elapsed time to the terminal window. True by default
.EXAMPLE
    $rootPath = 'D:\Git\Personal\DevOps\Automated-Packaging\'
    $allYamls = (Get-ChildItem -Path "$rootPath\YAMLs\*.yaml" -Exclude "Template*").FullName
    .\Start-Package.ps1 -SourceDirectory $rootPath -PackagerSession $packagerSession -PlayerSession
      $playerSession -Verbose -YamlFilePath ($allYamls | Where-Object {$_ -like "*freecad*"})
    
    Executes Start-Package.ps1 using session variables for the Packager and Player session parameters
.EXAMPLE
    $rootPath = 'D:\Git\Personal\DevOps\Automated-Packaging\'
    $allYamls = (Get-ChildItem -Path "$rootPath\YAMLs\*.yaml" -Exclude "Template*").FullName
    $packagerVMFolder = 'D:\VMs\AP\PackagerVM\'
    $playerVMFolder = 'D:\VMs\AP\PlayerVM\'
    .\Start-Package.ps1 -SourceDirectory $rootPath -PackagerVMFolder $packagerVMFolder -Verbose
      -PlayerVMFolder $playerVMFolder -YamlFilePath ($allYamls | Where-Object {$_ -like "*connection*"})
    
    Executes Start-Package.ps1 using VMFolder variables for the Packager and Player VMFolder parameters
#>
[CmdletBinding()]
param(
    [parameter(Mandatory=$true)]
	[string]$YamlFilePath,
    [Parameter(Mandatory = $false)]
    [string]$SourceDirectory,
    [parameter(Mandatory=$false)]
    [switch]$LocalTest,
    [Parameter(Mandatory = $true, ParameterSetName = "Session")]
    [System.Management.Automation.Runspaces.PSSession]$PackagerSession,
    [Parameter(Mandatory = $true, ParameterSetName = "Session")]
    [System.Management.Automation.Runspaces.PSSession]$PlayerSession,
    [Parameter(Mandatory = $true, ParameterSetName = "Vagrant")]
    [string]$PackagerVMFolder,
    [Parameter(Mandatory = $true, ParameterSetName = "Vagrant")]
    [string]$PlayerVMFolder,
    [parameter(Mandatory=$false, ParameterSetName = "Vagrant")]
    [switch]$DestroyVMs,
    [parameter(Mandatory=$false, ParameterSetName = "Vagrant")]
    [bool]$ResetVMs = $false,
    [parameter(Mandatory=$false)]
    [bool]$Capture = $true,
    [parameter(Mandatory=$false)]
    [bool]$Prefetch = $true, 
    [parameter(Mandatory=$false)]
    [bool]$Finalize = $true,
    [parameter(Mandatory=$false)]
    [bool]$NoNewLine = $true
)
## prereqs - not currently working so not adding.

if ($LocalTest) { $rootPath = $SourceDirectory }
else { $rootPath = $PSScriptRoot }

if (-not (Test-Path -Path $YamlFilePath -Type Leaf)) {
    throw "$YamlFilePath does not exist..."
}
$scriptName = Split-Path -Leaf $PSCommandPath
$YamlFileName = Split-Path -Leaf $YamlFilePath
Write-Verbose "[$scriptName] Running for '$YamlFileName'"
$yamlInfo = Get-Content $YamlFilePath | ConvertFrom-Yaml

Import-Module (Join-Path $rootPath 'AutomatedPackaging.psm1') -Force

## Initialize variables
$appName = $yamlInfo.AppSettings.AppName
$ProductionSTPRepository = $yamlInfo.AppSettings.ProductionSTPRepository
$InstallerDirectory = $yamlInfo.AppSettings.InstallerDirectory
$PkgStagingDirectory = $yamlInfo.AppSettings.PkgStagingDirectory
$STPBackupDirectory = $yamlInfo.AppSettings.STPBackupDirectory
$VMWorkingFolder = $yamlInfo.OutputSettings.OutputFolder
$appVersions = Convert-ForVersionCompare -Versions (Get-ChildItem -Path $InstallerDirectory -Directory).Name
Write-Verbose "Versions under ($InstallerDirectory):`n$($appVersions.Original -join "`n")"
$currentVersion = $appVersions | Where-Object { # In case there are multiple versions in Standard
    $_.Version -eq ($appVersions.Version | Measure-Object -Maximum).Maximum
} | Select-Object -ExpandProperty Original
$newBackupPath = Join-Path -Path $STPBackupDirectory -ChildPath $currentVersion
$currentPkgPath = Join-Path -Path $PkgStagingDirectory -ChildPath "${currentVersion}_pkg"
$currentPfPath = Join-Path -Path $PkgStagingDirectory -ChildPath "${currentVersion}_pf"
$stpName = $yamlInfo.ProjectSettings.ProjectName -f $currentVersion.Replace(".","-")
$STP_Production = Join-Path -Path $ProductionSTPRepository -ChildPath "$stpName.stp"
$vm_pkg_path = Join-Path -Path $VMWorkingFolder -ChildPath "${currentVersion}_pkg"
$vm_tok_path = Join-Path -Path $vm_pkg_path -ChildPath "$stpName.tok"
$vm_stp_path = Join-Path -Path $VMWorkingFolder -ChildPath "$stpName.stp"
$vm_stw_path = Join-Path -Path $vm_pkg_path -ChildPath "META-INF\Patch-0\$stpName.stw"
$vm_yaml_path = Join-Path -Path $VMWorkingFolder -ChildPath "YAMLs"
if ($yamlInfo.CaptureCommands.Installer -and $yamlInfo.CaptureCommands.Installer -ne ''){
    if ($yamlInfo.CaptureCommands.InstallerFill -and $yamlInfo.CaptureCommands.InstallerFill -ne '') {
        $Installer = $yamlInfo.CaptureCommands.Installer -f $(Invoke-Expression $yamlInfo.CaptureCommands.InstallerFill)
    }
    else { $Installer = $yamlInfo.CaptureCommands.Installer -f $currentVersion }
    if ($yamlInfo.CaptureCommands.InstallerLogPath) {
        $InstallerLogPath = $yamlInfo.CaptureCommands.InstallerLogPath -f $currentVersion
    }
    else { $InstallerLogPath = '' }
}
else {
    throw "CaptureCommand.Installer not specified in Config_File!"
}
if ($yamlInfo.CaptureCommands.InstallerProcess -and $yamlInfo.CaptureCommands.InstallerProcess -ne '') {
    $InstallerProcess = $yamlInfo.CaptureCommands.InstallerProcess
}
elseif ($installer.EndsWith('.exe')) {
    $InstallerProcess = $Installer.Replace('.exe','')
}
else {
    $InstallerProcess = ''
    Write-Host "Script does not support monitoring a/an .$($Installer.Split('.')[1]) installer process."
    Write-Verbose "Only CloudpagingStudio will be monitored"
}
Write-Verbose "InstallerProcess set to ($InstallerProcess)"

@(
    'Initialized variables:',
    "appName:$appName",
    "currentVersion:$currentVersion",
    "stpName:$stpName",
    "InstallerDirectory:$InstallerDirectory",
    "newBackupPath:$newBackupPath",
    "currentPkgPath:$currentPkgPath"
) | Write-Verbose

$mandatoryFileTypes = @(
    ".tok",
    ".xml",
    ".stc",
    ".ico",
    ".aib",
    ".stw"
)

# Currently unused
# ## Gather Cloudpaging Server data
# $CloudpagingServerSetUp = $false
# if (!$localTest -and $env:ADM_URL -and $env:WEB_SERV_KEY) {
#     $CloudpagingServerData = Get-CloudpagingServerData -ServerUrl $env:ADM_URL -WebServiceKey $env:WEB_SERV_KEY
#     $CloudpagingServerSetUp = $true
# }

# slack settings set up:
$sendSlack = $false
if (!$localTest -and $env:SLACK_BOT_TOKEN -and $env:CHANNEL) {
    Write-Verbose "`$env:SLACK_BOT_TOKEN ($([bool]$env:SLACK_BOT_TOKEN)) and `$env:CHANNEL ($env:CHANNEL) exist. Setting up to send slack messages..."
    switch ($env:CHANNEL) {
        '#<PROD_CHANNEL_NAME>' { $channel = '#<PROD_CHANNEL_NAME>' }
        Default { $channel = '#<TEST_CHANNEL_NAME>' }
    }
    $slackParams = @{
        APIToken = $env:SLACK_BOT_TOKEN
        Channel = $channel
        Title = "Automated-AppsAnywhere"
    }
    $sendSlack = $true
    $sendSlackScript = Join-Path -Path $rootPath -ChildPath 'Send-Slack.ps1'
    if ($env:JOB_URL){
        $prependSlackMessage = "<$env:JOB_URL|Execution of job> for "
    }
    else {
        $prependSlackMessage = ""
    }
}

## JIRA work - module imported in azure-pipelines
$jiraSetUp = $false
if (!$localTest -and $env:JIRA_CREDS_USR -and $env:JIRA_CREDS_TKN) {
    Write-Verbose "`$env:JIRA_CREDS_USR ($($env:JIRA_CREDS_USR)) and `$env:JIRA_CREDS_TKN ($([bool]$env:JIRA_CREDS_TKN)) exist. Setting up JIRA session..."
    $jiraSetUp = $true
    $user = $env:JIRA_CREDS_USR
    $pword = ConvertTo-SecureString -String $env:JIRA_CREDS_TKN -AsPlainText -Force
    $cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $user,$pword
    Set-JiraConfigServer '<Atlassian cloud url>' -Verbose:$false
    New-JiraSession -Credential $cred -ErrorAction 'Stop' -Verbose:$false | Out-Null
    # check for current jira issue for this version
    $jql = 'project = "Application Streaming" and summary ~ "AP" and status != archived'
    Write-Verbose "Running Jira jql query ($jql)"
    $APIssues = Get-JiraIssue -JQL $jql -Verbose:$false
    # create new issue if needed
    # Since R is currently the only app that has false positives, we'll account for it here
    if ($appName -eq 'R'){ $appIssues = $APIssues | Where-Object {$_.summary -like "AP - ${appName}:*"} }
    else { $appIssues = $APIssues | Where-Object {$_.summary -like "*$appName*"} }
    Write-Verbose "Found issues for ($appName):`n$($appIssues.summary -join "`n")"
    $currentIssue = $appIssues | Where-Object {$_.summary -like "*$currentVersion*"}
    if (-not $currentIssue) {
        Write-Verbose "No jira issue for [$appName $currentVersion]. Creating issue..."
        $issueParams = @{
            Summary = "AP - ${appName}: $currentVersion"
            Project = '<project key>'
            Priority = 3 #Medium
            IssueType = 'Task'
            Description = @"
                Status meaning table:
                |*Status*|*What is needed*|
                |Open|New version available|
                |In Progress|Manual prefetch required|
                |In Review|Add to AA and test|
                |Done|All work complete and [$appName $currentVersion] is in production|
        
                See Locally Run AP doc: <link>
                
                $appName Admin link: $($yamlInfo.AppSettings.AppAdminWebpage)
                
                If this issue is in a state that is not expected please post in #<channel>!
"@
            Fields = @{ # Fields set the reporter and assignee to desired user's id
                reporter = @{id = "<desired user id>"} 
                assignee = @{id = "<desired user id>"}
            }
        }
        $currentIssue = New-JiraIssue @issueParams -Verbose:$false
        Write-Host "Issue ($($currentIssue.key) '$($currentIssue.summary)' created.)"

        Write-Verbose "Finding WINS issue"
        # may add a field in the yaml file for the Jira issue key, but for now we'll just search by appName
        $WINSIssue = Get-JiraIssue -JQL "project = WINS and summary ~ '$appName'" -Verbose:$false
        $link = [PSCustomObject]@{
            outwardIssue = $currentIssue
            type = @{name = "Relates"}
        }
        if ($WINSIssue -and $currentIssue){
            Write-Host "Linking WINS issue ($($WINSIssue.key)) to ($($currentIssue.key))"
            Add-JiraIssueLink -Issue $WINSIssue -IssueLink $link -Verbose:$false
        }
        else { Write-Warning "WINSIssue ($($WINSIssue.key)) -and currentIssue ($($currentIssue.key)) resulted in false. Not linking [$($currentIssue.key) '$($currentIssue.summary)] to WINS issue..."}
    }
    # Old Jira Issue Cleanup
    if ($null -ne $yamlInfo.RetentionSettings.IssueUnmodifiedDays) {
        Write-Verbose "Configuration contains RetentionSettings.IssueUnmodifiedDays, checking for old issues to archive"
        $currentDate = Get-Date
        $toArchive = $appIssues | Where-Object { ($_.Status -eq 'Done') -and
            (($_.issuelinks | Measure-Object).count -eq 0) -and
            (($currentDate - $_.Updated).days -gt $yamlInfo.RetentionSettings.IssueUnmodifiedDays)
        }
        foreach ($oldIssue in $toArchive) {
            Write-Host "Archiving old issue ($($oldIssue.key) $($oldIssue.summary))"
            Invoke-JiraIssueTransition -Issue $oldIssue -Transition ($oldIssue.transition | Where-Object {$_.name -eq 'Archived'}) -Verbose:$false
        }
    }
}

$captureNeeded = $Capture
$prefetchNeeded = $Prefetch
$stpNeeded = $Finalize
if (!$LocalTest){
    Write-Verbose "Checking app: $appName"
    # Check in the reverse order, because if the STP is done, we don't need to prefetch, and if the prefetch is done we don't need to capture.
    # stpNeeded check
    if ($stpNeeded) {
        Write-Verbose "Checking for existing stp..."
        if (-not (Test-Path -Path  $STP_Production)) {
            Write-Verbose "STP_Production ($STP_Production) does not exist."
            $STP_Backup = (Join-Path -Path $newBackupPath -ChildPath "$stpName.stp")
            if (Test-Path -Path $STP_Backup) {
                Write-Host "STP ($stpName) exists in backup location ($newBackupPath), copying to production repo ($ProductionSTPRepository)"
                Copy-Item -Path $STP_Backup -Destination $ProductionSTPRepository
                $captureNeeded = $false
                $prefetchNeeded = $false
                $stpNeeded = $false
            }
            else {
                Write-Verbose "STP ($stpName) does not exist in backup location ($newBackupPath)"
                Write-Verbose "Leaving `$stpNeeded set as ($stpNeeded)"
            }
        }
        else {
            Write-Host "STP ($stpName) exists in production repo ($ProductionSTPRepository)"
            $captureNeeded = $false
            $prefetchNeeded = $false
            $stpNeeded = $false
        }

        # Set appropraite Jira status if $stpNeed was set to $false
        if ($stpNeeded -eq $false) {
            # Jira issue should in either In Review or Done
            if ($jiraSetUp -and (('Done','In Review') -notcontains $currentIssue.status)){
                Write-Host "Transitioning issue [$($currentIssue.key):'$($currentIssue.Summary)'] to 'In Review'"
                Invoke-JiraIssueTransition -Issue $currentIssue -Transition ($currentIssue.Transition | Where-Object {$_.name -eq 'In Review (All)'}) -Verbose:$false
            }
            else { Write-Verbose "Issue [$($currentIssue.key):'$($currentIssue.Summary)'] already set to '$($currentIssue.status)'" }
        }
    }

    # prefetchNeeded check
    if ($prefetchNeeded) {
        Write-Verbose "Checking for existing prefetch..."
        if (Test-Path -Path $currentPfPath) {
            $prevPrefetch = Get-ChildItem -Path "$currentPfPath\*.pf" -ErrorAction SilentlyContinue
            if ($prevPrefetch) {
                Write-Host "Prefetch file ($($prevPrefetch.Name)) exists for [$appName $currentVersion]. `$prefetchNeeded set to ($prefetchNeeded)."
                $captureNeeded = $false
                $prefetchNeeded = $false
            }
        }
    }

    # captureNeeded check
    if ($captureNeeded) {
        Write-Verbose "Checking if we need to capture..."
        if (Test-Path -Path $currentPkgPath) {
            Write-Verbose "currentPkgPath '$currentPkgPath' already exists. Checking for necessary file types..."
            $prevPackageFiles = Get-ChildItem -Path $currentPkgPath -Recurse -File -ErrorAction SilentlyContinue
            $missingFileTypes = $mandatoryFileTypes | Where-Object {$prevPackageFiles.Extension -notcontains $_}
            if ($missingFileTypes) {
                Write-Verbose "Package missing ('$($missingFileTypes -join "', '")') files, running capture again."
            }
            else {
                $captureNeeded = $false
                Write-Host "Necessary package files available for [$appName $currentVersion]. Setting `$captureNeeded to '$captureNeeded'"
            }
        }
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Vagrant') {
    if (-not (Test-Path -Path $PackagerVMFolder)) {
        throw "PackagerVMFolder ($PackagerVMFolder) does not exist!"
    }
    if (-not (Test-Path -Path $PlayerVMFolder)) {
        throw "PlayerVMFolder ($PlayerVMFolder) does not exist!"
    }
    
    if (($false -eq $ResetVMs) -and $LocalTest) {
        Write-Verbose "(`$ResetVMs -eq $false) -and -LocalTest"
        Write-Verbose "Not resetting VMs"
    }
    else {
        Write-Verbose "Resetting VM Environment..."
        if ($ResetVMs -or (Get-ResetVMStatus -VMFolder $PackagerVMFolder)){
            Write-Verbose "Resetting PackagerVM ($PackagerVMFolder)..."
            Reset-VMEnvironment -PackagerVMFolder $PackagerVMFolder -force:$DestroyVMs
        }
        if ($ResetVMs -or (Get-ResetVMStatus -VMFolder $PlayerVMFolder)){
            Write-Verbose "Resetting PlayerVM ($PlayerVMFolder)..."
            Reset-VMEnvironment -PlayerVMFolder $PlayerVMFolder -force:$DestroyVMs
        }
    }
    
    Write-Verbose "Checking vagrant vm status"
    $status = Get-VagrantVMs
    if (($status | Where-Object {$_.directory -like '*packagerVM*'}).state -ne 'running') {
        Write-Verbose 'PackagerVM not running. Running vagrant up"'
        Push-Location -Path $PackagerVMFolder
        vagrant up
        Pop-Location
    }
    if (($status | Where-Object {$_.directory -like '*playerVM*'}).state -ne 'running') {
        Write-Verbose 'playerVM not running. Running vagrant up'
        Push-Location -Path $PlayerVMFolder
        vagrant up
        Pop-Location
    }
    
    # Configure sessions
    $sessions = Initialize-VMSession -PackagerVMName 'AAA_Packager' -PlayerVMName 'AAA_Player'
    $PackagerSession = $sessions.packager
    $PlayerSession = $sessions.player
}

# Set up working folder & copy files
if ($captureNeeded -or $prefetchNeeded -or $stpNeeded){
    Write-Verbose "Setting up working folder and copying over files..."
    Initialize-Path -Path $VMWorkingFolder -Session ($PackagerSession, $PlayerSession)
    Copy-Item -ToSession $PackagerSession -Path (Join-Path -Path $rootPath -ChildPath 'AAA') -Destination $VMWorkingFolder -Recurse -Force
    $powershellYamlLocation = (Get-module powershell-yaml).Path.split('\')
    $powershellYamlLocation = $powershellYamlLocation[0..($powershellYamlLocation.length-3)] -join '\'
    Copy-Item -ToSession $PackagerSession -Path "$powershellYamlLocation" -Destination $VMWorkingFolder -Recurse -Force
    Copy-Item -ToSession $PackagerSession -Path (Join-Path -Path $rootPath -ChildPath 'YAMLs') -Destination $VMWorkingFolder -Recurse -Force
    Copy-Item -ToSession $PackagerSession -Path (Join-Path -Path $rootPath -ChildPath 'AppEvents') -Destination $VMWorkingFolder -Recurse -Force
    Copy-Item -ToSession $PackagerSession -Path (Join-Path -Path $rootPath -ChildPath 'Send-KeysToProcess.ps1') -Destination $VMWorkingFolder -Recurse -Force
}

if ($captureNeeded -or $stpNeeded) { Initialize-Path -Path (Join-Path -Path $VMWorkingFolder -ChildPath "${currentVersion}_pkg") -Session $PackagerSession }

if ($Capture -and $captureNeeded) {
    Write-Verbose "Capture Needed"
    Write-Output "Update required."

    Write-Verbose "Checking for prerequisites..."
    if ($yamlInfo.CaptureCommands.Prerequisites) {
        Write-Verbose "Prerequisites section present in yaml"
        $prerequisites = $yamlInfo.CaptureCommands.Prerequisites
        switch ($prerequisites.Version) {
            'latest' {
                $prereqVersions = Convert-ForVersionCompare -Versions (Get-ChildItem -Path ($prerequisites.Path) -Directory).Name
                Write-Verbose "Versions under ($($prerequisites.Path)):`n$($prereqVersions.Original -join "`n")"
                $currentPrereqVersion = $prereqVersions | Where-Object { # In case there are multiple versions in Standard
                    $_.Version -eq ($prereqVersions.Version | Measure-Object -Maximum).Maximum
                } | Select-Object -ExpandProperty Original
                $prereqInstallerDirectory = (Join-Path $prerequisites.Path $currentPrereqVersion)
            }
            'specific' {
                $prereqInstallerDirectory = $prerequisites.Path
                $currentPrereqVersion = Split-Path $prereqInstallerDirectory -Leaf
            }
            Default {
                Write-Warning "`$yamlInfo.CaptureCommands.Prerequisites.Version not set to specific or latest. Assuming prerequisites are not needed."
                $prereqInstallerDirectory = ''
            }
        }
        if ($prereqInstallerDirectory -ne '') {
            Write-Verbose "prereqInstallDirectory set to ($prereqInstallerDirectory)"
            Write-Output " Copying prerequisite install files to VM..."
            Copy-ItemWithFallback -ToSession $PackagerSession -Path $prereqInstallerDirectory -Destination $VMWorkingFolder -Force -Recurse -Exclude 'Thumbs.db'
            $script = 'start-studio-nip-prereqs.ps1'
            # studio-nip <yaml config> <installer path> <app version> -DefaultDispositionLayer <layer> -debug_mode "True"
            $command = @(
                "& $(Join-Path -Path $VMWorkingFolder -ChildPath 'Numecent\studio-nip.ps1')",
                "-config_file_path $(Join-Path -Path $VMWorkingFolder -ChildPath "yamls\$(Split-Path -Path $YamlFilePath -Leaf)")",
                "-installer_path '$(Join-Path -Path $VMWorkingFolder -ChildPath "$currentPrereqVersion\$($prerequisites.Installer)")'",
                "-app_version $currentVersion",
                "-DefaultDispositionLayer '$($prerequisites.DispositionLayer)'",
                " -debug_mode `"True`""
            ) -join ' '
            $command | Out-File -FilePath ".\$script"
            Write-Verbose "Set up $script with command:`n$command"
            Copy-Item -ToSession $PackagerSession -Path ".\$script" -Destination $VMWorkingFolder

            Write-Output "Capturing prerequisite for '$appName'..."
            $capturePrereqParams = @{
                TaskName = "Capture-$appName-prereq"
                Execute = 'Powershell.exe'
                Argument = "$(Join-Path -Path $VMWorkingFolder -ChildPath $script) -noexit"
                UserId = $PackagerSession.Runspace.OriginalConnectionInfo.Credential.UserName
                Session = $PackagerSession
            }
            if ($PSCmdlet.ParameterSetName -eq 'Vagrant') { Set-ResetVMStatus -VMFolder $PackagerVMFolder }
            Invoke-CommandAsScheduledTask @capturePrereqParams

            # monitor progress
            if ($prerequisites.InstallerProcess -and $prerequisites.InstallerProcess -ne '') {
                Wait-ForProcessWithLogging -Name $prerequisites.InstallerProcess -Path $prerequisites.InstallerLogPath -Session $PackagerSession -WaitForStart -NoNewLine:$NoNewLine
            }
            Wait-ForProcessWithLogging -WaitForStart -Name 'CloudpagingStudio' -Session $packagerSession -NoNewLine:$NoNewLine
        }
    }
    else { Write-Verbose "No prerequisites configured" }

    Copy-ItemWithFallback -ToSession $PackagerSession -Path (Join-Path -Path $InstallerDirectory -ChildPath $currentVersion) -Destination $VMWorkingFolder -Force -Recurse -Exclude 'Thumbs.db'
    $script = 'start-studio-nip.ps1'
    # studio-nip <yaml config> <installer path> <app version> -debug_mode "True"
    $command = @(
        "& $(Join-Path -Path $VMWorkingFolder -ChildPath 'Numecent\studio-nip.ps1')",
        "$(Join-Path -Path $VMWorkingFolder -ChildPath "yamls\$(Split-Path -Path $YamlFilePath -Leaf)")",
        "$(Join-Path -Path $VMWorkingFolder -ChildPath "$currentVersion\$Installer")",
        "$currentVersion -debug_mode `"True`""
    ) -join ' '
    $command | Out-File -FilePath ".\$script"
    Write-Verbose "Set up $script with command:`n$command"
    Copy-Item -ToSession $PackagerSession -Path ".\$script" -Destination $VMWorkingFolder
    
    Write-Output "Capturing '$appName'..."
    $captureParams = @{
        TaskName = "Package-$appName"
        Execute = 'Powershell.exe'
        Argument = "$(Join-Path -Path $VMWorkingFolder -ChildPath $script) -noexit"
        UserId = $PackagerSession.Runspace.OriginalConnectionInfo.Credential.UserName
        Session = $PackagerSession
    }
    if ($PSCmdlet.ParameterSetName -eq 'Vagrant') { Set-ResetVMStatus -VMFolder $PackagerVMFolder }
    Invoke-CommandAsScheduledTask @captureParams
    
    # monitor progress
    if ($InstallerProcess -and $InstallerProcess -ne '') {
        Wait-ForProcessWithLogging -Name $InstallerProcess -Path $InstallerLogPath -Session $PackagerSession -WaitForStart -NoNewLine:$NoNewLine
    }
    Wait-ForProcessWithLogging -WaitForStart -Name 'CloudpagingStudio' -Session $packagerSession -NoNewLine:$NoNewLine
    
    # verify all files were created
    Write-Verbose "Checking if all files created..."
    $vmPackageFiles = Invoke-Command -Session $PackagerSession -ScriptBlock {
        param($vm_pkg_path)
        Get-ChildItem -Path $vm_pkg_path -Recurse -File
    } -ArgumentList $vm_pkg_path
    $missingFileTypes = $mandatoryFileTypes | Where-Object {$vmPackageFiles.Extension -notcontains $_}
    if ($missingFileTypes) {
        if ((-not $LocalTest) -and $sendSlack) {
            & $sendSlackScript @slackParams -Text ($prependSlackMessage + "${appName} ${currentVersion}: Failed") -Color danger
        }
        throw "After capturing $appName files ('$($missingFileTypes -join "', '")') were missing"
    }

    ## START AppEvents Section ##
    Write-Verbose "Checking for needed CAEs..."
    $configurableAppEvents = $yamlInfo.PostCaptureSettings.ConfigurableAppEvents
    if (($configurableAppEvents.count -ge 1) -and ($configurableAppEvents.Values.Path -ne '')){
        $neededCAEs = $configurableAppEvents.keys | Where-Object { $configurableAppEvents.$_.path -ne '' }
        Write-Verbose "Found CAEs for triggers ('$($neededCAEs -join "', '")')"
        $script = 'start-Add-AppEvents.ps1'
        "Import-Module $(Join-Path $VMWorkingFolder 'powershell-yaml')" | Out-File -FilePath ".\$script"
        "`$yamlData = Get-Content $(Join-Path $vm_yaml_path $YamlFileName) | ConvertFrom-Yaml"  | Out-File -FilePath ".\$script" -Append
        $command = @(
            "& $(Join-Path -Path $VMWorkingFolder -ChildPath 'AppEvents\Add-AppEvents.ps1')",
            "-STWFilePath '$vm_stw_path'",
            "-STWLoadSeconds 15",
            '-YamlData $yamlData'
        ) -join ' '
        $command | Out-File -FilePath ".\$script" -Append
        Write-Verbose "Set up $script with content:`n$((Get-Content .\$script) -join "`n")"
        Copy-Item -ToSession $PackagerSession -Path ".\$script" -Destination $VMWorkingFolder
        
        Write-Output "Adding CAEs for '$appName'..."
        $addCAEsParams = @{
            TaskName = "AddCAEs-$appName"
            Execute = 'Powershell.exe'
            Argument = "$(Join-Path -Path $VMWorkingFolder -ChildPath $script) -noexit"
            UserId = $PackagerSession.Runspace.OriginalConnectionInfo.Credential.UserName
            Session = $PackagerSession
        }
        if ($PSCmdlet.ParameterSetName -eq 'Vagrant') { Set-ResetVMStatus -VMFolder $PackagerVMFolder }
        Invoke-CommandAsScheduledTask @addCAEsParams
        
        # monitor progress
        Wait-ForProcessWithLogging -WaitForStart -Name 'CloudpagingStudio' -Path (Join-Path $VMWorkingFolder 'SendKeys.log') -Session $packagerSession -NoNewLine:$NoNewLine
        
        # time to run another output command?
        Write-Verbose "CAEs added, running cloudify..."
        $script = 'start-cloudify-with-CAEs.ps1'
        $command = @(
            "& 'C:\Program Files\Numecent\Cloudpaging Studio\CloudpagingStudio.exe'",
            "-p '$vm_stw_path'",
            "-o '$vm_stp_path'"
        ) -join ' '
        $command | Out-File -FilePath ".\$script"
        Write-Verbose "Set up $script with content:`n$(Get-Content .\$script)"
        Copy-Item -ToSession $PackagerSession -Path ".\$script" -Destination $VMWorkingFolder
        
        Write-Output "Running Cloudify with CAEs for '$appName'..."
        $cloudifyWithCAEsParams = @{
            TaskName = "CloudifyWithCAEs-$appName"
            Execute = 'Powershell.exe'
            Argument = "$(Join-Path -Path $VMWorkingFolder -ChildPath $script) -noexit"
            UserId = $PackagerSession.Runspace.OriginalConnectionInfo.Credential.UserName
            Session = $PackagerSession
        }
        if ($PSCmdlet.ParameterSetName -eq 'Vagrant') { Set-ResetVMStatus -VMFolder $PackagerVMFolder }
        Invoke-CommandAsScheduledTask @cloudifyWithCAEsParams
        
        # monitor progress
        Wait-ForProcessWithLogging -WaitForStart -Name 'CloudpagingStudio' -Session $packagerSession -NoNewLine:$NoNewLine
        
        Write-Verbose "Extracting STP ($vm_stp_path) to ($vm_pkg_path)..."
        Invoke-Command -Session $PackagerSession -ScriptBlock {
            Move-Item -Path $using:vm_stp_path -Destination ($using:vm_stp_path).Replace('.stp','.zip')
            Expand-Archive -Force -Path ($using:vm_stp_path).Replace('.stp','.zip') -DestinationPath $using:vm_pkg_path
        }
    }
    else {
        Write-Verbose "No CAEs set up"
    }
    ## END AppEvents Section ##
    
    Write-Output "Packaging complete, copying files to $currentPkgPath"
    Initialize-Path -Path $currentPkgPath
    Copy-ItemWithFallback -FromSession $PackagerSession -Path $vm_pkg_path -Destination $currentPkgPath -Force -Recurse
}

if ($Prefetch -and $prefetchNeeded){
    Write-Verbose "Prefetch Needed"
    if ($yamlInfo.PrefetchSettings.Manual) {
        Write-Host "Manual prefetch required for $appName"
        $Finalize = $false
        Write-Verbose "`$Finalize set to ($Finalize)"
        if ($LocalTest){
            Write-Verbose "Copying package files to ($VMWorkingFolder) on player VM"
            Copy-ItemWithFallback -ToSession $PlayerSession -Path ($currentPkgPath, "$rootPath\Prefetch\New-Prefetch.ps1") -Destination $VMWorkingFolder -Recurse -Force
        }
        elseif ($sendSlack) {
            & $sendSlackScript @slackParams -Text ($prependSlackMessage + "$appName ${currentVersion}: Manual prefetch required") -Color warning
        }
        if ($jiraSetUp -and ($currentIssue.status -eq 'Open')){
            # move to in-progress if prefetch is needed
            Write-Verbose "Transitioning issue [$($currentIssue.key):'$($currentIssue.Summary)'] to 'In Progress'"
            Invoke-JiraIssueTransition -Issue $currentIssue -Transition ($currentIssue.Transition | Where-Object {$_.ResultStatus.name -eq 'In Progress'}) -Verbose:$false
        }
    }
    else {
        Write-Verbose "Starting prefetch..."

        # Prep packagerVM
        invoke-command -Session $PlayerSession -ScriptBlock {
            Write-Host "Ensuring DisableLocalPaging set to 0"
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Numecent\StreamingCore\Settings' -Name 'DisableLocalPaging' -Value '0'
        }
        $prefetchScriptFilePath = Join-Path -Path $rootPath -ChildPath 'Prefetch\New-Prefetch.ps1'
        Write-Host "Copying package ($currentPkgPath) and prefetchScript ($prefetchScriptFilePath) to ($VMWorkingFolder) on player VM"
        Copy-ItemWithFallback -ToSession $PlayerSession -Path ($currentPkgPath,$prefetchScriptFilePath) -Destination $VMWorkingFolder -Force -Recurse

        # set up script
        $script = 'start-New-Prefetch.ps1'
        $command = @(
            "& '$(Join-Path -Path $VMWorkingFolder -ChildPath 'New-Prefetch.ps1')'",
            "-verbose -TOKFilePath '$vm_tok_path'",
            "-PrefetchFileName '$($appName -replace '[^a-zA-Z0-9]+','-')-$currentVersion.pf'",
            "-Destination '$VMWorkingFolder'"
            "-LaunchCommands @('$($yamlInfo.PrefetchSettings.LaunchCommands -join "', '")')",
            "-Launches $($yamlInfo.PrefetchSettings.Launches)",
            "-RuntimeSeconds $($yamlInfo.PrefetchSettings.RuntimeSeconds)",
            "-VirtualizationSeconds $($yamlInfo.PrefetchSettings.VirtualizationSeconds)"
        ) -join ' '
        $command | Out-File -FilePath ".\$script"
        Write-Verbose "Set up $script with command:`n$command"
        Copy-Item -ToSession $PlayerSession -Path ".\$script" -Destination $VMWorkingFolder

        # set up scheduled task
        $prefetchParams = @{
            TaskName = "Prefetch-$appName"
            Execute = 'Powershell.exe'
            Argument = "$(Join-Path -Path $VMWorkingFolder -ChildPath $script)"
            UserId = $PlayerSession.Runspace.OriginalConnectionInfo.Credential.UserName
            Session = $PlayerSession
        }
        if ($PSCmdlet.ParameterSetName -eq 'Vagrant') { Set-ResetVMStatus -VMFolder $PlayerVMFolder }
        Invoke-CommandAsScheduledTask @prefetchParams
        Wait-ForProcessWithLogging -WaitForStart -Name 'CloudpagingPlayer' -Path "$(Join-Path -Path $VMWorkingFolder -ChildPath 'AutoPrefetch.log')" -Session $PlayerSession -NoNewLine:$NoNewLine

        Write-Output "Prefetch complete, copying files to $currentPfPath"
        Initialize-Path -Path $currentPfPath
        Copy-ItemWithFallback -FromSession $PlayerSession -Path (Join-Path -Path $VMWorkingFolder -ChildPath "*.pf") -Destination (Join-Path -Path $currentPfPath -ChildPath "$stpName.pf") -Force
    }
}

if ($Finalize -and $stpNeeded) {
    Write-Verbose "Final STP Needed"
    # Final packaging
    $prefetchFile = Get-ChildItem -Path "$currentPfPath\*.pf" | Select-Object -ExpandProperty fullname
    if (-not $prefetchFile) {
        Write-Host "No prefetch file yet."
        & $sendSlackScript @slackParams -Text ($prependSlackMessage + "$appName ${currentVersion}: prefetch required") -Color warning
        return $false
    }
    $stpName = $yamlInfo.ProjectSettings.ProjectName -f $currentVersion.Replace(".","-")

    Write-Verbose "Prefetch file exists, Checking for `$captureNeeded ($captureNeeded) -eq `$false"
    $extractNeeded = $true
    if ($PSCmdlet.ParameterSetName -eq 'Vagrant') {
        $extractNeeded = (-not (Get-ResetVMStatus -VMFolder $PackagerVMFolder))
    }
    Write-Verbose "`$extractNeeded set to ($extractNeeded)"
    if (($captureNeeded -eq $false) -and $extractNeeded) {
        Write-Verbose "Copying '$currentPkgPath' to '$VMWorkingFolder'"
        Copy-ItemWithFallback -ToSession $PackagerSession -Path $currentPkgPath -Destination $VMWorkingFolder -Recurse -Force

        Write-Verbose "Extracting $stpName.tok on packager VM"
        $script = 'start-studio-extract.ps1'
        $command = @(
            "& 'C:\Program Files\Numecent\Cloudpaging Studio\CloudpagingStudio.exe'",
            "-x:f '$vm_tok_path'"
        ) -join ' '
        $command | Out-File -FilePath ".\$script"
        Write-Verbose "Set up $script with command:`n$command"
        Copy-Item -ToSession $PackagerSession -Path ".\$script" -Destination $VMWorkingFolder

        $extractParams = @{
            TaskName = "Extract-$appName"
            Execute = 'Powershell.exe'
            Argument = "$(Join-Path -Path $VMWorkingFolder -ChildPath $script) -noexit"
            UserId = $PackagerSession.Runspace.OriginalConnectionInfo.Credential.UserName
            Session = $PackagerSession
        }
        if ($PSCmdlet.ParameterSetName -eq 'Vagrant') { Set-ResetVMStatus -VMFolder $PackagerVMFolder }
        Invoke-CommandAsScheduledTask @extractParams
        Wait-ForProcessWithLogging -Name 'CloudpagingStudio' -Session $PackagerSession -NoNewLine:$NoNewLine -WaitForStart
    }

    Write-Verbose "Creating final package..."

    Copy-ItemWithFallback -ToSession $PackagerSession -Path $prefetchFile -Destination (Join-Path -Path $vm_pkg_path -ChildPath "$stpName.pf")
    $script = 'start-studio-finalize-stp.ps1'
    $command = @(
        "& 'C:\Program Files\Numecent\Cloudpaging Studio\CloudpagingStudio.exe'",
        "-p '$vm_stw_path'",
        "-m:1 '$(Join-Path -Path $vm_pkg_path -ChildPath "$stpName.pf")'",
        "-o '$vm_stp_path'"
    ) -join ' '
    $command | Out-File -FilePath ".\$script"
    Write-Verbose "Set up $script with command:`n$command"
    Copy-Item -ToSession $PackagerSession -Path ".\$script" -Destination $VMWorkingFolder
    
    #Finalize
    $finalizeParams = @{
        TaskName = "Finalize-$appName"
        Execute = 'Powershell.exe'
        Argument = "$(Join-Path -Path $VMWorkingFolder -ChildPath $script) -noexit"
        UserId = $PackagerSession.Runspace.OriginalConnectionInfo.Credential.UserName
        Session = $PackagerSession
    }
    if ($PSCmdlet.ParameterSetName -eq 'Vagrant') { Set-ResetVMStatus -VMFolder $PackagerVMFolder }
    Invoke-CommandAsScheduledTask @finalizeParams
    Wait-ForProcessWithLogging -Name 'CloudpagingStudio' -Session $PackagerSession -NoNewLine:$NoNewLine -WaitForStart
    
    # check for stp
    $stpCheck = Invoke-Command -Session $PackagerSession -ScriptBlock {Test-Path $using:vm_stp_path}
    if (-not $stpCheck) {
        if ($sendSlack) {
            & $sendSlackScript @slackParams -Text ($prependSlackMessage + "${appName} ${currentVersion}: Failed") -Color danger
        }
        throw "Final stp ('$stpName') not found under ($VMWorkingFolder)"
    }
    
    Initialize-Path -Path $newBackupPath
    # copy stp to backup location
    Copy-ItemWithFallback -FromSession $PackagerSession -Path $vm_stp_path -destination $newBackupPath
    
    if (!$LocalTest) {
        # and to Cloudpaging server cache source
        Copy-ItemWithFallback -FromSession $PackagerSession -Path $vm_stp_path -destination $ProductionSTPRepository
        if ($sendSlack) {
            & $sendSlackScript @slackParams -Text ($prependSlackMessage + "$appName ${currentVersion}: Succeeded") -Color good
        }
        if ($jiraSetUp -and $currentIssue.status -ne 'In Review'){
            # move to in-review if STP is ready
            Write-Verbose "Transitioning issue [$($currentIssue.key):'$($currentIssue.Summary)'] to 'In Review'"
            Invoke-JiraIssueTransition -Issue $currentIssue -Transition ($currentIssue.Transition | Where-Object {$_.name -eq 'In Review (All)'}) -Verbose:$false
        }
    }
}

## (cleanup):
Limit-STPBackupFolders -Verbose -Path $STPBackupDirectory -Count $yamlInfo.RetentionSettings.STPCount
Limit-PackageFolders -Verbose -Path $PkgStagingDirectory -Count $yamlInfo.RetentionSettings.PackageCount

## Cloudpaging Server / STP work (cleanup):
# Check for stps with no license policies
# if old version then remove the STP from cloudpaging server & s2pkgs

### Soli Deo Gloria -mbparis