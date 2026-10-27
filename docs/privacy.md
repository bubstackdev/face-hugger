# Face Hugger privacy policy

Effective October 12, 2026. Face Hugger is developed by Zak Keown. For privacy or support requests, contact [support@bubstack.dev](mailto:support@bubstack.dev).

This policy covers existing Python-based builds and the native backend. Store build 3 uses the bundled Python backend. The native backend, including optional dataset-card drafting, is in Store build 6, which is awaiting release.

## What the app does with your information

Face Hugger is a Mac client for Hugging Face. It sends files you choose to upload, their repository paths, and the requests needed to browse and manage repositories to Hugging Face and its upload infrastructure. These services receive network information such as your IP address. The native build authenticates with the Hugging Face access token you enter. Older direct-download builds may also use an existing local Hugging Face CLI login. Repository requests retrieve account names, organization membership, repository information, and file listings to display in the app.

Your files are transferred to Hugging Face, not to a Face Hugger developer-operated upload server. The developer does not operate an analytics, advertising, or automatic crash-reporting service in the app. The native backend does not include the Hugging Face Hub SDK. Older Python-based builds disable that SDK’s optional telemetry flag. This does not prevent the service from processing the requests and operational information needed to provide uploads and account access.

Hugging Face controls its service-side processing and retention under its [privacy policy](https://huggingface.co/privacy). Repository visibility matters: files in public repositories are accessible to others. Deleting a local queue item or uninstalling Face Hugger does not delete uploaded files or repository history on Hugging Face. Use Hugging Face's repository and account controls for those records.

## Information kept on your Mac

An access token saved through Face Hugger is stored in macOS Keychain. Queue and saved-pairing records store local folder paths, repository identifiers, filters, transfer status, and limited recent failure output. Folder permission bookmarks may be saved to restore access to folders you selected. These records are stored in Face Hugger's Application Support directory. The native engine also saves file metadata, SHA-256 hashes, and confirmed commit receipts there to recover uploads; checkpoints do not contain access tokens or signed upload URLs. Removing a queue item removes its native checkpoints. Older Python-based builds can also leave runtime/dependency caches and Hugging Face upload checkpoints, including an upload cache inside a selected source folder. SDK caches or a separate CLI login can reside in Hugging Face’s own cache directory. Installing a newer native build does not automatically remove those older records.

The app attempts to redact Hugging Face tokens from displayed and saved diagnostic output. File paths, repository names, and other diagnostic details may still appear in logs. Local completion notifications can show a transfer title. macOS controls notification display and permissions.

You can remove saved pairings and finished queue items in the app. Removing the saved account deletes the token saved by Face Hugger; it does not revoke the token at Hugging Face or remove a separate CLI login. To revoke a token, use your Hugging Face account settings. To remove remaining local Face Hugger records, quit the app and remove its Application Support folder after preserving anything you need. Removing source-folder upload caches can discard resumable progress.

## Transfer history in version 1.1 development

Version 1.1 development builds additionally retain transfer receipts in the app's Application Support directory. A receipt contains the source folder's display name, repository and destination, attempt and plan identifiers, timestamps, recorded progress, confirmed commit references, a verified revision when available, and a limited error category and message. Receipts do not include the absolute source path, permission bookmarks, access tokens, signed upload URLs, file contents, or session logs. A copied receipt includes canonical Hugging Face commit or verified-revision links when recorded.

The latest 200 finished receipts and the active attempt are retained. Each receipt keeps up to 20 recent commit references together with total acknowledged commit and file counts. Removing a queue item removes its recovery checkpoints but leaves its receipt. Clear history removes finished receipts without removing queued work, active attempts, checkpoints, or remote files. Older queue outcomes are imported once; measurements that were not recorded remain unknown.

Upload review reads source files locally to compute content hashes and requests account and repository metadata from Hugging Face. It does not send source-file contents during review. After approval, normal upload negotiation may send file paths and small content samples before transferring file bodies. The on-disk review stores the source path, filters, file names, sizes and timestamps, hashes, account name, repository revision, planned actions, approval, and acknowledged execution state. It contains no file bodies, access tokens, signed provider URLs, or folder permission bookmarks. Cancelled reviews are removed when cancellation settles; approved plans remain with their queue items and are removed when those items are removed. Clearing receipt history keeps these plans for recovery.

Receipts also retain the last observed phase and activity time, outgoing request-body byte totals, request and retry counts, and fixed retry reason categories. These measurements can include repeated sends and encoded commit content; they exclude headers and transport overhead. Live throughput, current file names, request identifiers, and retry countdown deadlines are not retained in receipts.

Saved pairings additionally retain pinning and display-order preferences. Search text and the active-pairing indication remain in memory. Folder open events can temporarily retain local folder URLs and access scopes while waiting for the workspace or for you to choose one folder; opening a folder does not start an upload. Accepted folders use the existing workspace bookmark handling.

## Optional dataset-card drafting

When you open the dataset-card editor, Face Hugger reads file names, sizes, and the current upload filters to summarize your selected folder. An existing local README may be read into the editor for comparison; it is not passed to the model. Dataset contents are not sampled or sent for generation. If you choose **Draft on this Mac**, your purpose statement and a bounded metadata summary are processed using Apple's on-device Foundation Models model. Face Hugger does not route this feature to a cloud model. Drafts and context notes remain in memory until you explicitly save a local Markdown file. Saving does not upload it; the normal upload action sends the card to Hugging Face only when you choose to include it.

## Setup, links, and support

Older direct-download builds fetch Python and upload tools during setup from Astral/GitHub and Python package infrastructure. Those providers receive ordinary download requests and associated network information. The native backend replacement has uploads built in and does not perform that setup download. Opening account, help, or project links sends you to the corresponding third-party website, whose policies apply.

If you email support, the developer receives the address, message, and attachments you send and uses them to respond and investigate the issue. Never send access tokens. Send only the information needed for support. If you choose to report a bug in the public GitHub repository instead, anything you post there is public. Contact the address above to request deletion of support correspondence, subject to records that need to be retained for legal obligations or resolving an ongoing issue.

## Changes

This policy will be updated when the app's handling of information changes. The effective date above identifies the current version.
