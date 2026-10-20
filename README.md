# Backchannel

An agent that listens to your Tuple calls and quietly passes you notes: metrics, tickets, customer context and answers, as cards on your screen. It runs as an [Amp](https://ampcode.com) thread per call and starts on its own.

It has three parts:

- **Backchannel.app**, a small macOS app: a live transcript that collapses to an icon and expands on hover, plus the card overlay.
- **`backchannel.py`**, a background service. When the dev, staging or production Tuple app joins a call, it starts a private Amp thread in this repo, labeled `backchannel`. It streams the transcript, muted asides, card feedback and card actions into the thread as they happen. When the call ends, it tells the thread to wrap up.
- **`AGENTS.md`**, the playbook that thread follows.

## Install

Requires macOS 26, the `tuple` CLI at `/usr/local/bin/tuple`, the Amp CLI at `/opt/homebrew/bin/amp` (signed in), and Tuple's MCP portal connected to your Amp workspace. For muted asides: `brew install whisper-cpp`.

```sh
./install
```

This builds the app if needed and installs two LaunchAgents, so both parts start at login and restart if they exit. Run `./install --remove` to stop and remove them.

Logs are in `~/Library/Logs/Backchannel`. `service.log` links each call to its Amp thread. App data (cards, feedback, asides, per-call research) is in `~/Library/Application Support/Backchannel`.

## Talking to it while muted

While you're muted in Tuple, the app transcribes your mic on-device with Whisper, using the model Tuple already downloads, and sends what you say to the agent. The call never hears it. The transcript icon's dot turns purple while this is on. The first time, macOS asks for microphone access.

## Cards

The card format is in `AGENTS.md`. The top of the screen is shared and the bottom is private. Your own cards show bottom right, advisories bottom left, cards the agents on the call agreed to show everyone in gold at the top right, and rare warnings top center until acknowledged. The newest three at each level show at once and fade after 20 seconds (hovering pauses the countdown). Older ones collapse into a stack you can click through. Every card stays in the transcript as research; 👍/👎 go back to the agent.

| Keys | What it does |
|---|---|
| ⌃⌥⌘↩ | Opens the newest card on screen (warnings first). Press it again to close that card. With nothing on screen, brings back the newest earlier card. |
| ⌃⌥⌘⎋ | Closes the newest card on screen, acknowledging a warning first. |
| ⌘↩ / Esc | The same, once you've clicked a card. |
