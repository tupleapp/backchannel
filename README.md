# Backchannel

An agent that listens to your Tuple calls and quietly passes you notes: metrics, tickets, customer context and answers, as cards on your screen. It runs as an [Amp](https://ampcode.com) thread per call and starts on its own.

**This is a starter kit, not a product.** Your private backchannel is yours: fork it and change what it notices, how it tells you, and where it keeps notes. The split is:

- **Private cards are yours.** Your agent, your overlay, your rules. Edit `AGENTS.md` first; replace the overlay or `post-card` if you want something else.
- **Shared cards belong to the call.** When the agents on a call agree that everyone should see a card, it goes to Tuple as a native notification, not to anyone's private overlay.

It has three parts:

- **Backchannel.app**, a small macOS app: a live transcript that collapses to an icon and expands on hover, plus the card overlay.
- **`backchannel.py`**, a background service. When the dev, staging or production Tuple app joins a call, it starts a private Amp thread in this repo, labeled `backchannel`. It streams the transcript, muted asides, card feedback and card actions into the thread as they happen. When the call ends, it tells the thread to wrap up.
- **`AGENTS.md`**, the playbook that thread follows.

## Install

Requires macOS 26, the `tuple` CLI at `/usr/local/bin/tuple`, the Amp CLI at `/opt/homebrew/bin/amp` (signed in), and Tuple's MCP portal connected to your Amp workspace. For muted asides: `brew install whisper-cpp`.

```sh
./install
```

This builds the app if needed and installs two LaunchAgents, so both parts start at login and restart if they exit. It also adds a trigger to each Tuple environment's triggers folder (for example `~/.tuple/triggers/backchannel`), so Tuple wakes the service as soon as a call connects or ends. Turn triggers on once in Tuple's Settings → Triggers. Without them, the service checks for calls every 5 seconds instead. Run `./install --remove` to stop and remove all of it.

Logs are in `~/Library/Logs/Backchannel`. `service.log` links each call to its Amp thread. App data (cards, feedback, asides, per-call research) is in `~/Library/Application Support/Backchannel`.

## Talking to it while muted

While you're muted in Tuple, the app transcribes your mic on-device with Whisper, using the model Tuple already downloads, and sends what you say to the agent. The call never hears it. The transcript icon's dot turns purple while this is on. The first time, macOS asks for microphone access.

## Cards

The card format is in `AGENTS.md`. The top of the screen is shared and the bottom is private. Your own cards show bottom right, advisories bottom left, and rare warnings top center until acknowledged. The newest three at each level show at once and fade after 20 seconds (hovering pauses the countdown). Older ones collapse into a stack you can click through. Every card stays in the transcript as research; 👍/👎 go back to the agent. Cards shared with the whole call go to Tuple instead; the overlay only shows them, in gold at the top right, if Tuple can't.

| Keys | What it does |
|---|---|
| ⌃⌥⌘↩ | Opens the newest card on screen (warnings first). Press it again to close that card. With nothing on screen, brings back the newest earlier card. |
| ⌃⌥⌘⎋ | Closes the newest card on screen, acknowledging a warning first. |
| ⌘↩ / Esc | The same, once you've clicked a card. |
