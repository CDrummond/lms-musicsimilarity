package Plugins::MusicSimilarity::Settings;

#
# LMS Music Similarity
#
# (c) 2020-2021 Craig Drummond
#
# Licence: GPL v3
#

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.musicsimilarity',
	'defaultLevel' => 'ERROR',
});

my $prefs = preferences('plugin.musicsimilarity');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('MUSICSIMILARITY');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/MusicSimilarity/settings/musicsimilarity.html');
}

sub prefs {
	return ($prefs, qw(host port filter_genres filter_xmas exclude_artists exclude_albums min_duration max_duration no_repeat_artist no_repeat_album no_repeat_track dstm_tracks genre_groups));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;
	return $class->SUPER::handler($client, $params);
}

1;

__END__
