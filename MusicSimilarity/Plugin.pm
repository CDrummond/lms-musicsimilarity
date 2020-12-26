package Plugins::MusicSimilarity::Plugin;

#
# LMS Music Similarity
#
# (c) Craig Drummond, 2020
#
# Licence: GPL v3
#

use strict;

use Scalar::Util qw(blessed);
use LWP::UserAgent;
use JSON::XS::VersionOneAndTwo;
use File::Basename;
use File::Slurp;

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Prefs;

if ( main::WEBUI ) {
    require Plugins::MusicSimilarity::Settings;
}

use Plugins::MusicSimilarity::Settings;

my $initialized = 0;
my $NUM_TRACKS_TO_USE = 5;
my $NUM_SEED_TRACKS = 5;
my $MAX_PREVIOUS_TRACKS = 200;
my $NUM_MIX_TRACKS = 50;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.musicsimilarity',
    'defaultLevel' => 'ERROR',
    'logGroups'    => 'SCANNER',
});

my $prefs = preferences('plugin.musicsimilarity');

sub shutdownPlugin {
    $initialized = 0;
}

sub initPlugin {
    my $class = shift;

    return 1 if $initialized;

    $prefs->init({
        filter_genres   => 1,
        filter_xmas     => 1,
        exclude_artists => '',
        exclude_albums  => '',
        port            => 11000,
        min_duration    => 0,
        max_duration    => 0
    });

    if ( main::WEBUI ) {
        Plugins::MusicSimilarity::Settings->new;
    }

    # 'Create similarity mix'....
    Slim::Control::Request::addDispatch(['musicsimilarity', 'mix'], [1, 1, 1, \&cliMix]);

    Slim::Menu::TrackInfo->registerInfoProvider( musicsimilarity => (
        above    => 'favorites',
        func     => \&trackInfoHandler,
    ) );

    Slim::Menu::AlbumInfo->registerInfoProvider( musicsimilarity => (
        below    => 'addalbum',
        func     => \&albumInfoHandler,
    ) );

    Slim::Menu::ArtistInfo->registerInfoProvider( musicsimilarity => (
        below    => 'addartist',
        func     => \&artistInfoHandler,
    ) );

    Slim::Menu::GenreInfo->registerInfoProvider( musicsimilarity => (
        below    => 'addgenre',
        func     => \&genreInfoHandler,
    ) );
    #...

    $initialized = 1;
    return $initialized;
}

sub postinitPlugin {
    my $class = shift;

    # if user has the Don't Stop The Music plugin enabled, register ourselves
    if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
        require Slim::Plugin::DontStopTheMusic::Plugin;
        Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('MUSICSIMILARITY_MIX', sub {
            my ($client, $cb) = @_;

            my $seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, $NUM_SEED_TRACKS);
            my $tracks = [];

            # don't seed from radio stations - only do if we're playing from some track based source
            # Get list of valid seeds...
            if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
                my @seedIds = ();
                my @seedsToUse = ();
                foreach my $seedTrack (@$seedTracks) {
                    my ($trackObj) = Slim::Schema->find('Track', $seedTrack->{id});
                    if ($trackObj) {
                        main::DEBUGLOG && $log->debug("Seed " . $trackObj->path . " id:" . $seedTrack->{id});
                        push @seedsToUse, $trackObj;
                        push @seedIds, $seedTrack->{id};
                    }
                }

                if (scalar @seedsToUse > 0) {
                    my $previousTracks = _getPreviousTracks($client, \@seedIds, $MAX_PREVIOUS_TRACKS);
                    main::DEBUGLOG && $log->debug("Num tracks to previous: " . ($previousTracks ? scalar(@$previousTracks) : 0));

                    my $jsonData = _getMixData(\@seedsToUse, $previousTracks ? \@$previousTracks : undef, $NUM_TRACKS_TO_USE, 1);
                    my $port = $prefs->get('port') || 11000;
                    my $url = "http://localhost:$port/api/similar";
                    Slim::Networking::SimpleAsyncHTTP->new(
                        sub {
                            my $response = shift;
                            main::DEBUGLOG && $log->debug("Received API response");

                            my @songs = split(/\n/, $response->content);
                            my $count = scalar @songs;
                            my $tracks = ();

                            for (my $j = 0; $j < $count; $j++) {
                                # Bug 4281 - need to convert from UTF-8 on Windows.
                                if (main::ISWINDOWS && !-e $songs[$j] && -e Win32::GetANSIPathName($songs[$j])) {
                                    $songs[$j] = Win32::GetANSIPathName($songs[$j]);
                                }

                                if ( -e $songs[$j] || -e Slim::Utils::Unicode::utf8encode_locale($songs[$j]) || index($songs[$j], 'file:///')==0) {
                                    push @$tracks, Slim::Utils::Misc::fileURLFromPath($songs[$j]);
                                } else {
                                    $log->error('API attempted to mix in a song at ' . $songs[$j] . ' that can\'t be found at that location');
                                }
                            }

                            main::DEBUGLOG && $log->debug("Num tracks to use:" . scalar(@$tracks));
                            foreach my $track (@$tracks) {
                                main::DEBUGLOG && $log->debug("..." . $track);
                            }
                            $cb->($client, $tracks);
                        },
                        sub {
                            my $response = shift;
                            my $error  = $response->error;
                            main::DEBUGLOG && $log->debug("Failed to fetch URL: $error");
                            $cb->($client, []);
                        }
                    )->post($url, 'Content-Type' => 'application/json;charset=utf-8', $jsonData);
                }
            }
        });
    }
}

