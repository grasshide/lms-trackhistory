package Plugins::TrackHistory::Plugin;

# Lyrion Music Server - TrackHistory
# Records tracks which have been played into persist.db (attached as "persistentdb").
#
# Inspired by the historical TrackStat plugin (erland/lms-trackstat):
# https://github.com/erland/lms-trackstat/

use strict;
use warnings;
use utf8;
use base qw(Slim::Plugin::Base);

use Digest::MD5 qw(md5_hex);
use Scalar::Util qw(blessed);
use Time::HiRes ();

use Slim::Player::Playlist;
use Slim::Player::ProtocolHandlers;
use Slim::Player::Source;
use Slim::Player::Sync;
use Slim::Control::Request;
use Slim::Music::Import;
use Slim::Schema;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

if ( main::WEBUI ) {
	require Plugins::TrackHistory::Settings;
}

my $prefs = preferences('plugin.trackhistory');

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.trackhistory',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_TRACKHISTORY',
});

my $schemaReady;
my @pendingInserts;
my $flushScheduled;

sub getDisplayName {
	return 'PLUGIN_TRACKHISTORY';
}

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin();

	if ( main::WEBUI ) {
		Plugins::TrackHistory::Settings->new;
	}

	$prefs->init({
		enabled         => 1,
		min_track_secs  => 30,
		played_percent  => 50,
		include_remote  => 0,
	});

	Slim::Control::Request::subscribe(
		\&newsongCallback,
		[['playlist'], ['newsong']],
	);

	# Flush queued DB writes once scanning is done (this event is emitted by LMS).
	Slim::Control::Request::subscribe(
		\&_onRescanDone,
		[['rescan'], ['done']],
	);
}

sub shutdownPlugin {
	Slim::Control::Request::unsubscribe(\&newsongCallback);
	Slim::Control::Request::unsubscribe(\&_onRescanDone);
}

sub _onRescanDone {
	# try to flush any deferred inserts once scanning is done
	_flushPendingInserts();
}

sub _scheduleFlush {
	my ($delay) = @_;
	$delay ||= 5;

	return if $flushScheduled;
	$flushScheduled = 1;

	Slim::Utils::Timers::setTimer(
		undef,
		Time::HiRes::time() + $delay,
		sub {
			$flushScheduled = 0;
			_flushPendingInserts();
		},
	);
}

sub _flushPendingInserts {
	return if !@pendingInserts;

	# Don't attempt writes while scanner is running (VirtualLibraries uses the same signal).
	if ( Slim::Music::Import->stillScanning ) {
		_scheduleFlush(10);
		return;
	}

	return unless _ensureSchema();

	my $dbh = Slim::Schema->dbh;
	return unless $dbh;

	my $sql = qq{
		INSERT INTO persistentdb.track_history
		(url, urlmd5, musicbrainz_id, played, rating, client_id)
		VALUES (?, ?, ?, ?, ?, ?)
	};

	my @remaining;

	for my $row (@pendingInserts) {
		my $ok = eval {
			my $sth = $dbh->prepare_cached($sql);
			$sth->execute(
				$row->{url},
				$row->{urlmd5},
				$row->{musicbrainz_id},
				$row->{played},
				$row->{rating},
				$row->{client_id},
			);
			1;
		};

		if ( !$ok ) {
			my $err = $@ || '';

			# If DB is locked, keep it and retry later.
			if ( $err =~ /database is locked/i ) {
				push @remaining, $row;
				next;
			}

			# For other errors, drop the row (otherwise we'd loop forever).
			$log->error("Failed to flush track_history row (dropping): $err");
		}
	}

	@pendingInserts = @remaining;

	# If anything left (eg. locked), retry later.
	if (@pendingInserts) {
		_scheduleFlush(10);
	}
}

sub _queueInsert {
	my ($row) = @_;
	return unless $row && ref $row eq 'HASH';

	# Keep queue bounded to avoid unbounded growth if DB stays locked forever.
	if ( @pendingInserts > 5000 ) {
		shift @pendingInserts;
	}

	push @pendingInserts, $row;
	_scheduleFlush(10);
}

