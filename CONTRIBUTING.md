# Contributing to Arcane Portal

Everyone is welcome: bug reports, game results, translations, documentation and code. You do not need to ask
before opening an issue or a pull request.

## Ways to help

- **Report a bug** with the [bug form](https://github.com/akinware/arcane-portal/issues/new?template=bug_report.yml).
- **Report how a Windows game runs** with the [game report form](https://github.com/akinware/arcane-portal/issues/new?template=game_report.yml):
  game, Mac, macOS, how it was installed (Arcane Portal, CrossOver, Mac Steam with NotProton), renderer, result.
  Per-game recipes live in [GamePort](https://github.com/akinware/gameport); reports here help decide them.
- **Suggest a feature** with the [feature form](https://github.com/akinware/arcane-portal/issues/new?template=feature_request.yml).
  Start from the problem it solves.
- **Improve a translation** (see [Interface translations](#interface-translations)).
- **Pick an issue** labelled `good first issue` or `help wanted`, or open a pull request for something you need.
- **Questions and ideas** go to [Discussions](https://github.com/akinware/arcane-portal/discussions).

## Where code goes

| Change | Repository |
|---|---|
| The app: library, Spotlight, settings, Steam for Mac, porting, how Windows games appear and start | this repository |
| Windows engine, Wine prefixes, recipes, Lab, CrossOver and NotProton detection, storage moves | [akinware/gameport](https://github.com/akinware/gameport) (GamePortKit) |

`Package.swift` uses a `gameport` checkout next to this one when there is one, so a change that spans both can be
built and tested together:

~~~sh
git clone https://github.com/<you>/arcane-portal.git
git clone https://github.com/<you>/gameport.git
cd arcane-portal
~~~

Open one pull request in each repository and link them.

## Pull requests

1. Fork, then create a branch named after the change (`storage-move-progress`, `fix-crossover-detection`).
2. Keep a pull request to one change. Read [AGENTS.md](AGENTS.md), [architecture](docs/how-it-works/architecture.md)
   and [conventions](docs/working-on-it/conventions.md) first: new code follows an existing recipe there.
3. Update the documents the change touches in the same pull request (`docs/working-on-it/file-map.md`, the area's
   document, `CHANGELOG.md` under **Unreleased**).
4. Run the checks:

   ~~~sh
   python3 scripts/check_publication.py
   python3 scripts/check_localizations.py
   python3 -m unittest discover -s Tests/PublicationChecks
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
   bash scripts/build_app.sh
   codesign --verify --deep --strict "$HOME/Applications/Arcane Portal Dev.app"
   ~~~

5. Say in the pull request what you checked by hand in the app (and with which game, engine and renderer).
   Compilation alone does not verify a game. The **Checks** workflow runs the same checks on every pull request.

A maintainer reviews every pull request. Changes to behaviour are merged after a manual check in the app.

## Rules that keep the project open

- **Licences.** Contributions to this repository are under the MIT licence (`LICENSE`). Contributions to
  GamePortKit follow that repository's `CONTRIBUTING.md` (PolyForm Noncommercial 1.0.0). By opening a pull
  request you confirm you wrote the change or have the right to submit it under that licence.
- **No copied GPL code** and no code from closed-source tools. Wine, CrossOver, NotProton, Steam and other tools
  are used as separate programs, never linked or bundled. Never bundle Apple's D3DMetal or the Windows Steam client.
- **No anti-cheat workarounds or bypasses.** Anti-cheat information is shown to players, nothing more.
- **No game content.** Do not include games, keys, firmware, extracted content, personal configuration or raw
  diagnostics. Tests use synthetic fixtures. Review copied diagnostics and remove anything personal.
- **English** for code, comments, UI source strings and commit messages.
- Keep Play working for games that are already installed; never patch the user's nxnative checkout, silently
  follow upstream `main` or bypass the compatibility gate. Engine upgrades use the
  [upgrade checklist](docs/history/engine-upgrades/README.md).

## Releases

Releases are built with `scripts/release.sh` and published by a maintainer. The workflow only checks code and never
publishes anything. Record user-visible changes under **Unreleased** in [CHANGELOG.md](CHANGELOG.md); entries move
into a dated version when that release is published.

## Interface translations

The shared source is `Sources/NXLibraryCore/Resources/Localizable.xcstrings`. It includes en, it, fr, de, es, pt-BR and zh-Hans. Keep keys stable, preserve every typed placeholder, provide quantity variants, and leave product names (Arcane Portal, GamePort, Steam, CrossOver, NotProton), technical identifiers and user-provided content unchanged. Record the language and whether a fluent speaker reviewed the change.

Run `python3 scripts/check_localizations.py` and the publication regressions after editing the catalog. A development build also checks its compiled resources. New languages are welcome; no external translation service is needed.

## Security

Read [SECURITY.md](SECURITY.md) and report vulnerabilities privately, never in a public issue.
