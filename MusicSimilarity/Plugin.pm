package Plugins::MusicSimilarity::Plugin;

#
# LMS Music Similarity
#
# (c) 2020-2022 Craig Drummond
#
# Licence: GPL v3
#

use strict;

use Scalar::Util qw(blessed);
use LWP::UserAgent;
use JSON::XS::VersionOneAndTwo;
use File::Basename;
use File::Slurp;
use File::Spec;

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
my $essentiaLevelQueries = 0;
use constant DEF_NUM_DSTM_TRACKS => 5;
use constant NUM_SEED_TRACKS => 5;
use constant MAX_PREVIOUS_TRACKS => 200;
use constant DEF_MAX_PREVIOUS_TRACKS => 100;
use constant NUM_MIX_TRACKS => 50;
use constant NUM_SIMILAR_TRACKS => 100;
use constant ESSENTIA_LEVEL_CHECK_DELAY => 15;
use constant ESSENTIA_LEVEL_ATTEMPTS => (5*60) / ESSENTIA_LEVEL_CHECK_DELAY;
use constant MENU_WEIGHT => 95;
use constant ATTRMIX_FILE_EXT => '.attrmix';
use constant MSK_ACT_LOOP => 'materialskin_actions_loop';

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.musicsimilarity',
    'defaultLevel' => 'ERROR',
    'logGroups'    => 'SCANNER',
});

my $prefs = preferences('plugin.musicsimilarity');
my $serverprefs = preferences('server');

sub shutdownPlugin {
    $initialized = 0;
}

sub initPlugin {
    my $class = shift;

    return 1 if $initialized;

    $prefs->init({
        filter_genres                => 0,
        filter_xmas                  => 1,
        host                         => 'localhost',
        port                         => 11000,
        min_duration                 => 0,
        max_duration                 => 0,
        no_repeat_artist             => 15,
        no_repeat_album              => 25,
        no_repeat_track              => DEF_MAX_PREVIOUS_TRACKS,
        dstm_tracks                  => DEF_NUM_DSTM_TRACKS,
        timeout                      => 30,
        no_genre_match_adjustment    => 15,
        genre_group_match_adjustment => 7,
        max_bpm_diff                 => 50,
        max_loudness_diff            => 5,
        filter_key                   => 1,
        filter_attrib                => 1,
        attrib_weight                => 35,
        essentia_level               => -1
    });

    if ( main::WEBUI ) {
        Plugins::MusicSimilarity::Settings->new;
    }

    # 'Create similarity mix'....
    Slim::Control::Request::addDispatch(['musicsimilarity', '_cmd'], [0, 1, 1, \&cliMix]);

    Slim::Menu::TrackInfo->registerInfoProvider( musicsimilaritymix => (
        above    => 'favorites',
        func     => \&trackInfoHandler,
    ) );

    Slim::Menu::TrackInfo->registerInfoProvider( musicsimilarity => (
        above    => 'favorites',
        func     => \&similarTracksHandler,
    ) );

    Slim::Menu::TrackInfo->registerInfoProvider( musicsimilaritybyartist => (
        above    => 'favorites',
        func     => \&similarTracksByArtistHandler,
    ) );

    Slim::Menu::AlbumInfo->registerInfoProvider( musicsimilaritymix => (
        below    => 'addalbum',
        func     => \&albumInfoHandler,
    ) );

    Slim::Menu::ArtistInfo->registerInfoProvider( musicsimilaritymix => (
        below    => 'addartist',
        func     => \&artistInfoHandler,
    ) );

    Slim::Menu::GenreInfo->registerInfoProvider( musicsimilaritymix => (
        below    => 'addgenre',
        func     => \&genreInfoHandler,
    ) );
    #...

    _queryEssentiaStatus();

    if ( Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin') ) {
        my $rc = eval {
            require Plugins::MaterialSkin::Extensions;
            Plugins::MaterialSkin::Extensions::addJavascript("plugins/MusicSimilarity/html/js/musicsimilarity.js");
            Plugins::MaterialSkin::Extensions::addTranslation("plugins/MusicSimilarity/html/lang/");
            Plugins::MaterialSkin::Extensions::addDialog("musicsimilarity");
            main::DEBUGLOG && $log->debug("Registered javascript/div with Material");
            1;
        };
        if (! $rc) {
            main::DEBUGLOG && $log->debug("Failed to register javascript with Material");
        }
    }

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
            _dstmMix($client, $cb, 1);
        });
        Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('MUSICSIMILARITY_IGNORE_GENRE_MIX', sub {
            my ($client, $cb) = @_;
            _dstmMix($client, $cb, 0);
        });
    }
}

