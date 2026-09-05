# pair-adopt

Put an OpenAI-compatible inference server that **NVIDIA Personal AI Router (PAIR) cannot start** behind
PAIR anyway, so it is routable from every node's `:1234` by model id. vLLM in docker, a tensor-parallel
pair, a llama-server bound to a LAN address, TabbyAPI / ExLlamaV3, SGLang, TGI. Anything that already
answers `GET /v1/models` on the box.

One JSON file, two systemd units, one drop-in. PAIR probes, adopts, routes. It never owns the process
and has no code path that can stop it.

Lineage, so you know what was actually run. The `lmstudio` manifest override started on Windows with
PAIR spawning llama.cpp, was repeated on macOS, then on Linux `amd64` for llama.cpp and for servers PAIR
cannot start (an ExLlamaV3 / TabbyAPI box and llama-servers bound to LAN addresses), and finished on
`linux/arm64` with a DGX Spark pair serving vLLM. `adopt.sh` itself has run end to end on the Spark
(PAIR **0.91.7**, headless `nvpair` under systemd); the amd64 adoptions used the same manifest and units
through the per-node scripts this repo was distilled from. This is **unsupported**: it leans on three conditions in PAIR's source that a release can change
without an error message. Keep the files in version control and re-run `verify` after every update.

## Why it takes more than the obvious file

