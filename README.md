# deskrunner

Run the GitHub Actions jobs of your **private** repos on your own Windows PC,
not on GitHub's paid machines.

> [!WARNING]
> **Private repos only. Never use deskrunner for a public repo.**
>
> A runner executes whatever a workflow tells it to, on your PC. On a public
> repo, anyone on the internet can open a pull request from a fork that changes
> the code or the workflow, and that code would then run on your machine, with
> your network, your caches and (with `-Docker`) your Docker Desktop.
> [GitHub gives the same advice](https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners)
> for all self-hosted runners. deskrunner checks every `owner/repo` target and
> refuses public ones, with no override. For org targets, see [Security](#security).

## What it is

Every push and pull request on GitHub can start "Actions" jobs: tests, builds,
linters. For private repos GitHub runs them on its own machines and bills them
by the minute once your plan's free minutes are used up.

GitHub also lets you connect your own machine as a **self-hosted runner**.
Jobs then run on your hardware and use none of those minutes. They still show
up on pull requests and in the Actions tab exactly as before; only the place
where they run changes.

deskrunner makes that a single command on a Windows PC:

```powershell
./deskrunner.ps1 savings owner/repo        # see what moving would save
./deskrunner.ps1 init C:\path\to\checkout  # make the workflows switchable
./deskrunner.ps1 start owner/repo -Count 2 # run CI on this PC
./deskrunner.ps1 stop owner/repo           # CI goes back to GitHub by itself
```

- **Runners are Docker containers**, not programs installed on Windows. Jobs
  run inside a Linux container with CPU and memory limits.
- **Nothing listens on your PC.** Runners connect out to GitHub and wait for
  jobs. There is no port to open and no URL to share.
- **Caches stay warm.** pnpm, npm, uv, pip and tool downloads are kept between
  jobs, so repeat runs are often faster than on GitHub.
- **You can always go back.** `stop` sends your CI back to GitHub-hosted runners.

It is for one person with one PC and a handful of private repos. It is not:

- **a replacement for GitHub Actions.** You still use GitHub's workflows, UI and logs.
- **a local emulator** like [`act`](https://github.com/nektos/act). These are real runners doing real jobs.
- **a runner fleet for a team.** For that, use GitHub's
  [Actions Runner Controller](https://github.com/actions/actions-runner-controller).
- **a way to run Windows or macOS jobs.** Those stay on GitHub.

## Requirements

deskrunner is small and opinionated. It supports one setup and nothing else:

| Required | Why |
|---|---|
| **Windows 11** | The script refuses to run anywhere else |
| **Docker Desktop** | Runners are Linux containers |
| **PowerShell 7** | `deskrunner.ps1` is the whole tool |
| **1Password + `op` CLI** | The only way to supply the GitHub token; it is never written to disk |
| **Private repos only** | Public repos are refused, with no override |

It is a thin layer over the
[`myoung34/github-runner`](https://github.com/myoung34/docker-github-actions-runner)
image (Ubuntu 24.04). deskrunner adds the parts you would otherwise write
yourself: per-target runner stacks, 1Password token handling, a public-repo
guard, shared caches, resource limits, a workflow converter (`init`), a usage
report (`savings`) and an automatic fallback to GitHub-hosted runners.

> **For AI agents working in another project:** read "Use it from a project"
> below. Do not edit files in this folder or read `.env` unless the user asks.

## How it works

Runners make an outgoing connection to GitHub and wait for jobs. Nothing
listens on your PC: there is no port to open and no URL to share. GitHub sends
a job to a runner when the workflow's `runs-on` labels match.

A **target** is what a set of runners serves:

| Repo lives in | Target | Covers |
|---|---|---|
| An organization | `my-org` | Every private repo in the org |
| A personal account | `owner/repo` | That one repo (GitHub has no account-wide runners) |

Each target gets its own Docker Compose project (`deskrunner-<target>`). All
targets share the same cache volumes.

## One-time setup

1. Create a GitHub token that can manage runners:
   - classic PAT with `repo` (repo targets) and `admin:org` (org targets), or
   - fine-grained PAT with the repository permissions **Administration: Read and write**
     (register runners), **Variables: Read and write** (the fallback switch) and
     **Actions: Read** (`savings`), plus the organization permission
     **Self-hosted runners: Read and write** for org targets.
2. Save the token in 1Password, for example as an "API Credential" item.
3. Install the 1Password CLI and turn on its desktop app integration:
   `winget install AgileBits.1Password.CLI`
4. `Copy-Item .env.example .env`, then set `TOKEN_REF` to the item's secret
   reference: `op://<vault-id>/<item-id>/credential`. Use the item's unique ID
   (item menu > "Copy Item UUID"), because titles can be duplicated or renamed.
5. Check everything:

   ```powershell
   ./deskrunner.ps1 doctor
   ```

`doctor` checks Docker, the `op` CLI, `.env`, that 1Password can read the
token, and that GitHub accepts it. 1Password may ask you to approve the read.

## Commands

Run from this folder in PowerShell 7. `<target>` is `my-org` or `owner/repo`,
and can be omitted when `DEFAULT_TARGET` is set in `.env`.

| Command | What it does |
|---|---|
| `./deskrunner.ps1 doctor` | Check the setup and the token |
| `./deskrunner.ps1 savings <owner/repo> [-Days 30]` | Show billable minutes per workflow and what can move |
| `./deskrunner.ps1 init [path] [-DryRun]` | Make a checkout's workflows switchable (default path: current folder) |
| `./deskrunner.ps1 start <target>` | Start one runner, register it with GitHub and switch the repo to it |
| `./deskrunner.ps1 start <target> -Count 3` | Start three parallel runners |
| `./deskrunner.ps1 start <target> -Docker` | Start with access to Docker Desktop, for workflows that build or run containers |
| `./deskrunner.ps1 stop <target>` | Switch the repo back to GitHub, then deregister and remove the runners (caches are kept) |
| `./deskrunner.ps1 restart <target> [-Count N] [-Docker]` | Recreate the runners, e.g. after an image update |
| `./deskrunner.ps1 status` | List runner containers for all targets |
| `./deskrunner.ps1 logs <target>` | Follow the runner logs |
| `./deskrunner.ps1 update` | Pull the newest runner image |

Runners come back automatically when Docker Desktop starts, unless they were
stopped with `stop`. Quitting or pausing Docker Desktop takes them offline;
jobs then wait in the queue until a runner is back.

Each runner container is limited to 4 CPUs and 6 GB by default
(`RUNNER_CPUS`, `RUNNER_MEMORY` in `.env`). A single runner executes one job
at a time.

To wipe the caches: stop all runners, then
`docker volume rm deskrunner-cache deskrunner-toolcache`.

## The fallback switch

Switchable workflows pick their runner from a repo variable:

```yaml
jobs:
  build:
    runs-on: ${{ vars.RUNNER || 'ubuntu-latest' }}
```

deskrunner manages that variable for repo targets:

- `start` and `restart` set `RUNNER=self-hosted`, so jobs run on your PC.
- `stop` deletes it first, so new jobs go to GitHub-hosted runners and never
  wait for a runner that is gone.

Details:

- A `RUNNER` variable with any other value (for example custom labels) is
  yours: deskrunner never overwrites or deletes it.
- `-NoSwitch` turns this off for one command.
- Org targets are not switched automatically. Set the variable yourself, per
  repo or for the org.
- The switch only follows `start` and `stop`. If you quit Docker Desktop or
  shut the PC down without `stop`, the variable stays set and jobs wait in the
  queue until the runners are back.

## savings

```powershell
./deskrunner.ps1 savings owner/repo
```

```text
Workflow   Runner         Jobs Minutes List price
--------   ------         ---- ------- ----------
tests      GitHub Linux    310   1,450 $8.70
build      GitHub Windows   40     300 $3.00
tests      Self-hosted      50     200 -

Can move to deskrunner (GitHub Linux): 1,450 min, $8.70 at list price
Stays on GitHub (Windows and macOS):   300 min, $3.00 at list price
Already self-hosted:                   200 min, worth $1.20 on GitHub Linux
```

It reads the job history of the last 30 days (`-Days` for another period) and
counts minutes the way GitHub bills them: each job rounded up to a full minute.

- **List price** uses GitHub's standard-runner prices
  ([Linux $0.006, Windows $0.010, macOS $0.062 per minute](https://docs.github.com/en/billing/reference/actions-runner-pricing)).
  It ignores your plan's free minutes and larger runners, so treat it as an
  upper bound for standard runners, not as your bill.
- **GitHub-managed** rows are runs GitHub creates itself, such as Dependabot.
  They cannot be moved with `runs-on`.
- A repo with many runs takes a few minutes: it makes one API call per run.

## init

```powershell
./deskrunner.ps1 init C:\path\to\checkout -DryRun   # preview
./deskrunner.ps1 init C:\path\to\checkout           # apply
```

`init` edits the workflow files in a local checkout. It does not commit, push
or open a pull request: review the result with `git diff` and commit it yourself.

For every job in `.github/workflows`:

| Job | What init does |
|---|---|
| `runs-on: ubuntu-latest` or `ubuntu-NN.NN` | Rewrites it to `${{ vars.RUNNER \|\| 'ubuntu-latest' }}`, keeping the original label as the fallback |
| Uses `container:` or `services:` | Leaves it on GitHub and says why |
| Windows or macOS | Leaves it on GitHub |
| Matrix, label lists or other expressions | Leaves it and asks you to edit by hand |
| Already switchable | Leaves it |

It also reports converted jobs that use `actions/cache` (usually not needed on
deskrunner) and workflows without a `concurrency:` block. It only changes the
`runs-on` lines; comments, formatting and line endings stay as they are.

## Use it from a project

### 1. Check a runner is up

```powershell
./deskrunner.ps1 status
```

If the org or repo is not listed as running, start it.

### 2. Point the workflow at it

Run `init` on the checkout, or write the switchable form by hand:

```yaml
jobs:
  build:
    runs-on: ${{ vars.RUNNER || 'ubuntu-latest' }}
```

`start` and `stop` then set and delete the `RUNNER` variable for you (see
"The fallback switch"). To do it by hand:

```powershell
gh variable set RUNNER --body self-hosted      # use deskrunner
gh variable delete RUNNER                      # back to GitHub-hosted
```

Or hard-code it: `runs-on: [self-hosted, linux, deskrunner]`.

Runner labels: `self-hosted`, `linux`, `x64`, `deskrunner`, plus `docker` only
on runners started with `-Docker`.

### 3. Adjust the workflow for a self-hosted runner

- **Install tools explicitly.** The image is much leaner than `ubuntu-latest`.
  Use `actions/setup-node`, `pnpm/action-setup`, `astral-sh/setup-uv`,
  `actions/setup-python`, `dtolnay/rust-toolchain`, etc. Do not assume
  anything beyond git, curl and the Docker CLI.
- **Skip `actions/cache` for package stores.** pnpm, npm, uv and pip caches
  already persist on the runner. Uploading them to GitHub only slows the job.
- **Jobs run as root** in a Linux x64 container.
- **Windows and macOS jobs stay on GitHub.** deskrunner only provides Linux
  runners, even though it runs on Windows.
- **The workspace is not cleaned between jobs** beyond what `actions/checkout`
  does. Do not rely on leftover files, and do not leave secrets on disk.
- **Docker is off by default.** If steps need `docker build` or `docker run`,
  start the runner with `-Docker` (jobs then use Docker Desktop through the
  mounted socket). Limitations:
  - `container:` jobs, `services:` and Docker-based actions that mount the
    workspace are unreliable; avoid them or keep that job on `ubuntu-latest`.
  - Containers a job starts are siblings, not children. Reach published ports
    at `host.docker.internal`, not `localhost`, and remove them at the end of the job.
- **Add concurrency** so superseded pushes are cancelled:

  ```yaml
  concurrency:
    group: ${{ github.workflow }}-${{ github.ref }}
    cancel-in-progress: true
  ```

## Security

- **Private repos only.** On a public repo, a fork pull request could run any
  code on your PC. `start` and `restart` ask GitHub whether an `owner/repo`
  target is private and refuse if it is not.
- **Org targets:** deskrunner cannot check every repo in an org. Keep
  "Allow public repositories" turned off for the org's runner group (GitHub's
  default) so public repos in the org cannot use the runners.
- **The token** is read from 1Password at `start` and `restart` and passed to
  the container as an environment variable, because the runner needs it to
  register and deregister. It is visible in `docker inspect` while the
  container exists. `stop` removes the container.
- **`-Docker` gives jobs full control of Docker Desktop.** Use it only for
  repos that need it.
- **Dependency-update PRs** (Dependabot, Renovate) run third-party install
  scripts on your PC too. Private does not mean trusted.
- Never commit `.env`.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Job stuck on "Waiting for a runner" | Docker Desktop paused or quit, no runner started for that org or repo, or `runs-on` labels do not match. To send jobs back to GitHub: `gh variable delete RUNNER` |
| `start` warns it could not change the `RUNNER` variable | The token cannot write repo variables. Add the permission (see setup), or set the variable by hand |
| `start` says the repo is public | Working as intended; deskrunner does not serve public repos |
| Runner logs show 401/403/404 on registration | The token lacks the scope for that target, or has expired. Run `doctor` |
| `command not found` in a step | The tool is not in the image; add the matching `setup-*` action |
| Offline runners piling up in GitHub settings | A runner was killed without deregistering; delete them under Settings > Actions > Runners |

## Credits

deskrunner is a small wrapper. The real work is done by:

- [`myoung34/docker-github-actions-runner`](https://github.com/myoung34/docker-github-actions-runner)
  by [@myoung34](https://github.com/myoung34) and contributors (GPL-3.0): the runner image that every
  deskrunner container runs. deskrunner pulls it from Docker Hub and does not
  copy or redistribute it.
- [`actions/runner`](https://github.com/actions/runner) by GitHub (MIT): the
  runner program inside that image.
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) and
  Docker Compose: run the containers.
- [1Password CLI](https://developer.1password.com/docs/cli/): supplies the token.

Written with help from AI coding assistants (Claude Code).

## License

deskrunner's own files are MIT. See [LICENSE](LICENSE). The tools above keep
their own licenses.

deskrunner is not affiliated with or endorsed by GitHub, Docker or 1Password.
"GitHub Actions" is a trademark of GitHub, Inc.