sub prefName {
    my $class = shift;
    return lc($class->title);
}

sub title {
    my $class = shift;
    return 'MusicSimilarity';
}

sub _getPreviousTracks {
    my ($client, $seeIds, $count) = @_;
    my @seeds = ref $seeIds ? @$seeIds : ($seeIds);
    my %seedsHash = map { $_ => 1 } @seeds;
    return unless $client;

    $client = $client->master;

    my $tracks = ();
    for my $track (reverse @{ Slim::Player::Playlist::playList($client) } ) {
        if (!blessed $track) {
            $track = Slim::Schema->objectForUrl($track);
        }

        next unless blessed $track && !exists($seedsHash{ $track->id });

        push @$tracks, $track;
        if (scalar @$tracks >= $count) {
            return $tracks;
        }
    }
    return $tracks;
}

sub _getMixData {
    my $seedTracks = shift;
    my $previousTracks = shift;
    my $trackCount = shift;
    my $shuffle = shift;
    my @tracks = ref $seedTracks ? @$seedTracks : ($seedTracks);
    my @previous = ref $previousTracks ? @$previousTracks : ($previousTracks);
    my @mix = ();
    my @track_paths = ();
    my @previous_paths = ();
    my @exclude_artists = ();
    my @exclude_albums = ();

    foreach my $track (@tracks) {
        push @track_paths, $track->url;
    }

    if ($previousTracks and scalar @previous > 0) {
        foreach my $track (@previous) {
            push @previous_paths, $track->url;
        }
    }

    my $exclude = $prefs->get('exclude_artists');
    if ($exclude) {
        my @exclude_list = split(/,/, $exclude);
        foreach my $ex (@exclude_list) {
            push @exclude_artists, $ex;
        }
    }

    $exclude = $prefs->get('exclude_albums');
    if ($exclude) {
        my @exclude_list = split(/,/, $exclude);
        foreach my $ex (@exclude_list) {
            push @exclude_albums, $ex;
        }
    }

    my $http = LWP::UserAgent->new;
    my $jsonData = to_json({
                        count         => $trackCount,
                        format        => 'text',
                        filtergenre   => $prefs->get('filter_genres') || 0,
                        filterxmas    => $prefs->get('filter_xmas') || 0,
                        min           => $prefs->get('min_duration') || 0,
                        max           => $prefs->get('max_duration') || 0,
                        track         => [@track_paths],
                        previous      => [@previous_paths],
                        excludeartist => [@exclude_artists],
                        excludealbum  => [@exclude_albums],
                        shuffle       => $shuffle
                    });
    $http->timeout($prefs->get('timeout') || 5);
    main::DEBUGLOG && $log->debug("Request $jsonData");
    return $jsonData;
}


sub trackInfoHandler {
    my $return = _objectInfoHandler( 'track', @_ );
    return $return;
}

sub albumInfoHandler {
    my $return = _objectInfoHandler( 'album', @_ );
    return $return;
}

sub artistInfoHandler {
    my $return = _objectInfoHandler( 'artist', @_ );
    return $return;
}

sub genreInfoHandler {
    my $return = _objectInfoHandler( 'genre', @_ );
    return $return;
}