sub newsongCallback {
	my $request = shift;
	my $client  = $request->client() || return;

	return unless $prefs->get('enabled');

	# If synced, only listen to the master to avoid duplicate entries.
	if ( $client->isSynced() ) {
		return unless Slim::Player::Sync::isMaster($client);
	}

	# Clear any previous timers for this client.
	Slim::Utils::Timers::killTimers($client, \&_checkPlayed);

	my $url = Slim::Player::Playlist::url($client) || return;

	my $track = Slim::Schema->objectForUrl({ url => $url });
	return unless $track;

	# Build metadata (especially important for remote tracks).
	my $meta = _getMetaFor($client, $track, $url);

	# Ignore station-title "newsong" notifications (no duration + playlist index param).
	if ( !( $meta->{duration} || 0 ) && defined $request->getParam('_p3') ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Ignoring station title newsong notification');
		return;
	}

	# Ignore very short tracks early.
	my $minTrackSecs = _num($prefs->get('min_track_secs'), 30);
	if ( ($meta->{duration} || 0) && ($meta->{duration} < $minTrackSecs) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Ignoring short track ($meta->{duration}s) for url=$url");
		return;
	}

	# Ignore remote tracks if disabled.
	if ( $meta->{remote} && !$prefs->get('include_remote') ) {
		return;
	}

	# Determine when to consider this track "played".
	my $checktime = _playedThresholdSeconds($meta->{duration});

	# If we don't have a usable duration, record immediately (best effort).
	if ( !$checktime ) {
		_recordPlay($client, $track, $meta, {
			checktime => 0,
		});
		return;
	}

	# Cache state for this play instance on the master client.
	my $master = $client->master;
	$master->pluginData(
		trackhistory_started_at           => time(),
		trackhistory_url                  => $url,
		trackhistory_playlist_change_time => int($client->currentPlaylistChangeTime() || 0),
	);

	Slim::Utils::Timers::setTimer(
		$client,
		Time::HiRes::time() + $checktime,
		\&_checkPlayed,
		$track,
		$meta,
		$checktime,
	);
}

sub _checkPlayed {
	my ( $client, $track, $meta, $checktime ) = @_;
	return unless $client && $track;

	return unless $prefs->get('enabled');

	# Still the same track?
	my $cururl = Slim::Player::Playlist::url($client) || return;
	return if $cururl ne ($meta->{url} || $track->url);

	# Still the same play instance?
	my $master = $client->master;
	my $expectedChangeTime = int($master->pluginData('trackhistory_playlist_change_time') || 0);
	my $curChangeTime      = int($client->currentPlaylistChangeTime() || 0);
	return if $expectedChangeTime && $curChangeTime && $expectedChangeTime != $curChangeTime;

	# Has the user paused?
	my $songtime = Slim::Player::Source::songTime($client) || 0;
	if ( $songtime < $checktime ) {
		my $diff = $checktime - $songtime;
		Slim::Utils::Timers::killTimers($client, \&_checkPlayed);
		Slim::Utils::Timers::setTimer(
			$client,
			Time::HiRes::time() + $diff,
			\&_checkPlayed,
			$track,
			$meta,
			$checktime,
		);
		return;
	}

	_recordPlay($client, $track, $meta, {
		checktime => $checktime,
	});
}

sub _recordPlay {
	my ( $client, $track, $meta, $opts ) = @_;
	$opts ||= {};

	# Don't attempt DB writes while scanner is running; queue and retry later.
	if ( Slim::Music::Import->stillScanning ) {
		# Still do dedup bookkeeping to avoid repeated queueing for the same play instance.
		my $master     = $client->master;
		my $changeTime = int($master->pluginData('trackhistory_playlist_change_time') || $client->currentPlaylistChangeTime() || 0);
		$master->pluginData(trackhistory_last_recorded => {
			playlist_change_time => $changeTime,
			url                  => ($meta->{url} || $track->url),
		});

		# Build row now (rating/urlmd5 etc. at time of "played").
		my $url      = ($meta->{url} || $track->url);
		my $urlmd5   = eval { $track->urlmd5 } || md5_hex($url);
		my $mbid     = eval { $track->musicbrainz_id } || undef;
		my $rating   = eval { $track->rating };
		my $playedAt = time();

		_queueInsert({
			url           => $url,
			urlmd5        => $urlmd5,
			musicbrainz_id=> $mbid,
			played        => $playedAt,
			rating        => $rating,
			client_id     => $client->id,
		});

		return;
	}

	return unless _ensureSchema();

	my $dbh = Slim::Schema->dbh;
	return unless $dbh;

	my $master = $client->master;
	my $started_at = int($master->pluginData('trackhistory_started_at') || time());
	my $played_at  = time();
	my $changeTime = int($master->pluginData('trackhistory_playlist_change_time') || $client->currentPlaylistChangeTime() || 0);

	# Avoid duplicates if multiple callbacks fire.
	my $lastRecorded = $master->pluginData('trackhistory_last_recorded') || {};
	if ( ref $lastRecorded eq 'HASH' ) {
		if ( ($lastRecorded->{playlist_change_time} || 0) == $changeTime && ($lastRecorded->{url} || '') eq ($meta->{url} || $track->url) ) {
			return;
		}
	}

	my $url = ($meta->{url} || $track->url);

	# TrackStat-compatible fields (see wiki link in README/description):
	# url, urlmd5, musicbrainz_id, played, rating.
	my $urlmd5 = eval { $track->urlmd5 } || md5_hex($url);
	my $mbid   = eval { $track->musicbrainz_id } || undef;
	my $rating = eval { $track->rating };

	my $sql = qq{
		INSERT INTO persistentdb.track_history
		(url, urlmd5, musicbrainz_id, played, rating, client_id)
		VALUES (?, ?, ?, ?, ?, ?)
	};

	eval {
		my $sth = $dbh->prepare_cached($sql);
		$sth->execute(
			$url,
			$urlmd5,
			$mbid,
			$played_at,
			$rating,
			$client->id,
		);
	};

	if ( $@ ) {
		# If DB is locked (eg. scanner has a long-running write txn), queue and retry.
		if ( $@ =~ /database is locked/i ) {
			_queueInsert({
				url            => $url,
				urlmd5         => $urlmd5,
				musicbrainz_id => $mbid,
				played         => $played_at,
				rating         => $rating,
				client_id      => $client->id,
			});
			return;
		}

		$log->error("Failed to write track_history row: $@");
		return;
	}

	$master->pluginData(trackhistory_last_recorded => {
		playlist_change_time => $changeTime,
		url                  => ($meta->{url} || $track->url),
	});

	main::INFOLOG && $log->is_info && $log->info("Recorded play: " . ($meta->{title} || eval { $track->title } || $track->url));
}

