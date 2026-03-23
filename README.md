# swm — Simple Window Manager

A lightweight macOS command-line window manager for multi-display setups. Designed to be triggered via [Karabiner-Elements](https://karabiner-elements.pqrs.org/) hotkeys.

## Features

- **Cycle windows on primary display** — Brings the bottom-most window to the front. Repeat to keep cycling through your window stack.
- **Cycle windows on secondary display** — Same behavior for your secondary monitor.
- **Swap foremost windows** — Swaps the top window on each display to the other. Maintains relative positioning: full-screen windows stay full-screen on the target display, and windowed positions are scaled proportionally.
- **Push to secondary** — Moves the foremost window on the primary display to the secondary, then raises the next window on primary.
- **Pull to primary** — Moves the foremost window on the secondary display to the primary and raises it.
- **Toggle fill/center** — Toggles the foremost window between filling the screen and a centered layout (60% width, 75% height).
- **Hotkey cheat sheet** — Shows a floating overlay listing all Karabiner Hyper key shortcuts. Dismisses on any keypress.

## Requirements

- macOS 13 (Ventura) or later
- Swift 6.2+
- **Accessibility permissions** — The tool will prompt you to grant access on first run. Enable it in **System Settings > Privacy & Security > Accessibility**.

## Building

```bash
./build.sh
```

This builds a release binary and installs it to `~/bin/swm`.

To build manually:

```bash
swift build -c release
cp .build/release/swm ~/bin/swm
```

## Usage

```
SUBCOMMANDS:
  cycle-primary       Cycle windows on the primary display
  cycle-secondary     Cycle windows on the secondary display
  swap                Swap the foremost windows between primary and secondary displays
  push                Push the foremost window on the primary display to the secondary display
  pull                Pull the foremost window on the secondary display to the primary display
  toggle              Toggle the foremost window between filling the screen and a centered size
  keys                Show a floating overlay of all Karabiner Hyper key shortcuts
```

### Examples

```bash
# Cycle through windows on the primary display
swm cycle-primary

# Cycle through windows on the secondary display
swm cycle-secondary

# Swap the top window on each display
swm swap

# Push the foremost primary window to secondary (raises next primary window)
swm push

# Pull the foremost secondary window to primary
swm pull

# Toggle foremost window between fill and centered
swm toggle

# Show hotkey cheat sheet (press any key to dismiss)
swm keys
```

## Karabiner-Elements Integration

swm is designed to be triggered by hotkeys. Below are example Karabiner-Elements rules using a [Hyper key](https://karabiner-elements.pqrs.org/docs/json/typical-complex-modifications-examples/#change-caps_lock-to-commandcontroloptionshift) (Caps Lock remapped to Cmd+Ctrl+Opt+Shift).

### Hyper key setup

First, remap Caps Lock to Hyper. Add this rule to your `karabiner.json`:

```json
{
  "description": "Caps Lock → Hyper (Cmd+Ctrl+Opt+Shift)",
  "manipulators": [
    {
      "type": "basic",
      "from": {
        "key_code": "caps_lock",
        "modifiers": { "optional": ["any"] }
      },
      "to": [
        {
          "key_code": "left_shift",
          "modifiers": ["left_command", "left_control", "left_option"]
        }
      ]
    }
  ]
}
```

### Window management hotkeys

Then add rules for each swm command. These go inside the `"rules"` array in your Karabiner profile's `"complex_modifications"`:

```json
{
  "description": "Hyper+1: Cycle windows on primary display",
  "manipulators": [
    {
      "type": "basic",
      "from": {
        "key_code": "1",
        "modifiers": { "mandatory": ["command", "control", "option", "shift"] }
      },
      "to": [{ "shell_command": "~/bin/swm cycle-primary" }]
    }
  ]
},
{
  "description": "Hyper+2: Cycle windows on secondary display",
  "manipulators": [
    {
      "type": "basic",
      "from": {
        "key_code": "2",
        "modifiers": { "mandatory": ["command", "control", "option", "shift"] }
      },
      "to": [{ "shell_command": "~/bin/swm cycle-secondary" }]
    }
  ]
},
{
  "description": "Hyper+3: Swap foremost windows between displays",
  "manipulators": [
    {
      "type": "basic",
      "from": {
        "key_code": "3",
        "modifiers": { "mandatory": ["command", "control", "option", "shift"] }
      },
      "to": [{ "shell_command": "~/bin/swm swap" }]
    }
  ]
},
{
  "description": "Hyper+W: Push foremost window to secondary display",
  "manipulators": [
    {
      "type": "basic",
      "from": {
        "key_code": "w",
        "modifiers": { "mandatory": ["command", "control", "option", "shift"] }
      },
      "to": [{ "shell_command": "~/bin/swm push" }]
    }
  ]
},
{
  "description": "Hyper+R: Pull foremost window from secondary to primary",
  "manipulators": [
    {
      "type": "basic",
      "from": {
        "key_code": "r",
        "modifiers": { "mandatory": ["command", "control", "option", "shift"] }
      },
      "to": [{ "shell_command": "~/bin/swm pull" }]
    }
  ]
},
{
  "description": "Hyper+F: Toggle window between fill and centered",
  "manipulators": [
    {
      "type": "basic",
      "from": {
        "key_code": "f",
        "modifiers": { "mandatory": ["command", "control", "option", "shift"] }
      },
      "to": [{ "shell_command": "~/bin/swm toggle" }]
    }
  ]
},
{
  "description": "Hyper+/: Show hotkey cheat sheet",
  "manipulators": [
    {
      "type": "basic",
      "from": {
        "key_code": "slash",
        "modifiers": { "mandatory": ["command", "control", "option", "shift"] }
      },
      "to": [{ "shell_command": "~/bin/swm keys &" }]
    }
  ]
}
```

## How It Works

- Uses `CGWindowListCopyWindowInfo` to enumerate visible windows and determine their screen placement.
- Uses the macOS Accessibility API (`AXUIElement`) to raise, move, and resize windows.
- When moving windows between displays with different resolutions, margins are preserved as proportions of the screen size — a full-screen window stays full-screen, a half-width window stays half-width.
- Windows are moved to the destination screen before resizing, so apps can accept the full size of the new display.
- Handles Electron/Chromium apps (Edge, Teams, VS Code) that have mismatched CG and AX window representations.

## License

[MIT](LICENSE)
