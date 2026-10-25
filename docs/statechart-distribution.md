# Statechart distribution

## Sub-features

Complete upstream skill, scripts and tests from cursor/plugins revision 99b609a72323b70204eab407c622f436e858e112. Canonical statechart/ is copied into skills/statechart/, hermes/productivity/statechart/ and plugins/sharenow/skills/statechart/. The skills/ layout is consumed by studio’s verified Box bundle. No host release is needed.

## How to get to it

Ask a studio helper to use statechart; on another computer install with npx skills add AsyncFuncAI/sharenow --skill statechart -g -y. Existing Boxes refresh within 30 minutes of the server discovering main (up to five minutes). New hosts first check after five seconds.

## Driving it with

Run scripts/verify-package.sh; node --test statechart/scripts/test/*.test.mjs; node statechart/scripts/statechart.mjs --help. Confirm /api/studio/skills/bundle lists statechart, and the Box has readable SKILL.md and scripts through each runtime skill link. Generate a TLA+ chart and inspect its PNG.

## Gotchas

The upstream skill is explicit-invocation only. Copying SKILL.md alone is insufficient. Rendering installs pinned npm packages; model checking needs mise or Java and TLA2TOOLS. The host must own skill synchronization: never manually alter managed skill folders on a Box. Existing user-owned folders are preserved by the host.

Source of truth when this drifts: statechart/, scripts/build-layouts.sh, ../putti-next/crates/host/src/skills.rs, ~/temp/sharenow/server/studio/box-skills.ts.
