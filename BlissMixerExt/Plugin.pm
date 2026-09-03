package Plugins::BlissMixerExt::Plugin;

#
# Bliss Mixer Extensions companion for Lyrion Music Server
#
# (c) 2022-2026 Craig Drummond
# Additional sidecar adaptations (c) 2026 Christoph O'Bermair
#
# Licence: GPL v3
#

use strict;

use Scalar::Util qw(blessed);
use IO::Socket::INET;
use LWP::UserAgent;
use JSON::XS::VersionOneAndTwo;
use File::Basename;
use File::Spec::Functions qw(catdir catfile);
use Proc::Background;
use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::PluginManager;
use Slim::Utils::Prefs;
use Slim::Utils::Versions;

use Plugins::BlissMixerExt::Settings;
use Plugins::BlissMixerExt::Survey;

use constant DEF_NUM_DSTM_TRACKS => 5;
use constant NUM_FOREST_SEED_TRACKS => 10;
use constant NUM_SEED_TRACKS => 5;
use constant MAX_PREVIOUS_TRACKS => 200;
use constant DEF_MAX_PREVIOUS_TRACKS => 100;
use constant DB_NAME  => "bliss.db";
use constant STOP_MIXER => 60 * 60;
use constant MAX_MIXER_START_CHECKS => 10;
use constant FIRST_MIXER_PORT => 12001;
use constant LAST_MIXER_PORT => 12100;
use constant MIN_BLISSMIXER_VERSION => '0.10.0';

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.blissmixerext',
    'defaultLevel' => 'INFO',
    'logGroups'    => 'SCANNER',
});

my $prefs = preferences('plugin.blissmixer');
my $extprefs = preferences('plugin.blissmixerext');
my $dbPath = "";
my $dbSignature = "";
my $initialized = 0;
# Current bliss-mixer process
my $mixer;
# Port number mixer is running on
my $mixerPort = 0;
# Path to bliss-mixer that will be used on current system
my $mixerBinary;
# store time when bliss-mixer was started. This is then checked in _startMixer
# to ensure it is not attempted to be started again
my $lastMixerStart = 0;

my $lastWeights = "";

sub _upstreamCompatible {
    my $manifest = Slim::Utils::PluginManager->dataForPlugin('Plugins::BlissMixer::Plugin');
    return 0 unless $manifest;
    return Slim::Utils::Versions->compareVersions(
        $manifest->{version} || '0', MIN_BLISSMIXER_VERSION
    ) >= 0;
}

sub shutdownPlugin {
    _stopMixer();
    Plugins::BlissMixerExt::Survey::shutdown();
    if (Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin')) {
        Slim::Plugin::DontStopTheMusic::Plugin->unregisterHandler('BLISSMIXEREXT_DSTM');
    }
    $initialized = 0;
}

sub initPlugin {
    my $class = shift;

    return 1 if $initialized;

    $extprefs->init({
        learned_blend    => 50,
        triplets_backup_path => ''
    });

    if ( main::WEBUI ) {
        Plugins::BlissMixerExt::Settings->new;
    }

    #                                                            |requires Client
    #                                                            |  |is a Query
    #                                                            |  |  |has Tags
    #                                                            |  |  |  |Function to call
    #                                                            C  Q  T  F
    Slim::Control::Request::addDispatch(['blissmixerext', '_cmd'], [0, 0, 1, \&_cliCommand]);

    my $dbDir = Slim::Utils::Prefs::dir() || Slim::Utils::OSDetect::dirsFor('prefs');
    $dbPath = $dbDir . "/" . DB_NAME;

    _initBinaries();

    if (!_upstreamCompatible()) {
        $log->warn('BlissMixerExt requires an enabled upstream BlissMixer ' . MIN_BLISSMIXER_VERSION . ' or newer');
    }

    $initialized = 1;
    return $initialized;
}

sub postinitPlugin {
    my $class = shift;

    # Register a distinct provider. Upstream's BLISSMIXER_DSTM remains untouched.
    if ( _upstreamCompatible()
        && Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
        require Slim::Plugin::DontStopTheMusic::Plugin;
        Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('BLISSMIXEREXT_DSTM', sub {
            my ($client, $cb) = @_;
            _dstmMix($client, $cb, $prefs->get('filter_genres') || 0, 0);
        });
        #Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('BLISSMIXEREXT_DSTM_IGNORE_GENRES', sub {
        #    my ($client, $cb) = @_;
        #    _dstmMix($client, $cb, 0, 0);
        #});
    }
}

sub _initBinaries {
    my $dir = dirname(__FILE__);
    if (main::ISWINDOWS) {
        Slim::Utils::Misc::addFindBinPaths(catdir($dir, 'Bin', 'windows'));
    } elsif (main::ISMAC) {
        Slim::Utils::Misc::addFindBinPaths(catdir($dir, 'Bin', 'mac'));
    } else {
        my @linuxPaths = (
            catdir($dir, 'Bin', 'x86_64-linux'),
            catdir($dir, 'Bin', 'aarch64-linux'),
            catdir($dir, 'Bin', 'armhf-linux'),
        );
        for my $p (@linuxPaths) {
            Slim::Utils::Misc::addFindBinPaths($p);
        }
    }
    $mixerBinary = Slim::Utils::Misc::findbin('bliss-mixer-ext');
    main::INFOLOG && $log->info("Mixer: ${mixerBinary}");

    my $prefsDir = Slim::Utils::Prefs::dir();
    my $matrixPath = catfile($prefsDir, 'learned_matrix.json');
    my $tripletsPath = catfile($prefsDir, 'training_triplets.json');
    _migrateLearningFile(
        catfile($prefsDir, 'blissmixer-ext-matrix.json'), $matrixPath,
    );
    _migrateLearningFile(
        catfile($prefsDir, 'blissmixer-ext-triplets.json'), $tripletsPath,
    );
    Plugins::BlissMixerExt::Survey::init($dbPath, $matrixPath, $tripletsPath);
}

sub _migrateLearningFile {
    my ($legacyPath, $canonicalPath) = @_;
    if (-e $canonicalPath) {
        if (-e $legacyPath) {
            $log->warn("Both canonical and legacy BlissMixerExt learning files exist; using $canonicalPath and leaving $legacyPath untouched");
            return 'conflict';
        }
        return 'canonical';
    }
    return 'absent' unless -e $legacyPath;
    if (rename $legacyPath, $canonicalPath) {
        main::INFOLOG && $log->info("Migrated BlissMixerExt learning file from $legacyPath to $canonicalPath");
        return 'migrated';
    }
    $log->warn("Could not migrate BlissMixerExt learning file from $legacyPath to $canonicalPath: $!");
    return 'failed';
}

