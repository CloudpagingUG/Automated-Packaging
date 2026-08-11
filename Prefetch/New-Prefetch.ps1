<#
.SYNOPSIS
    New-Prefetch starts and completes a prefetch capture for a Cloudpaging package.
.DESCRIPTION
    New-Prefetch loads a Cloudpaging package with the specified token file, starts a capture, and
    runs through automated launches of the package, based on the specified launch commands.
.NOTES
    Initially setup for Automated Packaging of Cloudpaging packages 2026-Mar-13
.PARAMETER TOKFilePath
    Specifies the path to the .tok file for the Cloudpaging package to prefetch.
.PARAMETER PrefetchFileName
    Specifies what to name the .pf prefetch file that will be created. [Default: AutoPrefetch.pf]
.PARAMETER PrefetchFileName
    Specifies the log file that New-Prefetch will write to. [Default: AutoPrefetch.log]
.PARAMETER Destination
    Specifies the Destination where the .pf and log file will be placed on the local file system.
    [Default: C:\temp\]
.PARAMETER LaunchCommands
    Specifies how New-Prefetch should launch the Cloudpaging package during prefetch creation.
    PLAYER specifies launching with the Cloudpaging Player Launch button, but the full path to
    shortcut links or executables can also be used. [Default: PLAYER]
.PARAMETER Launches
    Specifies the number of launches New-Prefetch should complete for each command passed in via
    the LaunchCommands parameter during prefetch creation. [Default: 3]
.PARAMETER RuntimeSeconds
    Specifies how many seconds the script should wait for each launch before stopping the package
    using the Cloudpaging Player Stop button during prefetch creation. [Default: 20]
.PARAMETER VirtualizationSeconds
    Specifies how many seconds the script should wait for the Cloudpaging package to virtualize
    into the Cloudpaging Player during prefetch creation. [Default: 20]
.EXAMPLE
    .\New-Prefetch.ps1 -TOKFilePath C:\temp\app_pkg\*.tok

    Executes New-Prefetch to capture a prefetch for the Cloudpaing package extracted to app_pkg
    with the default settings.
.EXAMPLE
    $command = @(
        "& '$(Join-Path -Path $VMWorkingFolder -ChildPath 'New-Prefetch.ps1')'",
        "-verbose -TOKFilePath '$current_tok_path'",
        "-PrefetchFileName '$stpName.pf'",
        "-Destination '$VMWorkingFolder'"
        "-LaunchCommands @('$($yamlInfo.PrefetchSettings.LaunchCommands -join "', '")')",
        "-Launches $($yamlInfo.PrefetchSettings.Launches)",
        "-RuntimeSeconds $($yamlInfo.PrefetchSettings.RuntimeSeconds)",
        "-VirtualizationSeconds $($yamlInfo.PrefetchSettings.VirtualizationSeconds)"
    ) -join ' '
    $command | Out-File -FilePath ".\$script"
    Copy-Item -ToSession $playerSession -Path ".\$script" -Destination $VMWorkingFolder

    $prefetchParams = @{
        TaskName = "Prefetch-$appName"
        Execute = 'Powershell.exe'
        Argument = "$(Join-Path -Path $VMWorkingFolder -ChildPath $script)"
        UserId = 'player_s2\vagrant'
        Session = $playerSession
    }
    Invoke-CommandAsScheduledTask @prefetchParams

    Sets up the execution of New-Prefetch on the playerVM using Invoke-CommandAsScheduledTask based
    using the values specified in the yaml config file.
