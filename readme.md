# Balloon for Ashita v4 — cinematic controls

NPC dialogue in a movable, themed balloon, with native chat/UI hiding during NPC events. This community fork of [onimitch's Ashita v4 port](https://github.com/onimitch/ffxi-balloon-ashitav4) is maintained by **randoomdude**.

**Experimental pre-release:** the cinematic handlers have offline regression coverage. Broader in-game cutscene behavior still needs verification.

[Download the complete addon](https://github.com/randoomdude/ffxi-balloon-ashitav4openai/releases) · [Changes](CHANGELOG.md) · [Report an issue](https://github.com/randoomdude/ffxi-balloon-ashitav4openai/issues) · [Credits](CREDITS.md)

![Balloon's default theme](Example-default.png)

## What this fork changes

- Escape or `/` restores the native UI during a hidden dialogue.
- `/balloon cinematic on` re-enables hiding in the same event, without an addon reload.
- Re-enabling after Escape can reopen the current dialogue balloon.
- Advance attempts retain the visible balloon so subsequent presses remain available.
- Hiding checks the current UI flag before rendering, and restores UI for choices, typing, event exit and unload.
- Balloon no longer requests keyboard focus every frame.
- `/balloon status` reports event and visibility state for troubleshooting.

Upstream themes, portraits, scaling, font support and existing settings are retained. See the [changelog](CHANGELOG.md) for the complete change list.

## Install

1. Download `balloon-4.3.2-cinematic.1.zip` from this fork's [Releases page](https://github.com/randoomdude/ffxi-balloon-ashitav4openai/releases).
2. Extract it into your Ashita `addons` directory. The resulting path must be `addons/balloon/Balloon.lua`.
3. In FFXI, run:

```text
/addon load balloon
/balloon 2
/balloon cinematic on
```

The release ZIP includes the required **gdifonts** library. GitHub's automatic “Source code” ZIP does not include the submodule contents and is not a complete addon installation. For a source checkout, use `git clone --recurse-submodules` as described in [CONTRIBUTING.md](CONTRIBUTING.md).

Cinematic mode defaults to **off for fresh settings**. Existing saved preferences are honored. To load Balloon automatically, add `/addon load balloon` to the startup script used by your Ashita boot profile; the saved cinematic preference is reused.

## Update an existing installation

Unload Balloon with `/addon unload balloon`, back up `addons/balloon`, and replace it with the release's `balloon` folder. Keep `config/addons/balloon` so positions, themes and other preferences survive. Load it again afterward. If updating files while the addon is loaded, reload it once with `/addon reload balloon`.

## Cinematic controls

| Action | Result |
|---|---|
| `/balloon cinematic on` | Enable or re-enable native UI hiding. |
| `/balloon cinematic off` | Disable hiding and restore owned native UI state. |
| `/balloon cinematic` | Toggle the preference. |
| **Enter / controller confirm** | Continue dialogue through the native advance helper when the UI is hidden. |
| **Escape** while hidden | Restore native UI, close the balloon and suspend hiding for this event. |
| **`/`** while hidden | Restore native UI and pass the key through for command entry; suspend hiding for this event. |
| `/balloon cinematic on` after recovery | Clear the suspension and hide again once native typing has closed. |

Hiding affects the **native game UI**, including both original chat windows. Separately rendered addon windows such as FancyChat have their own visibility rules. Choice menus temporarily show native UI.

To retain a usable advance path, the addon hides only when a balloon is visible and the native advance helper is available. Native UI may reappear during gaps with no dialogue balloon. An event ending clears a temporary Escape/slash suspension.

## Display modes: dialogue text versus window visibility

These modes control the dialogue copy in the native log; cinematic mode separately controls UI visibility.

| Command | Dialogue display |
|---|---|
| `/balloon 0` | Native dialogue only; no balloon or cinematic hiding. |
| `/balloon 1` | Balloon dialogue; native log shows abbreviated `NPC: ...` placeholders with prompt markers. |
| `/balloon 2` | Full dialogue in both Balloon and native chat. Recommended when using Escape/slash recovery. |

Both modes 1 and 2 support cinematic hiding. The alias `/bl` also works.

## Appearance and other commands

Drag an open balloon with the mouse to position it, including at the bottom center.

| Command | Purpose |
|---|---|
| `/balloon theme <theme>` | Choose a theme. |
| `/balloon scale <number>` | Set a size multiplier, for example `1.5`. |
| `/balloon speed <number>` | Characters per second; `0` shows all text immediately. |
| `/balloon delay <seconds>` | Close delay for balloons with no advance prompt. |
| `/balloon portrait` | Toggle NPC portraits. |
| `/balloon move_close` | Toggle closing on player movement. |
| `/balloon always_on_top` | Toggle the ImGui rendering path. |
| `/balloon in_combat` | Toggle balloons during combat. |
| `/balloon system` | Toggle system messages outside cutscenes. |
| `/balloon fps` | Toggle cutscene FPS control. |
| `/balloon reset pos` | Reset position without resetting other settings. |
| `/balloon reset` | Reset all settings to this fork's defaults. |
| `/balloon test` | List sample dialogue balloons. |
| `/balloon test bahamut` | Preview a sample balloon. |
| `/balloon status` | Print cinematic/event, menu, typing, hidden, owned and suspended state. |
| `/balloon help` | Show command help. |

### Included themes

`default`, `ffvii-r`, `ffxi`, `snes-ff`, `ffxi-window5` and `ffxi-window5-solid`.

The FFVII-R theme uses [Libre Franklin](https://fonts.google.com/specimen/Libre+Franklin). The SNES theme uses [DotGothic16](https://fonts.google.com/specimen/DotGothic16), with DePixel as an alternative. Install the relevant font in Windows before selecting those themes.

For customization, copy a theme from `addons/balloon/themes/<theme>` to `config/addons/balloon/themes/<your-theme>`, edit its XML or images, then use `/balloon theme <your-theme>`. Upstream bold/italic support and Window Style 5 themes are included.

## Troubleshooting

- **Chat returns after Escape or `/`:** expected recovery behavior. Use `/balloon cinematic on` to resume hiding in the same event.
- **Only hides once:** confirm this fork's current version is loaded. Reload once after replacing addon files; subsequent `on` commands should not need a reload.
- **Nothing hides:** mode 0, an unavailable advance helper, a missing balloon, native typing or a choice menu can keep UI visible. Check `/balloon status`.
- **Cinematic preference is on but UI is suspended:** run `/balloon cinematic on` explicitly.
- **No balloon after an update:** check that the ZIP contains `balloon/gdifonts/include.lua` and that files were not extracted into a second nested `balloon` folder.
- **Unable to type commands:** Escape or `/` restores native UI in this fork. You can also use the Ashita sidebar's Addons panel to unload/reload Balloon if native chat is unavailable.

For issue reports, include addon/Ashita versions, client type, the affected NPC/cutscene and `/balloon status` output when possible. Reports belong in [this fork's issue tracker](https://github.com/randoomdude/ffxi-balloon-ashitav4openai/issues).

## Development and validation

See [CONTRIBUTING.md](CONTRIBUTING.md) for source setup, regression checks and release packaging. The checks mock native game interfaces and do not constitute complete in-game verification.

## Credits and license

Original Balloon by Hando, with modifications by Kenshi, Yuki and Ghosty; Ashita v4 port by onimitch. This fork retains the upstream license, themes, portraits and contributor credits. See [CREDITS.md](CREDITS.md) and [LICENSE](LICENSE). The gdifonts dependency is pinned to the upstream revision; its own license notices remain included.
