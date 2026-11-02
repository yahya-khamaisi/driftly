# Driftly — behaviour spec

How each feature behaves, and which macOS API implements it. Every feature is free.

## 1. Behaviour

| Area | Behaviour |
|---|---|
| **Master toggle** | Switch in the panel, plus a global hotkey (default ⌃⌘D, recordable). The status line shows Off / Waiting for idle · Ns / Active · next move in Ns / Paused · reason / "Activates: Mon ≈09:03". |
| **Modes** | **Standard:** straight eased moves at exact intervals. **Natural:** curved Bézier paths, varied speed, sub-pixel jitter, varied click timing, ±8% on both intervals, and Schedule and Auto-stop times shifted ±1–5 min per day (shown with ≈). **Silent:** a zero-distance move plus `IOPMAssertionDeclareUserActivity`; no clicks and no scroll. Key press still works. |
| **Start after idle** | Seconds of *real* inactivity (5s–10min) before the first move. |
| **Move every** | Interval after the first move (5s–5min), or continuously. |
| **Range** | Small: a few px, then returns to where you left it. Medium: wanders nearby. Full: anywhere on the current display. |
| **Click** | None / Left / Right / Alternate, at each saved point in turn (or at the cursor if none are saved). The cursor then moves to a random spot. |
| **Scroll** | Vertical / Horizontal / Both: a few ticks one way, then the same number back. |
| **Key press** | A bare Control tap (`flagsChanged`) with each cycle. Types nothing. |
| **Schedule** | Active hours on chosen weekdays (overnight windows supported). A manual toggle holds until the next scheduled start or stop. |
| **Auto-stop** | *At time*: repeats daily, only switches off, never on. *After*: countdown restarts on every activation; always exact. |
| **App rules** | Is running / Is in front / Isn't in front, for a list of apps. Only gates jiggling; Driftly still has to be switched on. |
| **Automatic pauses** | Real input (mouse, keys, scroll, gestures), screen lock (optional), fast user switching, sleep, screensaver, another app's open menu, screenshot UI (⌘⇧4/5), battery below a threshold. |
| **Power** | Optional display-sleep assertion while active. It's released while the screen is locked. |
| **Open at login** | Opens Driftly at login, and resumes only if it was active when you quit. |

## 2. macOS APIs

| Need | API | Notes |
|---|---|---|
| Move / click / scroll / key | `CGEvent(...).post(tap: .cghidEventTap)` | Posting at the HID tap resets the system idle timer, which Teams, Slack and screensavers read. `CGWarpMouseCursorPosition` does not. |
| Permissions | `CGPreflightPostEventAccess` / `CGRequestPostEventAccess`, `CGPreflightListenEventAccess` / `CGRequestListenEventAccess` | Both work inside the App Sandbox. |
| Ignore own events | `.eventSourceUserData` marker, filtered in a global `NSEvent` monitor | |
| Silent keep-alive | Zero-delta `mouseMoved` + `IOPMAssertionDeclareUserActivity` | |
| Keep awake | `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep)` | |
| Lock / screensaver | `DistributedNotificationCenter`: `com.apple.screenIsLocked/Unlocked`, `com.apple.screensaver.didstart/didstop` | |
| User switch / sleep | `NSWorkspace` `sessionDidResignActive/BecomeActive`, `willSleep/didWake` | |
| Menu / screenshot open | `CGWindowListCopyWindowInfo`: another app's window at `popUpMenuWindow` level, or owner `screencaptureui` | Layer and owner name need no Screen Recording permission. |
| App rules | `NSWorkspace.runningApplications`, `frontmostApplication` | |
| Battery | `IOPSCopyPowerSourcesInfo` | |
| Hotkey | Carbon `RegisterEventHotKey` | Works in the sandbox. |
| Login item | `SMAppService.mainApp` | |
| UI | `MenuBarExtra(.window)`, grouped `Form`, `LSUIElement = YES` | |

## 3. Engine loop (`AppState.tick`, once per second)

```
schedule boundary crossed?            → setActive(inWindow)   (manual choice holds until the next boundary)
auto-stop deadline / battery cutoff   → setActive(false)
!active                               → "Off" / "Activates: …"
blocker (permission, lock, switch, sleep, menu, app rule) → "Paused · …"
real idle < threshold                 → "Waiting for idle · Ns"
first move since activity, or interval elapsed → Mover.cycle()
```

Any real input during a cycle aborts it immediately.

## 4. Known follow-ups

- First-run onboarding that explains both permissions before the system prompts.
- Verify the menu-detection heuristic doesn't cause permanent pauses with third-party menu-bar apps.
- Localization.
- App icon artwork (the asset catalog has an empty `AppIcon`).