sub _registerMenu {
    main::DEBUGLOG && $log->debug("Register menu");
    Slim::Control::Jive::registerPluginMenu([{
        stringToken => 'MUSICSIMILARITY_ATTRMIX',
        weight      => MENU_WEIGHT,
        id          => 'attrmix',
        node        => 'myMusic',
        'icon-id'   => 'plugins/MusicSimilarity/html/images/mix_svg.png',
        actions => {
            go => {
                player => 0,
                cmd    => [ 'musicsimilarity', 'attrmixes' ],
                params => {
                    menu => 1,
                },
            },
        },
        window         => {
            'icon-id'  => 'plugins/MusicSimilarity/html/images/mix_svg.png'
        },
    }]);
}

sub _queryEssentiaStatus {
    Slim::Utils::Timers::killTimers(undef, \&_queryEssentiaStatus);
    my $host = $prefs->get('host') || 'localhost';
    my $port = $prefs->get('port') || 11000;
    my $url = "http://$host:$port/api/essentia";
    $essentiaLevelQueries += 1;
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $response = shift;
            my $level = int($response->content);
            $prefs->set('essentia_level', $level);
            main::DEBUGLOG && $log->debug("Essentia level: " . $level);
            if ($level > 1) {
                _registerMenu();
            }
        },
        sub {
            if ($essentiaLevelQueries<=ESSENTIA_LEVEL_ATTEMPTS) {
                main::DEBUGLOG && $log->debug("Failed to determine Essentia level, will try again afer " . ESSENTIA_LEVEL_CHECK_DELAY . " seconds");
                Slim::Utils::Timers::killTimers(undef, \&_queryEssentiaStatus);
                Slim::Utils::Timers::setTimer(undef, time() + ESSENTIA_LEVEL_CHECK_DELAY, \&_queryEssentiaStatus);
            }
        }
    )->get($url);
}

sub _getMixableProperties {
	my ($client, $count) = @_;

	return unless $client;

	$client = $client->master;

	my ($trackId, $artist, $title, $duration, $tracks);

    # Get last count*2 tracks from queue
    foreach (reverse @{ Slim::Player::Playlist::playList($client) } ) {
		($artist, $title, $duration, $trackId) = Slim::Plugin::DontStopTheMusic::Plugin->getMixablePropertiesFromTrack($client, $_);

		next unless defined $artist && defined $title;

		push @$tracks, $trackId;
		if ($count && scalar @$tracks > ($count * 2)) {
		    last;
		}
	}

	if ($tracks && ref $tracks && scalar @$tracks && $duration) {
		main::INFOLOG && $log->info("Auto-mixing from random tracks in current playlist");

		if ($count && scalar @$tracks > $count) {
			Slim::Player::Playlist::fischer_yates_shuffle($tracks);
			splice(@$tracks, $count);
		}

		return $tracks;
	} elsif (main::INFOLOG && $log->is_info) {
		if (!$duration) {
			$log->info("Found radio station last in the queue - don't start a mix.");
		}
		else {
			$log->info("No mixable items found in current playlist!");
		}
	}

	return;
}

