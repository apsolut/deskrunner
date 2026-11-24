# Instructions for AI agents

deskrunner runs GitHub Actions jobs for **private** repos on the user's Windows
PC, in Docker containers. The whole tool is `deskrunner.ps1`. The full manual
is [README.md](README.md); this file is the short version for agents.

Two situations are covered:

- [Moving a project's CI to deskrunner](#moving-a-projects-ci-to-deskrunner):
  you work in another repo and the user wants its CI to run locally.
- [Working on deskrunner itself](#working-on-deskrunner-itself): you change
  this repo.

## Rules

1. **Never use deskrunner for a public repo.** Code from a fork pull request
   would run on the user's PC. `start` refuses public repos; do not look for a
   way around it, and do not make a repo private to get past the check.
2. **Do not read `.env`** and never print, log or store the GitHub token. The
   token lives in 1Password and the script reads it when needed.
3. **Say before you run a command that needs the token.** `doctor`, `savings`,
   `start`, `restart` and `stop` make 1Password ask the user for approval. Tell
   them first, or they will see a prompt they did not expect.
4. **Do not change files in the deskrunner folder** while working on another
   project, unless the user asks.
5. **Do not commit, push or open pull requests** unless the user asks. `init`
   only edits files; the user reviews the diff.
6. **`start` and `stop` change a repo setting.** They set and delete the repo
   variable `RUNNER`. Use `-NoSwitch` if the user does not want that.
7. **Use `-Docker` only when a workflow needs it.** It gives every job full
   control of the user's Docker Desktop.

## Moving a project's CI to deskrunner

`<deskrunner>` is the path to `deskrunner.ps1`. Run commands in PowerShell 7.

### 1. Check the repo is private

```powershell
gh repo view owner/repo --json visibility,isFork
```

Stop if it is public. Tell the user why.

### 2. See whether it is worth it

```powershell
<deskrunner> savings owner/repo
```

Only the "GitHub Linux" minutes can move. Windows and macOS jobs stay on
GitHub. If most minutes are Windows or macOS, say so: the better fix is then
to run those jobs less often (for example only on tags), not to move the
Linux jobs.

### 3. Convert the workflows

```powershell
<deskrunner> init C:\path\to\checkout -DryRun   # preview
<deskrunner> init C:\path\to\checkout           # apply
```

`init` rewrites `runs-on: ubuntu-*` to
`runs-on: ${{ vars.RUNNER || 'ubuntu-latest' }}`. With the variable unset, the
job runs on GitHub as before, so the change is safe to merge at any time.

Read its report. It leaves these jobs alone, and you should too unless the
user decides otherwise:

| Report line | Meaning |
|---|---|
| `!` uses `container` or `services` | Unreliable on deskrunner. Keep the job on GitHub |
| `-` Windows or macOS | deskrunner only provides Linux runners |
| `?` edit by hand | Matrix, label list or expression. Convert it by hand only if every value is a Linux label |

### 4. Fix each converted job for a self-hosted runner

The runner image has git, curl and the Docker CLI, and little else.

- **Install every tool the job uses** with a setup action: `actions/setup-node`,
  `pnpm/action-setup`, `actions/setup-python`, `astral-sh/setup-uv`,
  `dtolnay/rust-toolchain`, `actions/setup-go`, and so on. Tools that
  `ubuntu-latest` has preinstalled are missing here. System packages need
  `apt-get update && apt-get install -y ...` (jobs run as root, no `sudo` needed).
- **Remove `actions/cache` steps for package stores.** pnpm, npm, uv and pip
  caches already persist on the runner. Keep `actions/cache` for anything else.
- **Do not rely on a clean machine.** The workspace is not wiped between jobs
  beyond what `actions/checkout` does. Do not leave secrets on disk.
- **Docker steps** (`docker build`, `docker run`) need runners started with
  `-Docker`. Containers a job starts are siblings: reach their ports at
  `host.docker.internal`, not `localhost`, and remove them at the end of the job.
- **Add a `concurrency:` block** if the workflow has none, so superseded
  pushes are cancelled:

  ```yaml
  concurrency:
    group: ${{ github.workflow }}-${{ github.ref }}
    cancel-in-progress: true
  ```

The converted workflow must still pass on `ubuntu-latest`, because that is
where it runs whenever the runners are stopped.

### 5. Start the runners

After the workflow change is merged (or on the branch you want to test):

```powershell
<deskrunner> start owner/repo            # one job at a time
<deskrunner> start owner/repo -Count 3   # three jobs in parallel
<deskrunner> status
```

`start` sets `RUNNER=self-hosted` on the repo. Each runner uses up to 4 CPUs
and 6 GB, so do not start more than the workflow's parallel jobs need.

For a repo in an organization, the target can be the org name (`my-org`); the
runners then serve every private repo in it. Org targets are not switched
automatically: set the `RUNNER` variable yourself.

### 6. Check it worked

Trigger a run, then:

```powershell
gh run list --repo owner/repo --limit 3
gh api repos/owner/repo/actions/runs/<run-id>/jobs -q '.jobs[] | "\(.name): \(.runner_name)"'
```

Jobs on deskrunner have a runner name that starts with `desk-`. Jobs on GitHub
show `GitHub Actions <number>`.

If a job fails with `command not found`, add the matching setup action
(step 4). If a job waits for a runner, see the table below.

### 7. Going back

```powershell
<deskrunner> stop owner/repo
```

This deletes the `RUNNER` variable first, so new jobs run on GitHub again.

### Problems

| Symptom | Cause and fix |
|---|---|
| Job stuck on "Waiting for a runner" | No runner is up (`status`), Docker Desktop is paused or closed, or the PC was shut down without `stop`. Start the runners, or run `gh variable delete RUNNER --repo owner/repo` to send jobs to GitHub |
| `start` says the repo is public | Intended. Do not work around it |
| `start` warns it could not change `RUNNER` | The token cannot write repo variables. Ask the user to add the permission, or run `gh variable set RUNNER --body self-hosted --repo owner/repo` |
| `command not found` in a step | The tool is not in the image. Add its setup action |
| Registration fails with 401, 403 or 404 in `logs` | The token is missing a scope or has expired. Run `doctor` |
| More jobs queue than run | One runner runs one job at a time. Use `restart owner/repo -Count N` |

## Working on deskrunner itself

deskrunner is deliberately small and opinionated. Keep it that way.

- **Hard requirements, not options:** Windows 11, Docker Desktop, PowerShell 7,
  1Password, private repos only. Do not add support for other operating
  systems, other secret stores, plain tokens, or a flag that allows public repos.
- **One script.** Everything is in `deskrunner.ps1`, with `compose.yaml` and
  `compose.docker.yaml` beside it. Do not add a build step or dependencies.
- **The token never touches disk** and is never printed. It is passed to
  Docker through an environment variable and removed from the session afterwards.
- **The README must match the script.** Change both in the same commit when
  behaviour, commands, labels or permissions change. Update this file too.
- **Names that users depend on:** the runner label `deskrunner`, the variable
  `RUNNER` with the value `self-hosted`, the volumes `deskrunner-cache` and
  `deskrunner-toolcache`, and Compose projects named `deskrunner-<target>`.
  Changing any of them breaks existing setups.
- **Never commit `.env`** or anything that names a real repo, vault or person.
  Use `owner/repo` and `my-org` in examples.

### Testing a change

There is no test suite. Before you say a change works, run what you changed:

```powershell
./deskrunner.ps1 doctor
./deskrunner.ps1 status
./deskrunner.ps1 init <a scratch folder with sample workflows> -DryRun
```

- Check the script parses and that `docker compose -f compose.yaml config`
  accepts the Compose files.
- For `init`, test on a scratch copy with one job of each kind: plain Ubuntu,
  `services:`, Windows, matrix, already converted, and a reusable workflow call.
- `start`, `stop` and `savings` need the user's token and change real things.
  Ask the user before running them, and say plainly which parts you could not test.
