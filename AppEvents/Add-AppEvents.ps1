<#
.SYNOPSIS
    Add-AppEvents sets up Configurable App Events in Cloudpaging Studio.
.DESCRIPTION
    Add-AppEvents loads in Configurable App Event configurations from the passed in config file,
    sets up the appropraite key presses required, and then uses Send-KeysToProcess to add send the
    keystrokes to Cloudpaging Studio.
.NOTES
    Initially set up for Automated Packaging of Cloudpaging packages 2026-Oct-01
.PARAMETER STWFilePath
    Specifies the path to the .STW file that will be opened in Cloudpaging Studio and have the
    Configurable App Events added.
.PARAMETER STWLoadSeconds
    Specifies how many seconds to wait for Cloudpaging Studio to open the STW file.
.PARAMETER YamlData
    The object containing data from the application's config file. Data used by this function:
    OutputSettings.OutputFolder, and PostCaptureSettings.ConfigurableAppEvents
.EXAMPLE
    & Add-AppEvents.ps1 -STWFilePath <OutputFolder>\<version>_pkg\META-INF\Patch-0\<file>.stw -STWLoadSeconds 15 -YamlData $yamlData
    
    Add-AppEvents opens <file>.stw in Cloudpaging Studio and adds AppEvents based on the data
    passed in using the -YamlData parameter.
#>
[CmdletBinding()]
param(
    [parameter(Mandatory = $true)]
    [String]$STWFilePath,

    [parameter(Mandatory = $false)]
    [int]$STWLoadSeconds = 20,

    [parameter(Mandatory = $true)]
    [hashtable]$YamlData # from the imported yaml config file
)
## helpful key: + -eq SHIFT, % -eq ALT, ^ -eq CTRL
$configurableAppEvents = $YamlData.PostCaptureSettings.ConfigurableAppEvents

