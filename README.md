# Full Screen Bar

Full Screen Bar applies menu bar rules to the **native full-screen window you’re using**. By default it keeps the menu bar visible on screens with a camera notch and auto-hides it on screens without one. Open **Settings** from the menu bar icon to change the display defaults. To add an exception, choose **Add App…** and pick an open app, or choose **Browse Applications…** if it isn’t running.

Turn on **Auto-hide during full-screen playback** in Settings to override the display and app rules while the focused full-screen app signals playback. The normal rule returns when that signal stops. This is off by default and needs no browser extension. Detection uses Safari’s WebKit media playback assertion and video-related display wake locks, such as [Chromium’s Video Wake Lock](https://chromium.googlesource.com/chromium/src/+/a0743f978ed3dd32db13a1d1fb371ab21cca1b8b/third_party/blink/renderer/core/html/media/video_wake_lock.cc). The signal is app-wide: it can’t distinguish a full-screen video from a full-screen browser window playing media in another tab. Apps that don’t expose a recognised signal won’t trigger the override.

The app changes macOS’s global full-screen setting, so other full-screen displays may change too. When the focused display defaults to Auto-Hide, the app keeps that full-screen setting ready on the desktop to avoid switching it after the next Space opens. The desktop menu bar itself is unaffected. macOS may still wait for pointer movement after a keyboard-only switch. Pausing rules or quitting restores your previous setting unless you’ve changed it yourself.

## Build and run

```sh
app="$(bash Scripts/build-app.sh)"
open "$app"
```

The build script produces a local, ad hoc signed app bundle. Verified on macOS 27.2.1 on an Apple silicon MacBook with a Dell P3424WE and **Displays have separate Spaces** enabled. The app uses private, read-only WindowServer interfaces to identify the focused full-screen Space; macOS updates may change that behaviour.

## Command-line diagnostics

Quit or pause the menu bar app before running a diagnostic that changes the global setting. `MenuBarProbe watch [rules.json]` runs a separate Accessibility-based watcher in the terminal; `MenuBarProbe focused` reports the current native full-screen focus.

### Test the global switch

```sh
swift build
probe="$(swift build --show-bin-path)/MenuBarProbe"
"$probe" displays
"$probe" status
"$probe" global hide 20
```

Switch to an app that's already in native full screen before the timer expires. Move the pointer away from the top edge and check whether the menu bar disappears, whether the app expands into the space, and whether hovering at the top still reveals the menu bar. Keep the same window open through the end of the test to check restoration. Use `global show 20` to test in the other direction. The exact stored value is preserved, including an unset preference.

The test changes the global **full-screen** preference and sends the system's refresh notification. It does not change the desktop preference or Control Center's settings selection. The timer and Ctrl-C restore the previous value, unless the preference is no longer the value the test applied. If the process is force-killed, run `"$probe" recover` to restore it from the recovery record. Avoid changing the same preference in System Settings during the test: a change to the same value the probe set can't be distinguished from the probe's own write.

The refresh mechanism is documented by [Houdini](https://github.com/mgxv/houdini/blob/HEAD/Sources/MenuBarToggler.swift) and [FreeSwitch](https://github.com/Having-Liu/FreeSwitch/blob/HEAD/README.en.md). The visual result must be checked on screen. Reading the preference or inspecting `NSScreen.visibleFrame` is not proof that the menu bar or app layout changed.

### Experimental per-display override

The experimental SkyLight command is available on macOS 27.2.1 (Apple silicon). The API can request **force visible** on one display; clearing that flag returns the display to normal policy. It cannot force-hide a display. The flag can also clear during menu tracking and is separate from macOS's always-visible full-screen setting.

1. With the MacBook lid open and an external monitor connected, use `"$probe" displays` to confirm that macOS sees both screens. With **Displays have separate Spaces** enabled in System Settings, put an app in native full screen on each display.
2. If the full-screen menu bars are normally shown, run `"$probe" global hide 90` in one terminal. This sets auto-hide for both displays for the duration of the experiment.
3. In another terminal, run `"$probe" skylight show <notched-display-id> 45`, substituting the ID from step 1. Return to the two full-screen apps and move the pointer away from the top edge.
4. Check whether the bar stays visible on the MacBook and remains hidden on the external screen when you move focus between them. Check hover reveal and available app space on the external screen. Repeat targeting the external display to rule out a main-display effect.

`"$probe" skylight status` reads the flag, not the bar's actual visibility. On the Dell P3424WE it changed from unset to set and back after Ctrl-C; that does not establish the behaviour in full-screen Spaces. The probe requests a clear on timeout or Ctrl-C, but WindowServer may defer it. `recover` applies only to the global preference.

Run `swift test` to check the global restore logic without touching system settings.
