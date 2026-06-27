# The Expeditor

The Expeditor is the fleet view between you and the kitchen. In the WezTerm model it requires no extra tools — the tab bar IS the dashboard.

## Tab state colors

Add the `format-tab-title` event handler from `docs/wezterm-lua.md` to your WezTerm config. Once added, your tab bar colors brigade tabs automatically based on the prefix line cooks write:

| Tab title prefix | Color | Meaning |
|---|---|---|
| `⏳ brigade-<id>` | Orange | Working — line cook mid-turn |
| `🔴 brigade-<id>` | Red | In the weeds — needs your input |
| `✅ brigade-<id>` | Green | On the pass — done, awaiting review |

Line cooks update their own tab with:
```bash
wezterm cli set-tab-title --pane-id "$WEZTERM_PANE" "✅ brigade-<id>"
```

`$WEZTERM_PANE` is set automatically by WezTerm in every pane's environment.

## Optional: system notifications

See `docs/wezterm-lua.md` for a Lua snippet that fires a macOS notification when a tab flips to `✅` or `🔴`.

## Verification checklist

After adding the WezTerm config snippet:

- [ ] Firing a ticket opens a new `⏳ brigade-<id>` tab with an orange background
- [ ] When a line cook finishes, the tab flips to `✅ brigade-<id>` (green)
- [ ] When a cook needs input, the tab flips to `🔴 brigade-<id>` (red)
- [ ] `brigade-teardown.sh <id>` closes the tab and it disappears from the tab bar
