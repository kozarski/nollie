# Remove Nollie

[← Nollie](../../README.md)

Nollie keeps everything it writes on your Mac in one folder:
`~/Library/Application Support/Nollie`. Removing it is one button.

## Remove Nollie from this Mac

Open **Settings › About › Remove**, then **Remove Nollie from this Mac…**. A sheet lists what goes
and what stays before anything happens. Press **Remove Nollie** and it works down the list:

1. Your helpers' own computers are turned off and deleted. Each helper's settings go back to what
   they were first.
2. Nollie Runtime and Nollie Notifications stop and leave Login Items. The assistant Nollie set up
   stops first.
3. If you connected Nollie to a Hermes of your own, Nollie's add-ons go to the Trash and its settings
   stop listing them. A dated copy of each settings file is kept beside it.
4. If Nollie installed Cua for you, Cua goes too, with your helpers' computers.
5. The assistant Nollie set up on this Mac is deleted, with its chats, memory and settings.
6. Nollie's folder is deleted, with its caches, logs and records, and so are Nollie's settings and
   the folders macOS keeps for Nollie by name.
7. Nollie's connections and saved sign-ins are deleted from the keychain.
8. Only if you tick **Also delete Nollie's data in iCloud**: Nollie's alerts in your iCloud.
9. Nollie moves itself to the Trash and quits.

If a step can't be done, the sheet says which one and what you can do instead.

## What stays

- **Privacy & Security rows.** macOS keeps the permissions you gave Nollie, and only you can remove
  them. The last screen has a button that opens Privacy & Security for you.
- **A Hermes you set up yourself.** Its bots, chats, memory and settings stay. Only Nollie's add-ons
  leave. Nollie also leaves the dated copies of your Hermes settings it made
  (`config.yaml.bak-nollie-…`), in case you want one back.
- **A Hermes on another computer.** Nollie can only tidy a Hermes on this Mac. On another computer,
  remove the `nollie-…` folders from its `plugins` folder there.
- **Cua you installed yourself.** If Cua Spaces is in your Applications folder, Nollie used it and
  leaves it there.
- **Backups you saved yourself**, wherever you saved them.
- **Nollie Notifications' small alert queue**, inside its own macOS container
  (`~/Library/Containers/com.coreykozarski.nollie.background-alerts`), which macOS manages.

## Dragging Nollie to the Trash

If you drag Nollie to the Trash instead, Nollie Runtime notices within about a minute. It stops your
assistant and Cua's background part, leaves Login Items for now, and quits. It deletes nothing,
because there is nobody to ask. Nollie Notifications quits too.

Install Nollie again and it says **Welcome back**: **Use it** picks up your assistant where it was,
and **Remove it** removes the earlier setup with the same list as above, keeping the new Nollie.

To remove everything without reinstalling, put Nollie back in Applications, open it, and use
**Remove Nollie from this Mac**.

## On iPhone, iPad and the Mac App Store edition

**Settings › About › Remove › Remove Nollie's data…** deletes Nollie's chats, pictures and settings
on that device and its connections in the keychain, then goes back to the first screen. Your bots
and chats stay on your Hermes. Deleting the app afterwards removes the rest.
