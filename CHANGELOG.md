# Changelog

## 4.3.2-cinematic.1 — 2026-10-08

First experimental release of randoomdude's cinematic-control fork.

### Cinematic controls

- Maintain native UI hiding during an NPC event rather than assuming a single hide write remains active.
- Detect NPC events separately from the camera-dependent cutscene detector used for FPS control.
- Add `/balloon cinematic on` and `/balloon cinematic off` alongside the existing toggle.
- Restore native UI with Escape or `/` and suspend hiding for the current event.
- Clear that suspension when cinematic mode is explicitly enabled again, without requiring an addon reload.
- Reopen the current dialogue balloon when re-enabling cinematic mode after Escape.
- Keep dialogue visible while invoking native advance, allowing subsequent presses to advance a page.
- Restore native UI if the native advance helper is unavailable or fails; do not hide without a visible dialogue and an available advance helper.
- Restore UI for choices and native typing, and release owned UI state on event exit or unload.
- Remove the repeated ImGui keyboard-focus request.
- Add `/balloon status` with event, visibility, ownership and suspension diagnostics.
- Default cinematic mode to off for fresh installations; preserve existing saved preferences.

### Repository and packaging

- Preserve upstream Window Style 5 themes, bold/italic support and the FPS setting alias.
- Correct the `system_messages` setting lookup and apply FPS changes through the correct setting key.
- Use HTTPS for the pinned gdifonts submodule.
- Add install, upgrade, command and troubleshooting documentation, contributor credits and automated regression checks.
- Build a complete `balloon/` ZIP that includes the pinned gdifonts dependency.

### Validation

LuaJIT regression checks cover repeat advance, Escape/slash recovery, repeated re-enabling in one event, menu/typing visibility and restoration. These are offline checks; the release is a pre-release pending broader in-game cutscene testing.
