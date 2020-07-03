# Scheduled Virtual Machine Shutdown/Startup - Microsoft Azure

# Why Use This?
Money! The largest share of Azure subscription costs when using Virtual Machines (IaaS) is the compute time: how many hours the VMs are running per month. If you have VMs that can be stopped during certain time periods, you can reduce the bill by turning them off (and “deallocating” them).

Unfortunately, Microsoft doesn’t include any tools to directly manage a schedule like this. That’s what this runbook helps achieve without 3rd party management tools or chaining a junior admin to the keyboard for 6AM wakeup call.

# Credits

Let me start by saying this script was not invented originally by me, I have copied the script from Automys and made tweeks and improvements. I have Automys consent to publish this script. The original can be found here: https://automys.com/library/asset/scheduled-virtual-machine-shutdown-startup-microsoft-azure

# What It Does
This runbook automates scheduled startup and shutdown of Azure virtual machines. You can implement multiple granular power schedules for your virtual machines using simple tag metadata in the Azure portal or through PowerShell. For example, you could tag a single VM or group of VMs to be shut down between the hours of 10:00 PM and 6:00 AM, all day on Saturdays and Sundays, and during specific days of the year, like December 25.

The runbook is intended to run on a schedule in an Azure Automation account, with a configured subscription and associated access credentials. For example, it can run once every hour, checking all the schedule tags it finds on your virtual machines or resource groups. If the current time falls within a shutdown period you’ve defined, the runbook will stop the VM if it is running, preventing any compute charges. If the current time falls outside of any tagged shutdown period, this means the VM should be running, so the runbook starts any such VM that is stopped. It is possible to set a time of the day when the machine should be shut down, but never started automatically, so you don't forget to turn it off in the evening.

Once the runbook is in place and scheduled, the only configuration required can be done through simple tagging of resources, and the runbook will implement whatever power schedules it finds during its next scheduled run. Think of this as a quick and basic power management scheduling solution for your Azure virtual machines.

# Tag-based Power Schedules
If our goal is to manage the times that our virtual machines are shut down and powered on, we need a way to define this schedule. For example, perhaps we want to shut down our VMs after close of business and have them start up before people arrive in the office in the morning. But we also might want them shut down all weekend, not just at night. And what about holidays? Clearly, we also need an approach that allows some flexibility to get granular with scheduling.

The first thing we might think to use is a runbook schedule, which Azure already provides out of the box. In essence, we can configure a runbook to run hourly or daily and do a task like shutting down VMs. But as just discussed, what if you have multiple schedules for different VMs? And that’s for shutting down – what about starting them again? Do you use multiple runbooks following multiple schedules? This starts to get confusing and awkward to manage. Unfortunately most of the existing examples I came across followed this kind of approach.

When you think about it, the power schedule applies to the resource, not to the runbook. The alternative approach used by the runbook solution here described is to tag a VM with a schedule, so that the mechanism used to stop and start VMs is transparent – it just happens when you declare that it should. If you’re especially nerdy when it comes to programming, you might recognize this as a declarative rather than imperative approach. It doesn’t use PowerShell Desired State Configuration (yet?), but is in the same spirit.

So what does it look like? We simply apply a tag to a virtual machine or an Azure resource group that contains VMs. This tag is a simple string that describes the times the VM should be shut down.
