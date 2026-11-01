# Setup prompt

Open Claude Code or Codex in the folder where you want the app, then paste everything in the box below. To update later, paste it again in the same folder; your saved layout stays.

```text
Install Amber Terminal on this computer for me. It's a Bloomberg-style market terminal that runs locally: you type a ticker and a function code, press Enter, and get the screen, four at a time. It has world indices, news, company descriptions, financials, SEC filings, insider trades, holders, options chains, yield curves, money markets, the Fed rate path priced by futures, economic data and calendars, central bank rates, positioning, commodities, currencies, crypto, charts and a backtester with quant checks. Every number comes from a public source that needs no account and no API key. It downloads from GitHub: https://github.com/HandsomeWJ/amber-terminal. It needs Node.js 18 or newer and nothing else: no API keys, no accounts, no npm install. It's not affiliated with Bloomberg.

HOW TO WORK WITH ME
- Talk to me like a friendly, patient helper. Assume I've never done this before. Use short sentences and everyday words, no jargon. If you have to use a technical word like "terminal" or "Node.js", explain it in a few plain words the first time.
- Keep each update to a line or two. Tell me what's happening and what it means for me, not the technical detail.
- Before each step, tell me in one short line what you're about to do. Show where we are as "Step 2 of 5".
- Run every command yourself. Only hand me a command if it needs my password or admin rights.
- If a command fails, read the error, fix the cause and run it again. Try up to three fixes per step, then tell me in plain words what's wrong and what you tried.
- This needs internet access: github.com and codeload.github.com for the download; nodejs.org (or Homebrew's or nvm's servers) only if Node.js is missing; and the public data sites the app reads (SEC, Nasdaq, Yahoo, CBOE, the US Treasury and Fed, FRED, CFTC, ECB, BIS, Binance, Coinbase, Kraken and a few news feeds). If your sandbox blocks network access, ask me to approve it.
- The app's own scripts (every `node scripts/...` command) also use this computer's local network ports, and anything started inside a sandbox keeps the sandbox's limits after this chat ends. So if your commands run in a sandbox, run those scripts outside it only with my approval, or hand them to me one at a time, each starting with a cd into the amber-terminal folder (in Claude Code I type ! followed by the command).
- If a safety check blocks you from downloading or running these files (for example Claude Code's auto mode), don't try to change your own permission settings. Tell me in one line, then give me one command at a time to run myself (in Claude Code I type ! followed by the command). If what it blocked was a `node scripts/...` command, tell me at the end I can skip that next time by allowing `Bash(node scripts/*)` for this folder (/permissions in Claude Code).
- Never ask me for passwords, API keys, exchange keys or broker logins. Nothing here needs them.
- Don't use sudo or admin rights yourself, and don't install anything except Node.js, and only after I say yes.
- Don't change the app's code during the install unless a check fails and the fix is clearly in the code.
- If you can't ask me questions (for example you're running non-interactively), use the defaults and keep going.

STEP 1 OF 5: CHECK THIS COMPUTER
Work out the operating system and shell (macOS, Linux, or Windows with PowerShell, cmd or Git Bash). Run `node -v`.
- 18 or newer: carry on.
- Missing or older: tell me, offer the simplest install for my system, and wait for my yes:
  - macOS: `brew install node` if Homebrew is installed. Otherwise the LTS installer from https://nodejs.org, which asks for my Mac password, so I run it myself.
  - Windows: `winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements`. Windows may ask me to approve an admin prompt; that's fine. The new node isn't on this terminal's PATH yet, so call it by its full path: `& "C:\Program Files\nodejs\node.exe"` in PowerShell, `"C:\Program Files\nodejs\node.exe"` in cmd, `"/c/Program Files/nodejs/node.exe"` in Git Bash.
  - Linux: the distribution's package if it's 18 or newer (it needs sudo, so hand me that command), otherwise nvm (https://github.com/nvm-sh/nvm), which doesn't. After nvm, start each node command with `. ~/.nvm/nvm.sh && `.
  Then run `node -v` again to confirm, and use that same node for every node command below, including any you hand me.

STEP 2 OF 5: DOWNLOAD
Install into a folder called amber-terminal inside the folder you're running in now. The commands below create that folder and unpack the app straight into it.
- If the folder you're running in is the app itself (it has server.js and scripts/stop.js), you were opened inside it: go up one folder (cd ..) and carry on from there. If the app's folder has a different name, use that name wherever the commands say amber-terminal.
- If ./amber-terminal already has server.js in it, this is an update. Run `node scripts/stop.js` inside it first, then run the commands below from the folder above it. They replace the app's own files and leave the data folder alone: that's my saved layout, and the download never contains one.
- If ./amber-terminal exists, has no server.js and isn't empty, ask me before using it.
- macOS, Linux or Git Bash:
    mkdir -p amber-terminal && curl -fsSL -o amber-terminal.tar.gz https://github.com/HandsomeWJ/amber-terminal/archive/refs/heads/main.tar.gz && tar -xzf amber-terminal.tar.gz --strip-components=1 -C amber-terminal && rm amber-terminal.tar.gz
  If curl is missing (Ubuntu Desktop has wget instead), use `wget -qO amber-terminal.tar.gz <the same address>` in place of the curl part. Don't install curl.
- Windows PowerShell:
    New-Item -ItemType Directory -Force amber-terminal | Out-Null
    Remove-Item "$env:TEMP\amber-terminal.zip" -ErrorAction SilentlyContinue
    curl.exe -fsSL -o "$env:TEMP\amber-terminal.zip" https://github.com/HandsomeWJ/amber-terminal/archive/refs/heads/main.zip
    if ($LASTEXITCODE -eq 0) { & "$env:SystemRoot\System32\tar.exe" -xf "$env:TEMP\amber-terminal.zip" --strip-components=1 -C amber-terminal; Remove-Item "$env:TEMP\amber-terminal.zip" }
- Windows cmd:
    if not exist amber-terminal mkdir amber-terminal
    del "%TEMP%\amber-terminal.zip" 2>nul
    curl.exe -fsSL -o "%TEMP%\amber-terminal.zip" https://github.com/HandsomeWJ/amber-terminal/archive/refs/heads/main.zip && "%SystemRoot%\System32\tar.exe" -xf "%TEMP%\amber-terminal.zip" --strip-components=1 -C amber-terminal && del "%TEMP%\amber-terminal.zip"
- On Windows, call Windows' own tar.exe by its full path as shown: it reads zip files, and the tar that comes with Git doesn't. Windows 10 (version 1803 or later) and 11 come with curl.exe and tar.exe.
- In Windows PowerShell 5, chain commands with ; not &&, and `curl` means Invoke-WebRequest (use curl.exe for real curl).
- You now have an amber-terminal folder. Check it has server.js and package.json, and run every command below from inside it.

STEP 3 OF 5: TEST IT
Run `node scripts/check.js`. It runs the offline tests, checks which public data sources this connection can reach, starts the app briefly and loads live data, then prints READY or NOT READY.
- READY: tell me in one line which sources work, for example "markets, rates, filings and options all reachable". If a source is blocked or busy, say in one line which screens it affects and that the rest work.
- NOT READY: read the FAIL lines, fix the cause and run it again.
- Use `node scripts/...` rather than `npm run ...` throughout. On Windows, PowerShell's execution policy can block npm; node works everywhere.

STEP 4 OF 5: MAKE IT MINE
If this was an update, skip this step: my layout is already saved. Go straight to step 5.
Ask me: "What do you mostly follow: US stocks, crypto, currencies, rates and futures, or a mix?" If I name a stock or coin I care about, use it as the ticker.
Then run one of these (stocks, crypto, fx, macro or mix; mix if I don't answer):
node scripts/setup.js --profile <stocks|crypto|fx|macro|mix> [--ticker <the stock or coin I named>]
It sets the four panels for what I follow and prints them. Tell me in one line what's in each panel.

STEP 5 OF 5: OPEN IT
If this was an update, run `node scripts/stop.js` once more first, so the new version is the one that runs. Then run `node scripts/launch.js`. It starts the terminal in the background, so it keeps running after this chat ends, and opens my browser. Give me the address it prints as a link. If no browser opened, tell me to open that address myself: on WSL, in my Windows browser; on a remote server or in a container, the address only works on that machine, so tell me how to forward the port first (for example `ssh -L 3787:localhost:3787 <server>`).
Then, if you are Claude Code, ask me: "Want me to connect Claude to the terminal, so you can ask about the markets and get answers from its screens?" If I say yes, run `node scripts/mcp.js --help`, run the `claude mcp add` line it prints, and tell me it works from my next Claude Code chat: I type PLAY in the terminal, copy a playbook and paste it there. If you are another agent, tell me in one line that typing ASK in the terminal shows how to connect Claude.

Finish with one short, friendly message in plain words, covering only this:
- It's running at <address>.
- How it works: type a ticker and a function code in a panel, then press Enter. Try `WEI`, `AAPL US EQUITY DES`, `NVDA OMON`, `WIRP`, `GC`, then `SPY BTST`. Type `HELP` for every function and `DATA` to see where each screen's numbers come from.
- Next time: run `node scripts/launch.js` in the amber-terminal folder; it reuses a copy that's already running. Double-clicking start.command (Mac) or start.bat (Windows) also works, but it runs in a window you keep open, so only use it when the app isn't already running. Stop it with `node scripts/stop.js`.
- Your layout is saved in the data folder inside amber-terminal. To update the app later, paste this same prompt again in the folder we used today (the one that holds amber-terminal). It keeps your data folder, but replaces the app's own files, so any changes made to those would need doing again.
- Want a screen it doesn't have? Ask me in this chat, for example "add a function that shows the biggest insider buys this week" or "add a screen with my own watchlist and its news". New screens go in public/js/fn and lib/fn.
- What it can't do: it has no live order book, some stock and futures prices run up to 15 minutes behind, and it doesn't trade real money: it's for research and backtesting. It's Bloomberg-style, built from public data, and not affiliated with Bloomberg.
```
