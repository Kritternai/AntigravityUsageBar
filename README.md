# AntigravityUsageBar

> Track your Google Antigravity model quotas, reset countdowns, and local token telemetry right from your Mac menu bar!

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-12.0+-blue.svg)](https://www.apple.com/macos/)
[![Release](https://img.shields.io/github/v/release/Kritternai/AntigravityUsageBar)](https://github.com/Kritternai/AntigravityUsageBar/releases)

A lightweight, open-source macOS menu bar application (built with Swift & SwiftUI) that displays your **Google Antigravity** model usage limits, reset times, plan credits, and local token telemetry in real time.

> 💡 **Inspiration**: This project is directly inspired by [**Kritternai/ClaudeUsageBar**](https://github.com/Kritternai/ClaudeUsageBar) (and [Artzainnn/ClaudeUsageBar](https://github.com/Artzainnn/ClaudeUsageBar)), adapted and re-architected natively for Google Antigravity's local language server and telemetry architecture.

---

## 📥 Download

**[Download Latest Release (`AntigravityUsageBar-Installer.dmg`)](https://github.com/Kritternai/AntigravityUsageBar/releases/latest)**

1. Download `AntigravityUsageBar-Installer.dmg` from [Releases](https://github.com/Kritternai/AntigravityUsageBar/releases)
2. Open the DMG and drag **AntigravityUsageBar** to your **Applications** folder
3. Launch **AntigravityUsageBar** (if macOS Gatekeeper prompts, right-click → **Open** or run `xattr -cr /Applications/AntigravityUsageBar.app`)
4. **Done!** No browser cookies or manual tokens required — it connects to Antigravity automatically.

---

## ✨ Features

- 🚀 **Zero-Config Auto-Discovery** — Automatically detects your running local Antigravity `language_server` process, port, and CSRF token. No manual cookie copying needed!
- 📊 **Real-Time Model Quotas** — Tracks remaining quota and reset countdowns across all Antigravity models:
  - **Gemini 4 Argon** (Low / Medium / High)
  - **Gemini 3.8 Flash** (Low / Medium / High)
  - **Claude Sonnet 5.5** (Low / Medium / High)
  - **Claude Opus 5.5** (Low / Medium / High)
  - **GPT-OSS 120B**
- 🎯 **Active Model Highlight** — Reads your active model from `~/.gemini/antigravity/antigravity_state.pbtxt` and highlights it with an `ACTIVE` badge.
- 🧮 **Local Token Telemetry** — Scans `~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl` to display **Today** and **All-Time** input, output, and cache-read token usage.
- 💳 **Plan & Credit Tracking** — Displays your current tier (`Google AI Pro` / `Ultra`) alongside available **Prompt Credits** and **Flow Credits**.
- 🎨 **Color-Coded Menu Bar Icon** — Visual spark icon that changes color based on quota usage (`Green < 70%`, `Yellow 70–90%`, `Red > 90%`). Choose whether the menu bar shows `Active`, `Highest`, `Gemini`, or `Claude` usage.
- ⏱️ **Pace Marker** — Optional tick mark on each progress bar showing where usage *should* sit based on elapsed time in the 5-hour or 7-day reset window.
- 🔔 **Smart Notifications** — Alerts at 25%, 50%, 75%, and 90% quota thresholds.
- ⌨️ **Global Keyboard Shortcut** — Toggle the popup from anywhere with `Cmd+Shift+U` (`⌘⇧U`).
- 🔒 **100% Local & Private** — Communicates strictly with `127.0.0.1` and local `~/.gemini` files. Zero external network requests or analytics.

---

## 🖥️ Preview

**Menu Bar Display:**
```
✦ 4%   (Green icon when quota usage < 70%)
```

**Popup Interface:**
- **Header**: Tier badge (`Google AI Pro`), account email, and live connection indicator
- **Model Quotas**: Grouped by model family or expanded across all tiers (`Low` / `Medium` / `High`), with progress bars and reset countdowns
- **Credits**: Available Prompt Credits & Flow Credits
- **Local Token Telemetry**: Today vs. All-Time token breakdown (`In`, `Out`, `Cache`)
- **Settings**: Menu bar metric selector, Open at Login, Notifications, Pace Marker, Reset time format, and Appearance (`System` / `Dark` / `Light`)

---

## 🛠️ Build from Source

**Requirements:**
- macOS 12.0 (Monterey) or later
- Xcode Command Line Tools (`xcode-select --install`)

**Build and launch the app:**
```bash
cd app
chmod +x build.sh
./build.sh
```
The compiled universal binary (`arm64` + `x86_64`) will be generated at `app/build/AntigravityUsageBar.app`.

**Create DMG installer:**
```bash
cd app
chmod +x create_dmg.sh
./create_dmg.sh
```

---

## 📁 Repository Structure

```
app/
├── AntigravityUsageBar.swift     # Main application code (SwiftUI + AppKit)
├── Info.plist                    # App bundle configuration (LSUIElement)
├── build.sh                      # Universal binary build script
├── create_dmg.sh                 # DMG installer creation script
├── make_app_icon.sh              # App icon (.icns) generator
├── AntigravityUsageBar.icns      # Generated macOS app icon
└── antigravityusagebar-icon.png  # Source icon PNG
```

---

## 🤝 Contributing

Contributions, issues, and feature requests are welcome!
1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'feat: add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## 🙏 Acknowledgments & Inspiration

- Inspired by [**Kritternai/ClaudeUsageBar**](https://github.com/Kritternai/ClaudeUsageBar) & [**Artzainnn/ClaudeUsageBar**](https://github.com/Artzainnn/ClaudeUsageBar) — Track your Claude.ai usage right from your Mac menu bar.

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.
