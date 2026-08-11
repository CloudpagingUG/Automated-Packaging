# Automated Packaging Changelog

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