sub _resetMixerTimeout {
    Slim::Utils::Timers::killTimers(undef, \&_stopMixer);
    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + STOP_MIXER, \&_stopMixer);
}

sub _stopMixer {
    Slim::Utils::Timers::killTimers(undef, \&_stopMixer);
    if ($mixer && $mixer->alive) {
        $mixer->die;
    } else {
        main::DEBUGLOG && $log->debug("$mixerBinary not running");
    }
    $lastMixerStart = 0;
    $mixerPort = 0;
}

sub _portAvailable {
    my $port = shift;
    my $socket = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => $port,
        Proto => 'tcp',
        Listen => 1,
        ReuseAddr => 0,
    );
    return 0 unless $socket;
    close $socket;
    return 1;
}

sub _availableMixerPort {
    my $upstreamPort = int($prefs->get('mixer_port') || 0);
    for my $port (FIRST_MIXER_PORT .. LAST_MIXER_PORT) {
        next if $port == $upstreamPort;
        return $port if _portAvailable($port);
    }
    $log->warn('Could not find an available loopback port for bliss-mixer-ext');
    return 0;
}

# The Ext binary deliberately uses an auto-selected loopback-only port. The
# experimental binary reports dynamic ports to the upstream "blissmixer"
# command, which a sidecar must never replace or intercept.
sub _checkIfMixerReady {
    my ($attempts, $port) = @_;
    my $url = "http://localhost:$port/api/ready";
    my $http = LWP::UserAgent->new;

    $http->timeout(1);

    main::DEBUGLOG && $log->debug("Call $url");

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            main::DEBUGLOG && $log->debug("Mixer is ready");
            $mixerPort = int($port);
        },
        sub {
            if ($attempts < MAX_MIXER_START_CHECKS) {
                Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, sub {
                    _checkIfMixerReady($attempts + 1, $port);
                });
            } else {
                main::DEBUGLOG && $log->debug("Could not determine if mixer is ready, assume it is?");
                $mixerPort = int($port);
            }
        }
    )->get($url, 'Content-Type' => 'application/json;charset=utf-8');
}

sub _weightParam {
    my @weights = ();
    my $tempo = int($prefs->get('weight_tempo') || 4);
    my $timbre = int($prefs->get('weight_timbre') || 30);
    my $loudness = int($prefs->get('weight_loudness') || 9);
    my $chroma = int($prefs->get('weight_chroma') || 57);

    my $total = $tempo + $timbre + $loudness + $chroma;
    $tempo = (($tempo / $total) * 100.0) / 4.0;
    $timbre = (($timbre / $total) * 100.0) / 30.0;
    $loudness = (($loudness / $total) * 100.0) / 9.0;
    $chroma = (($chroma / $total) * 100.0) / 57.0;

    push @weights, $tempo;
    for (my $i = 0; $i < 7; $i++) {
        push @weights, $timbre;
    }
    for (my $i = 0; $i < 2; $i++) {
        push @weights, $loudness;
    }
    for (my $i = 0; $i < 13; $i++) {
        push @weights, $chroma;
    }

    my $str = join(",", @weights);
    return $str;
}

sub _databaseSignature {
    return '' unless -e $dbPath;
    my @stat = stat($dbPath);
    return join(':', $stat[7] || 0, $stat[9] || 0);
}

sub _originalAnalyserRunning {
    my $request = Slim::Control::Request::executeRequest(
        undef,
        ['blissmixer', 'analyser', 'act:status']
    );
    return 0 unless $request && $request->isStatusDone;
    return int($request->getResult('running') || 0);
}

sub _startMixer {

    if ($mixer && $mixer->alive) {
        main::DEBUGLOG && $log->debug("$mixerBinary already running");
        return 1;
    }
    if (!$mixerBinary) {
        $log->warn("No mixer binary");
        return 0;
    }

    # Check to see if we attempted to start bliss-mixer less that 'MAX_MIXER_START_CHECKS+1'
    # seconds ago. If so, then we are awaiting its start response so no need to try to start
    my $now = Time::HiRes::time();
    if ($lastMixerStart!=0 && ($now-$lastMixerStart)<(MAX_MIXER_START_CHECKS+1)) {
        return 1;
    }

    $lastMixerStart = 0;
    if (!-e $dbPath) {
        $log->warn("No database ($dbPath)");
        return 0;
    }
    $mixerPort = 0;
    my $cfgPort = _availableMixerPort();
    return 0 unless $cfgPort;
    my @params = ("--port", $cfgPort);
    push @params, "--db";
    push @params, $dbPath;
    push @params, "--address";
    push @params, "127.0.0.1";
    if ($prefs->get('mixerdebug')) {
        push @params, "--logging";
        push @params, "debug";
    }
    push @params, "--weights";
    $lastWeights = _weightParam();
    push @params, $lastWeights;
    # Auto-detect learned metric matrix
    my $matrixFile = Plugins::BlissMixerExt::Survey::matrixPath();
    if ($matrixFile && -e $matrixFile) {
        push @params, "--matrix";
        push @params, $matrixFile;
        main::INFOLOG && $log->info("Using learned matrix: $matrixFile");
    }
    main::DEBUGLOG && $log->debug("Start mixer: $mixerBinary @params");
    eval { $mixer = Proc::Background->new({ 'die_upon_destroy' => 1 }, $mixerBinary, @params); };
    if ($@) {
        $log->warn($@);
    } else {
        $dbSignature = _databaseSignature();
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, sub {
            if ($mixer && $mixer->alive) {
                main::DEBUGLOG && $log->debug("$mixerBinary running");
                _checkIfMixerReady(0, $cfgPort);
            } else {
                main::DEBUGLOG && $log->debug("$mixerBinary NOT running");
            }
        });
    }

    # Store start time
    $lastMixerStart = $now;
    return 1;
}

