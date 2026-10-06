# Dispatcher Console permission sets and settings

Six permission sets and one org setting. They let a user open the Field Service
Dispatcher Console, see the engineers on the Gantt, and use the map.

This directory is used only together with the Field Service managed package.
The permission sets reference the `FSL__` objects, so they deploy only to an
org where the package is installed. `setup.sh` deploys this directory after it
confirms that the package is there, and skips it otherwise. Nothing in this
integration needs the console: Timefold plans the round without it.

## The permission sets

Salesforce creates these permission sets when you click **Setup > Field
Service Settings > Getting Started > Permission Sets**. They are org-local
custom permission sets without a namespace:

```
sf data query -q "SELECT Name, NamespacePrefix, IsCustom FROM PermissionSet
                  WHERE Name LIKE 'FSL%'"
```

So they are kept here as metadata and deployed like the rest of the
integration, and no click is necessary.

| Permission set | Who needs it | What it carries |
|---|---|---|
| `FSL_Dispatcher_License` | the dispatcher | the `FieldServiceDispatcher` user permission, tied to the `FieldServiceDispatcherPsl` license |
| `FSL_Dispatcher_Permissions` | the dispatcher | read and write on the FSL objects the console reads: scheduling policies, work rules, Gantt filters, user settings |
| `FSL_Resource_License` | each engineer | the `FieldServiceScheduling` user permission |
| `FSL_Resource_Permissions` | each engineer | the subset an engineer needs |
| `FSL_Admin_License` | whoever administers Field Service | the `FieldServiceStandardPsl` license |
| `FSL_Admin_Permissions` | whoever administers Field Service | the Field Service Settings tabs, the Field Service Admin app, and ten custom permissions the dispatcher set does not include |

Without `FSL_Admin_Permissions`, the package's **Getting Started** page shows
**Missing permissions** and disables **Go to Guided Setup**.

The dispatcher also needs the `FieldServiceDispatcherPsl` **permission set
license**. It is standard and available when Field Service is on. `setup.sh`
grants it with `sf org assign permsetlicense`. Do not confuse it with the
`FSL_Dispatcher_License` permission set.

## The setting

`settings/FieldService.settings-meta.xml` sets `canPopulateGoogleAddress`:
**Setup > Field Service Settings > "Send geolocation and map data to Google
and Apple"**. It is off in a new org. When it is off, the console shows the
`GANTT` tab and no `MAP` tab.

The setting is in this directory and not in `field-service/` because the map
is part of the managed package, and because `setup.sh` deploys
`field-service/` only to an org where Field Service is off.
