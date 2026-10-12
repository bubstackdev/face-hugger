# Architecture

Face Hugger is a macOS 27+ SwiftUI app (macOS 15+ through 1.0) with a small Python bridge to the official Hugging Face runtime. The first release keeps process ownership inside the app: closing a window preserves work, while quitting stops the upload before the app exits.

## Components

| Component | Responsibility |
| --- | --- |
| `Sources/FaceHugger` | SwiftUI interface, account state, queue scheduling, menu bar, notifications, sleep activity, subprocess execution |
| `Sources/FaceHuggerCore` | Job/repository models, reported progress, scheduling/cancellation state, input validation, atomic queue persistence and interrupted-job recovery |
| `Resources/bridge.py` | JSONL protocol, HF SDK repository operations, CLI upload process supervision |
| `requirements.txt` | Pin for the managed Hugging Face runtime |
| `Resources/Assets.xcassets` | Native app icon and mascot |
| `Tests/FaceHuggerCoreTests` | Swift core behavior tests |
| `TestsPython` | Mocked bridge behavior and real local subprocess cancellation tests |

The Swift package builds the independently testable core. XcodeGen’s `project.yml` builds the macOS application, including the Swift core sources, Python bridge, requirements, and asset catalog.

## Runtime and credentials

Direct-build setup downloads a pinned official uv release with SHA-256 verification, then installs Python 3.12.14 in the app's support directory and synchronizes the complete checksum-locked requirements. The app uses `~/Library/Application Support/Face Hugger/runtime-v3/bin/python3`; Python installations and setup caches use explicit subdirectories beside it. A readiness marker is written after successful setup; an incomplete environment is not considered ready. The older runtime is preserved during migration. Store builds use an embedded runtime and compile out the installation flow.

The app stores its optional token in the macOS Keychain under service `dev.zakkeown.FaceHugger`, account `huggingface`. It passes that token in `HF_TOKEN`, never as a command-line argument or in the queue archive. With no app token, Hugging Face can use the existing CLI login. Removing the saved app account only removes the app’s Keychain item.

Both the Swift subprocess reader and the bridge redact tokens from displayed output. HF telemetry is disabled for app-launched processes. No upload content or credentials are sent through another application service.

## Queue lifecycle

`AppModel` owns the queue on the main actor. `QueueArchive` writes JSON atomically to `~/Library/Application Support/Face Hugger/queue.json`.

Jobs contain a local folder path, repository identity/type, remote destination, filters, timestamps, state, and last status message. There are no file snapshots or credentials in the archive. On load, a saved `running` job becomes `interrupted`; other states remain intact. The queue is paused on launch.

Only one upload runs at a time. Success advances to the next queued job. A failure pauses the queue. Stop requests terminate the current bridge process and keep the queue paused. Resume moves the job back to the queue and invokes the same upload command against the current contents of its source folder.

`UploadQueueControl` separates scheduling intent from the active worker’s cancellation latch. Restarting a queue while a stop is being acknowledged cannot turn the old worker’s cancellation into a failure. Explicit Start/Resume prioritizes the chosen job. Stale completion callbacks are ignored, and a drained queue becomes paused. Notification authorization runs independently so it cannot delay the worker’s launch.

Newly created repositories are retained in the repository picker briefly while HF’s search-backed listing catches up. A generation token prevents stale owner-list responses from replacing newer selections.

The app holds a process activity to prevent idle system sleep when enabled. This does not permit uploading during system sleep or after explicit application termination. Notification permission is requested when starting an upload.

## Bridge protocol

Each command starts a separate bridge process:

```text
python3 bridge.py whoami
python3 bridge.py repos --owner OWNER
python3 bridge.py tree --repo OWNER/NAME --type model|dataset --path PATH
python3 bridge.py create --repo OWNER/NAME --type model|dataset --private true|false
python3 bridge.py delete --repo OWNER/NAME --type model|dataset --path FILE
python3 bridge.py upload --repo OWNER/NAME --type model|dataset \
  --source FOLDER --destination PATH [--include GLOB] [--exclude GLOB]
```

`--include` and `--exclude` repeat. The bridge uses argument arrays without a shell. Repository IDs require an explicit owner, and remote paths reject traversal components.

Standard output contains JSON objects, one per line:

| Event | Fields | Meaning |
| --- | --- | --- |
| `result` | `data` | Successful SDK command result |
| `status` | `message` | Upload activity description |
| `log` | `message` | Redacted output from the upload CLI |
| `progress` | `checked`, `total`, `uploaded`, `upload_total`, `transferred`, `committed`, `commits` | Counts from a recognized HF 2.0 progress line |
| `complete` | `url` | Upload CLI exited successfully |
| `error` | `message` | Command failed or was interrupted |

Non-upload result shapes:

