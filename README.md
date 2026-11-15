# The Shape of a Class (iOS)

A SwiftUI app for slow flow teachers: the energy arc, the six-week rotation, a one-page class plan, a playlist builder that checks the music against the arc, and an in-class timer.

## Run it on your iPhone

1. You need Xcode 16 or newer on your Mac.
2. Double-click `ShapeOfAClass.xcodeproj`.
3. Click the ShapeOfAClass project in the sidebar. Under Signing & Capabilities, choose your Apple ID as the Team. A free Apple ID works for your own phone.
4. Plug in your iPhone, pick it as the run destination, and press Run.
5. The first time, on the phone go to Settings > General > VPN & Device Management and trust your developer profile.

Requires iOS 17. Data stays on the phone.

## What's in it

- **Teach**: start class, see the current phase, time left, BPM band, countdown to the peak, the planned track playing now, and your note for that phase. The screen stays awake, and the phone taps when the phase changes.
- **Arc**: the intensity curve and all seven phases for 60 or 75 minutes.
- **Weeks**: the rotation, with the current week marked. Each week has a class plan and a playlist.
- **Playlist**: tracks grouped by phase. It flags a playlist shorter than class plus five minutes, music changes that land more than a minute off a phase boundary, and an empty peak.
- **Guide**: the playlist rules, a music licensing note, the cautions, and the date your rotation started.

## Recording a class

- On **Teach**, turn on **Record my voice**, then tap **Start class and record**.
- Only your voice is recorded. Phase changes and planned track changes are logged with timestamps.
- Use a clip-on mic or AirPods so the room's speakers stay out of the recording. Keep the app open during class.
- When you tap **End**, the class is saved to **Classes** and your cues are transcribed on the phone.
- In **Classes**, play it back with the arc, current phase, the track to play, and your cues highlighted in sync. Tap any cue to jump there. Share the cue sheet from the ••• menu.

## Recording video

- On **Teach**, set **Record** to **Video**. Allow camera and microphone access.
- Choose **1080p** or **4K** and **Landscape** or **Portrait**, then frame your mat using the live preview.
- The mic check shows which mic is in use and its level. A wireless clip-on mic keeps the speakers out.
- The storage line estimates space for a full class. 4K uses roughly 3x the space of 1080p.
- Pausing class keeps the camera rolling; the timeline stays in sync. Keep the phone plugged in and the app open.
- Recorded videos appear in **Classes** with synced phases, tracks and transcribed cues.
- The simulator has no camera. Test video on a real iPhone.

## Spotify pilot

1. Go to developer.spotify.com/dashboard and create an app (Premium account required).
2. Select **Web API**. Add the redirect URI `shapeofaclass://spotify-callback`.
3. Under **User Management**, add the Spotify email of each pilot teacher (5 people total, including you).
4. Copy the **Client ID**. In the app, open **Guide > Spotify (pilot)**, paste it, and tap **Connect Spotify**.
5. In **Weeks > a week > Playlist**, tap the import icon and pick one of your own playlists. Songs are placed into phases by length.
6. On **Teach**, pick the device to play on (open Spotify first so it shows up) and start class. Music starts, pauses and ends with class, and skips ahead at phase changes if it's running behind.

Spotify only shares the songs in playlists you own or collaborate on. It doesn't work in the simulator; use a real iPhone with the Spotify app installed.
