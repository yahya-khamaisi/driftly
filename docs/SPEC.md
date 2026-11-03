# Driftly — behaviour spec

How each feature behaves, and which macOS API implements it. Every feature is free.

## 1. Behaviour

| Area | Behaviour |
|---|---|
| **Session** | The main switch (or the hotkey, default ⌃⌘D) starts a session. A manual session lasts indefinitely, for a preset length (15 min–8 h) or until a time; choosing a new length during a session restarts the countdown. The display either stays on or can sleep; the Mac itself always stays awake. |
| **Status** | Header: "Awake" with time left and end time, "Until you turn it off", "While Zoom is running", or "Off · starts today at 09:00". The ring shows the share of a timed session still to go. The menu bar can show time left (H:MM). |
| **Simulate activity** | Optional within any session. Modes: **Standard** (straight eased moves at exact intervals), **Natural** (Bézier paths, varied speed, ±8% on both intervals, schedule times shifted ±1–5 min per day, shown with ≈), **Silent** (a zero-distance move plus `IOPMAssertionDeclareUserActivity`; no clicks or scroll). Start after idle 5s–10min; move every 5s–5min or continuously; range small/medium/full. Extra activity: clicks at saved points, a scroll that returns, a bare Control tap. |
| **Triggers** | Each one only decides *when* a session starts: schedule, app (running / in front), power (charger / on battery / battery above N%), display (external / mirroring), device (USB or Bluetooth), network (Wi-Fi name / VPN), audio output, drive mounted, download in Downloads (30 s grace after the last partial file), CPU above N%. A triggered session uses the main panel's settings, hands over to another trigger that's still true, and ends when none matches. |
| **Manual override** | Ending any session by hand holds off every trigger that's currently true until it stops matching. Starting by hand while a trigger matches makes the session manual. |
| **Automatic pauses** | Simulated activity pauses for real input, user switching, sleep, the screensaver, another app's open menu and the screenshot UI. With "When the screen is locked: Pause", activity stops and the display may sleep while locked. |
| **Ends on its own** | Timer or until-time reached, battery below the cutoff (on battery), or no trigger matching. A notification says why, if enabled. |
| **Lock after idle** | During a session, locks the screen after N minutes without real input. |
| **Drive keep-alive** | During a session, writes a small hidden file to the chosen drive every 60 s. |
| **Statistics** | Seconds awake and sessions per day, kept for 60 days. Settings shows today and this week. |
| **Open at login** | Opens Driftly at login, and resumes a manual session that was on when you quit. |
| **Migration** | v1 settings migrate once: Schedule and App rules become triggers, Auto-stop "after" becomes the session length, Keep awake and Pause when locked map to the new pickers. |

## 2. macOS APIs

| Need | API | Notes |
|---|---|---|
| Keep awake | `IOPMAssertionCreateWithName`: `PreventUserIdleSystemSleep`, plus `PreventUserIdleDisplaySleep` when the display stays on | Released when the session ends. |
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
| Hotkey | Carbon `RegisterEventHotKey` | |
| Login item | `SMAppService.mainApp` | |
| UI | `MenuBarExtra(.window)`, grouped `Form`, `LSUIElement = YES` | |

## 3. Engine loop (`AppState.tick`, 4 Hz)

```
every 2 s: evaluate triggers  → start (.trigger) / hand over / end
timer or until-time reached   → end
on battery below cutoff       → end
power assertions              → system while active; display unless "can sleep" or paused while locked
!active                       → "Off" / "Off · starts …"
lock after idle, drive keep-alive, statistics
simulate activity on?  blocker → "Paused · …"
                       idle < threshold → "Waiting for idle · Ns"
                       first move since activity, or interval elapsed → Mover.cycle()
```

Any real input during a cycle aborts it immediately.

## 4. Not included

- Staying awake with the lid closed: it needs an admin helper that changes system power settings, which doesn't fit a sandboxed app.
- AppleScript: Shortcuts actions are the better modern route and a possible follow-up.