sub _dstmMix {
    my ($client, $cb, $filterGenres) = @_;
    main::DEBUGLOG && $log->debug("Get similar tracks");
    my $seedTracks = _getMixableProperties($client, NUM_SEED_TRACKS); # Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, NUM_SEED_TRACKS);
    my $tracks = [];

    # don't seed from radio stations - only do if we're playing from some track based source
    # Get list of valid seeds...
    if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
        my @seedIds = ();
        my @seedsToUse = ();
        my $numSpot = 0;
        foreach my $seedTrack (@$seedTracks) {
            my ($trackObj) = Slim::Schema->find('Track', $seedTrack);
            if ($trackObj) {
                main::DEBUGLOG && $log->debug("Seed " . $trackObj->path . " id:" . $seedTrack);
                push @seedsToUse, $trackObj;
                push @seedIds, $seedTrack;
                if ( $trackObj->path =~ m/^spotify:/ ) {
                    $numSpot++;
                }
            }
        }

        if (scalar @seedsToUse > 0) {
            my $maxNumPrevTracks = $prefs->get('no_repeat_track');
            if ($maxNumPrevTracks<0 || $maxNumPrevTracks>MAX_PREVIOUS_TRACKS) {
                $maxNumPrevTracks = DEF_MAX_PREVIOUS_TRACKS;
            }
            my $previousTracks = _getPreviousTracks($client, $maxNumPrevTracks);
            main::DEBUGLOG && $log->debug("Num tracks to previous: " . ($previousTracks ? scalar(@$previousTracks) : 0));

            my $dstm_tracks = $prefs->get('dstm_tracks') || DEF_NUM_DSTM_TRACKS;
            my $jsonData = _getMixData(\@seedsToUse, $previousTracks ? \@$previousTracks : undef, $dstm_tracks, 1, $filterGenres);
            my $host = $prefs->get('host') || 'localhost';
            my $port = $prefs->get('port') || 11000;
            my $url = "http://$host:$port/api/similar";
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

                    if (!defined $tracks) {
                        _mixFailed($client, $cb, $numSpot);
                    } else {
                        main::DEBUGLOG && $log->debug("Num tracks to use:" . scalar(@$tracks));
                        foreach my $track (@$tracks) {
                            main::DEBUGLOG && $log->debug("..." . $track);
                        }
                        if (scalar @$tracks > 0) {
                            $cb->($client, $tracks);
                        } else {
                            _mixFailed($client, $cb, $numSpot);
                        }
                    }
                },
                sub {
                    my $response = shift;
                    my $error  = $response->error;
                    main::DEBUGLOG && $log->debug("Failed to fetch URL: $error");
                    _mixFailed($client, $cb, $numSpot);
                }
            )->post($url, 'Content-Type' => 'application/json;charset=utf-8', $jsonData);
        }
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

sub _mixFailed {
    my ($client, $cb, $numSpot) = @_;

    if ($numSpot > 0 && exists $INC{'Plugins/Spotty/DontStopTheMusic.pm'}) {
        main::DEBUGLOG && $log->debug("Call through to Spotty");
        Plugins::Spotty::DontStopTheMusic::dontStopTheMusic($client, $cb);
    } elsif (exists $INC{'Plugins/LastMix/DontStopTheMusic.pm'}) {
        main::DEBUGLOG && $log->debug("Call through to LastMix");
        Plugins::LastMix::DontStopTheMusic::please($client, $cb);
    } else {
        main::DEBUGLOG && $log->debug("Return empty list");
        $cb->($client, []);
    }
}

sub _getPreviousTracks {
    my ($client, $count) = @_;
    main::DEBUGLOG && $log->debug("Get last " . $count . " tracks");
    return unless $client;

    $client = $client->master;

    my $tracks = ();
    if ($count>0) {
        for my $track (reverse @{ Slim::Player::Playlist::playList($client) } ) {
            if (!blessed $track) {
                $track = Slim::Schema->objectForUrl($track);
            }

            next unless blessed $track;

            push @$tracks, $track;
            if (scalar @$tracks >= $count) {
                return $tracks;
            }
        }
    }
    return $tracks;
}

sub _getMixData {
    my $seedTracks = shift;
    my $previousTracks = shift;
    my $trackCount = shift;
    my $shuffle = shift;
    my $filterGenres = shift;
    my @tracks = ref $seedTracks ? @$seedTracks : ($seedTracks);
    my @previous = ref $previousTracks ? @$previousTracks : ($previousTracks);
    my @mix = ();
    my @track_paths = ();
    my @previous_paths = ();

    foreach my $track (@tracks) {
        push @track_paths, $track->url;
    }

    if ($previousTracks and scalar @previous > 0) {
        foreach my $track (@previous) {
            push @previous_paths, $track->url;
        }
    }

    my $mediaDirs = $serverprefs->get('mediadirs');
    my $jsonData = to_json({
                        count           => $trackCount,
                        format          => 'text',
                        filtergenre     => $filterGenres,
                        filterxmas      => $prefs->get('filter_xmas') || 1,
                        min             => $prefs->get('min_duration') || 0,
                        max             => $prefs->get('max_duration') || 0,
                        track           => [@track_paths],
                        previous        => [@previous_paths],
                        shuffle         => $shuffle,
                        norepart        => $prefs->get('no_repeat_artist'),
                        norepalb        => $prefs->get('no_repeat_album'),
                        genregroups     => _genreGroups(),
                        nogenrematchadj => $prefs->get('no_genre_match_adjustment'),
                        genregroupadj   => $prefs->get('genre_group_match_adjustment'),
                        maxbpmdiff      => $prefs->get('max_bpm_diff'),
                        maxloudnessdiff => $prefs->get('max_loudness_diff'),
                        filterkey       => $prefs->get('filter_key'),
                        filterattrib    => $prefs->get('filter_attrib'),
                        attribweight    => $prefs->get('attrib_weight'),
                        mpath           => @$mediaDirs[0]
                    });

    main::DEBUGLOG && $log->debug("Request $jsonData");
    return $jsonData;
}