PAIR routes only to two engine names, `ollama` and `lmstudio`. Its engine manager, though, reads a
per-user `engines/<name>.json` and deep-merges it onto the bundled manifest of the same name. So you
keep the name `lmstudio` and replace the body: command mode, start and stop commands that do nothing,
health probes pointed at your server. [XDA published that shape for vLLM.](https://www.xda-developers.com/connected-two-pcs-one-ai-endpoint-nvidia-new-router-serving-engine/)
It is correct and it is not enough. Three gates in the source stop it, and the headless unit discards
the logs where each refusal is written.

**Gate 1 — PAIR will not probe a command-mode engine unless a `detect` path exists.**
`nvpair-engine-manager/status.go`, `reconcilePresence`:

```go
// A command-mode engine needs its control CLI. A compatible HTTP endpoint
// alone (for example another OpenAI server on LM Studio's port) is not an
// installation and must not suppress the installer.
if !pathInstalled && st.plat.Runtime.modeOrDefault() != "process" {
    return presenceResult{}
}
```

The bundled LM Studio manifest detects the `lms` binary. If you do not have it, PAIR accepts your
override, decides LM Studio is not installed, and never sends a probe. Symptom: `{"models":[]}`
forever, no log line. Fix: `detect` names any path that exists.

**Gate 2 — the port must be the bundled default (1235), or PAIR rewrites your file.**
`nvpair-engine-manager/setport.go`, `persistPort`: for a bundled engine, a port equal to the bundled
default deletes the override; any other port is written as a three-line `{engine, runtime:{port}}`
delta that **replaces** the whole file (the merge-into-existing branch is for non-bundled engines
only). The caller is the UI broker: at startup it places the LM Studio slot at 1235 through
`engine:set-port` (gate 3), so a manifest that says your server's real port loses every custom key
five seconds after start. Fix: the manifest says 1235, and a loopback
forwarder on 1235 carries traffic to your server's real port.

**Gate 3 — 1235 must be FREE at the instant the UI broker starts.**
`nvpair-ui-broker/lmstudioport.go`, `prepareManagedLMStudioFacade`: the broker asks for engine status
while probing **port 1234 only**, so it can never see your forwarder on 1235. Then:

```go
if !st.Running && !available(st.Port) {
    backend := nextAvailablePort(managedLMStudioBackendStart, available)
```

Not running and its port occupied? Move it to 1236 and persist (gate 2 fires). Fix: the forwarder
socket binds 1235 only after the broker is done. The precise signal is PAIR's LM Studio proxy listening
on 1234, which the broker spawns only after this step. `pair-adopt-1235.socket` waits for it.

Two shortcuts fail on the same code: `chattr +i` makes set-port fail and the broker then moves the
`:1234` proxy itself to a fallback port; a forwarder on 1234 is adopted and then fails the move the
same way. Both break the endpoint, not just the engine.

## Install

Prerequisites on the node: Linux with systemd (`systemd-socket-proxyd`, shipped with systemd), `ss`
(iproute2), `getent`, `curl`, `python3`, and PAIR running headless as a systemd unit (`nvpair` by
default). The account PAIR runs as must have a primary group of the same name, or pass `--pair-user`
and adjust ownership afterwards.

On the node that runs the server, as a user who can `sudo`:

```
git clone https://github.com/jds1-ai/pair-adopt && cd pair-adopt
sudo ./adopt.sh install --target 127.0.0.1:8888 --model my-model-id --detect /usr/bin/docker
```

- `--target` is where your server actually listens (`ip:port`; a LAN address is fine, the forwarder
  runs on the same box).
- `--model` is the id your server reports in `/v1/models`, used only by `verify`.
- `--detect` is any path that exists; the server's own binary is the honest choice.
- Optional: `--pair-unit nvpair` (the systemd unit that runs PAIR; default `nvpair`),
  `--pair-user <user>` (the account PAIR runs as; default: the invoking user via `SUDO_USER`).

`install` writes `~<pair-user>/.config/Nvidia Corporation/Personal AI Router/engines/lmstudio.json`
(backing up any existing file to `lmstudio.json.bak`), installs the socket + service + drop-in, checks
that nothing holds 1235, restarts PAIR, and runs `verify`.

## Verify

```
./adopt.sh verify --target 127.0.0.1:8888 --model my-model-id
```

In this order, because each one discriminates a different failure:

1. The override is still your file a minute after PAIR started (size, not existence — gate 3 leaves a
   63-byte file behind; gate 2 with the port at default leaves none).
2. The socket is active and `127.0.0.1:1235/v1/models` answers as your server (gate 3).
3. PAIR's engine surface `127.0.0.1:14322/v1/models` lists your model under `lmstudio`. An empty list in
   the first minute is the poll interval, not a failure (gate 1 is the one that stays empty forever).
4. A chat completion through `127.0.0.1:1234` naming the model returns `finish_reason: stop`. Reasoning
   models need a few hundred `max_tokens` or the reply is empty and looks like a routing fault.
5. From another PAIR node, the same request to *its* `127.0.0.1:1234`.

`sweep.sh` sends one small completion to every id PAIR advertises and prints code, wall time, and
result. Advertised is not servable; this tells you which is which.

## Uninstall

```
sudo ./adopt.sh uninstall
```

Removes the units and drop-in, restores the backed-up override (or deletes ours), restarts PAIR.

## What it does not do

- The dashboard never shows the engine's model as "loaded". PAIR's extractor filters on string and
  array fields; most servers report state in neither. Cosmetic.
- Turning the engine off in the UI errors with "still serving on port 1235". That is the safety
  property: PAIR has no process to kill and no command that would kill one. Keep it that way; the risk
  of adopting a live server is handing a UI switch the power to stop it.
- One LM Studio slot per node. If you also want PAIR to spawn llama-server on this box, pick one.
- Measured on a two-Spark tensor-parallel vLLM: the router adds no latency within noise (same prompt,
  same 107-token answer, 1.57 s direct vs 1.56 s via `:1234`). Cross-node adds the network hop and
  nothing else.

## Files

| File | What |
|---|---|
| `adopt.sh` | install / verify / uninstall |
| `manifest.json.in` | the `lmstudio` override template (`@DETECT@`, `@PLATFORM@`, `@DISPLAY@`) |
| `pair-adopt-1235.socket` | loopback 1235, gated to bind after PAIR's proxy is on 1234 |
| `pair-adopt-1235.service.in` | `systemd-socket-proxyd` to `@TARGET@` |
| `nvpair-10-pair-adopt.conf` | drop-in so the socket follows every PAIR restart |
| `sweep.sh` | one completion per advertised model id |

## Read more

- [The router deleted my config file twice. Both times it was working as designed.](https://jds5.com/posts/the-router-deleted-my-config-twice/) — the four attempts behind these three gates.
- [NVIDIA's AI router says it supports two engines. It routes to a third if you lie to it in one file.](https://jds5.com/posts/llamacpp-behind-nvidia-pair-one-file-four-roadblocks/) — the other shape: PAIR spawning llama.cpp itself.

## Credits and license

The command-mode adoption shape was first published by XDA Developers for vLLM. The three gates were
found by reading PAIR's source (Apache-2.0, NVIDIA) after three failed deployments on a live cluster;
the quoted excerpts are NVIDIA's, see `NOTICE`. Built with Claude Code; every gate was verified
against upstream source and on real hardware.

Apache-2.0 — see `LICENSE`.
