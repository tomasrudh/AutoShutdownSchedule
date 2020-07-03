# Scheduled Virtual Machine Shutdown/Startup - Microsoft Azure

## Why Use This?
Money! The largest share of Azure subscription costs when using Virtual Machines (IaaS) is the compute time: how many hours the VMs are running per month. If you have VMs that can be stopped during certain time periods, you can reduce the bill by turning them off (and “deallocating” them).

Unfortunately, Microsoft doesn’t include any tools to directly manage a schedule like this. That’s what this runbook helps achieve without 3rd party management tools or chaining a junior admin to the keyboard for 6AM wakeup call.

## Credits

Let me start by saying this script was not invented originally by me, I have copied the script from Automys and made tweeks and improvements. I have Automys consent to publish this script. The original can be found here: https://automys.com/library/asset/scheduled-virtual-machine-shutdown-startup-microsoft-azure

## What It Does
This runbook automates scheduled startup and shutdown of Azure virtual machines. You can implement multiple granular power schedules for your virtual machines using simple tag metadata in the Azure portal or through PowerShell. For example, you could tag a single VM or group of VMs to be shut down between the hours of 10:00 PM and 6:00 AM, all day on Saturdays and Sundays, and during specific days of the year, like December 25.

The runbook is intended to run on a schedule in an Azure Automation account, with a configured subscription and associated access credentials. For example, it can run once every hour, checking all the schedule tags it finds on your virtual machines or resource groups. If the current time falls within a shutdown period you’ve defined, the runbook will stop the VM if it is running, preventing any compute charges. If the current time falls outside of any tagged shutdown period, this means the VM should be running, so the runbook starts any such VM that is stopped. It is possible to set a time of the day when the machine should be shut down, but never started automatically, so you don't forget to turn it off in the evening.

Once the runbook is in place and scheduled, the only configuration required can be done through simple tagging of resources, and the runbook will implement whatever power schedules it finds during its next scheduled run. Think of this as a quick and basic power management scheduling solution for your Azure virtual machines.

## Tag-based Power Schedules
If our goal is to manage the times that our virtual machines are shut down and powered on, we need a way to define this schedule. For example, perhaps we want to shut down our VMs after close of business and have them start up before people arrive in the office in the morning. But we also might want them shut down all weekend, not just at night. And what about holidays? Clearly, we also need an approach that allows some flexibility to get granular with scheduling.

The first thing we might think to use is a runbook schedule, which Azure already provides out of the box. In essence, we can configure a runbook to run hourly or daily and do a task like shutting down VMs. But as just discussed, what if you have multiple schedules for different VMs? And that’s for shutting down – what about starting them again? Do you use multiple runbooks following multiple schedules? This starts to get confusing and awkward to manage. Unfortunately most of the existing examples I came across followed this kind of approach.

When you think about it, the power schedule applies to the resource, not to the runbook. The alternative approach used by the runbook solution here described is to tag a VM with a schedule, so that the mechanism used to stop and start VMs is transparent – it just happens when you declare that it should. If you’re especially nerdy when it comes to programming, you might recognize this as a declarative rather than imperative approach. It doesn’t use PowerShell Desired State Configuration (yet?), but is in the same spirit.

So what does it look like? We simply apply a tag to a virtual machine or an Azure resource group that contains VMs. This tag is a simple string that describes the times the VM should be shut down.

## Tag Content
The runbook looks for a tag named “AutoShutdownSchedule” assigned to a virtual machine or resource group containing VMs. The value of this tag is one or more schedule entries, or time ranges, defining when VMs should be shut down. By implication, any times not defined in the shutdown schedule are times the VM should be online. So, each time the runbook checks the current time against the schedule, it makes sure the VM is powered on or off accordingly.

There are three kinds of entries:

Time range: two times of day or absolute dates separated by ‘->’ (dash greater-than). Use this to define a period of time when VMs should be shut down.

Day of week / Date: Interpreted as a full day that VMs should be shut down.

Time only: the hour the machine should be shut down, the time has to be the only value in the tag, this machine will never be automatically started.