sub _getSimilarData {
    my $seedTrack = shift;
    my $byArtist = shift;
    my $count = shift;
    my $http = LWP::UserAgent->new;
    my $mediaDirs = $serverprefs->get('mediadirs');
    my $jsonData = to_json({
                        count           => $count,
                        format          => 'text-url',
                        min             => $prefs->get('min_duration') || 0,
                        max             => $prefs->get('max_duration') || 0,
                        track           => [$seedTrack->url],
                        filterartist    => $byArtist,
                        genregroups     => _genreGroups(),
                        nogenrematchadj => $prefs->get('no_genre_match_adjustment'),
                        genregroupadj   => $prefs->get('genre_group_match_adjustment'),
                        maxbpmdiff      => $prefs->get('max_bpm_diff'),
                        maxloudnessdiff => $prefs->get('max_loudness_diff'),
                        filterkey       => $prefs->get('filter_key'),
                        filterattrib    => $prefs->get('filter_attrib'),
                        attribweight    => $prefs->get('attrib_weight'),
                        mpath           => @$mediaDirs[0]
                    });
    $http->timeout($prefs->get('timeout') || 30);
    main::DEBUGLOG && $log->debug("Request $jsonData");
    return $jsonData;
}

my $configuredGenreGroups = ();
my $configuredGenreGroupsTs = 0;

sub _genreGroups {
    # Check to see if config has changed, saves try to read and process each time
    my $ts = $prefs->get('_ts_genre_groups');
    if ($ts==$configuredGenreGroupsTs) {
        return $configuredGenreGroups;
    }
    $configuredGenreGroupsTs = $ts;

    $configuredGenreGroups = ();
    my $ggpref = $prefs->get('genre_groups');
    if ($ggpref) {
        my @lines = split(/\n/, $ggpref);
        foreach my $line (@lines) {
            my @genreGroup = split(/\;/, $line);
            my $grp = ();
            foreach my $genre (@genreGroup) {
                # left trim
                $genre=~ s/^\s+//;
                # right trim
                $genre=~ s/\s+$//;
                if (length $genre > 0){
                    push(@$grp, $genre);
                }
            }
            if (scalar $grp > 0) {
                push(@$configuredGenreGroups, $grp);
            }
        }
    }
    return $configuredGenreGroups;
}

my $configuredIgnoreGenre = ();
my $configuredIgnoreGenreTs = 0;

sub trackInfoHandler {
    return _objectInfoHandler( 'track', @_ );
}

sub albumInfoHandler {
    return _objectInfoHandler( 'album', @_ );
}

sub artistInfoHandler {
    return _objectInfoHandler( 'artist', @_ );
}

