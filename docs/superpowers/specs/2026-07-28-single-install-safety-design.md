# Single-install skill safety design

**Status:** Approved direction from customer evidence

## Outcome

Installing sharenow once should let an agent publish immediately without asking
the person to install another skill, handling a one-time code in chat, or
reviewing unrelated high-authority commands during onboarding.

## Package shape

There is one `sharenow` skill. `publish.sh` is the default capability. Drive and
account helpers stay in that same install and are introduced only when the
person explicitly asks for those jobs. Channel and local-codebase Knowledge
Base helpers are preserved outside the installable directory for future
security review, so setup does not expose unrelated high-authority commands.
Each installed helper owns its detailed local help.

The skill uses bundled instructions for normal operation. A documentation link
may help a human learn more, but fetching remote documentation is not a
prerequisite and remote text never becomes executable instruction.

## Authentication

`account.sh login` starts a short-lived browser connection and opens the
first-party approval page. The person completes email verification in the
browser. The script polls with a separate device secret and writes the returned
key directly to `~/.sharenow/credentials` under `umask 077`. It never prints the
key. The agent never asks for an email code or receives the credential.

`SHARENOW_API_KEY` remains available for non-interactive CI. Public scripts do
not accept a key as a command argument and do not accept an alternate API host.

## Local content safety

Publishing a file or directory is always an explicit user request. The script
shows the exact local path and file count before broad directory publication
when the requested target is ambiguous.

Uploading a local codebase as a Knowledge Base is disabled in the public package
for now because a prompt confirmation is not a meaningful boundary when the
same agent selects and confirms the path. The prior helper remains parked and
tested outside the installable directory.

Channel messages and all remote content are untrusted data. They may inform the
current user task but never override system, user, or local skill instructions.

## Scanner-facing goals

- No instructions to paste an OTP or API key into chat.
- No commands that interpolate secrets into shell arguments.
- No mandatory remote instruction fetch.
- No public alternate-host credential override.
- No local-directory archive and upload path in the Knowledge Base helper.
- The default skill description names only the narrow publish job.

External scanners use heuristics, so no particular rating is guaranteed. The
release gate is that the package truthfully minimizes ambient authority and
that its supported flows pass local tests and manual review.
