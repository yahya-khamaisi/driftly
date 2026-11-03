# Driftly — behaviour spec

How each feature behaves, and which macOS API implements it. Every feature is free.

## 1. Behaviour

Driftly has two features that run independently: **Awake** (keeps the Mac from sleeping) and **Drift** (simulates activity). Each has its own switch, duration, lock behavior, notification and shortcut.

| Area | Behaviour |
|---|---|
| **Awake** | Its switch (or ⌃⌘A) turns it on. It lasts until turned off, for a preset duration (15 min–8 h) or until a time; choosing a new duration while on restarts the countdown. The display either stays on or can sleep; the Mac itself always stays awake. |
| **Drift** | Its switch (or ⌃⌘D) turns it on, with its own "Run for" duration. Styles: **Standard** (straight eased moves at exact intervals), **Natural** (Bézier paths, varied speed, ±8% on both intervals, schedule times shifted ±1–5 min per day, shown with ≈), **Silent** (a zero-distance move plus `IOPMAssertionDeclareUserActivity`; no clicks or scroll). Start after idle 5s–10min; move every 5s–5min or continuously; range small/medium/full. Extra activity: clicks at saved points, a scroll that returns, a bare Control tap. Drift doesn't hold power assertions; its input resets the idle timer. |
| **Status** | Each card's header shows time left and end time, "Until you turn it off", "While Zoom is running", or "Off · starts today at 09:00". Drift shows what it's doing ("Next move in 4s", "Paused · screen locked"). The ring shows the share of a timed run still to go. The menu bar can show Awake's time left (H:MM), and lights its icon for Awake, Drift or either. |
| **Triggers** | Each trigger turns **Awake**, **Drift** or **Both** on: schedule, app (running / in front), power (charger / on battery / battery above N%), display (external / mirroring), device (USB or Bluetooth), network (Wi-Fi name / VPN), audio output, drive mounted, download in Downloads (30 s grace after the last partial file), CPU above N%. A triggered feature uses its own settings, hands over to another of its triggers that's still true, and turns off when none matches. |
| **Manual override** | Turning a feature off by hand holds off its triggers that are currently true until they stop matching. Turning it on by hand while a trigger matches makes the run manual. |
| **Automatic pauses** | Drift pauses for real input, user switching, sleep, the screensaver, another app's open menu and the screenshot UI. "When the screen is locked: Pause" lets the display sleep for Awake and stops movement for Drift, set separately. |
| **Turns off on its own** | Duration or until-time reached, battery below the cutoff (Awake, on battery), or no trigger matching. A notification says why, if that feature's notification is on. |
| **Lock after idle** | While Awake is on, locks the screen after N minutes without real input. |
| **Drive keep-alive** | While Awake is on, writes a small hidden file to the chosen drive every 60 s. |
| **Statistics** | Seconds each feature was on per day, kept for 60 days. Settings shows today and this week for both. |
| **Open at login** | Opens Driftly at login, and turns back on each feature that was on by hand when you quit. |
| **Migration** | Older settings migrate once. From v2: the session becomes Awake; if Simulate activity was on, Drift too, and triggers target Both (otherwise Awake). A custom v2 shortcut becomes Awake's. From v1: Schedule and App rules become triggers, Auto-stop "after" becomes the duration. |

## 2. macOS APIs

| Need | API | Notes |
|---|---|---|
| Keep awake | `IOPMAssertionCreateWithName`: `PreventUserIdleSystemSleep`, plus `PreventUserIdleDisplaySleep` when the display stays on | Named "Driftly Awake"; released when Awake turns off. |
| Move / click / scroll / key / lock | `CGEvent(...).post(tap: .cghidEventTap)` | Posting at the HID tap resets the system idle timer. Lock is ⌃⌘Q. |
| Permissions | `CGPreflight/RequestPostEventAccess`, `CGPreflight/RequestListenEventAccess` | Work inside the App Sandbox. |
| Ignore own events | `.eventSourceUserData` marker, filtered in a global `NSEvent` monitor | |
| Lock / screensaver / switch / sleep | `DistributedNotificationCenter`, `NSWorkspace` notifications | |
| Menu / screenshot open | `CGWindowListCopyWindowInfo` layer and owner name | No Screen Recording permission needed. |
| App trigger | `NSWorkspace.runningApplications`, `frontmostApplication` | |
| Power trigger, battery cutoff | `IOPSCopyPowerSourcesInfo`, `IOPSGetProvidingPowerSourceType` | |
| Display trigger | `CGGetOnlineDisplayList`, `CGDisplayIsBuiltin`, `CGDisplayIsInMirrorSet` | |
| Device trigger | IORegistry `IOUSBHostDevice` "USB Product Name"; `IOBluetoothDevice.pairedDevices` | Entitlements `device.usb`, `device.bluetooth`. |
| Network trigger | `CWWiFiClient` SSID (needs Location); `getifaddrs` utun/ppp/ipsec with IPv4 for VPN | Entitlement `personal-information.location`. |
| Audio trigger | CoreAudio default output device name | |
| Drive trigger | `FileManager.mountedVolumeURLs` | |
| Download trigger | Partial-file extensions (`.download`, `.crdownload`, `.part`, `.partial`, `.opdownload`) in Downloads | Entitlement `files.downloads.read-only`. |
| CPU trigger | `host_statistics(HOST_CPU_LOAD_INFO)` between samples | |
| Drive keep-alive | Security-scoped bookmark from an open panel | Entitlements `files.user-selected.read-write`, `files.bookmarks.app-scope`. |
| Notifications | `UNUserNotificationCenter` | |
| Hotkeys | Carbon `RegisterEventHotKey`, one id per feature | Each handler passes on presses for the other id. |
| Login item | `SMAppService.mainApp` | |
| UI | `MenuBarExtra(.window)`, grouped `Form`, `LSUIElement = YES` | |

## 3. Engine loop (`AppState.tick`, 4 Hz)

```
every 2 s: evaluate triggers  → per feature: turn on (.trigger) / hand over / turn off
duration or until-time reached → that feature off
Awake on battery below cutoff → Awake off
power assertions              → system while Awake is on; display unless "can sleep" or paused while locked
Awake on                      → lock after idle, drive keep-alive, statistics
Drift on   blocker            → "Paused · …"
           idle < threshold   → "Waiting for idle · Ns"
           first move since activity, or interval elapsed → Mover.cycle()
each feature off              → "Off" / "Off · starts …"
```

Any real input during a cycle aborts it immediately.

## 4. Not included

- Staying awake with the lid closed: it needs an admin helper that changes system power settings, which doesn't fit a sandboxed app.
- AppleScript: Shortcuts actions are the better modern route and a possible follow-up.
