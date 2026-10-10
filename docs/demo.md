# Local Clipline demo fixture

This scene contains only synthetic travel content and a sample conversation. The composer accepts actual image files from a native drag. It creates a browser-local preview using an object URL; it never uploads or sends anything. The disabled send button is intentional.

Verified on 2026-10-10: a native macOS screen-region capture appeared on the real Clipline shelf, then an actual `NSDraggingSession` delivered `Weekend-lake-2.png` into this fixture in Chrome. The destination displayed “Screenshot attached” and an image preview. This confirms the native file-drag path into the local browser fixture; receiving a file in a real ChatGPT conversation was not tested.

The recording uses a native verification host compiled from the same current App sources, with a dedicated screenshot folder, a separate clipboard folder, and isolated shelf preferences. The host uses the actual screenshot watcher, shelf UI, and drag handlers. It does not read Desktop or change system screenshot preferences. A user-authorized mouse-event script completed the native drag because CUA could not drag from the floating `NSPanel`; that one-off helper remains outside the committed source.

The 13-second release demo is edited from the actual recording: the initial Space transition is omitted, playback runs at 80% speed, and captions plus a final hold make the attachment visible. No attachment or shelf behavior is simulated. The preview is in [`media/clipline-demo.gif`](media/clipline-demo.gif); the full MP4 is a release asset.

Start the page from the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory scripts/demo
```

Open `http://127.0.0.1:8765` in a browser. A 1440 × 900 screen is ideal; a 1280 × 800 screen also fits the scene. Use a single browser window and close private tabs or other visible windows before recording. Select the travel card on the left for a macOS region screenshot; drop the resulting native Clipline item in the dashed composer on the right. The resulting image preview and “Screenshot attached” label provide a visible endpoint.

Suggested 12–15 second sequence:

1. Hold the page still for about one second.
2. Capture the left travel card with the native region screenshot interaction.
3. Let Clipline reveal the new item, then drag that item into the right composer.
4. Hold the attached preview for two seconds.

At a browser content viewport of 1440 × 780, the left card starts 48 pixels from the content area's left edge, while the chat occupies the right side. Inspect the live CUA screenshot for the exact card and composer rectangles and add the observed browser chrome/window origin. At narrower widths, layout adapts. Capture the actual native shelf in the recording crop if it appears above or alongside the browser. Do not infer screen coordinates from this document.

Installed recording tools were inspected on 2026-10-10:

- `/usr/sbin/screencapture` advertises `-v` for video, `-V seconds` for fixed duration, `-R x,y,w,h` for a crop, `-k` for click indicators, and `-l windowid` for a specific window. `-h` prints usage and exits 1.
- `/opt/homebrew/bin/ffmpeg` is installed. The helper uses it only after native recording finishes, to produce an H.264 MP4.

After the crop has been reviewed, run:

```sh
zsh scripts/demo/record.sh 0,80,1440,780 /absolute/path/clipline-demo.mp4 15
```

The rectangle above is an example only. The helper requires an explicit rectangle and refuses existing output paths. It retains the original `.mov` and strips audio from the MP4. Native recording duration can differ from the requested `-V` value; inspect the resulting file duration before trimming or adding an end hold. Preparing the fixture does not grant Screen Recording access or alter screenshot preferences. The successful native capture and drag described above were observed in the verification session; a new recording still requires checking its own captured frames and crop.
