# Proton VPN for Omarchy

A bar widget for the Omarchy shell that wraps the official `protonvpn` CLI, so
you don't have to open a terminal to connect, switch countries or change settings.

- **Bar icon**: lit when connected, dim when not, pulses while connecting.
  The tooltip shows the server.
  Left-click opens the panel, right-click connects or disconnects, middle-click refreshes.
- **Panel**:
  - an on/off switch, with the city, server, load and protocol shown when connected
  - quick connect: Fastest, Random, P2P, Secure Core
  - your five most recent countries
  - country search: type any letter or `/`, then press Enter to connect to the top match
  - settings: NetShield, kill switch, VPN Accelerator, port forwarding, Moderate NAT, IPv6
- **Keyboard**: arrows or `hjkl` to move, Enter or Space to activate.
  Left and right cycle NetShield or flip toggles.
  Esc closes the panel.

## Requirements

- `protonvpn` CLI (1.0.x), already signed in (`protonvpn signin`).
  If you are signed out, the panel offers a button that opens a terminal to sign in.
- `nmcli` (NetworkManager), used for the cheap bar-icon poll
- `python3`

## Install

```bash
omarchy plugin add https://github.com/robinmarin/vpn-plugin.git --enable
```

Or, for development, symlink the checkout:

```bash
ln -s "$PWD" ~/.config/omarchy/plugins/badger.protonvpn
omarchy-shell shell rescanPlugins
omarchy plugin enable badger.protonvpn
```

## Settings

| Key | Default | Meaning |
|-----|---------|---------|
| `pollIntervalSec` | `5` | How often the bar icon checks NetworkManager |
| `quickConnectCountry` | `""` | Country code used by the switch and right-click. Leave empty to use the fastest server |

## IPC

```bash
omarchy-shell badger.protonvpn toggle        # open or close the panel
omarchy-shell badger.protonvpn connect SE    # connect to a country ("" = quick connect)
omarchy-shell badger.protonvpn disconnect
omarchy-shell badger.protonvpn toggleVpn
omarchy-shell badger.protonvpn status        # "connected SE#183" / "disconnected"
```

These are handy for Hyprland keybindings.

## How it works

`protonvpn-ctl` runs the CLI and parses its tables into JSON (`state`,
`countries`, `connect`, `disconnect`, `set`).
It caches the country list in `~/.cache/omarchy-protonvpn/`
and keeps recent countries in `~/.local/state/omarchy-protonvpn/`.
The bar icon only polls `nmcli`; the slower Python CLI runs when you open
the panel or when the connection changes.

## License

MIT
