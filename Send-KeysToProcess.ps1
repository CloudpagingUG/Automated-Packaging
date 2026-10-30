<#
.SYNOPSIS
    Send-KeysToProcess.ps1 sends key presses to a process for automating GUI tasks.
.DESCRIPTION
    Send-KeysToProcess.ps1 looks for the process specified with the -Name paramenter, sends the key
    presses specified with the -Keys parameter to the process using the WScript.Shell ComObject's
    SendKeys() method, and if desired logs to the file specified with -LogFilePath
.NOTES
    Initially set up for Automated Packaging of Cloudpaging packages 2026-Oct-01
.PARAMETER Name
    Specifies the process name to send key presses to.
    Used to filter the results from (Get-CimInstance -ClassName Win32_Process).
.PARAMETER Keys
    Specifies an array of strings to signify what keys will be sent to the process. See Microsoft's
    sendkeys doc: 'https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.sendkeys'.
.PARAMETER SecondsBetween
    How long to wait (in seconds) between each SendKeys() calls.
.PARAMETER LogFilePath
    Specifies the full path to the file that Send-KeysToProcess will log to. [Default: <EMPTY>] and
    will not log to a file.
.EXAMPLE
    & (Join-Path $YamlData.OutputSettings.OutputFolder 'Send-KeysToProcess.ps1') -Name 'CloudpagingStudio.exe'
      -Keys $keysToPress -LogFilePath (Join-Path $YamlData.OutputSettings.OutputFolder 'SendKeys.log')
    
    Send-KeysToProcess will look for a process called 'CloudpagingStudio.exe', send all the keys
    specified with -Keys, and log to 'SendKeys.log'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [parameter(Mandatory = $true)]
    [String[]]$Keys,
    [parameter(Mandatory = $false)]
    [Int]$SecondsBetween = 1,
    [parameter(Mandatory = $false)]
    [string]$LogFilePath
)

if ($LogFilePath -eq '') {
    $teeObjectArgs = @{ Variable = 'null' }
}
else {
    $teeObjectArgs = @{
        FilePath = $LogFilePath
        Append = $true
    }
}
"[$(get-date)]Starting Send-KeysToProcess..." | Tee-Object @teeObjectArgs | Write-Verbose
$proc = Get-CimInstance -ClassName Win32_Process | Where-Object {$_.name -eq $Name}
if ($proc){
    "[$(get-date)]Process ($($proc.Name)) found. Keys will be sent to this process." | Tee-Object @teeObjectArgs | Write-Verbose
    $id = $proc.Handle
    $wshell = New-Object -ComObject WScript.Shell
    $wshell.AppActivate($id) | Out-Null
    
    foreach ($key in $Keys) {
        if ($key -match '^[{~^+%]') {
            "Sending keys '$key'" | Tee-Object @teeObjectArgs | Write-Verbose
            $wshell.SendKeys($key)
        }
        else {
            "Writing out string '$key'" | Tee-Object @teeObjectArgs | Write-Verbose
            foreach ($char in $key.ToCharArray()){
                $wshell.SendKeys($char)
            }
        }
        Start-Sleep -Seconds $SecondsBetween
    }
}
else { "[$(get-date)]No process found with name -eq ($Name)" | Tee-Object @teeObjectArgs | Write-Warning }
"[$(get-date)]Completed Send-KeysToProcess" | Tee-Object @teeObjectArgs | Write-Output

### Soli Deo Gloria -mbparis