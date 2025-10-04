# Almost Completed Achievements (v1.3.5)

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


## Version 1.3.5
Scannig Logic:
- Single-scan guard: addon now scans once per session and keeps results in RAM; repeated tab-switches or filter changes only re-filter the cached list instead of re-scanning.
- Scan is only re-triggered when user clicks Refresh, threshold slider changes, ignore list is modified.
- Prevents overlapping scans

Performance / UX:
- Reward-dropdown changes are instant (no wipe, no scan).
- Old achievement rows are cleared before populating a new set (no ghost entries while updating).
- Removed redundant ACA_Cache file-cache hits for the main list; in-memory table is used unless threshold changes.

Options tab:
- Threshold slider moved from main panel into dedicated Options tab.
- Includes inline help text explaining the setting.
- Open for expansion

Scan progress bar:
- Replaced the old threshold slider slot with a visual progress bar that fills during scans.
- Shows real-time numbers: Scanned / Total (%).
- Bar fill colour updated to emerald green (0, 0.8, 0.2, 1) to match the achievement-panel theme; background remains dark-grey 60 % alpha.
- Automatically returns to “Idle” when scan finishes.

Performance / UX:
- Changed parse perameters to smooth out scanning permance hit.
- Replaced the old threshold slider slot with a visual progress bar that fills during scans.
- Shows real-time numbers: Scanned / Total (%).
- Bar fill colour updated to emerald green (0, 0.8, 0.2, 1) to match the achievement-panel theme; background remains dark-grey 60 % alpha.
- Automatically returns to “Idle” when scan finishes.

