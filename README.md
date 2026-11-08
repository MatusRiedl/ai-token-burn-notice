# AI Burn Notice

A Windows tray app that shows how many tokens your [Claude Code](https://claude.com/claude-code) sessions burn, what they would cost at API prices, and how your **weekly plan budget** is holding up, split into 7 daily slots so you can pace yourself until the reset.

![Weekly usage view](assets/screenshot-week.png)

*Screenshots use synthetic demo data.*

## What you get

- **Weekly usage**: % of your weekly limit used, 7 day slots of 14.29% each, a marker for where an even pace would be right now, plus today / pace / left-until-reset cards. Resets Sunday 05:00 by default.
- **Past hour, 6 hours, 24 hours, 7 days, 30 days**: total tokens, token mix (input / output / cache write / cache read), per-model share and estimated cost.
- **Tray tooltip** with the numbers you care about, a panel that opens on click, refreshes every 5 minutes, optional start with Windows.

![24 hour view](assets/screenshot-24h.png)

## Install

Needs Windows 10/11, PowerShell 5.1 (built in) and [Node.js](https://nodejs.org).

```powershell
git clone https://github.com/<you>/ai-burn-notice
cd ai-burn-notice
powershell -ExecutionPolicy Bypass -File install.ps1 -Startup
```

That creates an **AI Burn Notice** shortcut on your desktop (double-click to start, or to open the panel if it is already running) and, with `-Startup`, a Start-with-Windows shortcut. `install.ps1 -Uninstall` removes both.

Then click **Weekly usage → Set weekly %** and type the weekly limit % shown in Claude's Settings → Usage. Do this once; update it now and then.

## How it works

- `aggregate.js` reads the session logs Claude Code already writes to `~/.claude/projects/**/*.jsonl` and sums the per-message token usage. Logs are append-only, so each run only reads new bytes. Messages are de-duplicated by message and request id.
- Cost = those tokens × the public per-token prices from the [LiteLLM price list](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json), refreshed once a day.
- `tray.ps1` is the tray icon and the panel (WinForms + GDI+, no dependencies).
- State (cache, prices, your calibration, the latest numbers, a small log) lives in `%LOCALAPPDATA%\AIBurnNotice`. Nothing leaves your machine except that daily download of the price list.

## About the weekly %

The weekly % is **an estimate**, not an official number. Your one calibration reading says "this much logged cost equals this many % of the limit"; everything else is scaled from it. Because of that:

- It only sees Claude Code usage on this PC. Chat, the web app and your phone use the same limit but are not in the logs.
- Cache reads are most of the tokens, so tokens are not a good proxy for the limit; cost is used instead.
- A reading taken at a higher % is more accurate than one taken at 3%.
- If your reset time differs, change `RESET_DAY` / `RESET_HOUR` in `aggregate.js`.
- Cost is the API-price equivalent. On a Pro/Max plan you pay a flat fee.

## Files

| File | Purpose |
| --- | --- |
| `aggregate.js` | Log parser, windows, weekly buckets, calibration |
| `tray.ps1` | Tray icon and panel |
| `flame.ps1`, `make-icon.ps1`, `assets/flame.ico` | The flame mark and the icon generator |
| `start.vbs` | Launches the tray without a console window |
| `install.ps1` | Creates / removes the shortcuts |

Set `BURN_NOTICE_DATA` to keep the state somewhere else.

## Disclaimer

AI Burn Notice is an independent, unofficial hobby project. It is not affiliated with, endorsed by or sponsored by Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic. The tool only reads local log files on your own machine, and its numbers are estimates.

## License

[MIT](LICENSE)