- Identity: `{name, fullName, avatarUrl, organizations: [String]}`.
- Repositories: `[{id, type, private, url}]`.
- Tree: `[{path, type: "file" | "directory", size}]`.
- Creation: `{id, type, private, url}`.
- Deletion: `{path}`.

Unexpected SDK output is redirected to standard error. Swift captures output and displays relevant errors/logs. The app retains only a bounded recent log; logs are not persisted.

## Upload execution and stopping

Repository listing and management use `HfApi`. Uploads run the official CLI through the same managed Python interpreter:

```text
python3 -m huggingface_hub.cli.hf upload OWNER/NAME SOURCE DESTINATION --repo-type TYPE
```

The bridge checks that the destination repository exists before launching the CLI. This prevents `hf upload` from implicitly creating a public repository. New repositories go through the separate creation flow with explicit visibility.

The CLI child gets its own process session. SIGINT/SIGTERM delivered to the bridge is forwarded to that process group, and the bridge waits for the child. After eight seconds it escalates to SIGKILL and reaps the child. Cancellation during process creation is deferred until the child handle is available, preventing an orphaned upload in that narrow race.

Stopping is not rollback. HF may already have committed some files. Rerunning uses HF’s resumable, deduplicating pipeline. An exact-format parser extracts counts from the pinned CLI’s progress summary, including its optional validation suffix. Unknown formats retain log-only behavior. These are overlapping stage counters, not an overall percentage. Uploaded counts can include reused content, so the UI says “uploaded or reused.” Sampled counters are hidden on successful completion because the CLI can exit without printing a final counter update.

The app’s quit delegate waits for its active job to finish stopping before replying to the termination request. There is no launch agent in this version.

## Validation and release boundary

Swift tests exercise validation and queue persistence/recovery. Python tests exercise protocol output, filtering arguments, path validation, explicit creation visibility, token redaction, missing-repo checks, successful/failed CLI exits, and signal delivery to actual local subprocesses. They require no network or credentials.

The opt-in `Scripts/live_smoke.py --run-live` additionally checks authenticated private-model and public-dataset operations, hashes, filters, replacement, deletion, interruption, and resume. It uses only synthetic files and deletes its temporary repositories. It is never run by default or in CI. Native UI verification also exercises creation, upload, stop/relaunch/resume, browsing, and deletion. See [verification results](verification.md).

CI also builds the application with ad-hoc signing. This is build verification, not a distribution release: signing with a Developer ID, notarization, a bundled or more self-contained runtime installer, and bounded testing under prolonged outages remain release work. Multi-terabyte disk capacity is not an acceptance requirement; use synthetic many-file trees, bounded payloads, and controlled interruption/recovery checks.

## Transfer Bench workspace

The native workspace pairs a local metadata preview with a remote repository browser. The bridge `scan` command applies the pinned SDK's folder filters and default ignores, returns at most 2,000 preview rows, and counts the entire tree. Each upload and resume repeats metadata preflight to reject unreadable files and external or broken file symlinks. This is a preview of current files, not an immutable snapshot.

Local scans are cancellable; generation checks prevent older scans and repository requests from replacing newer selections. Submission rechecks repository visibility and verifies the source, filters, and destination are unchanged before queueing. New remote subfolders may be previewed as empty without treating missing repositories or authentication errors as empty folders.

Saved pairings persist atomically in `pairings.json` beside the queue. They store paths, repository identity, and filters, never credentials. Applying a pairing revalidates the destination and never starts an upload. The activity shelf presents queued, running, stopped, interrupted, and completed states; logs remain session-only.

## Path status and recovery

The `compare` command accepts a temporary JSON manifest of up to 2,000 staged paths and recursively streams remote entries under the destination, stopping at 100,000 entries or when all requested paths are found. It returns matching relative paths and a completeness flag. Only a complete result establishes a new path; failures and incomplete listings retain “Not checked.” Paths and types are compared, including files blocking destination ancestors and remote directories occupying local file paths. Contents and hashes are not compared. Refresh before acting on remotely changed content; this is an advisory snapshot, not a transaction.

Comparison processes are cancelled and generation-guarded when the source, filters, repository, or destination changes. Temporary manifests are removed after the request. No local contents are uploaded for comparison.

Failed CLI exits retain a bounded, redacted tail of output in the persisted job message. Conservative recovery hints suggest account settings or network checks; unknown failures stay generic. Missing source folders offer a native locator. Locating replaces that job's source, clears stale progress, prepares its source/filter/destination workspace, and leaves the job stopped. It never starts a transfer. Remote browser failures remain visibly distinct from empty directories.

Before CLI launch, every included source path is indexed in temporary SQLite storage and checked against the full remote tree. This preflight is not limited by the 2,000 preview rows or 100,000 preview listing cap. Conflicts fail before upload; source or remote changes after preflight remain possible.