sub _objectInfoHandler {
    my ( $objectType, $client, $url, $obj, $remoteMeta, $tags ) = @_;
    $tags ||= {};

    my $special;
    if ($objectType eq 'album') {
        $special->{'actionParam'} = 'album_id';
        $special->{'modeParam'}   = 'album';
        $special->{'urlKey'}      = 'album';
    } elsif ($objectType eq 'artist') {
        $special->{'actionParam'} = 'artist_id';
        $special->{'modeParam'}   = 'artist';
        $special->{'urlKey'}      = 'artist';
    } elsif ($objectType eq 'genre') {
        $special->{'actionParam'} = 'genre_id';
        $special->{'modeParam'}   = 'genre';
        $special->{'urlKey'}      = 'genre';
    } else {
        $special->{'actionParam'} = 'track_id';
        $special->{'modeParam'}   = 'track';
        $special->{'urlKey'}      = 'song';
    }

    return {
        type      => 'redirect',
        jive      => {
            actions => {
                go => {
                    player => 0,
                    cmd    => [ 'musicsimilarity', 'mix' ],
                    params => {
                        menu     => 1,
                        useContextMenu => 1,
                        $special->{actionParam} => $obj->id,
                    },
                },
            }
        },
        name      => cstring($client, 'MUSICSIMILARITY_CREATEMIX'),
        favorites => 0,

        player => {
            mode => 'musicsimilarity_mix',
            modeParams => {
                $special->{actionParam} => $obj->id,
            },
        }
    };
}

