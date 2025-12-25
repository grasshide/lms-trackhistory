package Plugins::TrackHistory::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.trackhistory');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_TRACKHISTORY');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/TrackHistory/settings/basic.html');
}

sub prefs {
	return ($prefs,
		'enabled',
		'min_track_secs',
		'played_percent',
		'include_remote',
	);
}

1;

__END__


