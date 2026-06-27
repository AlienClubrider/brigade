# WezTerm Lua Config

Add this to your existing `~/.config/wezterm/wezterm.lua` (or `~/.wezterm.lua`). It colors brigade tabs based on the `⏳`/`🔴`/`✅` prefix that line cooks write, turning your tab bar into a live fleet dashboard.

```lua
-- Brigade tab color coding
-- Line cooks rename their tab with:
--   wezterm cli set-tab-title --pane-id "$WEZTERM_PANE" "⏳ brigade-<id>"
wezterm.on('format-tab-title', function(tab, tabs, panes, config, hover, max_width)
  local title = tab.active_pane.title
  if title:find('^⏳') then
    -- Working — orange
    return {
      { Background = { Color = '#c94f1a' } },
      { Foreground = { Color = '#ffffff' } },
      { Text = ' ' .. title .. ' ' },
    }
  elseif title:find('^🔴') then
    -- Needs input — red
    return {
      { Background = { Color = '#8b2020' } },
      { Foreground = { Color = '#ffffff' } },
      { Text = ' ' .. title .. ' ' },
    }
  elseif title:find('^✅') then
    -- Done — green
    return {
      { Background = { Color = '#2d7a4f' } },
      { Foreground = { Color = '#ffffff' } },
      { Text = ' ' .. title .. ' ' },
    }
  end
  return title
end)
```

## Optional: macOS notifications on status change

Add this if you want a system notification when a line cook finishes or needs input:

```lua
wezterm.on('format-tab-title', function(tab, tabs, panes, config, hover, max_width)
  local title = tab.active_pane.title
  -- Detect state transitions (fires every render, so guard with a flag if needed)
  if title:find('^✅') then
    -- On macOS: osascript fires a native notification
    wezterm.background_child_process({
      'osascript', '-e',
      'display notification "Line cook is on the pass" with title "Brigade" subtitle "' .. title .. '"'
    })
  elseif title:find('^🔴') then
    wezterm.background_child_process({
      'osascript', '-e',
      'display notification "Line cook needs input" with title "Brigade" subtitle "' .. title .. '"'
    })
  end
  -- ... rest of color coding as above
end)
```

## Verification

After adding the snippet and reloading WezTerm config (`Ctrl+Shift+R`):

- [ ] Fire a ticket — a new tab opens titled `⏳ brigade-<id>` with an orange background
- [ ] When the cook is done — tab title becomes `✅ brigade-<id>` with a green background
- [ ] When the cook needs input — tab title becomes `🔴 brigade-<id>` with a red background
- [ ] The main brigade tab stays its default color (no `⏳`/`🔴`/`✅` prefix)
