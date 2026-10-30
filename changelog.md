# Automated Packaging Changelog

# Automated AppsAnywhere Changelog

## 1.1.0 (Q4-2026)

* New Feature:
  * Configurable App Event Support (see Audacity for example)
* Added AppEvents folder with
  * Add-AppEvents.ps1
  * App events for Audacity 4 firewall rules
* Added scripts used in adding Configurable App Events
  * AppEvents\Add-AppEvents.ps1
  * Send-KeysToProcess.ps1
* Start-Package.ps1
  * Updated for AppEvent Support
* stuido-nip.ps1
  * Added DefaultDispositionLayer parameter (for future prerequisite support)
* Updated config files to template 3.2 (CAE and prerequisite support)

## 1.0.2 (Q3-2026)

* Added support for the following applications:
  * Agisoft Metashape Professional
  * LockDown Browser (Lab)
  * Racket
  * SketchUp Pro
  * WinSCP
  * Zotero
* Start-Package.ps1
  * Add -WaitForStart to line 457
  * Turned off verbose messaging for Jira commands
* AutomatedPackaging module updates:
  * Added Convert-ForVersionCompare
  * Added Initialize-VMSession
  * Fixed bug in Limit-* functions
  * Fixed bug in Reset-VMEnvironment where if a VM didn't have a snapshot it would just stay at the same state.
  * Simplified Reset-VMEnvironment parameters
* Updated vagrantfiles boot timeout and winrm execution time limit to address vagrant commands hanging
* Template config file updated to initial 3.2 revision (prerequisites & AppEvents support)

## 1.0.1 (Aug26 PR)

* Initial commit
* Working folder abstraction
* Created and implemented Invoke-CommandAsScheduledTask function
* Created and implemented Initialize-path function
* Created and implemented set-ResetVMStatus command
* Updated Yaml files (config version 3.1):
  * Updated variable names
  * added staging directory & backup directory
  * added RetentionSettings
* Moved Invoke-AutoPrefetch code to prefetch section of Start-Package
* Created and implemented Limit-PackageFolders
* Created and implemented Limit-STPBackupFolders
* Updated readme
* Added session parameters to start-package so it can be used with any VMs
  * Updated scheduled task code to use the username from the session variable
* Created FreeCAD yaml config file
* Reorgaized Start-Package to flow more logically and reduce/remove duplicate checks
* Add Installer, InstallerCommands, InstallerFill, InstallerLogPath, and InstallerProcess under CaptureCommands in *_Config_File.yaml to enable installers other than PSADT script
