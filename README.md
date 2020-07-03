# Scheduled Virtual Machine Shutdown/Startup - Microsoft Azure

# What It Does
This runbook automates scheduled startup and shutdown of Azure virtual machines. You can implement multiple granular power schedules for your virtual machines using simple tag metadata in the Azure portal or through PowerShell. For example, you could tag a single VM or group of VMs to be shut down between the hours of 10:00 PM and 6:00 AM, all day on Saturdays and Sundays, and during specific days of the year, like December 25.

The runbook is intended to run on a schedule in an Azure Automation account, with a configured subscription and associated access credentials. For example, it can run once every hour, checking all the schedule tags it finds on your virtual machines or resource groups. If the current time falls within a shutdown period you’ve defined, the runbook will stop the VM if it is running, preventing any compute charges. If the current time falls outside of any tagged shutdown period, this means the VM should be running, so the runbook starts any such VM that is stopped.