### Get to Know DateTime
All times must be strings that can be successfully parsed as “DateTime” values. In other words, PowerShell must be able to look at the text value you provide and say “OK, I know how to interpret that as a specific date/time”. There is a surprising amount of flexibility allowed, and the easiest way to verify your choice is to open a PowerShell prompt and try the command `Get-Date '<time text>'`, and see what happens. If PowerShell spits out a formatted timestamp, that’s good. If it complains that it doesn’t know what you mean, try writing the time differently.

## Schedule Tag Examples
The easiest way to write the schedule is to say it first in words as a list of times the VM should be shut down, then translate that to the string equivalent. Remember, any time period not defined as a shutdown time is online time, so the runbook will start the VMs accordingly. Let’s look at some examples:

- Shut down from 10PM to 6 AM UTC every day
  - 10pm->6am
- Shut down from 10PM to 6 AM UTC every day (different format, same result as above)
  - 22:00->06:00
- Shut down from 8PM to 12AM and from 2AM to 7AM UTC every day (bringing online from 12-2AM for maintenance in between)
  - 8PM->12AM, 2AM -> 7AM
- Shut down all day Saturday and Sunday (midnight to midnight)
  - Saturday, Sunday
- Shut down from 2AM to 7AM UTC every day and all day on weekends
  - 2:00->7:00, Saturday, Sunday
- Shut down on Christmas Day and New Year’s Day
  - December 25, January 1
- Shut down from 2AM to 7AM UTC every day, and all day on weekends, and on Christmas Day
  - 2:00->7:00, Saturday, Sunday, December 25
- Shut down always – I don’t want this VM online, ever
  - 0:00 -> 23:59:59
- Shut down at 5PM, but never start
  - 17:00

## What the Runbook Does
The runbook AutoShutdownSchedule is an Azure Automation runbook. It can be run once at a time manually, but is intended to be configured to run on a schedule, e.g. once per hour.

The runbook expects three parameters: the name of the Azure subscription that contains the VMs, the name of an Azure Automation credential asset with stored username and password for the account to use when connecting to that subscription and the timezone you are in. If not specifically configured, the runbook will try by default to find a credential asset named “Default Automation Credential” and a variable asset named “Default Azure Subscription”. Setting these up is discussed in more detail below. There is a fourth parameter called "Simulate" which, if True, tells the runbook to only evaluate schedules but not enforce them. This is discussed further below.

Once successfully authenticated to the target subscription, the runbook looks for any VM or resource group that has a tag named “AutoShutdownSchedule”. Any resource groups without this specific tag are ignored. For each tagged resource found, we next look at the tag values to see what the schedule entries are. Each is inspected and compared with the current time. Then, one of several decisions is made:

If the current time is outside of the defined schedules, the runbook concludes that this is “online time” and starts any directly or indirectly tagged VM that is currently powered off.

If the current time matches any of the schedules, the runbook concludes that this is “shutdown time” and stops any directly or indirectly tagged VM that is currently powered on.

If the tag contains a single time value, will the machine be turned off at that time. It will not be turned on at other times.

If any of the defined schedules can’t be parsed (PowerShell doesn’t understand “beer thirty”), it will ignore that and treat whatever was intended as online time. Therefore, **the default failsafe behavior is to keep VMs online** or start them, not shut them down.

## Runbook Logs
Various output messages are recorded by the runbook every time it runs, indicating what actions were taken and whether any errors occurred in processing tags or accessing the subscription. These logs can be found in the output of each job.

## Performance
Startup and shutdown are done in parallell. The machines are started in alphabetical order by their names.

## Testing
To test the runbook without actually starting or stopping your VMs, you can use the "Simulate" option. If true, the schedules will be evaluated but no power actions will be taken. You can then see whether everything would have worked as you expect before setting up the runbook to run live (runbook runs live by default).

## Azure Modules

You need to add these modules to your Automation account, do not add all Az modules.
  - Az.Accounts
  - Az.Compute
  - Az.KeyVault
  - Az.Profile
  - Az.Resources