#>
[CmdletBinding()]
param(
    [parameter(Mandatory = $true)]
    [String]$TOKFilePath,
    [parameter(Mandatory = $false)]
    [String]$PrefetchFileName = 'AutoPrefetch.pf',
    [parameter(Mandatory = $false)]
    [String]$LogFileName = 'AutoPrefetch.log',
    [parameter(Mandatory = $false)]
    [String]$Destination = 'C:\temp\',
    [parameter(Mandatory = $false)]
    [String[]]$LaunchCommands = 'PLAYER',
    [parameter(Mandatory = $false)]
    [Int]$Launches = 3,
    [parameter(Mandatory = $false)]
    [Int]$RuntimeSeconds = 20,
    [parameter(Mandatory = $false)]
    [Int]$VirtualizationSeconds = 20
)
$logFilepath = Join-Path $Destination $LogFileName
"Starting New-Prefetch.ps1 for ($TOKFilePath)" | Tee-Object -FilePath $logFilepath -Append
"Validating input." | Tee-Object -FilePath $logFilepath -Append | Write-Verbose
if (-not (Test-Path $TOKFilePath)) { throw "TOKFilePath ($TOKFilePath) not valid." }
if ( -not ($PrefetchFileName.EndsWith(".pf")) ) { throw "PrefetchFileName ($PrefetchFileName) does not end with '.pf' extension." }
if ( $PrefetchFileName.Contains('+') ) { throw "PrefetchFileName ($PrefetchFileName) contains unpermitted character '+'." }
if ($Destination[-1] -ne '\') { $Destination += '\' }

if (Test-Path "C:\Program Files\Numecent\Cloudpaging Player\CloudpagingPlayer.exe") {
    # Cloudpaging player >= 9.6
    & 'C:\Program Files\Numecent\Cloudpaging Player\CoreCLI.exe' cache clear
    "Verifying the Cloudpaging Player is running in captureprefetch mode." | Tee-Object -FilePath $logFilepath -Append | Write-Verbose
    $proc = Get-CimInstance -ClassName Win32_Process | Where-Object {$_.name -eq 'CloudpagingPlayer.exe'}
    if ($null -eq $proc){
        "Starting Cloudpaging Player in captureprefetch mode." | Tee-Object -FilePath $logFilepath -Append | Write-Verbose
        & 'C:\Program Files\Numecent\Cloudpaging Player\CloudpagingPlayer.exe' /captureprefetch
        Start-Sleep -Seconds 5
        $proc = Get-CimInstance -ClassName Win32_Process | Where-Object {$_.name -eq 'CloudpagingPlayer.exe'}
    }
    elseif ($proc.CommandLine -notlike '*/captureprefetch*'){
        "Restarting Cloudpaging Player in captureprefetch mode." | Tee-Object -FilePath $logFilepath -Append | Write-Verbose
        Stop-Process -Id $proc.Handle -Force
        Start-Sleep -Seconds 20
        & 'C:\Program Files\Numecent\Cloudpaging Player\CloudpagingPlayer.exe' /captureprefetch
        Start-Sleep -Seconds 5
        $proc = Get-CimInstance -ClassName Win32_Process | Where-Object {$_.name -eq 'CloudpagingPlayer.exe'}
    }
    $id = $proc.Handle
}
else {
    # Cloudpaging Player < 9.6
    throw "Doesn't currently support versions of Cloudpaging Player prior to version 9.6"
}

# gathering appID for later
$packageFolder = Split-Path -Path $TOKFilePath -Parent
[xml]$xml = Get-Content -Path "$packageFolder\*.xml"
$appID = $xml.appset.'app-id'

"Loading $TOKFilePath..." | Tee-Object -FilePath $logFilepath -Append | Write-Verbose
& "$TOKFilePath"
Start-Sleep -Seconds $VirtualizationSeconds

"Verifying $TOKFilePath loaded..." | Tee-Object -FilePath $logFilepath -Append | Write-Verbose
if ((& 'C:\Program Files\Numecent\Cloudpaging Player\CoreCLI.exe' application getIdList) -like "*$appID*") {
    "Loaded token $TOKFilePath" | Tee-Object -FilePath $logFilepath -Append
}
else { throw "Token $TOKFilePath failed to load"}

$fileName = $Destination + $PrefetchFileName

"Ensuring $fileName does not exist." | Tee-Object -FilePath $logFilepath -Append | Write-Verbose
if (Test-Path $fileName) { Remove-Item $fileName -Force }
$wshell = New-Object -ComObject WScript.Shell

"Starting Capture..." | Tee-Object -FilePath $logFilepath -Append | Write-Verbose
$wshell.AppActivate($id) | Out-Null
$wshell.SendKeys('^+C') # Ctrl + Shift + C - start capture
Start-Sleep -Seconds 1
$wshell.SendKeys('%n') # Alt + n - select file name field
Start-Sleep -Seconds 1
foreach ($char in $fileName.ToCharArray()){
    $wshell.SendKeys($char)
}
$wshell.SendKeys('%s') # Alt + s - Save file
Start-Sleep -Seconds 3
"Verifying prefetch file was created" | Tee-Object -FilePath $logFilepath -Append | Write-Verbose
if ( -not (Test-Path $fileName)) {
    # alt f4 twice to close out of any extra windows
    $wshell.SendKeys('%{F4}')
    $wshell.SendKeys('%{F4}')

    "Attempting to start capture again." | Tee-Object -FilePath $logFilepath -Append | Write-Verbose
    $wshell.AppActivate($id) | Out-Null
    $wshell.SendKeys('^+C') # Ctrl + Shift + C - start capture
    Start-Sleep -Seconds 1
    $wshell.SendKeys('%n') # Alt + n - select file name field
    Start-Sleep -Seconds 1
    foreach ($char in $fileName.ToCharArray()){
        $wshell.SendKeys($char)
    }
    $wshell.SendKeys('%s') # Alt + s - Save file
    Start-Sleep -Seconds 3
    if (-not (Test-Path $fileName)) { throw "Prefetch File ($fileName) was not created!" }
}
"Prefetch File ($fileName) was created. Gathering prefetch..." | Tee-Object -FilePath $logFilepath -Append

"Prefetching Package with settings:" | Tee-Object -FilePath $logFilepath -Append | Write-Verbose
"LaunchCommands: ('$($LaunchCommands -join "', '")')" | Tee-Object -FilePath $logFilepath -Append | Write-Verbose
"For each command: (Number of launches:$Launches | Runtime per launch:$RuntimeSeconds)" | Tee-Object -FilePath $logFilepath -Append | Write-Verbose
foreach ($command in $LaunchCommands) {
    "Running Launch command: '$command'" | Tee-Object -FilePath $logFilepath -Append | Write-Verbose
    
    for ($i = 0; $i -lt $Launches; $i ++){
        if ($command -eq 'PLAYER') {
            "Launch $($i + 1)..." | Tee-Object -FilePath $logFilepath -Append | Write-Verbose
            $wshell.AppActivate($id) | Out-Null
            $wshell.SendKeys('^l') # Ctrl + l - Launch Application
        }
        else {
            try {
                & $command
            }
            catch {
                throw "Unexpected error running ($command): $($_.Exception.Message)`n$($_.Exception.StackTrace)"
            }
        }
        Start-Sleep -Seconds $RuntimeSeconds
        $wshell.AppActivate($id) | Out-Null
        $wshell.SendKeys('^s') # Ctrl + s - Stop Application
        $wshell.SendKeys('{LEFT}') # Confirm you want to stop the application
        $wshell.SendKeys('{ENTER}')
        Start-Sleep -Seconds 2
    }
}
$wshell.AppActivate($id) | Out-Null
$wshell.SendKeys('^+C') # Ctrl + Shift + C - stop capture
"Prefetch '$fileName' complete for '$TOKFilePath'" | Tee-Object -FilePath $logFilepath -Append
& 'C:\Program Files\Numecent\Cloudpaging Player\CoreCLI.exe' application remove $appID
"Exiting CloudpagingPlayer" | Tee-Object -FilePath $logFilepath -Append
Stop-Process -Name 'CloudpagingPlayer' -Force -ErrorAction SilentlyContinue

exit 0

### Soli Deo Gloria -mbparis