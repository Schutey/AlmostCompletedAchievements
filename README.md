# Almost Completed Achievements (v1.3)

This addon highlights achievements that are nearly complete, helping you focus on the ones closest to finishing.

## Features
- Scans all achievements and shows those above a customizable completion threshold
- NEW – Reward-filter dropdown: show only achievements that grant Mounts, Pets,
  Titles, Appearances, Drake Customisations, Warband Campsite, or “Other” rewards
- NEW – Per-character Ignore list (replaces old global blacklist)
- “Ignored” tab to review or un-ignore hidden achievements
- Automatic one-time import of old blacklist on first load
- Adjustable slider (50%–100%) to filter results
- Clickable achievement buttons to open them in the default UI
- Works in both Retail and Mists of Pandaria Classic

## Usage
- Type `/aca` to open the panel at any time the achievements UI is open. Adjust the slider to change the threshold.
- Click the “X” on a row to ignore that achievement; visit the “Ignored” tab to undo.
- Use the Dropdown to filter by reward type

## Compatibility
- Retail WoW (Interface: 100105)
- MoP Classic (Interface: 50501)

## Authors
Schutey & Kagrok

## Version 1.2:
- Added achievement blacklist feature (X button)
- Added /acareset command to clear blacklist
- Improved UI and tooltips

## Version 1.3:
- Added reward-type filter dropdown (Mount, Pet, Title, Appearance, etc.)
- Replaced global blacklist with per-character ignore list + Ignored tab
- Automatic import of old blacklist on first load
- Improved row layout: icon, two-line text, reward text right-aligned
- Real-time scan progress (x / y %)
- Lower memory usage via row object pool
- Throttled scan slightly to improve stability while scanning
- Changed from global table to local namespace
