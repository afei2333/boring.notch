# Agent HUD Open core

This local Swift package contains `AgentHUDCore`, `AgentHUDSupport`, and
`AgentHUDDesktop` from
[Agent HUD Open](https://github.com/jazzenchen/agent-hud-open), revision
`3e53f98618ef03f85624e1ae8d4cd22879a75531`, plus the source working tree's
uncommitted `CodexRateLimits.swift` change at integration time. Its standalone
executable and tests are not copied. The source is licensed under Apache-2.0;
see [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).

`SessionObservers.configure` has one host-specific addition:
`includePermissionHooks` lets Boring Notch collect activity without installing
approval handlers, because this integration does not answer approvals.
The desktop panel exposes a host view with one detected provider selected at a
time, filters its chart and sessions to that provider, and hides its footer.
