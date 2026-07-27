# Sandbox — confined execution

`Insika::Sandbox` is the engine primitive for **confined execution**: a single,
pluggable interface a tool holds to touch the filesystem and run commands inside
a bounded environment. It follows the principle of the *narrowest sandbox that
supports the task* — cheap in-process confinement by default, real container
isolation when the task warrants it, chosen by configuration rather than code.

It has two halves:

- **FS confinement (`Boundary`) — always on, always host-side.** Every path a
  tool resolves is proven to live inside a single root *before any IO happens*.
- **Command exec — via a swappable provider.** `local` (in-process, the default)
  or `docker` (isolated container). The provider is selected by data on the agent
  profile, not by branching in tool code.

## The FS boundary

`Insika::Sandbox::Boundary` confines every path to one root directory. It
rejects, before touching disk:

- `..` traversal that escapes the root (path normalized, then string-contained on
  a separator boundary — so `/ws-evil` does not pass for root `/ws`);
- absolute paths outside the root;
- symlinks: the final path component may never be a symlink (an `lstat` check that
  also catches a *broken* symlink whose target does not yet exist), and any
  existing target's real path (`File.realpath`) must also be contained — a symlink
  inside the root pointing outside is refused rather than followed.

An escape raises `Insika::Sandbox::Escape`; tools rescue it and return a
structured `{ error: ... }` to the model, never a crashed turn.

The boundary is **always host-side**, for both providers. With `docker`, the FS
tools still read and write host files (confined by the boundary); the container
sees the same bytes through a bind mount. Only the risky part — shell exec — is
isolated. That is the "narrowest sandbox" line: don't containerize a file read.

## Exec providers

`sandbox.exec(command)` returns a `Insika::Sandbox::Result`
(`exit_status`, `output`, `timed_out`). Both providers enforce a **hard-kill
wall-clock timeout**: on the deadline the process — and, via its own process
group, any children — is force-killed and the partial output is returned with
`timed_out: true`. (The engine's fiber contract forbids `Timeout.timeout`; the
deadline is enforced with a bounded `Thread#join` and a process-group kill.)

### `local` (default)

Runs the command in-process (`/bin/bash -c`) with the working directory pinned to
the root. Cheap, no daemon, no image pull. It is **not** an isolation boundary for
a shell (a command can still read absolute paths or `cd ..`); shell tools stay
approval-gated, and untrusted execution should use `docker`.

### `docker`

Runs the command inside a throwaway container (`docker run --rm`) with the root
bind-mounted at a fixed workdir. Conservative defaults: `--network none`, a memory
cap, a cpu cap, and a minimal image — all overridable. The container is named so
the timeout teardown can `docker kill` the exact container.

## Declaring a sandbox (config-over-code)

The provider and its policy are **data on the agent profile**, under the
`sandbox` key — never a branch in tool code:

```ruby
Insika::AgentProfile.build(
  id: "coder",
  # ...
  sandbox: {
    provider: "docker",       # "local" (default) | "docker"
    root:     "/srv/project", # confinement root (default: cwd)
    timeout:  120,            # per-exec wall-clock seconds
    image:    "ruby:3.3",     # docker only
    network:  "none",         # docker only (default: none)
    memory:   "512m",         # docker only
    cpus:     "1.0"           # docker only
  }
)
```

A deployment turns that config into the object every tool holds:

```ruby
sandbox = Insika::Sandbox.build(profile.sandbox)   # => Insika::Sandbox::Env

sandbox.resolve("src/app.rb")        # host path, guaranteed inside the root
sandbox.exec("bundle exec rspec")    # => Result(exit_status:, output:, timed_out:)
```

The config round-trips through the JSON store (Studio edits), so profile and
runtime never drift. Absent (`nil`) config means a deployment builds a `local`
sandbox by default.

## Reference deployment

`plugins/insika-code` is the reference consumer: the FS/shell toolset
(`read_file`, `list_dir`, `grep`, `write_file`, `edit_file`, `bash`) is built on
this primitive, and `examples/insika-code/boot.rb` declares the `sandbox` block
on its profile while the plugin builds the matching `Sandbox` from the same
config. See [`examples/insika-code/README.md`](../examples/insika-code/README.md).

The sandbox is one of two independent controls on the high-risk tools; the other
is the engine's human-approval gate (`approvals_required` + the `ToolEnvelope`
suspend/resume path). They compose: confinement bounds *where* a tool can act;
approval bounds *whether* it acts at all.