sub _cliCommand {
    my $request = shift;

    if ($request->isNotCommand([['blissmixerext']])) {
        $request->setStatusBadDispatch();
        return;
    }

    my $cmd = $request->getParam('_cmd');
    if ($request->paramUndefinedOrNotOneOf($cmd, ['port', 'stop', 'survey'])) {
        $request->setStatusBadParams();
        return;
    }

    if ($cmd eq 'port') {
        my $number = $request->getParam('number');
        if (!$number) {
            $request->setStatusBadParams();
            return;
        }
        $mixerPort = int($number);
        $request->setStatusDone();
        return;
    }

    if ($cmd eq 'stop') {
        _stopMixer();
        $request->setStatusDone();
        return;
    }

    Plugins::BlissMixerExt::Survey::cliCommand($request);
}
sub _getMixableProperties {
    my ($client, $count, $strict) = @_;

    return unless $client;

    $client = $client->master;

    my ($trackId, $artist, $title, $duration);
    my $tracks = [];
    my $durationFilteredTracks = [];
    my $pos = 0;
    my $minDuration = int($prefs->get('min_duration') || 0);
    my $maxDuration = int($prefs->get('max_duration') || 0);
    my $minCount = $count && $count>4 ? $count-2 : $count;
    my $collectLimit = $strict ? $count : ($count * 2);

    # Get last tracks from queue (strict: exactly count, otherwise count*2)
    foreach (reverse @{ Slim::Player::Playlist::playList($client) } ) {
        ($artist, $title, $duration, $trackId) = Slim::Plugin::DontStopTheMusic::Plugin->getMixablePropertiesFromTrack($client, $_);

        # We reverse the queue (to get last N tracks) so need to check if 1st item in this list is radio
        if ($pos==0 && !$duration) {
            main::INFOLOG && $log->info("Found radio station last in the queue - don't start a mix.");
        }
        $pos++;

        next unless defined $artist && defined $title;

        if ((0!=$minDuration && $duration<$minDuration) || (0!=$maxDuration && $duration>$maxDuration)) {
            push @$durationFilteredTracks, $trackId;
            next;
        }

        push @$tracks, $trackId;
        if ($count && scalar @$tracks >= $collectLimit) {
            last;
        }
    }

    # Too few tracks? Add some that were filtered due to duration
    if ($minCount && scalar @$tracks < $minCount && scalar @$durationFilteredTracks) {
        foreach my $trackId (@$durationFilteredTracks) {
            push @$tracks, $trackId;
            if (scalar @$tracks >= $minCount) {
                last;
            }
        }
    }

    if (scalar @$tracks) {
        main::INFOLOG && $log->info($strict
            ? "Using last " . scalar(@$tracks) . " tracks from current playlist"
            : "Auto-mixing from random tracks in current playlist");

        if ($count && scalar @$tracks > $count) {
            Slim::Player::Playlist::fischer_yates_shuffle($tracks);
            splice(@$tracks, $count);
        }

        return $tracks;
    } elsif (main::INFOLOG && $log->is_info) {
        main::INFOLOG && $log->info("No mixable items found in current playlist!");
    }

    return;
}

sub _mixerNotAvailable {
    my ($client, $cb) = @_;
    my $numSpot = 0;
    my $seedTracks = _getMixableProperties($client, NUM_SEED_TRACKS); # Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client,
    if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
        foreach my $seedTrack (@$seedTracks) {
            my ($trackObj) = Slim::Schema->find('Track', $seedTrack);
            if ($trackObj) {
                if ( $trackObj->path =~ m/^spotify:/ ) {
                    $numSpot++;
                }
            }
        }
    }
    _mixFailed($client, $cb, $numSpot);
}

sub _startsWith {
    my $str = shift;
    my $needle = shift;
    return rindex($str, $needle, 0)!=-1 ? 1 : 0;
}