sub genreInfoHandler {
    return _objectInfoHandler( 'genre', @_ );
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
        type => 'redirect',
        jive => {
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

sub _trackSimilarityHandler {
    my ( $byArtist, $client, $url, $obj, $remoteMeta, $tags ) = @_;
    $tags ||= {};

    my $special;
    $special->{'actionParam'} = 'track_id';
    $special->{'modeParam'}   = 'track';
    $special->{'urlKey'}      = 'song';

    return {
        type      => 'redirect',
        jive      => {
            actions => {
                go => {
                    player => 0,
                    cmd    => [ 'musicsimilarity', 'list' ],
                    params => {
                        menu     => 1,
                        useContextMenu => 1,
                        $special->{actionParam} => $obj->id,
                        byArtist => $byArtist
                    },
                },
            }
        },
        name      => cstring($client, $byArtist == 1 ? 'MUSICSIMILARITY_SIMILAR_TRACKS_BY_ARTIST' : 'MUSICSIMILARITY_SIMILAR_TRACKS'),
        favorites => 0,

        player => {
            mode => 'musicsimilarity_list',
            modeParams => {
                $special->{actionParam} => $obj->id,
            },
        }
    };
}

sub similarTracksHandler {
    return _trackSimilarityHandler( 0, @_ );
}

sub similarTracksByArtistHandler {
    return _trackSimilarityHandler( 1, @_ );
}

sub _listAttrMixes {
    my @mixes  = ();
    main::DEBUGLOG && $log->debug("List");
	my $dir = $serverprefs->get('playlistdir');
	my $len = length(ATTRMIX_FILE_EXT) * -1;
	if ($dir) {
	    my @files = glob($dir . '/*' . ATTRMIX_FILE_EXT);
	    foreach my $file(@files) {
	        main::DEBUGLOG && $log->debug("Mix file:" . $file);
	        push(@mixes, substr(basename($file), 0, $len));
	    }
	}
	return \@mixes;
}

sub _attrMixes {
    my $request  = shift;
    my $mixes    = _listAttrMixes();
    my $menu     = $request->getParam('menu');
    my $material = $request->getParam('materialskin');
    my $menuMode = defined $menu;
    my $loopname = $menuMode ? 'item_loop' : 'mixes_loop';
    my $count    = 0;

    if ($menuMode) {
        $request->addResult('offset', 0);
    }

    if (defined $material) {
        $request->addResultLoop(MSK_ACT_LOOP, $count, 'title', $request->string('MUSICSIMILARITY_ADDMIX'));
        $request->addResultLoop(MSK_ACT_LOOP, $count, 'id', 'msim-add');
        $request->addResultLoop(MSK_ACT_LOOP, $count, 'svg', 'plugins/MusicSimilarity/html/images/add.svg');
        $request->addResultLoop(MSK_ACT_LOOP, $count, 'type', 'toolbar');
        $request->addResultLoop(MSK_ACT_LOOP, $count, 'script', "bus.\$emit('musicsimilarity.open');");

        $count++;
        $request->addResultLoop(MSK_ACT_LOOP, $count, 'title', $request->string('EDIT'));
        $request->addResultLoop(MSK_ACT_LOOP, $count, 'id', 'msim-edit');
        $request->addResultLoop(MSK_ACT_LOOP, $count, 'icon', 'edit');
        $request->addResultLoop(MSK_ACT_LOOP, $count, 'type', 'item');
        $request->addResultLoop(MSK_ACT_LOOP, $count, 'script', "bus.\$emit('musicsimilarity.open', '\$ITEMID');");

        $count++;
        $request->addResultLoop(MSK_ACT_LOOP, $count, 'title', $request->string('DELETE'));
        $request->addResultLoop(MSK_ACT_LOOP, $count, 'id', 'msim-delete');
        $request->addResultLoop(MSK_ACT_LOOP, $count, 'icon', 'delete_outline');
        $request->addResultLoop(MSK_ACT_LOOP, $count, 'type', 'item');
        $request->addResultLoop(MSK_ACT_LOOP, $count, 'script', "bus.\$emit('musicsimilarity-remove', '\$ITEMID', '\$TITLE');");

        $count = 0;
    }

    for my $item (@$mixes) {
        if ($menuMode) {
            $request->addResultLoop($loopname, $count, 'actions', {
                go => {
                    player => 0,
                    cmd    => [ 'musicsimilarity', 'mix' ],
                    params => {
                        menu => 1,
                        mix  => $item
                    }
                },
            });
            $request->addResultLoop($loopname, $count, 'text', $item);
            $request->addResultLoop($loopname, $count, 'id', $item);
            $request->addResultLoop($loopname, $count, 'type', 'playlist');
        } else {
            $request->addResultLoop($loopname, $count, 'name', $item);
        }
        $count++;
    }

    $request->addResult('count', $count);
    $request->setStatusDone();
}

sub _readAttrMixJson {
    my $mix = shift;
    my $fileOnly = shift;
    my $dir = $serverprefs->get('playlistdir');
    my $mixFile = File::Spec->catpath('', $dir, $mix . ATTRMIX_FILE_EXT); # First arg ignored???
    if (! -e $mixFile) {
        main::DEBUGLOG && $log->debug("Request mix file, $mixFile, does not exist");
        return;
    }

    if (open my $fh, "<", $mixFile) {
        main::DEBUGLOG && $log->debug("Reading $mixFile");
        my $mediaDirs = $serverprefs->get('mediadirs');
        my %req = $fileOnly ? () : ( 'format' => 'text', 'mpath'  => @$mediaDirs[0] );
        my $ok = 0;
        while (my $line = <$fh>) {
            if (rindex($line, '#', 0)==-1) {
                $line =~ s/[\r\n]+$//;
                my @parts = split /=/, $line;
                if (scalar(@parts)==2) {
                    if (@parts[0] eq 'genre') {
                        my @genres = split /;/, @parts[1];
                        $req{@parts[0]}=[@genres];
                    } else {
                        $req{@parts[0]}=@parts[1];
                    }
                    $ok = 1;
                }
            }
        }
        close $fh;
        if ($ok) {
            return to_json(\%req);
        }
    }
}

sub _attrMix {
    my $request = shift;
    my $mix = $request->getParam('mix');
    my $body = $request->getParam('body');

    if ($body) {
        if ($mix) {
            _saveMix($request, $mix, $body);
        }
        _callApi($request, 'attrmix', $body, 500, 0, undef);
        return;
    } elsif ($mix) {
        my $jsonData = _readAttrMixJson($mix, 0);
        if ($jsonData) {
            _callApi($request, 'attrmix', $jsonData, 500, 0, undef);
            return;
        }
    }

    $request->setStatusBadDispatch();
}

sub _readMix {
    my $request = shift;
    my $mix = $request->getParam('mix');
    if ($mix) {
        my $jsonData = _readAttrMixJson($mix, 1);
        if ($jsonData) {
            $request->addResult('body', $jsonData);
            $request->setStatusDone();
            return;
        }
    }
    $request->setStatusBadDispatch();
}

sub _saveMix {
    my $request = shift;
    my $mix = shift;
    my $body = shift;
    my $dir = $serverprefs->get('playlistdir');
    my $mixFile = File::Spec->catpath('', $dir, $mix . ATTRMIX_FILE_EXT); # First arg ignored???
    my $isNew = ! -e $mixFile;
    main::DEBUGLOG && $log->debug("Saving $mixFile");
    if (open my $fh, ">", $mixFile) {
        my %hash = %{$body};
        foreach my $key (keys %hash) {
            if ($key eq 'genre') {
                my $v = join(";", @{%hash{$key}});
                print $fh "$key=$v\n";
            } else {
                my $v=%hash{$key};
                print $fh "$key=$v\n";
            }
        }
        close $fh;
        if ($isNew) {
            # Material will need to refresh its parent list...
            $request->addResult('refreshparent', 1);
        }
    }
}

sub _delMix {
    my $request = shift;
    my $mix = $request->getParam('mix');
    if ($mix) {
        my $dir = $serverprefs->get('playlistdir');
        my $mixFile = File::Spec->catpath('', $dir, $mix . ATTRMIX_FILE_EXT); # First arg ignored???
        if (-e $mixFile) {
            unlink($mixFile);
            if (! -e $mixFile) {
                $request->setStatusDone();
                return;
            } else {
                main::DEBUGLOG && $log->error("Failed to delete $mixFile");
            }
        } else {
            main::DEBUGLOG && $log->debug("Mix file $mixFile does not exist");
        }
    }
    $request->setStatusBadDispatch();
}

sub _callApi {
    my $request = shift;
    my $api = shift;
    my $jsonData = shift;
    my $maxTracks = shift;
    my $isMix = shift;
    my $seedToAdd = shift;
    my $host = $prefs->get('host') || 'localhost';
    my $port = $prefs->get('port') || 11000;
    my $url = "http://$host:$port/api/$api";
    my $http = LWP::UserAgent->new;

    $http->timeout($prefs->get('timeout') || 30);

    main::DEBUGLOG && $log->debug("Call $url");
    $request->setStatusProcessing();
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $response = shift;
            main::DEBUGLOG && $log->debug("Received API response ");

            my @songs = split(/\n/, $response->content);
            my $count = scalar @songs;
            my $tracks = ();

            if ($isMix) {
                Slim::Player::Playlist::fischer_yates_shuffle(\@songs);
            }

            my $tags     = $request->getParam('tags') || 'al';
            my $menu     = $request->getParam('menu');
            my $menuMode = defined $menu;
            my $loopname = $menuMode ? 'item_loop' : 'titles_loop';
            my $chunkCount = 0;
            my $useContextMenu = $request->getParam('useContextMenu');
            my @usableTracks = ();
            my @ids          = ();

            if ($isMix) {
                # TODO: Add more?
                push @usableTracks, $seedToAdd;
                push @ids, $seedToAdd->id;
            }

            foreach my $track (@songs) {
                # Bug 4281 - need to convert from UTF-8 on Windows.
                if (main::ISWINDOWS && !-e track && -e Win32::GetANSIPathName($track)) {
                    $track = Win32::GetANSIPathName($track);
                }

                if ( -e $track || -e Slim::Utils::Unicode::utf8encode_locale($track) || index($track, 'file:///')==0) {
                    my $trackObj = Slim::Schema->objectForUrl(Slim::Utils::Misc::fileURLFromPath($track));
                    if (blessed $trackObj && (!$isMix || ($trackObj->id != $seedToAdd->id))) {
                        push @usableTracks, $trackObj;
                        main::DEBUGLOG && $log->debug("..." . $track);
                        push @ids, $trackObj->id;
                        if (scalar(@ids) >= $maxTracks) {
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
                $request->addResultLoop($loopname, $chunkCount, 'text', $request->string($isMix ? 'MUSICSIMILARITY_PLAYTHISMIX' : 'MUSICSIMILARITY_PLAYTHISLIST'));
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
}

sub cliMix {
    my $request = shift;

    # check this is the correct query.
    if ($request->isNotQuery([['musicsimilarity']])) {
        $request->setStatusBadDispatch();
        return;
    }

    my $cmd = $request->getParam('_cmd');
main::DEBUGLOG && $log->debug("CMD:$cmd");
    if ($request->paramUndefinedOrNotOneOf($cmd, ['mix', 'list', 'attrmixes', 'readmix', 'savemix', 'delmix']) ) {
        $request->setStatusBadParams();
        return;
    }

    if ($cmd eq 'attrmixes') {
        _attrMixes($request);
        return;
    }

    if ($cmd eq 'readmix') {
        _readMix($request);
        return;
    }

    if ($cmd eq 'delmix') {
        _delMix($request);
        return;
    }

    if ($cmd eq 'mix' && $request->getParam('attrmix')==1) {
        _attrMix($request);
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
    my $isMix = $cmd eq 'mix';

    if ($request->getParam('track_id')) {
        my ($trackObj) = Slim::Schema->find('Track', $request->getParam('track_id'));
        if ($trackObj) {
            main::DEBUGLOG && $log->debug("Similarity Track Seed " . $trackObj->path);
            push @seedsToUse, $trackObj;
        }
    } elsif ($isMix) {
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
        if (scalar @seedsToUse > NUM_SEED_TRACKS) {
            Slim::Player::Playlist::fischer_yates_shuffle(\@seedsToUse);
            @seedsToUse = splice(@seedsToUse, 0, NUM_SEED_TRACKS);
        }

        foreach my $trackObj (@seedsToUse) {
            main::DEBUGLOG && $log->debug("Similarity Track Seed " . $trackObj->path);
        }
    }

    main::DEBUGLOG && $log->debug("Num tracks for similarity mix/list: " . scalar(@seedsToUse));

    if (scalar @seedsToUse > 0) {
        my $maxTracks = $isMix ? NUM_MIX_TRACKS : NUM_SIMILAR_TRACKS;
        my $jsonData = $isMix ? _getMixData(\@seedsToUse, undef, $maxTracks * 2, 1, $prefs->get('filter_genres') || 0) : _getSimilarData(@seedsToUse[0], $request->getParam('byArtist') || 0, $maxTracks);

        if ($isMix) {
            Slim::Player::Playlist::fischer_yates_shuffle(\@seedsToUse);
        }
        _callApi($request, $isMix ? 'similar' : 'dump', $jsonData, $maxTracks, $isMix, $isMix ? @seedsToUse[0] : undef);
        return;
    }
    $request->setStatusBadDispatch();
}

1;

__END__