sub cliMix {
    my $request = shift;

    # check this is the correct query.
    if ($request->isNotQuery([['musicsimilarity', 'mix']])) {
        $request->setStatusBadDispatch();
        return;
    }

    # get our parameters
    my $client = $request->client();
    my $tags   = $request->getParam('tags') || 'al';

    my $params = {
        track  => $request->getParam('track_id'),
        artist => $request->getParam('artist_id'),
        album  => $request->getParam('album_id'),
        genre  => $request->getParam('genre_id')
    };

    my @seedsToUse = ();

    if ($request->getParam('track_id')) {
        my ($trackObj) = Slim::Schema->find('Track', $request->getParam('track_id'));
        if ($trackObj) {
            main::DEBUGLOG && $log->debug("Browse Track Seed " . $trackObj->path);
            push @seedsToUse, $trackObj;
        }
    } else {
        my $sql;
        my $col = 'track';
        my $param;
        my $dbh = Slim::Schema->dbh;
        if ($request->getParam('artist_id')) {
            $sql = $dbh->prepare_cached( qq{SELECT track FROM contributor_track WHERE contributor = ?} );
            $param = $request->getParam('artist_id');
        } elsif ($request->getParam('album_id')) {
            $sql = $dbh->prepare_cached( qq{SELECT id FROM tracks WHERE album = ?} );
            $col = 'id';
            $param = $request->getParam('album_id');
        } elsif ($request->getParam('genre_id')) {
            $sql = $dbh->prepare_cached( qq{SELECT track FROM genre_track WHERE genre = ?} );
            $param = $request->getParam('genre_id');
        } else {
            $request->setStatusBadDispatch();
            return
        }

        $sql->execute($param);
        if ( my $result = $sql->fetchall_arrayref({}) ) {
            foreach my $res (@$result) {
                my ($trackObj) = Slim::Schema->find('Track', $res->{$col});
                if ($trackObj) {
                    push @seedsToUse, $trackObj;
                }
            }
        }
        if (scalar @seedsToUse > $NUM_SEED_TRACKS) {
            Slim::Player::Playlist::fischer_yates_shuffle(\@seedsToUse);
            @seedsToUse = splice(@seedsToUse, 0, $NUM_SEED_TRACKS);
        }

        foreach my $trackObj (@seedsToUse) {
            main::DEBUGLOG && $log->debug("Browse Track Seed " . $trackObj->path);
        }
    }

    main::DEBUGLOG && $log->debug("Num tracks for browse mix:" . scalar(@seedsToUse));

    if (scalar @seedsToUse > 0) {
        my $jsonData = _getMixData(\@seedsToUse, undef, $NUM_MIX_TRACKS * 2, 1);
        my $port = $prefs->get('port') || 11000;
        my $url = "http://localhost:$port/api/similar";
        $request->setStatusProcessing();
        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $response = shift;
                main::DEBUGLOG && $log->debug("Received API response");

                my @songs = split(/\n/, $response->content);
                my $count = scalar @songs;
                my $tracks = ();

                Slim::Player::Playlist::fischer_yates_shuffle(\@seedsToUse);
                my $seedToAdd = @seedsToUse[0];

                Slim::Player::Playlist::fischer_yates_shuffle(\@songs);

                my $tags     = $request->getParam('tags') || 'al';
                my $menu     = $request->getParam('menu');
                my $menuMode = defined $menu;
                my $loopname = $menuMode ? 'item_loop' : 'titles_loop';
                my $chunkCount = 0;
                my $useContextMenu = $request->getParam('useContextMenu');
                my @usableTracks = ();
                my @ids      = ();

                # TODO: Add more?
                push @usableTracks, $seedToAdd;
                push @ids, $seedToAdd->id;

                foreach my $track (@songs) {
                    # Bug 4281 - need to convert from UTF-8 on Windows.
                    if (main::ISWINDOWS && !-e track && -e Win32::GetANSIPathName($track)) {
                        $track = Win32::GetANSIPathName($track);
                    }

                    if ( -e $track || -e Slim::Utils::Unicode::utf8encode_locale($track) || index($track, 'file:///')==0) {
                        my $trackObj = Slim::Schema->objectForUrl(Slim::Utils::Misc::fileURLFromPath($track));
                        if (blessed $trackObj && $trackObj->id != $seedToAdd->id) {
                            push @usableTracks, $trackObj;
                            main::DEBUGLOG && $log->debug("..." . $track);
                            push @ids, $trackObj->id;
                            if (scalar(@ids) >= $NUM_MIX_TRACKS) {
                                last;
                            }
                        }
                    }
                }

                if ($menuMode) {
                    my $idList = join( ",", @ids );
	                my $base = {
		                actions => {
			                go => {
				                cmd => ['trackinfo', 'items'],
				                params => {
					                menu => 'nowhere',
					                useContextMenu => '1',
				                },
				                itemsParams => 'params',
			                },
			                play => {
				                cmd => ['playlistcontrol'],
				                params => {
					                cmd  => 'load',
					                menu => 'nowhere',
				                },
				                nextWindow => 'nowPlaying',
				                itemsParams => 'params',
			                },
			                add =>  {
				                cmd => ['playlistcontrol'],
				                params => {
					                cmd  => 'add',
					                menu => 'nowhere',
				                },
				                itemsParams => 'params',
			                },
			                'add-hold' =>  {
				                cmd => ['playlistcontrol'],
				                params => {
					                cmd  => 'insert',
					                menu => 'nowhere',
				                },
				                itemsParams => 'params',
			                },
		                },
	                };

	                if ($useContextMenu) {
		                # "+ is more"
		                $base->{'actions'}{'more'} = $base->{'actions'}{'go'};
		                # "go is play"
		                $base->{'actions'}{'go'} = $base->{'actions'}{'play'};
	                }
	                $request->addResult('base', $base);

	                $request->addResult('offset', 0);
	                #$request->addResult('text', $request->string('MUSICMAGIX_MIX'));
	                my $thisWindow = {
			                'windowStyle' => 'icon_list',
			                'text'       => $request->string('MUSICSIMILARITY_MIX'),
	                };
	                $request->addResult('window', $thisWindow);

	                # add an item for "play this mix"
	                $request->addResultLoop($loopname, $chunkCount, 'nextWindow', 'nowPlaying');
	                $request->addResultLoop($loopname, $chunkCount, 'text', $request->string('MUSICSIMILARITY_PLAYTHISMIX'));
	                $request->addResultLoop($loopname, $chunkCount, 'icon-id', '/html/images/playall.png');
	                my $actions = {
		                'go' => {
			                'cmd' => ['playlistcontrol', 'cmd:load', 'menu:nowhere', 'track_id:' . $idList],
		                },
		                'play' => {
			                'cmd' => ['playlistcontrol', 'cmd:load', 'menu:nowhere', 'track_id:' . $idList],
		                },
		                'add' => {
			                'cmd' => ['playlistcontrol', 'cmd:add', 'menu:nowhere', 'track_id:' . $idList],
		                },
		                'add-hold' => {
			                'cmd' => ['playlistcontrol', 'cmd:insert', 'menu:nowhere', 'track_id:' . $idList],
		                },
	                };
	                $request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
	                $chunkCount++;
                }

                foreach my $trackObj (@usableTracks) {
                    if ($menuMode) {
                        Slim::Control::Queries::_addJiveSong($request, $loopname, $chunkCount, $chunkCount, $trackObj);
                    } else {
                        Slim::Control::Queries::_addSong($request, $loopname, $chunkCount, $trackObj, $tags);
                    }
                    $chunkCount++;
                }
                main::DEBUGLOG && $log->debug("Num tracks to use:" . ($chunkCount - 1)); # Remove 'Play this mix' from count
                $request->addResult('count', $chunkCount);
                $request->setStatusDone();
            },
            sub {
                my $response = shift;
                my $error  = $response->error;
                main::DEBUGLOG && $log->debug("Failed to fetch URL: $error");
                $request->setStatusDone();
            }
        )->post($url, 'Timeout' => 30, 'Content-Type' => 'application/json;charset=utf-8', $jsonData);
        return;
    }
    $request->setStatusBadDispatch();
}

1;

__END__
