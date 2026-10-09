# Contributing

Use an issue or pull request in this repository for changes specific to this fork. Include the client type, Ashita version, addon version, other UI addons and the dialogue or cutscene that reproduces the problem. Do not include account credentials or API keys.

## Development setup

```text
git clone --recurse-submodules https://github.com/randoomdude/ffxi-balloon-ashitav4openai.git
cd ffxi-balloon-ashitav4openai
python -m pip install -r requirements-test.txt
python tests/test_cinematic.py
python tools/package_release.py
```

The regression suite uses LuaJIT through Lupa and mocks the game/UI interfaces. It checks the delivered handlers and cinematic state transitions. It does not connect to FFXI or confirm native memory behavior.

For live verification, test a dialogue with multiple pages, a choice menu, Escape recovery, slash command entry, repeated `/balloon cinematic on` calls during one event, event exit and an addon unload. Keep user settings intact when updating an installation.

## Releases

Update `addon.version` in `Balloon.lua` and add matching change and release notes. The release workflow runs checks and packages the pinned gdifonts submodule. It publishes a new pre-release when a version does not already have a GitHub release; existing release assets are not overwritten. Run the workflow manually when a release needs to be retried.
