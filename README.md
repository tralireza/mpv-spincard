# mpv-spincard

A cinematic **now-playing card** for [mpv](https://mpv.io) — it identifies the
movie or TV episode you're watching and overlays a rich info card built from
your **local Kodi/Emby library artwork and `.nfo` metadata**: poster, dimmed
fanart backdrop, transparent clearlogo title, a **spinning disc**, plus title,
year, rating, genres, plot, cast, and live file details.

Runs **fully offline** — everything comes from the files next to your media.
Online lookup (TMDB) is optional and off unless you add a key.

![spincard — clearlogo, poster, fanart backdrop and a spinning disc](docs/screenshots/spindisc.png)

![spincard — rich .nfo metadata card](docs/screenshots/movie.png)

![spincard — TV episode card (season progress, air date, cast)](docs/screenshots/tv.png)

## Features

- **Identifies content from the full path** — `SxxEyy` ⇒ TV, else movie; a
  `/Movies/` path never gets mistaken for TV.
- **Local `.nfo` as the primary source** (Kodi/Emby `<movie>` / `<episodedetails>`):
  title, year, plot, rating, runtime, genres, cast, director, studio, air date.
- **Artwork from the media folder** (Kodi/Emby naming), decoded with ffmpeg:
  - **Poster** (`poster.jpg` / `folder.jpg` / `<name>.jpg`), top-right.
  - **Fanart** backdrop (`fanart.jpg` / `backdrop.jpg`), dimmed, full-frame.
  - **Clearlogo** (`clearlogo.png`) as the title, in the card's title slot.
  - **Disc** (`disc.png`) — a 3/4 disc nestled at the card's corner that **spins**.
- **Live file details from mpv** (no external tools): codec · HDR/SDR · fps ·
  resolution · container · size, audio/subtitle languages (channels + forced),
  chapter count, and a **live progress bar** with ETA.
- **Season progress** — `S03E08 (/10)` counted from the season folder.
- **Live TV (Tvheadend)** — playing a Tvheadend stream shows the current
  programme from its EPG: title, channel, plot, a live now-bar with start/end
  times, and an **Up next** list of the following programmes. Resolved from
  the stream URL's channel id.
- **Optional TMDB** enrichment for files without a full `.nfo` (needs an API key).
- Bottom-anchored card that grows upward; shows only for real video (not
  images/audio); toggle key; auto-hide; colour-coded star rating; pill badges.

## Requirements

- **mpv** built with Lua (LuaJIT or Lua 5.1/5.2).
- **ffmpeg** on `PATH` — for the poster / fanart / clearlogo / disc images.
- **curl** — only if you enable TMDB (`api_key`) or Tvheadend (`tvheadend_url`).

## Install

Copy the script directory and config into your mpv config dir
(`~/.config/mpv`, or the legacy `~/.mpv`):

```sh
cp -r scripts/spincard          ~/.config/mpv/scripts/
cp    script-opts/spincard.conf ~/.config/mpv/script-opts/
```

Bind a toggle key in `~/.config/mpv/input.conf` — use a **plain** key (over
tmux/SSH, `Ctrl+<letter>` collides with Tab/Enter/Esc):

```
c script-binding spincard/toggle
```

Or push to a remote host with the included helper:

```sh
./deploy.sh myhost      # rsyncs scripts/spincard → myhost:~/.mpv/scripts/spincard
```

Restart mpv and play something with artwork/`.nfo` beside it.

## Configuration

All options live in `script-opts/spincard.conf`:

```
auto_show=yes          # show the card when a file opens
duration=7             # auto-show timeout in seconds (0 = until toggled)
toggle_timeout=17      # toggle-key auto-close (0 = until toggled)
show_on_pause=no       # pop the card while paused, hide on resume

anchor=bottom          # "bottom" (hug bottom, grow up) or "top"
pos_x=40  pos_y=40     # margin in a 1280x720 virtual space

show_poster=yes   poster_height=0.42   poster_margin=0.02
show_fanart=yes   fanart_opacity=0.4
show_logo=yes     logo_height=0.12
show_disc=yes     disc_size=0.22
disc_spin=yes     disc_spin_secs=2.5   disc_spin_frames=64
show_banner=no    banner_height=0.10
show_tech=yes     # codec/HDR/audio/subs/chapters + live progress

enrich=yes   api_key=   language=en-US   # TMDB (optional; empty = local only)
tvheadend_url=                           # live-TV EPG (e.g. http://127.0.0.1:9981)
live_upcoming=3                          # live TV: "Up next" programmes to list (0 = none)
```

## Library layout (Kodi / Emby)

spincard reads standard Kodi/Emby sidecars next to each file:

```
Movies/Blade Runner 2049 (2017)/
  Blade Runner 2049 (2017).mkv
  Blade Runner 2049 (2017).nfo          <movie> …
  poster.jpg  fanart.jpg  clearlogo.png  disc.png

TV/Breaking Bad/
  poster.jpg  fanart.jpg  clearlogo.png
  Season.4/
    Breaking.Bad.S04E07.Problem.Dog.mkv
    Breaking.Bad.S04E07.Problem.Dog.nfo   <episodedetails> …
```

No `.nfo`? The card falls back to the parsed filename (and TMDB, if a key is set).

## Live TV (Tvheadend)

Point spincard at your [Tvheadend](https://tvheadend.org) server and a live-TV
stream becomes a now-playing card built from Tvheadend's EPG — current
programme title, channel, plot, a live progress bar (start/end times, when it
ends) and an **Up next** list of the following programmes (three by default;
set `live_upcoming`).

```
tvheadend_url=http://127.0.0.1:9981
live_upcoming=3
```

It activates whenever the played URL is a Tvheadend stream (`…/stream/channel…`).
The channel is resolved from the URL's `channelid` via Tvheadend's own playlist
(`/playlist/channels`, where `tvg-id` is the channel UUID), falling back to the
channel name (mpv's `media-title`). Only the EPG is read — no artwork or TMDB
lookups for live TV. If your server needs auth, embed it in the URL
(`http://user:pass@host:9981`).

## How it works

`identify.lua` parses the path → `nfo.lua` reads the sidecar → `main.lua` draws
the card (ASS via `osd-overlay`) and the artwork (BGRA via `overlay-add`, decoded
by ffmpeg). The disc spin packs rotation frames into one file and cycles the
overlay byte-offset. Live file details come straight from mpv properties.

## Notes

- mpv draws image overlays **above** ASS text, so the fanart backdrop tints the
  card (kept dim); poster/disc sit clear of the text.
- Tuned to be light on low-end GPUs — every animation/section is opt-out.
  `disc_spin_secs` / `disc_spin_frames` trade smoothness for load; on mpv < 0.42
  the frame file is kept small.
- spincard only **reads** your library — artwork/metadata come from your media
  manager's output; nothing is written back.

## Screenshots

Capture from mpv itself so the overlays are included — in `input.conf` or the
console (`` ` ``):

```
screenshot window     # grabs the window incl. OSD/overlays
```

## License

MIT — see [LICENSE](LICENSE).
