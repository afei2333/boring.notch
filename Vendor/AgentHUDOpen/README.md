# Agent HUD Open core

This local Swift package contains `AgentHUDCore`, `AgentHUDSupport`, and
`AgentHUDDesktop` from
[Agent HUD Open](https://github.com/jazzenchen/agent-hud-open). The pinned
upstream commit is in [UPSTREAM_REVISION](UPSTREAM_REVISION). Its standalone
executable and tests are not copied. The source is licensed under Apache-2.0;
see [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).

Run `./update_agent_hud.sh` from the repository root to fetch the latest
upstream commit, apply the Boring Notch integration patch, compile the package,
and record the new commit and notices. The update stops before replacing this copy
if its sources have local changes, the patch conflicts, or compilation fails.
A local source checkout can be passed as
the first argument for offline verification. Build Boring Notch after updating
to check that its host API calls still match the upstream package.

`SessionObservers.configure` has one host-specific addition:
`includePermissionHooks` lets Boring Notch collect activity without installing
approval handlers, because this integration does not answer approvals.
The desktop panel exposes a host view with one detected provider selected at a
time, filters its chart and sessions to that provider, and hides its footer.
