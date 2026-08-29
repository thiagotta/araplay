# Contributing to AraPlay

## Setup

You need Xcode 16+ (26 recommended) and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
git clone https://github.com/thiagotta/araplay.git
cd araplay
xcodegen generate
open AraPlay.xcodeproj
```

`project.yml` is the source of truth — **edit it, never the `.xcodeproj`**,
which is generated and not checked in. Re-run `xcodegen generate` after
changing it.

## Workflow

`main` is protected: it only moves through pull requests, and a PR only
merges when CI is green. The loop:

```bash
git switch main && git pull        # always start from the latest main
git switch -c short-topic-name     # one branch per change
# ...edit, build, run the tests...
git add -A && git commit -m "What changed and why"
git push -u origin short-topic-name
gh pr create --fill                # or use the button GitHub shows
```

CI (build + all tests, on an Apple Silicon runner) runs on the PR
automatically. When it's green, merge — merges are **squash-only**, so the
PR title becomes the commit on `main`; make it a good one. The branch is
deleted automatically after merging; then everyone syncs with
`git switch main && git pull`.

Enforced by repo rules, so there are no surprises: no direct pushes to
`main`, no force-pushes, required check is `Build & test (Apple Silicon)`.
Review approval is not required — but for anything non-trivial, ask for one
anyway.

## Expectations

- **Keep PRs small** — one topic per branch. Small PRs review quickly and
  rarely conflict.
- **Run the tests** (`⌘U` in Xcode, or `xcodebuild -project AraPlay.xcodeproj
  -scheme AraPlay test`). Logic changes — parsing, the recents store, engine
  routing — should come with a test in `Tests/`.
- **Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before touching
  `MPVEngine`.** The mpv integration has non-obvious constraints (the
  property-observation rule, the Lua/Hardened-Runtime interaction, the
  resize workaround) that were expensive to learn; the document exists so
  nobody pays for them twice.
- **Comments explain *why*, not *what*.** Match the style around you.
- **Never commit media files.** `.gitignore` blocks the common containers;
  test with your own local files.
