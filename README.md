# mpv-spincard

A cinematic **now-playing card** for [mpv](https://mpv.io) — it identifies the
movie or TV episode you're watching and overlays a rich info card built from
your **local Kodi/Emby library artwork and `.nfo` metadata**: poster, dimmed
fanart backdrop, transparent clearlogo title, a **spinning disc**, plus title,
year, ratings (IMDb · Rotten Tomatoes · Metacritic · TMDB), awards, box office,
genres, a scrolling plot, cast, and live file details.

Works **fully offline** from the files next to your media. Optional online lookups
add more: **TMDB** for metadata + a poster/fanart/clearlogo fallback when a title has
no local images, **fanart.tv** for the **disc** and **banner** art TMDB doesn't carry,
and **OMDb** for IMDb / Rotten Tomatoes / Metacritic scores — each off unless you add
its key.

![spincard — Waterworld: a top-left scrolling cast-headshot strip with names and roles, local banner and clearlogo title, poster and a spinning disc, an IMDb · Rotten Tomatoes · Metacritic · TMDB rating row, awards, box office, genres, scrolling plot and tier-coloured tech pills](docs/screenshots/spindisc.png)

![spincard — Mechanic: Resurrection: a scrolling cast-headshot strip, plus TMDB-hosted clearlogo, poster and fanart with no local artwork, an IMDb · Rotten Tomatoes · Metacritic · TMDB rating row, a nomination, box office, genres above a scrolling plot](docs/screenshots/movie.png)

![spincard — Breaking Bad TV episode card: a scrolling cast-headshot strip (profiles merged onto the .nfo cast), banner and clearlogo, S04E01 season progress, IMDb and TMDB rating, air date, genres and plot](docs/screenshots/tv.png)

![spincard — live TV via Tvheadend: current programme, channel, signal/SNR meter, transponder pills and a "Next" list](docs/screenshots/livetv.png)

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
  - **TMDB-hosted fallback** (`remote_art`) — any poster / fanart / clearlogo with
    no local file is fetched from TMDB and cached to disk, so it downloads once.
  - **fanart.tv fallback** (`fanart_tv_api_key`) — TMDB has no disc or banner art, so
    with a free fanart.tv key the **disc** and **banner** are fetched from fanart.tv when
    there's no local `disc.png` / `banner.jpg` (movie-only; cached to disk like the rest).
- **Cast headshots** (`cast_headshots`, off by default) — a separate desktop strip of
  TMDB cast profile photos, top-left under the banner (TMDB-only; cached like the other
  art). Two styles via `casthead_style`: **`static`** (a fixed row with name labels) or
  **`scroll`** (a right→left marquee of all cast faces, each with its name and role labelled
  beneath it). Either way it replaces the card's text cast. By default (`casthead_pause_only`)
  the strip appears **only while paused** (while playing the card just omits the cast), and
  the marquee resumes from where it left off on the next pause.
- **Live file details from mpv** (no external tools): codec · HDR/SDR · fps ·
  resolution · container · size, audio/subtitle languages (channels + forced),
  chapter count, and a **live progress bar** with ETA.
- **Season progress** — `S03E08 (/10)` counted from the season folder.
- **Live TV (Tvheadend)** — playing a Tvheadend stream shows the current
  programme from its EPG: title, channel, plot, a live now-bar with start/end
  times, and a **Next** list of the following programmes. Resolved from
  the stream URL's channel id.
- **Ratings from multiple sources** — a colour-coded ★ **IMDb** headline (via the
  OMDb API) with a right-hand cluster of **TMDB**, **Rotten Tomatoes** and
  **Metacritic** score pills, plus **awards** ("Won 3 Oscars") and **box office**.
  Ratings are dynamic (hourly refresh); even a local `.nfo` card gets live scores.
- **Optional TMDB enrichment** for files without a full `.nfo` — genres, cast,
  director, studio, certification, tagline, runtime — and the TMDB artwork fallback
  above. TMDB needs `api_key`; IMDb / Rotten Tomatoes / Metacritic need
  `omdb_api_key` (independent — set either, both, or neither).
- Bottom-anchored card that grows upward; shows only for real video (not
  images/audio); toggle key; auto-hide; colour-coded star rating; a **scrolling
  synopsis** and cast marquee; and a row of **tier-coloured pill badges** (see
  [Badges](#badges)).

## Layout

Where each building block sits on the mpv output. Every position is a fraction of
the **live output size**, so the layout holds at 1080p, 4K, or in a resized window:

```
  banner ▭                 · fanart backdrop ·                 ▭ poster
  ▪▪▪ cast-headshots (row, under the banner)

  ┌ card — bottom-left, grows upward ─────────────────┐ ◖ disc (top-right corner)
  │ clearlogo · ratings · meta · plot · cast · tech · progress
  └───────────────────────────────────────────────────┘
```

- **banner** — wide title art, top-left (`show_banner`).
- **cast-headshots** — a row of TMDB cast faces under the banner (`cast_headshots`):
  a right→left scrolling marquee (`casthead_style=scroll`) or a static fitted row.
- **poster** — top-right; width capped (`poster_max_width`) so it clears the card.
- **fanart** — dimmed full-frame backdrop, behind everything (shown while paused).
- **card** — the info panel, bottom-left, grows upward; the 3/4 **disc** nestles on
  its **top-right** corner and spins.

Image overlays draw **above** the ASS text, so the layers stack back-to-front as
`fanart → poster → banner → clearlogo → disc → cast-headshots`. That's why the fanart
is dimmed (it tints the card) while the poster, disc, and faces stay clear of it.

The card's own top-to-bottom anatomy (a fully-populated **movie** card — a TV episode
or TMDB-only card shows fewer rows; the `│` is the gold accent edge):

```
  ┌──────────────────────────────────────────◖ disc (top-right corner)
  │ CLEARLOGO            (title art, or plain title text)
  │ 1995 · tagline
  │ ★★★☆☆ IMDb 8.0 (223k)   [TMDB] [RT] [MC]      rating row
  │ runtime · cert · $box office · director · studio
  │ genres                              ★ awards   (one row: genres L, award R)
  │ plot / synopsis                               (scrolls)
  │ cast — Name (Role)      (scrolls; replaced by the headshot strip when on)
  │ [4K][HDR][HEVC][7.1][fps]                     tier-coloured tech pills
  │ Audio · Subs · chapters · size
  │ ▓▓▓▓▓▓░░░  1:42:10 / 2:44:00  [23:50]         live progress
  └──────────────────────────────────────────
```

## Requirements

- **mpv** built with Lua (LuaJIT or Lua 5.1/5.2).
- **ffmpeg** on `PATH` — for the poster / fanart / clearlogo / disc images.
- **curl** — only for the online features: TMDB (`api_key`), OMDb (`omdb_api_key`),
  the TMDB artwork fallback (`remote_art`), fanart.tv disc/banner (`fanart_tv_api_key`),
  or Tvheadend (`tvheadend_url`).

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
pos_x=22  pos_y=22     # margin in a 1280x720 virtual space (~3%, matches the banner inset)

show_poster=yes   poster_height=0.42   poster_margin=0.02
show_fanart=yes   fanart_opacity=0.25   fanart_pause_only=yes   # dimmed backdrop, shown while paused
show_logo=yes     logo_height=0.12
remote_art=yes    # fetch poster/fanart/clearlogo from TMDB when there's no local file (cached to disk)
show_disc=yes     disc_size=0.22
disc_spin=yes     disc_spin_secs=5   disc_spin_frames=96
show_banner=yes   banner_height=0.10   # wide banner.jpg top-left (if present)
fanart_tv_api_key=                       # fanart.tv key: fetch movie disc + banner when no local file (movie-only)
show_tech=yes     # codec/HDR/audio/subs/chapters + live progress
overview_scroll=yes  overview_lines=4  overview_scroll_mode=smooth   # synopsis: smooth glide (or "line")
cast_headshots=no  casthead_style=scroll  casthead_max=10  casthead_pause_only=yes   # cast photo strip; shown while paused (scroll | static)

enrich=yes   api_key=   omdb_api_key=   language=en-US   # TMDB + OMDb (optional; empty = local only)
rating_ttl=3600                          # refresh IMDb/TMDB ratings when older than this (s); 0 = off
tvheadend_url=                           # live-TV EPG (e.g. http://127.0.0.1:9981)
live_upcoming=7                          # live TV: "Next" programmes to list (0 = none)
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

Missing artwork is fetched online when the keys are set: **poster / fanart / clearlogo**
from **TMDB** (`remote_art`, on by default), and the **disc + banner** — which TMDB
doesn't provide — from **fanart.tv** (`fanart_tv_api_key`, movie-only). Both only kick in
when the local file is absent, and each download is cached under `~/.cache/spincard/img/`
so a title is fetched once.

## Live TV (Tvheadend)

Point spincard at your [Tvheadend](https://tvheadend.org) server and a live-TV
stream becomes a now-playing card built from Tvheadend's EPG — current
programme title, channel, plot, a live progress bar (start/end times, when it
ends) and a **Next** list of the following programmes (three by default;
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

## Badges

![Sample tech badge row — 4K · HDR10 in gold, HEVC · 5.1 in green, AC3 · 23.976FPS in grey](docs/screenshots/badges.png)

The card's tech line is a row of **pill badges** summarising the stream. The six
file-detail pills are **tier-coloured** — the colour tells you how good each spec
is at a glance:

```
Tier   │ Meaning       │ Examples
───────┼───────────────┼────────────────────────────────────
gold   │ premium       │ 4K · HDR10 · TrueHD/FLAC · 7.1
green  │ good / modern │ 1080p · HEVC/AV1 · EAC3/AAC/DTS · 5.1
grey   │ standard      │ 720p · H264 · AC3 · Stereo · frame rate
dim    │ legacy / low  │ SD · MPEG2/VC1 · MP3 · Mono
```

The badges, and how each value maps to a tier:

```
Badge        │ Values → tier
─────────────┼──────────────────────────────────────────────────────────
Resolution   │ 4K(gold) · 1080p(green) · 720p(grey) · SD(dim)
HDR          │ HDR10 · HLG — always gold
Video codec  │ HEVC/AV1/VP9(green) · H264(grey) · MPEG2/VC1/WMV3(dim)
Audio codec  │ TrueHD/FLAC/ALAC(gold) · EAC3/AAC/Opus/DTS(green) ·
             │ AC3/PCM(grey) · MP3/MP2/WMA(dim)
Channels     │ 7.1(gold) · 5.1(green) · Stereo(grey) · Mono(dim)
Frame rate   │ e.g. 24FPS · 23.976FPS · 50FPS — grey
```

An unrecognised codec defaults to **grey**, never dim — a codec newer than the
list won't be mislabelled as legacy.

Two more pill sets carry **fixed** colours (identity/category, not quality):

```
Rating row   │ IMDb (gold, the headline) + a right-aligned cluster of TMDB (blue) ·
             │ Rotten Tomatoes (red) · Metacritic (green) score pills
Live-TV mux  │ delivery system (DVB-S2…) + modulation (8PSK…) in card gold;
             │ polarisation V/H in blue/violet
```

## How it works

`identify.lua` parses the path → `nfo.lua` reads the sidecar → `main.lua` draws
the card (ASS via `osd-overlay`) and the artwork (BGRA via `overlay-add`, decoded
by ffmpeg). The disc spin packs rotation frames into one file and cycles the
overlay byte-offset. Live file details come straight from mpv properties. Optional
TMDB / OMDb / fanart.tv lookups and the remote-artwork downloads run as async `curl`
subprocesses, cached under `~/.cache/spincard/` so a title is only fetched once.

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