# Keys to open CAE settings
[string[]]$keysToPress = ('^+A')
foreach ($trigger in $configurableAppEvents.Keys) {
    Write-Verbose "Checking CAE ($trigger)"
    if ($configurableAppEvents.$trigger.path -and ($configurableAppEvents.$trigger.path -ne '')){
        Write-Verbose "Adding keys for CAE trigger ($trigger)"

        # Keys to add an AppEvent
        $keysToPress = $keysToPress + '%a'

        # trigger - Always needed
        switch ($trigger) {
            AfterRegistration { <# No extra presses needed #> }
            AfterActivation { $keysToPress = $keysToPress + '{DOWN}' }
            AfterVirtualization { $keysToPress = $keysToPress + ('{DOWN}','{DOWN}') }
            AfterLaunch { $keysToPress = $keysToPress + ('{DOWN}','{DOWN}','{DOWN}') }
            AfterExit { $keysToPress = $keysToPress + ('{DOWN}','{DOWN}','{DOWN}','{DOWN}') }
            BeforeDevirtualization { $keysToPress = $keysToPress + 'b' }
            BeforeDeactivation { $keysToPress = $keysToPress + ('b','{DOWN}') }
            Default { throw "No Parameter Set?!?!" }
        }
        Write-Verbose "Added keys for Trigger ($trigger)"

        # Frequency
        if ($configurableAppEvents.$trigger.keys -contains 'Frequency') {
            if ($configurableAppEvents.$trigger.Frequency -eq 'FirstTime') { <# No extra presses needed #> }
            else { $keysToPress = $keysToPress + '%e' }
            Write-Verbose "Added keys for Frequency ($($configurableAppEvents.$trigger.Frequency))"
        }

        # command line - Always needed
        $keysToPress = $keysToPress + ('%n',(Join-Path $YamlData.OutputSettings.OutputFolder $configurableAppEvents.$trigger.path))
        Write-Verbose "Added keys for command line file name ($($configurableAppEvents.$trigger.path))"
        if ($configurableAppEvents.$trigger.HandlerCommandLine.Parameters -and ($configurableAppEvents.$trigger.HandlerCommandLine.Parameters -ne '')) {
            $keysToPress = $keysToPress + ('%p',$configurableAppEvents.$trigger.HandlerCommandLine.Parameters)
            Write-Verbose "Added keys for command line parameters ($($configurableAppEvents.$trigger.HandlerCommandLine.Parameters))"
        }
        if ($configurableAppEvents.$trigger.HandlerCommandLine.UseLocalApplication) {
            $keysToPress = $keysToPress + '%u'
            Write-Verbose "Added keys to enable command line 'Use local application' checkbox"
        }

        # Handler launching - Always needed (but RunVirtualized is not an option if the app is not virtualized)
        if (($configurableAppEvents.$trigger.HandlerLaunching.keys -contains 'RunVirtualized') -and ($configurableAppEvents.$trigger.HandlerLaunching.RunVirtualized -eq $false)) {
            # default is TRUE so we only do this if we want it false
            $keysToPress = $keysToPress + '%v'
            Write-Verbose "Added keys to disable Handler launching 'Run virtualized' checkbox"
        }
        if ($configurableAppEvents.$trigger.HandlerLaunching.RunElevated) {
            $keysToPress = $keysToPress + '%l'
            Write-Verbose "Added keys to enable Handler launching 'Run elevated' checkbox"
        }
        if ($configurableAppEvents.$trigger.HandlerLaunching.RunAsLocalSystem) {
            $keysToPress = $keysToPress + ('%a','%a') # for some reason the first time it doesn't check the box when using send-keys but it does when doing it via the gui :shrug:
            Write-Verbose "Added keys to enable Handler launching 'Run as LocalSystem' checkbox"
        }

        # After launching
        if ($configurableAppEvents.$trigger.keys -contains 'AfterLaunching') {
            if ($configurableAppEvents.$trigger.AfterLaunching.WaitForHandlerExit -eq $false) {
                $keysToPress = $keysToPress + '%w'
                Write-Verbose "Added keys to disable After launching 'Wait for the handler to exit' checkbox"
            }
            if ($configurableAppEvents.$trigger.AfterLaunching.TimeOut -ne 1) {
                $keysToPress = $keysToPress + ('%m',$configurableAppEvents.$trigger.AfterLaunching.TimeOut.ToString())
                Write-Verbose "Added keys to set After launching 'Time Out after' to ($($configurableAppEvents.$trigger.AfterLaunching.TimeOut))"
            }
            if ($configurableAppEvents.$trigger.AfterLaunching.TimeOutUnit -eq 'SECONDS') {
                $keysToPress = $keysToPress + ('%m','{TAB}','s')
                Write-Verbose "Added keys to set After launching 'Time Out after' units to ($($configurableAppEvents.$trigger.AfterLaunching.TimeOutUnit))"
            }
            if ($configurableAppEvents.$trigger.AfterLaunching.SuccessCodes -ne '0') {
                $keysToPress = $keysToPress + ('%s',$configurableAppEvents.$trigger.AfterLaunching.SuccessCodes)
                Write-Verbose "Added keys to set After launching 'Success codes' to ($($configurableAppEvents.$trigger.AfterLaunching.SuccessCodes))"
            }
        }

        # OK - Select Trigger (just in case we're on a checkbox) and ENTER
        $keysToPress = $keysToPress + ('%t','{ENTER}')
        Write-Verbose "Finished adding keys for trigger ($trigger)"
    }
    else {
        Write-Verbose "No CAE for trigger ($trigger)"
    }
}

# OK, save, close cloudpaging studio
if ($keysToPress -gt 1) {
    $keysToPress = $keysToPress + ('{ENTER}','^s','%{F4}')
    Write-Verbose "Added keys to save and close."

    # start cloudpaging studio by launching stw
    & $STWFilePath
    Write-Verbose "Waiting $STWLoadSeconds seconds for STW ($STWFilePath) to open"
    Start-Sleep -Seconds $STWLoadSeconds

    Write-Host "Sending keys to 'CloudpagingStuido.exe'"
    & (Join-Path $YamlData.OutputSettings.OutputFolder 'Send-KeysToProcess.ps1') -Name 'CloudpagingStudio.exe' -Keys $keysToPress -LogFilePath (Join-Path $YamlData.OutputSettings.OutputFolder 'SendKeys.log')
}
else { Write-Warning "Execution resulted in no extra keysToPress based on YamlData. No App Events added." }

### Soli Deo Gloria -mbparis