# Convert a track object into a path relative to music folder
sub _trackToPath {
    my $mediaDirs = shift;
    my $track = shift;

    # Is this a CUE track? If so encode <file>#<start>-<stop> as <file>.CUE_TRACK.<num>
    my @parts = split(/#/, $track->url);
    my $suffix = "";
    if (2==scalar(@parts)) {
        $suffix = ".CUE_TRACK." . $track->tracknum;
    }

    # Get track's path relative to mediaDir
    my $path = $track->path;
    if (main::ISWINDOWS) {
       $path =~ s#\\#/#g;
    }

    foreach my $mediaDir (@$mediaDirs) {
        my $mdLen = length($mediaDir);
        if ($mdLen<1) {
            next;
        }
        if (main::ISWINDOWS) {
            $mediaDir =~ s#\\#/#g;
        }
        if (_startsWith($path, $mediaDir)) {
            $path = substr($path, $mdLen);
            $path = Slim::Utils::Unicode::utf8decode_locale($path);
            last;
        }
    }

    # Remove any leading slash
    if (_startsWith($path, "/")) {
        $path = substr($path, 1);
    }

    return $path . $suffix;
}

# Convert a path relative to music folder to a track object
sub _pathToTrack {
    my $mediaDirs = shift;
    my $path = shift;
    my $sep = "/";

    if (main::ISWINDOWS) {
        $path =~ s#/#\\#g;
        $sep = "\\";
    }

    # Decode <file>.CUE_TRACK.<num> to <file>#<start>-<stop>
    my $cueTrackNum = 0;
    my @parts = split(/\.CUE_TRACK\./, $path);
    if (2==scalar(@parts)) {
        $cueTrackNum = int($parts[1]);
        $path = @parts[0];
    }

    foreach my $mediaDir (@$mediaDirs) {
        my $mdLen = length($mediaDir);
        if ($mdLen<1) {
            next;
        }

        if (main::ISWINDOWS) {
           $mediaDir =~ s#/#\\#g;
        }
        my $md = substr($mediaDir, -1) eq $sep ? $mediaDir : "${mediaDir}${sep}";
        my $absPath = "${md}${path}";

        # Bug 4281 - need to convert from UTF-8 on Windows.
        if (main::ISWINDOWS && !-e $absPath && -e Win32::GetANSIPathName($absPath)) {
            $absPath = Win32::GetANSIPathName($absPath);
        }

        if (-e $absPath || -e Slim::Utils::Unicode::utf8encode_locale($absPath)) {
            my $url = Slim::Utils::Misc::fileURLFromPath($absPath);

            if ($cueTrackNum>0) {
                # Get URL of specific track in CUE file
                my $dbh = Slim::Schema->dbh;
                my $sql = $dbh->prepare("SELECT url FROM tracks WHERE url LIKE '$url#%' AND tracknum = $cueTrackNum LIMIT 1");
                $sql->execute();
                if ( my $result = $sql->fetchall_arrayref({}) ) {
                    my $trackUrl = $result->[0]->{'url'} if ref $result && scalar @$result;
                    if ($trackUrl) {
                        # Got URL now get object
                        my $trackObj = Slim::Schema->objectForUrl($trackUrl);
                        if (blessed $trackObj) {
                            return $trackObj;
                        }
                    }
                }
            } else {
                my $trackObj = Slim::Schema->objectForUrl($url);
                if (blessed $trackObj) {
                    return $trackObj;
                }
            }
        }
    }
}

sub _dstmMix {
    my ($client, $cb, $filterGenres, $callCount) = @_;

    if (_originalAnalyserRunning()) {
        _stopMixer();
        $log->warn('Upstream BlissMixer analysis is running; Bliss (Ext) is temporarily unavailable');
        _mixerNotAvailable($client, $cb);
        return;
    }

    my $currentDbSignature = _databaseSignature();
    if ($mixer && $mixer->alive && $dbSignature ne $currentDbSignature) {
        main::INFOLOG && $log->info('Upstream bliss.db changed; restarting bliss-mixer-ext');
        _stopMixer();
    }

    if (_weightParam() ne $lastWeights) {
        _stopMixer();
    }

    # If mixer is not running, or not yet informed us of its port, then start mixer
    if (!$mixer || !$mixer->alive || $mixerPort<1) {
        if ($mixerBinary && $callCount < MAX_MIXER_START_CHECKS) {
            $callCount++;
            my $ok = _startMixer(0);
            if ($ok == 1) {
                Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, sub {
                    _dstmMix($client, $cb, $filterGenres, $callCount);
                });
                return;
            }
        }

        $lastMixerStart = 0;
        _mixerNotAvailable($client, $cb);
        return;
    }

    _resetMixerTimeout();

    main::DEBUGLOG && $log->debug("Get tracks");
    my $useForest = $prefs->get('use_forest') || 0;
    my $useAdaptiveWeights = $prefs->get('use_adaptive_weights') || 0;
    my $numSeedTracks = $useAdaptiveWeights
        ? ($prefs->get('num_seed_tracks') || 3)
        : ($useForest ? NUM_FOREST_SEED_TRACKS : NUM_SEED_TRACKS);
    my $strictSeeds = $useAdaptiveWeights && ($prefs->get('seed_strict_order') // 1);
    my $seedTracks = _getMixableProperties($client, $numSeedTracks, $strictSeeds);

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
                if ( $trackObj->path =~ m/^spotify:/ ) {
                    $numSpot++;
                } elsif (! ($trackObj->path =~ m/^deezer:/ || $trackObj->path =~ m/^qobuz:/ || $trackObj->path =~ m/^wimp:/) ) {
                    push @seedsToUse, $trackObj;
                    push @seedIds, $seedTrack;
                }
            }
        }

        if (scalar @seedsToUse > 0) {
            if (main::INFOLOG) {
                my $strategy;
                my $singleSeedLearnedOverride = 0;
                my $configuredBlend;
                if ($useAdaptiveWeights) {
                    my $blend = int($extprefs->get('learned_blend') // 50);
                    $configuredBlend = $blend;
                    my $matrixFile = Plugins::BlissMixerExt::Survey::matrixPath();
                    my $hasMatrix = $matrixFile && -e $matrixFile;
                    $singleSeedLearnedOverride = $hasMatrix && scalar(@seedsToUse) == 1;
                    my $lfm = $prefs->get('use_lastfm_weighting') && exists $INC{'Plugins/LastMix/LFM.pm'};
                    my $blendDesc = !$hasMatrix || $blend == 0 ? 'pure variance-based'
                                  : $blend == 100              ? 'pure learned matrix'
                                  :                              "${blend}% learned matrix";
                    my @details = ($blendDesc);
                    push @details, 'Last.fm enabled' if $lfm;
                    $strategy = 'adaptive weighting (' . join(', ', @details) . ')';
                } elsif ($useForest) {
                    $strategy = 'extended isolation forest';
                } else {
                    $strategy = 'static weights';
                }
                $log->info("Mixing strategy: $strategy");
                if ($singleSeedLearnedOverride && defined $configuredBlend && $configuredBlend < 100) {
                    $log->info("Single-seed override: using pure learned matrix.");
                }
                # At debug level the upstream "Seed /path id:X" messages already list seeds
                unless ($log->is_debug) {
                    $log->info("Seed: " . $_->artistName . " - " . $_->title) for @seedsToUse;
                }
            }

            my $dstm_tracks = $prefs->get('dstm_tracks') || DEF_NUM_DSTM_TRACKS;
            my $lastfmWeighting = $useAdaptiveWeights && $prefs->get('use_lastfm_weighting')
                && exists $INC{'Plugins/LastMix/LFM.pm'};
            my $requestCount = $lastfmWeighting ? $dstm_tracks * 10 : $dstm_tracks;
            my $shuffle = $lastfmWeighting ? 0 : 1;
            # Inflate norepart/norepalb to cover the full pool so the sliding window
            # in bliss-mixer never scrolls past a recently-played artist/album as the
            # large output list is built up (formula: user_setting + requestCount - 1)
            my ($noRepArtOverride, $noRepAlbOverride);
            if ($lastfmWeighting) {
                my $noRepArt = int($prefs->get('no_repeat_artist') || 0);
                my $noRepAlb = int($prefs->get('no_repeat_album') || 0);
                $noRepArtOverride = $noRepArt > 0 ? $noRepArt + $requestCount - 1 : undef;
                $noRepAlbOverride = $noRepAlb > 0 ? $noRepAlb + $requestCount - 1 : undef;
            }

            my $maxNumPrevTracks = $prefs->get('no_repeat_track');
            if ($maxNumPrevTracks<0 || $maxNumPrevTracks>MAX_PREVIOUS_TRACKS) {
                $maxNumPrevTracks = DEF_MAX_PREVIOUS_TRACKS;
            }
            # When Last.fm weighting inflates norepart, ensure we fetch enough previous
            # tracks to populate that window — otherwise bliss-mixer receives an empty
            # previous list and artist-repeat filtering has no context to work from.
            my $prevFetchCount = $maxNumPrevTracks;
            $prevFetchCount = $noRepArtOverride if defined $noRepArtOverride && $noRepArtOverride > $prevFetchCount;
            $prevFetchCount = $noRepAlbOverride if defined $noRepAlbOverride && $noRepAlbOverride > $prevFetchCount;
            my $previousTracks = _getPreviousTracks($client, $prevFetchCount);
            main::DEBUGLOG && $log->debug("Num tracks to previous: " . ($previousTracks ? scalar(@$previousTracks) : 0));

            # Collect comparison seeds for "what-if" logging (debug only, adaptive weights only)
            my @staticCompSeeds = ();
            my @eifCompSeeds = ();
            if ($log->is_debug && $useAdaptiveWeights) {
                my $staticSeedTracks = _getMixableProperties($client, NUM_SEED_TRACKS, 0);
                if ($staticSeedTracks && ref $staticSeedTracks) {
                    foreach my $st (@$staticSeedTracks) {
                        my ($obj) = Slim::Schema->find('Track', $st);
                        if ($obj && !($obj->path =~ m/^spotify:/ || $obj->path =~ m/^deezer:/ || $obj->path =~ m/^qobuz:/ || $obj->path =~ m/^wimp:/)) {
                            push @staticCompSeeds, $obj;
                        }
                    }
                }
                my $eifSeedTracks = _getMixableProperties($client, NUM_FOREST_SEED_TRACKS, 0);
                if ($eifSeedTracks && ref $eifSeedTracks) {
                    foreach my $st (@$eifSeedTracks) {
                        my ($obj) = Slim::Schema->find('Track', $st);
                        if ($obj && !($obj->path =~ m/^spotify:/ || $obj->path =~ m/^deezer:/ || $obj->path =~ m/^qobuz:/ || $obj->path =~ m/^wimp:/)) {
                            push @eifCompSeeds, $obj;
                        }
                    }
                }
            }

            my $jsonData = _getMixData(\@seedsToUse, $previousTracks ? \@$previousTracks : undef, $requestCount, $shuffle, $filterGenres, $noRepArtOverride, $noRepAlbOverride);
            my $port = $mixerPort;
            unless ($port) {
                _mixFailed($client, $cb, $numSpot);
                return;
            }
            my $url = "http://localhost:$port/api/mix";
            main::DEBUGLOG && $log->debug("URL: ${url}");
            Slim::Networking::SimpleAsyncHTTP->new(
                sub {
                    my $response = shift;
                    main::DEBUGLOG && $log->debug("Received API response: " . ($response->headers->header('X-Bliss-Debug') || $response->content));

                    # Analyse and log dynamic weights debug info if returned by bliss-mixer
                    if (main::INFOLOG) {
                        my $debugHeader = $response->headers->header('X-Bliss-Debug');
                        if ($debugHeader) {
                            eval {
                                my $dbg = from_json($debugHeader);
                                if ($dbg->{weights} && ref($dbg->{weights}) eq 'ARRAY') {
                                    my %w = map { $_->{feature} => $_->{weight} } @{$dbg->{weights}};

                                    # Sum per-feature weights within each metric group
                                    my $tempo_sum  = $w{Tempo} // 0;
                                    my $timbre_sum = 0;
                                    $timbre_sum += ($w{$_} // 0) for qw(Zcr MeanSpectralCentroid StdDeviationSpectralCentroid MeanSpectralRolloff StdDeviationSpectralRolloff MeanSpectralFlatness StdDeviationSpectralFlatness);
                                    my $loudness_sum = ($w{MeanLoudness} // 0) + ($w{StdDeviationLoudness} // 0);
                                    my $chroma_sum = 0;
                                    $chroma_sum += ($w{"Chroma$_"} // 0) for 1..13;

                                    # Compute equivalent static slider values.
                                    # Static pipeline: slider s -> per-feature w = (s/total*100)/ref -> effective weight w²
                                    # Dynamic pipeline: per-feature weight W_i -> effective weight W_i
                                    # Equivalent: w² = avg(W_i for group) -> w = √avg -> s = w * ref
                                    # Then normalize so sliders sum to 100.
                                    my $eq_tempo    = sqrt($tempo_sum / 1)  * 4;    # 1 feature,  ref=4
                                    my $eq_timbre   = sqrt($timbre_sum / 7) * 30;   # 7 features, ref=30
                                    my $eq_loudness = sqrt($loudness_sum / 2) * 9;  # 2 features, ref=9
                                    my $eq_chroma   = sqrt($chroma_sum / 13) * 57;  # 13 features, ref=57
                                    my $eq_total = $eq_tempo + $eq_timbre + $eq_loudness + $eq_chroma;
                                    if ($eq_total > 0) {
                                        # Scale to sum=96, then +1 each → sum=100, all values in 1..97
                                        my $eq_scale = 96.0 / $eq_total;
                                        $eq_tempo    = 1 + $eq_tempo    * $eq_scale;
                                        $eq_timbre   = 1 + $eq_timbre   * $eq_scale;
                                        $eq_loudness = 1 + $eq_loudness * $eq_scale;
                                        $eq_chroma   = 1 + $eq_chroma   * $eq_scale;
                                        $log->info(sprintf("Equivalent static sliders: Tempo=%.0f  Timbre=%.0f  Loudness=%.0f  Chroma=%.0f  (configured: %d/%d/%d/%d)",
                                            $eq_tempo, $eq_timbre, $eq_loudness, $eq_chroma,
                                            int($prefs->get('weight_tempo') || 4), int($prefs->get('weight_timbre') || 30),
                                            int($prefs->get('weight_loudness') || 9), int($prefs->get('weight_chroma') || 57)));
                                    }

                                    # Sort features by weight to find strongest/weakest seed similarities
                                    my @sorted = sort { $b->{weight} <=> $a->{weight} } @{$dbg->{weights}};
                                    my @top3    = @sorted[0..2];
                                    my @bottom3 = @sorted[-3..-1];

                                    $log->info("Strongest seed similarities (highest weight): "
                                        . join(", ", map { sprintf("%s=%.2f", $_->{feature}, $_->{weight}) } @top3));
                                    $log->info("Weakest seed similarities (lowest weight): "
                                        . join(", ", map { sprintf("%s=%.2f", $_->{feature}, $_->{weight}) } @bottom3));
                                }

                                if ($dbg->{stats}) {
                                    my $s = $dbg->{stats};
                                    $log->info(sprintf("Stats: %d tracks in DB, %d scored, %d usable (discarded: dur=%d bpm=%d genre=%d xmas=%d album=%d; filtered: artist=%d album=%d title=%d)",
                                        $s->{db_total}, $s->{scored}, $s->{usable},
                                        $s->{discarded_duration}, $s->{discarded_bpm}, $s->{discarded_genre}, $s->{discarded_xmas}, $s->{discarded_album},
                                        $s->{filtered_artist}, $s->{filtered_album}, $s->{filtered_title}));
                                }

                                if ($dbg->{timing_ms}) {
                                    my $t = $dbg->{timing_ms};
                                    $log->debug(sprintf("Timing: %dms total (db=%dms calc=%dms sort=%dms filter=%dms)",
                                        $t->{total}, $t->{db_load}, $t->{distance_calc}, $t->{sort}, $t->{filter}));
                                }
                            };
                            if ($@) {
                                $log->debug("Failed to parse debug header: $@");
                            }
                        }
                    }

                    my @songs = split(/\n/, $response->content);
                    my $count = scalar @songs;
                    my $tracks = ();
                    my @trackObjs = ();
                    my $mediaDirs = Slim::Utils::Misc::getMediaDirs('audio');

                    for (my $j = 0; $j < $count; $j++) {
                        my $trackObj = _pathToTrack($mediaDirs, $songs[$j]);
                        if (blessed $trackObj) {
                            push @$tracks, $trackObj->url;
                            push @trackObjs, $trackObj;
                            main::DEBUGLOG && $log->debug("  " . $trackObj->path);
                        } else {
                            $log->error('API attempted to mix in a song at ' . $songs[$j] . ' that can\'t be found at that location');
                        }
                    }

                    if (!defined $tracks) {
                        _mixFailed($client, $cb, $numSpot);
                    } else {
                        main::DEBUGLOG && $log->debug("Num tracks to use:" . scalar(@$tracks));
                        if (scalar @$tracks > 0) {
                            if ($lastfmWeighting) {
                                _selectViaLastFm(\@seedsToUse, \@trackObjs, $dstm_tracks, sub {
                                    my $weightedUrls = shift;
                                    $cb->($client, $weightedUrls);
                                });
                            } else {
                                if (main::INFOLOG) {
                                    $log->info("Selected tracks (" . scalar(@trackObjs) . "):");
                                    $log->info("  " . $_->artistName . " - " . $_->title) for @trackObjs;
                                }
                                $cb->($client, $tracks);
                            }

                            # Fire "what-if" comparison requests (debug only, adaptive weights only)
                            # Queued and fired sequentially to avoid overwhelming bliss-mixer
                            if (main::DEBUGLOG && $useAdaptiveWeights) {
                                my $prevRef = $previousTracks ? \@$previousTracks : undef;
                                my @compQueue = ();
                                if (scalar @staticCompSeeds > 0) {
                                    my $staticJson = _buildComparisonJson(\@staticCompSeeds, $prevRef, $dstm_tracks, $filterGenres, 0, 0, 0);
                                    my $staticDesc = sprintf("static weights (Tempo=%d/Timbre=%d/Loudness=%d/Chroma=%d)",
                                        int($prefs->get('weight_tempo') || 4), int($prefs->get('weight_timbre') || 30),
                                        int($prefs->get('weight_loudness') || 9), int($prefs->get('weight_chroma') || 57));
                                    push @compQueue, [$url, $staticDesc, $staticJson];
                                }
                                if (scalar @eifCompSeeds >= 4) {
                                    my $eifJson = _buildComparisonJson(\@eifCompSeeds, $prevRef, $dstm_tracks, $filterGenres, 1, 0, 0);
                                    push @compQueue, [$url, "extended isolation forest", $eifJson];
                                } else {
                                    $log->debug('Comparison for "extended isolation forest" skipped (needs >= 4 seeds, have ' . scalar(@eifCompSeeds) . ')');
                                }
                                # Pure variance-based (no learned matrix influence) — skip if already at blend=0%
                                my $currentBlend = int($extprefs->get('learned_blend') // 50);
                                if ($currentBlend != 0) {
                                    my $varianceJson = _buildComparisonJson(\@seedsToUse, $prevRef, $dstm_tracks, $filterGenres, 0, 1, 0);
                                    push @compQueue, [$url, "adaptive weighting (pure variance, blend=0%)", $varianceJson];
                                }
                                # Pure learned-matrix (full learned matrix influence) — skip if already at blend=100%
                                if ($currentBlend != 100) {
                                    my $learnedJson = _buildComparisonJson(\@seedsToUse, $prevRef, $dstm_tracks, $filterGenres, 0, 1, 100);
                                    push @compQueue, [$url, "adaptive weighting (pure learned, blend=100%)", $learnedJson];
                                }
                                _fireComparisonQueue(\@compQueue) if @compQueue;
                            }
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
        } else {
            _mixFailed($client, $cb, $numSpot);
        }
    }
}

sub _selectViaLastFm {
    my ($seeds, $trackObjs, $finalCount, $cb) = @_;

    my @seedInfo;
    my %lastfmArtists;
    my %seenArtists;
    my $targetPercent = int($prefs->get('lastfm_weighting_weight') || 25);
    $targetPercent = 1 if $targetPercent < 1;
    $targetPercent = 100 if $targetPercent > 100;

    $log->debug("Last.fm weighted selection: " . scalar(@$seeds) . " seeds, " . scalar(@$trackObjs) . " bliss candidates, target=$targetPercent%, selecting $finalCount");

    foreach my $seed (@$seeds) {
        my $key = _lastfmNormalizeArtist($seed->artistName);
        $lastfmArtists{$key} = 1;
        unless ($seenArtists{$key}++) {
            push @seedInfo, {
                artist      => $seed->artistName,
                artist_mbid => ($seed->artist ? $seed->artist->musicbrainz_id : undef),
            };
        }
    }

    _fetchSimilarArtistsForSeeds([@seedInfo], \%lastfmArtists, sub {
        my ($hadError, $stats) = @_;
        $stats ||= {};

        if ($hadError) {
            my $poolSize = scalar @$trackObjs;
            my $end = ($finalCount - 1 < $#{$trackObjs}) ? $finalCount - 1 : $#{$trackObjs};
            if (main::INFOLOG) {
                $log->info("Last.fm API error: falling back to pure bliss top-$finalCount tracks");
                $log->info(sprintf("Last.fm artist selection: 0 last.fm-endorsed, %d bliss-only in pool of %d (target=%d%%) -> selected %d",
                    $poolSize, $poolSize, $targetPercent, $end + 1));
                for my $i (0 .. $end) {
                    $log->info("  [bliss-only, similarity-rank " . ($i + 1) . "/$poolSize] "
                        . $trackObjs->[$i]->artistName . " - " . $trackObjs->[$i]->title);
                }
            }
            my $urls = [ map { $_->url } @{$trackObjs}[0..$end] ];
            $cb->($urls);
            return;
        }

        if (main::INFOLOG && ($stats->{failed} || 0) > 0) {
            my $ok = $stats->{succeeded} || 0;
            my $failed = $stats->{failed} || 0;
            $log->info("Last.fm partial result: $ok seed lookups succeeded, $failed failed; using collected endorsements");
        }

        main::INFOLOG && $log->info("Last.fm: " . scalar(keys %lastfmArtists) . " endorsed artists (incl. seed artists)");

        my @weighted;
        my ($endorsed_count, $rest_count) = (0, 0);
        my $poolSize = scalar @$trackObjs;
        for my $i (0 .. $#$trackObjs) {
            my $trackObj = $trackObjs->[$i];
            my $artistKey = _lastfmNormalizeArtist($trackObj->artistName);
            my $endorsed = exists $lastfmArtists{$artistKey};
            if ($endorsed) { $endorsed_count++ } else { $rest_count++ }
            push @weighted, { track => $trackObj, endorsed => $endorsed, rank => $i + 1 };
        }

        my $endorsedWeight = _lastfmEndorsedWeightForPercent($targetPercent, $endorsed_count, $rest_count);
        for my $entry (@weighted) {
            my $w = $entry->{endorsed} ? $endorsedWeight : 1;
            my $key = rand() ** (1.0 / $w);
            $entry->{key} = $key;
        }

        @weighted = sort { $b->{key} <=> $a->{key} } @weighted;
        splice(@weighted, $finalCount) if $poolSize > $finalCount;

        main::INFOLOG && $log->info(sprintf(
            "Last.fm artist selection: %d last.fm-endorsed, %d bliss-only in pool of %d (target=%d%%, computed weight=%.3f) -> selected %d",
            $endorsed_count, $rest_count, scalar @$trackObjs, $targetPercent, $endorsedWeight, scalar @weighted));

        if (main::INFOLOG) {
            my $rankWidth = length("$poolSize");
            my $maxTierLen = 0;
            for my $entry (@weighted) {
                my $len = $entry->{endorsed} ? length('last.fm-endorsed') : length('bliss-only');
                $maxTierLen = $len if $len > $maxTierLen;
            }
            my $tierWidth = $maxTierLen + 2;  # +2 for one space padding each side
            foreach my $entry (@weighted) {
                my $tier = $entry->{endorsed} ? 'last.fm-endorsed' : 'bliss-only';
                my $pad  = $tierWidth - length($tier);
                my $lpad = ' ' x int($pad / 2);
                my $rpad = ' ' x ($pad - int($pad / 2));
                $log->info(sprintf("  [%s%s%s| similarity-rank %*d/%d ] %s - %s",
                    $lpad, $tier, $rpad, $rankWidth, $entry->{rank}, $poolSize,
                    $entry->{track}->artistName, $entry->{track}->title));
            }
        }

        my $urls = [ map { $_->{track}->url } @weighted ];
        $cb->($urls);
    });
}

sub _lastfmEndorsedWeightForPercent {
    my ($targetPercent, $endorsedCount, $restCount) = @_;

    return 1 if $endorsedCount <= 0 || $restCount <= 0;
    return 1000000 if $targetPercent >= 100;

    my $target = $targetPercent / 100.0;
    my $weight = ($target * $restCount) / ((1.0 - $target) * $endorsedCount);
    return $weight > 0 ? $weight : 0.000001;
}

sub _fetchSimilarArtistsForSeeds {
    my ($seedInfo, $resultHash, $cb, $stats) = @_;
    $stats ||= { succeeded => 0, failed => 0 };

    if (!@$seedInfo) {
        my $allFailed = $stats->{failed} > 0 && $stats->{succeeded} == 0;
        $cb->($allFailed ? 1 : 0, $stats);
        return;
    }

    my $seed = shift @$seedInfo;
    main::DEBUGLOG && $log->debug("Last.fm: getSimilarArtists for \"" . ($seed->{artist} // '') . "\"");

    Plugins::LastMix::LFM->getSimilarArtists(sub {
        my $results = shift;
        if ($results && ref $results && $results->{error}) {
            my $msg = $results->{message} // "code " . $results->{error};
            $log->warn("Last.fm error for \"" . ($seed->{artist} // '') . "\": $msg");
            $stats->{failed}++;
            _fetchSimilarArtistsForSeeds($seedInfo, $resultHash, $cb, $stats);
            return;
        } elsif ($results && ref $results && $results->{similarartists} && ref $results->{similarartists}) {
            $stats->{succeeded}++;
            my $artists = $results->{similarartists}->{artist};
            if ($artists && ref $artists eq 'ARRAY') {
                my $count = 0;
                foreach my $a (@$artists) {
                    next unless $a->{name};
                    my $key = _lastfmNormalizeArtist($a->{name});
                    $resultHash->{$key} = 1;
                    $count++;
                }
                main::INFOLOG && $log->info("Last.fm: got $count similar artists for \"" . ($seed->{artist} // '') . "\"");
                if (main::DEBUGLOG) {
                    $log->debug("  Last.fm similar artist: " . $_->{name}) for grep { $_->{name} } @$artists;
                }
            }
        } else {
            $stats->{succeeded}++;
            main::INFOLOG && $log->info("Last.fm: no similar artists returned for \"" . ($seed->{artist} // '') . "\"");
        }
        _fetchSimilarArtistsForSeeds($seedInfo, $resultHash, $cb, $stats);
    }, {
        artist => $seed->{artist},
        mbid   => $seed->{artist_mbid},
    });
}

sub _lastfmNormalizeArtist {
    my $artist = shift;
    my $a = lc($artist // '');
    $a =~ s/^\s+|\s+$//g;
    return $a;
}

sub prefName {
    my $class = shift;
    return lc($class->title);
}

sub title {
    my $class = shift;
    return 'BlissMixerExt';
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
    my $noRepArtOverride = shift;
    my $noRepAlbOverride = shift;
    my @tracks = ref $seedTracks ? @$seedTracks : ($seedTracks);
    my @previous = ref $previousTracks ? @$previousTracks : ($previousTracks);
    my @mix = ();
    my @track_paths = ();
    my @previous_paths = ();
    my $mediaDirs = Slim::Utils::Misc::getMediaDirs('audio');

    foreach my $track (@tracks) {
        push @track_paths, _trackToPath($mediaDirs, $track);
    }

    if ($previousTracks and scalar @previous > 0) {
        foreach my $track (@previous) {
            push @previous_paths, _trackToPath($mediaDirs, $track);
        }
    }

    my $filterXmas = 1;
    my $filterXmpsPref = $prefs->get('filter_xmas');
    if (defined $filterXmpsPref) {
        $filterXmas = int($filterXmpsPref);
    }

    my $jsonData = to_json({
                        count       => int($trackCount),
                        filtergenre => int($filterGenres),
                        filterxmas  => $filterXmas,
                        min         => int($prefs->get('min_duration') || 0),
                        max         => int($prefs->get('max_duration') || 0),
                        maxbpmdiff  => int($prefs->get('max_bpm_diff') || 0),
                        tracks      => [@track_paths],
                        previous    => [@previous_paths],
                        shuffle     => int($shuffle),
                        norepart    => int($noRepArtOverride // $prefs->get('no_repeat_artist')),
                        norepalb    => int($noRepAlbOverride // $prefs->get('no_repeat_album')),
                        forest      => int($prefs->get('use_forest') || 0),
                        adaptiveweights => int($prefs->get('use_adaptive_weights') || 0),
                        learnedblend => int($extprefs->get('learned_blend') // 50),
                        genregroups => _genreGroups(),
                        allgenres   => int($prefs->get('match_all_genres') || 0),
                        main::DEBUGLOG ? (debug => 1) : ()
                    });
    main::DEBUGLOG && $log->debug("Request $jsonData");
    return $jsonData;
}

sub _buildComparisonJson {
    my ($seedTracks, $previousTracks, $trackCount, $filterGenres, $forest, $adaptiveweights, $learnedblend) = @_;
    my @tracks = ref $seedTracks ? @$seedTracks : ($seedTracks);
    my @track_paths = ();
    my @previous_paths = ();
    my $mediaDirs = Slim::Utils::Misc::getMediaDirs('audio');

    foreach my $track (@tracks) {
        push @track_paths, _trackToPath($mediaDirs, $track);
    }

    if ($previousTracks and ref $previousTracks eq 'ARRAY' and scalar @$previousTracks > 0) {
        foreach my $track (@$previousTracks) {
            push @previous_paths, _trackToPath($mediaDirs, $track);
        }
    }

    my $filterXmas = 1;
    my $filterXmpsPref = $prefs->get('filter_xmas');
    if (defined $filterXmpsPref) {
        $filterXmas = int($filterXmpsPref);
    }

    return to_json({
                        count       => int($trackCount),
                        filtergenre => int($filterGenres),
                        filterxmas  => $filterXmas,
                        min         => int($prefs->get('min_duration') || 0),
                        max         => int($prefs->get('max_duration') || 0),
                        maxbpmdiff  => int($prefs->get('max_bpm_diff') || 0),
                        tracks      => [@track_paths],
                        previous    => [@previous_paths],
                        shuffle     => 1,
                        norepart    => int($prefs->get('no_repeat_artist')),
                        norepalb    => int($prefs->get('no_repeat_album')),
                        forest      => int($forest),
                        adaptiveweights => int($adaptiveweights),
                        learnedblend => int($learnedblend // 0),
                        genregroups => _genreGroups(),
                        allgenres   => int($prefs->get('match_all_genres') || 0),
                    });
}

# Fire comparison requests sequentially (each waits for the previous to finish)
sub _fireComparisonQueue {
    my $queue = shift;
    return unless @$queue;

    my $entry = shift @$queue;
    my ($url, $strategyName, $jsonData) = @$entry;

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $response = shift;
            my @songs = split(/\n/, $response->content);
            $log->debug("Mixing strategy \"${strategyName}\" would have chosen:");
            my $mediaDirs = Slim::Utils::Misc::getMediaDirs('audio');
            foreach my $song (@songs) {
                my $trackObj = _pathToTrack($mediaDirs, $song);
                if (blessed $trackObj) {
                    $log->debug("  " . $trackObj->path);
                }
            }
            # Fire next comparison in queue
            _fireComparisonQueue($queue);
        },
        sub {
            my $response = shift;
            $log->debug("Comparison request for \"${strategyName}\" failed: " . $response->error);
            # Continue with next even on failure
            _fireComparisonQueue($queue);
        }
    )->post($url, 'Content-Type' => 'application/json;charset=utf-8', $jsonData);
}

my $genreGroups = [];
my $genreGroupsTs = 0;
my $useTrackGenreTs = 0;

sub _genreGroups {
    # Check to see if config has changed, saves having to read and process each time
    my $ggTs = $prefs->get('_ts_genre_groups');
    my $utgTs = $prefs->get('_ts_use_track_genre');
    if ($ggTs==$genreGroupsTs && $utgTs==$useTrackGenreTs) {
        return $genreGroups;
    }
    $genreGroupsTs = $ggTs;
    $useTrackGenreTs = $utgTs;

    $genreGroups = [];
    my %genresInGroups=();
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
                if (length $genre > 0) {
                    push(@$grp, $genre);
                    $genresInGroups{$genre}=1;
                }
            }
            if (scalar $grp > 0) {
                push(@$genreGroups, $grp);
            }
        }
    }
    if ($prefs->get('use_track_genre')) {
        my $request = Slim::Control::Request::executeRequest(undef, ["genres", 0, 5000] );
        foreach my $genre ( @{ $request->getResult('genres_loop') || [] } ) {
            my $name = $genre->{genre};
            if ($name && (not exists($genresInGroups{$name}))) {
                $genresInGroups{$name}=1;
                my $grp = ();
                push(@$grp, $name);
                push(@$genreGroups, $grp);
            }
        }
    }
    return $genreGroups;
}

1;

__END__
