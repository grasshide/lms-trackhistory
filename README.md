# TrackHistory (Lyrion Music Server plugin)

TrackHistory records played tracks into LMS' persistent SQLite database (`persist.db`) in a `track_history` table (TrackStat-compatible), including the **client id** which played the track.

## Features

- Records a play once a track has been played long enough (configurable threshold)
- Optional recording of remote/radio tracks (disabled by default)
- Stores plays in `persist.db` (attached by LMS as `persistentdb`)
- Keeps TrackStat-style columns, plus `client_id`

## Database schema

The plugin ensures the table exists and will **add the `client_id` column if it is missing**.

```sql
CREATE TABLE persistentdb.track_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  url text NOT NULL,
  musicbrainz_id varchar(40),
  played int(10),
  rating int(10),
  urlmd5 char(32) NOT NULL default '0',
  client_id text
);
CREATE INDEX persistentdb.tshurlIndex on track_history (url);
CREATE INDEX persistentdb.tshmusicbrainzIndex on track_history (musicbrainz_id);
```

## Installation

This repository is laid out like other LMS plugins (eg. RatingsLight).

- Download the repository as a zip (or clone it).
- Copy the `TrackHistory/` folder into your LMS plugins folder (eg. `Plugins/TrackHistory/` in the LMS preferences directory).
- Restart LMS.
- Enable the plugin in `LMS > Settings > Manage Plugins`.

## Settings

`LMS > Settings > Advanced > Track History`

- Enable/disable recording
- Minimum track duration (seconds)
- Played threshold (%)
- Include remote/radio tracks


## Dev

Create a release:
```bash
VERSION="1.0"
zip -r "TrackHistory-${VERSION}.zip" TrackHistory
shasum -a 1 "TrackHistory-${VERSION}.zip"
````


## License

GPL-3.0 (see `LICENSE`).