sub _ensureSchema {
	return 1 if $schemaReady;
	return if defined $schemaReady && $schemaReady < 0;

	my $dbh = Slim::Schema->dbh;
	return if !$dbh;

	# Verify the persistent DB is attached (SQLiteHelper does this for SQLite library DBs).
	eval { $dbh->do('SELECT name FROM persistentdb.sqlite_master LIMIT 1') };
	if ( $@ ) {
		$log->warn("persistentdb is not available (not SQLite or not attached). TrackHistory will be inactive: $@");
		$schemaReady = -1;
		return;
	}

	eval {
		# TrackStat wiki describes these core fields:
		# url, urlmd5, musicbrainz_id, played, rating.
		# https://wiki.lyrion.org/index.php/TrackStat_plugin.html#track_history
		#
		# We keep the following extras: client_id.
		$dbh->do(q{
			CREATE TABLE IF NOT EXISTS persistentdb.track_history (
				id INTEGER PRIMARY KEY AUTOINCREMENT,
				url text NOT NULL,
				musicbrainz_id varchar(40),
				played int(10),
				rating int(10),
				urlmd5 char(32) NOT NULL default '0',
				client_id text
			)
		});
	};

	if ( $@ ) {
		$log->error("Failed to initialize persistentdb.track_history schema: $@");
		$schemaReady = -1;
		return;
	}

	# Ensure required columns exist on older installs (SQLite won't change an existing
	# table definition created by other plugins/older versions).
	eval {
		my $cols = $dbh->selectall_arrayref(
			q{PRAGMA persistentdb.table_info(track_history)}
		) || [];

		my %have;
		for my $row ( @{$cols} ) {
			# PRAGMA table_info returns: cid, name, type, notnull, dflt_value, pk
			my $name = $row->[1];
			$have{$name} = 1 if defined $name && length $name;
		}

		if ( !$have{client_id} ) {
			$dbh->do(q{ALTER TABLE persistentdb.track_history ADD COLUMN client_id text});
		}
	};

	if ( $@ ) {
		$log->error("Failed to migrate persistentdb.track_history schema: $@");
		$schemaReady = -1;
		return;
	}

	# TrackStat-friendly indexes (no UNIQUE).
	eval {
		$dbh->do(q{
			CREATE INDEX IF NOT EXISTS persistentdb.tshurlIndex
			ON track_history (url)
		});

		$dbh->do(q{
			CREATE INDEX IF NOT EXISTS persistentdb.tshmusicbrainzIndex
			ON track_history (musicbrainz_id)
		});
	};

	$schemaReady = 1;

	return 1;
}

sub _getMetaFor {
	my ( $client, $track, $url ) = @_;

	my $meta = {
		url      => $url,
		duration => eval { $track->secs } || undef,
		title    => eval { $track->title } || undef,
		artist   => eval { $track->artistName } || undef,
		album    => eval { $track->albumname } || undef,
		remote   => eval { $track->remote } ? 1 : 0,
	};

	if ( $meta->{remote} ) {
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);

		if ( $handler && $handler->can('getMetadataFor') ) {
			my $hmeta = $handler->getMetadataFor($client, $url, 'forceCurrent') || {};

			# Only overwrite if present; remote handlers can provide better data.
			$meta->{title}    = $hmeta->{title}    if $hmeta->{title};
			$meta->{artist}   = $hmeta->{artist}   if $hmeta->{artist};
			$meta->{album}    = $hmeta->{album}    if $hmeta->{album};
			$meta->{duration} = $hmeta->{duration} if $hmeta->{duration};
		}
	}

	return $meta;
}

sub _playedThresholdSeconds {
	my ($duration) = @_;
	$duration = _num($duration, 0);
	return 0 if !$duration;

	my $percent = int(_num($prefs->get('played_percent'), 50));
	$percent = 50 if $percent <= 0 || $percent > 100;

	my $byPercent = int($duration * ($percent / 100));
	$byPercent = 1 if $byPercent < 1;

	return $byPercent;
}

sub _num {
	my ( $v, $default ) = @_;
	return $default if !defined $v;
	return $default if $v !~ /^-?(?:\d+(?:\.\d+)?)$/;
	return $v + 0;
}

1;

__END__


