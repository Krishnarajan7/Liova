# Downloads

Liova shows downloads in progress in the notch: a ring (or the speed) when closed, and a card with the name, app, progress, size, speed and time left when open. When a download finishes, a brief green "Downloaded" flash shows the final file name. Turn it off in Settings (`downloadsEnabled`, on by default).

## What's detected, and how

Liova never opens or reads a file. It uses only **file-system metadata** (paths, names, sizes, whether a file exists) and the **file progress other apps publish** through Foundation. It looks in these folders and nowhere else:

| Folder | What counts |
| --- | --- |
| `~/Downloads` (and its subfolders) | Published download progress; partial files that grow |
| Telegram for macOS: `~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/*/account-*/postbox/media/` | Only files named `*_partial` that grow |

Two sources run side by side and are merged (`CompositeDownloadSource`):

1. **Published progress** (`FileProgressDownloadSource`). Apps can publish an `NSProgress` for a file; it's how Finder draws a progress bar on a downloading file's icon. Liova subscribes to `~/Downloads` with `Progress.addSubscriber(forFileURL:)` and observes each progress with KVO (completed and total bytes, throughput, time remaining, cancelled, finished), coalesced to at most four updates a second per download. Only `downloading` and `receiving` (AirDrop) operations count; copies, uploads and unzipping don't. This source knows the total size, so it shows a real progress bar.
2. **Growing partial files** (`PartialFileDownloadSource`) for apps that don't publish progress. One FSEvents stream (file-level events, ~0.75 s latency) watches the folders above. A file counts as a download when its name is a partial-download name **and** its size grows:

   | Name | Typical app |
   | --- | --- |
   | `*.crdownload` | Chrome, Edge, Brave, Arc, Vivaldi |
   | `*.part` | Firefox and others (also in `~/Downloads/Telegram Desktop/`) |
   | `*.download` (a bundle) | Safari |
   | `*.opdownload` | Opera |
   | `*.partial`, `*_partial` | Various; Telegram for macOS |

   The display name drops the suffix (`Movie.mkv.crdownload` → `Movie.mkv`). It finishes when the partial file disappears and the final file exists (if the app renamed it to something else in the same folder at the same moment, that name is used). It ends quietly if the file is deleted, or hasn't grown for 60 seconds.

   To avoid noise, a partial file is only shown once it has grown, is at least 1 MB, and was first seen at least 2 seconds ago; anything that finishes sooner never appears.

When both sources see the same download (Safari publishes progress *and* writes a `.download` bundle), the published progress wins and the partial-file copy is hidden, including its finish, so it flashes once.

## In the notch

- One `low`-priority activity per download (`system.downloads.<id>`), updated in place. Low is the ambient level, the same as music: timers, agent prompts and HUDs cover it, and it comes back when they end. Between two low activities the newer one shows, so a download that starts while music plays takes the notch until it ends.
- More than three at once collapse into one "N downloads" activity with combined size, speed and progress.
- Finished: a `high` "Downloaded" flash for 4 seconds. Failed, cancelled or stalled: the activity just ends.
- Progress is rounded to 1% and text only changes when what's shown changes, so the engine drops identical updates.

## Battery

- **Nothing runs while nothing downloads.** FSEvents and KVO are push-based; there's no polling.
- While at least one partial file is being tracked, a single 1 Hz timer (250 ms leeway, so macOS can coalesce wake-ups) checks the sizes of those files only, to compute speed (exponentially smoothed, ~3 s time constant) and notice stalls. It stops as soon as none are tracked.
- Published progress needs no timer; updates are coalesced to 4 per second per download.
- The closed notch is static: a ring or a speed label, never a looping animation, and values stream in without animation.

## Limitations

- **Telegram for macOS has no file name or total size** in its cache, so its downloads show as "Telegram download" with bytes and speed but no progress bar. Telegram's folders are found when the feature starts; a Telegram account added later is picked up the next time it starts. On recent macOS versions, looking inside another app's group container can make macOS ask once whether Liova may access data from other apps; declining just turns off Telegram detection.
- **Apps that download into private caches can't be seen** (App Store, many game launchers, cloud-sync clients, apps that write to a temporary folder and move the file at the end). Liova only sees what lands in `~/Downloads` or publishes progress there.
- Partial-file downloads have no total size (the size the server will send isn't in the file system), so they show bytes and speed but no percentage, unless the browser also publishes progress.
- Chrome sometimes names a download `Unconfirmed 123456.crdownload` before it knows the real name; it's shown as "Download" until it finishes.
- Downloads saved outside `~/Downloads` aren't detected.

## Code

| Piece | Where |
| --- | --- |
| `DownloadItem`, `DownloadSourcing` | `Sources/LiovaProviders/Downloads/DownloadItem.swift` |
| Name rules, speed smoothing (pure) | `PartialFileRules.swift` |
| Partial-file state machine (pure) | `PartialDownloadTracker.swift` |
| FSEvents source | `PartialFileDownloadSource.swift` |
| Published-progress source | `FileProgressDownloadSource.swift` |
| Merge | `CompositeDownloadSource.swift` |
| Policy, feature, renderer | `Sources/LiovaFeatures/Downloads/` |
