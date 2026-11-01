# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub: open the repository's **Security** tab and choose
**Report a vulnerability**. Don't open a public issue or pull request for a vulnerability before it's fixed.

Include what you found, the steps to reproduce it, and the TV model and Android version if a TV is involved. You
should get a first answer within a week. Once a fix ships, the advisory is published with credit to you, unless you'd
rather stay anonymous.

## Supported versions

Only the latest release of the iPhone app and of the TV Home launcher get security fixes.

## What's in scope

- The iPhone app (`ios/`): pairing and the remote connection, the guided setup over network debugging, restoring
  from recovery records, and the TV Home editor.
- The TV Home launcher (`tv-launcher/launcher`), in particular the phone editor link and its listener.
- The scripts and tools in this repository, and the CI workflows.

Out of scope: the Android TV Remote protocol itself, Android or TV firmware, and apps this project disables or
leaves alone.

## How the project handles keys and data

- Each iPhone creates its own keys for the remote and for network debugging. They stay in that iPhone's Keychain and
  never leave it. After pairing, the app only talks to the TV whose certificate it saved.
- The phone editor uses a new random key for every visit, sent through the already paired remote connection. Its
  traffic is encrypted and authenticated, and the TV only listens for a short time.
- Network debugging is only needed during setup or a restore. The app shows how to turn it off afterwards and can
  check that it's off.
- Never commit private keys, keystores, the ADB key, recovery records, provisioning profiles or build products. The
  `.gitignore` excludes them; please keep it that way in pull requests.
