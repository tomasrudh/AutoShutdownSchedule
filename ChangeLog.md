## 3.9.1 2022 7th of November
- Compensate for when conversion to UTC ends up on wrong day.

## 3.9 2022 11th of April
- Added ability to specify Azure environment. Thanks to Hank McCord for contributing this change.

## 3.8 2021 29th of November
- Bugfix, authentication did not always work, change the readme text to be a bit clearer.

## 3.8 2021 3rd of November
- Sometimes stop did not work

## 3.7 2021 31st of October
- Added possibility to use System or User Managed Identity
- Added to have several shutdown only times
- Added better validation and error reporting of the tags

## 3.5 2020 30th of December
Added deallocation of machines stopped but not deallocated

## 3.4 2020 4th of July
Cloned the original script from [Automys](https://automys.com/library/asset/scheduled-virtual-machine-shutdown-startup-microsoft-azure)

These are the changes and enhancements made:
- Added time zone, to be able to use local times
- Allows two machines with the same name but in different resource groups
- Starts and stops machines in parallel
- Allows the schedule to be temporarily invalidated by simply adding an 'X' to the tag name: AutoShutdownScheduleX
- Changed from AzureRM to Az modules, removed the need for the Azure modules

- These are the allowed tags:
  - 19:00->08:00
  - 7pm->8am
    - Turns off between 19 and 08, turns on at other times
  - Sunday
    - Turns off Sundays, turns on at other times
  - 12-24
  - December 24
    - Turns off 24th of December, turns on at other times
  - 19:00->08:00,Sunday
    - Turns off between 19 and 08 and on Sundays, turns on at other times
  - 17:00
    - Turns off at 17, does never start, has to be alone in the tag
- All tags can be combined comma separated, except the last one.

The script cannot control classic Azure machines.
