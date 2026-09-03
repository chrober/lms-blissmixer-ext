use strict;
use warnings;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use JSON::PP ();

BEGIN {
    package main;
    sub INFOLOG () { 0 }
    sub DEBUGLOG () { 0 }
    sub WEBUI () { 0 }
    sub ISWINDOWS () { 0 }
    sub ISMAC () { 0 }
    sub STATISTICS () { 1 }

    package TestPrefs;
    our %values = (
        'plugin.blissmixer' => {
            mixer_port => 12000,
            weight_tempo => 4,
            weight_timbre => 30,
            weight_loudness => 9,
            weight_chroma => 57,
            _ts_genre_groups => 1,
            _ts_use_track_genre => 1,
            genre_groups => " Rock ; Hard Rock \n Jazz* ; \n ; Ambient ",
            use_track_genre => 0,
        },
        'plugin.blissmixerext' => {
            learned_blend => 50,
            playcount_influence => 0,
            lastfm_track_guidance_percent => 25,
        },
    );
    sub get { return $values{$_[0]->{name}}{$_[1]} }
    sub init { return }
    sub setChange { return }

    package Slim::Utils::Prefs;
    sub preferences { return bless {name => $_[0]}, 'TestPrefs' }
    sub dir { return '/tmp' }
    sub import {
        no strict 'refs';
        *{caller() . '::preferences'} = \&preferences;
    }
    $INC{'Slim/Utils/Prefs.pm'} = __FILE__;

    package TestLog;
    sub warn { return }
    sub info { return }
    sub debug { return }
    sub error { return }
    sub is_info { return 0 }
    sub is_debug { return 0 }

    package Slim::Utils::Log;
    sub addLogCategory { return bless {}, 'TestLog' }
    sub logger { return bless {}, 'TestLog' }
    $INC{'Slim/Utils/Log.pm'} = __FILE__;

    package Slim::Utils::Misc;
    sub addFindBinPaths { return }
    sub findbin { return undef }
    sub getMediaDirs { return ['/music'] }
    $INC{'Slim/Utils/Misc.pm'} = __FILE__;

    package Slim::Utils::OSDetect;
    sub dirsFor { return '/tmp' }
    $INC{'Slim/Utils/OSDetect.pm'} = __FILE__;

    package Slim::Utils::PluginManager;
    our $manifest;
    our $dstm_enabled = 1;
    sub dataForPlugin { return $manifest }
    sub isEnabled { return $dstm_enabled }
    $INC{'Slim/Utils/PluginManager.pm'} = __FILE__;

    package Slim::Utils::Versions;
    sub compareVersions {
        my ($class, $left, $right) = @_;
        my @left = split /\./, $left;
        my @right = split /\./, $right;
        my $last = @left > @right ? $#left : $#right;
        for my $index (0 .. $last) {
            my $comparison = ($left[$index] || 0) <=> ($right[$index] || 0);
            return $comparison if $comparison;
        }
        return 0;
    }
    $INC{'Slim/Utils/Versions.pm'} = __FILE__;

    package LWP::UserAgent;
    sub new { return bless {}, $_[0] }
    sub timeout { return }
    $INC{'LWP/UserAgent.pm'} = __FILE__;

    package Proc::Background;
    sub new { return bless {}, $_[0] }
    sub alive { return 0 }
    sub die { return }
    $INC{'Proc/Background.pm'} = __FILE__;

    package JSON::XS::VersionOneAndTwo;
    sub import {
        no strict 'refs';
        my $caller = caller();
        *{"${caller}::to_json"} = sub { JSON::PP::encode_json($_[0]) };
        *{"${caller}::from_json"} = sub { JSON::PP::decode_json($_[0]) };
    }
    $INC{'JSON/XS/VersionOneAndTwo.pm'} = __FILE__;

    package Plugins::BlissMixerExt::Settings;
    sub new { return bless {}, $_[0] }
    $INC{'Plugins/BlissMixerExt/Settings.pm'} = __FILE__;

    package Plugins::BlissMixerExt::Survey;
    our $matrix_path;
    sub init { return }
    sub shutdown { return }
    sub cliCommand { return }
    sub matrixPath { return $matrix_path }
    $INC{'Plugins/BlissMixerExt/Survey.pm'} = __FILE__;

    package Slim::Plugin::DontStopTheMusic::Plugin;
    our @registered;
    sub registerHandler { push @registered, [$_[1], $_[2]] }
    sub unregisterHandler { return }
    $INC{'Slim/Plugin/DontStopTheMusic/Plugin.pm'} = __FILE__;

    package TestTrack;
    sub new {
        my ($class, $url, $playcount, $artist, $title, $mbid) = @_;
        return bless {
            url => $url,
            playcount => $playcount,
            artist => $artist || 'Artist',
            title => $title || $url,
            mbid => $mbid,
        }, $class;
    }
    sub url { return $_[0]->{url} }
    sub playcount { return $_[0]->{playcount} }
    sub artistName { return $_[0]->{artist} }
    sub title { return $_[0]->{title} }
    sub musicbrainz_id { return $_[0]->{mbid} }
}

use lib "$FindBin::Bin/..";
require Plugins::BlissMixerExt::Plugin;

$Slim::Utils::PluginManager::manifest = undef;
ok(!Plugins::BlissMixerExt::Plugin::_upstreamCompatible(),
    'missing upstream BlissMixer is rejected');

$Slim::Utils::PluginManager::manifest = {version => '0.9.9'};
ok(!Plugins::BlissMixerExt::Plugin::_upstreamCompatible(),
    'older upstream BlissMixer is rejected');

$Slim::Utils::PluginManager::manifest = {version => '0.10.0'};
ok(Plugins::BlissMixerExt::Plugin::_upstreamCompatible(),
    'minimum supported upstream BlissMixer is accepted');

@Slim::Plugin::DontStopTheMusic::Plugin::registered = ();
Plugins::BlissMixerExt::Plugin->postinitPlugin();
is(scalar @Slim::Plugin::DontStopTheMusic::Plugin::registered, 1,
    'one sidecar DSTM provider is registered');
is($Slim::Plugin::DontStopTheMusic::Plugin::registered[0][0], 'BLISSMIXEREXT_DSTM',
    'the sidecar uses its distinct DSTM provider id');
is(ref $Slim::Plugin::DontStopTheMusic::Plugin::registered[0][1], 'CODE',
    'the sidecar DSTM provider has a callback');

$Slim::Utils::PluginManager::manifest = {version => '0.9.9'};
@Slim::Plugin::DontStopTheMusic::Plugin::registered = ();
Plugins::BlissMixerExt::Plugin->postinitPlugin();
is(scalar @Slim::Plugin::DontStopTheMusic::Plugin::registered, 0,
    'incompatible upstream prevents DSTM registration');

{
    no warnings 'redefine';
    local *Plugins::BlissMixerExt::Plugin::_portAvailable = sub {
        return $_[0] == 12003;
    };
    $TestPrefs::values{'plugin.blissmixer'}{mixer_port} = 12002;
    is(Plugins::BlissMixerExt::Plugin::_availableMixerPort(), 12003,
        'the sidecar automatically selects the first available loopback port');
}

{
    no warnings 'redefine';
    local *Plugins::BlissMixerExt::Plugin::_portAvailable = sub { return 1 };
    $TestPrefs::values{'plugin.blissmixer'}{mixer_port} = 12001;
    is(Plugins::BlissMixerExt::Plugin::_availableMixerPort(), 12002,
        'automatic selection never reuses the configured upstream mixer port');
}

my @default_weights = split /,/, Plugins::BlissMixerExt::Plugin::_weightParam();
is(scalar @default_weights, 23, 'BlissMixer weights expand to all 23 analysis features');
ok(!(grep { abs($_ - 1) > 0.000001 } @default_weights),
    'the upstream default sliders produce neutral per-feature weights');

$TestPrefs::values{'plugin.blissmixer'}{weight_tempo} = 25;
$TestPrefs::values{'plugin.blissmixer'}{weight_timbre} = 25;
$TestPrefs::values{'plugin.blissmixer'}{weight_loudness} = 25;
$TestPrefs::values{'plugin.blissmixer'}{weight_chroma} = 25;
my @custom_weights = split /,/, Plugins::BlissMixerExt::Plugin::_weightParam();
cmp_ok(abs($custom_weights[0] - 6.25), '<', 0.000001,
    'tempo weight is derived from the upstream slider');
cmp_ok(abs($custom_weights[1] - (25 / 30)), '<', 0.000001,
    'timbre feature weights are derived from the upstream slider');

is(Plugins::BlissMixerExt::Plugin::_lastfmEndorsedWeightForPercent(50, 2, 8), 4,
    'Last.fm weighting solves the requested endorsed share');
is(Plugins::BlissMixerExt::Plugin::_lastfmEndorsedWeightForPercent(100, 2, 8), 1_000_000,
    'a 100 percent target uses the finite upper bound');
is(Plugins::BlissMixerExt::Plugin::_lastfmEndorsedWeightForPercent(50, 0, 8), 1,
    'an empty endorsed set keeps neutral weighting');
is(Plugins::BlissMixerExt::Plugin::_lastfmNormalizeArtist('  The Artist  '), 'the artist',
    'Last.fm artist keys are normalized consistently');
is(Plugins::BlissMixerExt::Plugin::_lastfmTrackWeight(1, 0), 1,
    'zero Last.fm track guidance is neutral');
cmp_ok(abs(Plugins::BlissMixerExt::Plugin::_lastfmTrackWeight(1, 100) - 10),
    '<', 0.000001, 'maximum recording evidence has a bounded tenfold weight');
$TestPrefs::values{'plugin.blissmixerext'}{lastfm_track_guidance_percent} = 125;
is(Plugins::BlissMixerExt::Plugin::_lastfmTrackGuidance(), 100,
    'Last.fm similar-track guidance is clamped at the positive limit');

$TestPrefs::values{'plugin.blissmixerext'}{playcount_influence} = 55;
is(Plugins::BlissMixerExt::Plugin::_playCountInfluence(), 55,
    'configured play-count influence is available when LMS statistics are enabled');
$TestPrefs::values{'plugin.blissmixerext'}{playcount_influence} = 123;
is(Plugins::BlissMixerExt::Plugin::_playCountInfluence(), 100,
    'play-count influence is clamped at the positive limit');
{
    no warnings 'redefine';
    local *Plugins::BlissMixerExt::Plugin::_statisticsEnabled = sub { return 0 };
    is(Plugins::BlissMixerExt::Plugin::_playCountInfluence(), 0,
        'play-count influence is inactive when LMS listening statistics are disabled');
}
is(Plugins::BlissMixerExt::Plugin::_playCountPoolMultiplier(0), 1,
    'disabled play-count influence does not expand the candidate pool');
is(Plugins::BlissMixerExt::Plugin::_playCountPoolMultiplier(5), 2,
    'any non-zero play-count influence expands the candidate pool');
is(Plugins::BlissMixerExt::Plugin::_playCountPoolMultiplier(-100), 10,
    'maximum negative influence uses the maximum candidate pool');
is(Plugins::BlissMixerExt::Plugin::_playCountPoolMultiplier(100), 10,
    'maximum positive influence uses the maximum candidate pool');
is(Plugins::BlissMixerExt::Plugin::_candidatePoolMultiplier(1, 100), 10,
    'Last.fm and play count share one 10x pool instead of multiplying pools');
cmp_ok(
    Plugins::BlissMixerExt::Plugin::_playCountWeight(1, 100),
    '>',
    Plugins::BlissMixerExt::Plugin::_playCountWeight(-1, 100),
    'positive influence gives frequently played tracks more weight',
);
cmp_ok(
    Plugins::BlissMixerExt::Plugin::_playCountWeight(-1, -100),
    '>',
    Plugins::BlissMixerExt::Plugin::_playCountWeight(1, -100),
    'negative influence gives less-played tracks more weight',
);

my @playcount_tracks = (
    TestTrack->new('low', 0),
    TestTrack->new('middle', 5),
    TestTrack->new('high', 100),
);
is_deeply(
    Plugins::BlissMixerExt::Plugin::_selectWeightedCandidates(
        \@playcount_tracks, 1, 100, undef, undef, sub { 0.5 },
    ),
    ['high'],
    'positive influence can promote a frequently played candidate over Bliss rank',
);
is_deeply(
    Plugins::BlissMixerExt::Plugin::_selectWeightedCandidates(
        \@playcount_tracks, 1, -100, undef, undef, sub { 0.5 },
    ),
    ['low'],
    'negative influence keeps a less-played candidate ahead',
);
my @equal_playcount_tracks = (
    TestTrack->new('first', 0),
    TestTrack->new('second', undef),
);
is_deeply(
    Plugins::BlissMixerExt::Plugin::_selectWeightedCandidates(
        \@equal_playcount_tracks, 1, 100, undef, undef, sub { 0.5 },
    ),
    ['first'],
    'missing and zero play counts are equivalent and preserve Bliss order',
);
my @lastfm_track_candidates = (
    TestTrack->new('unmatched', 0, 'Artist', 'Unmatched'),
    TestTrack->new('track-match', 0, 'Artist', 'Matched'),
);
is_deeply(
    Plugins::BlissMixerExt::Plugin::_selectWeightedCandidates(
        \@lastfm_track_candidates,
        1,
        0,
        undef,
        undef,
        sub { 0.5 },
        {mbid => {}, name => {'artist|matched' => 1}},
        100,
    ),
    ['track-match'],
    'Last.fm recording evidence can promote a matching Bliss candidate',
);
my $selection_log_lines = Plugins::BlissMixerExt::Plugin::_selectionLogLines(
    [
        {
            track => TestTrack->new('bliss-only', 13, 'Ten Years After', 'Here They Come'),
            playcount => 13,
            rank => 2,
            weight => 0.580,
            endorsed => 0,
            track_support => 0,
        },
        {
            track => TestTrack->new('artist-match', 8, 'The Stills-Young Band', 'Midnight on the Bay'),
            playcount => 8,
            rank => 6,
            weight => 3.250,
            endorsed => 1,
            track_support => 0,
        },
        {
            track => TestTrack->new('track-match', 3, 'Johnny Cash', 'You Are My Sunshine'),
            playcount => 3,
            rank => 18,
            weight => 16.965,
            endorsed => 1,
            track_support => 0.765,
        },
    ],
    20,
    25,
);
like($selection_log_lines->[0], qr/bliss-only/,
    'combined selection log retains the Bliss-only tier');
like($selection_log_lines->[1], qr/last\.fm-endorsed/,
    'combined selection log retains the artist-endorsement tier');
like($selection_log_lines->[2], qr/last\.fm-track\+artist/,
    'combined selection log distinguishes recording plus artist evidence');
my @first_pipes;
my @second_pipes;
my @third_pipes;
while ($selection_log_lines->[0] =~ /\|/g) { push @first_pipes, pos($selection_log_lines->[0]) }
while ($selection_log_lines->[1] =~ /\|/g) { push @second_pipes, pos($selection_log_lines->[1]) }
while ($selection_log_lines->[2] =~ /\|/g) { push @third_pipes, pos($selection_log_lines->[2]) }
is_deeply(\@first_pipes, \@second_pipes,
    'combined selection log pipe separators align between Bliss and artist tiers');
is_deeply(\@first_pipes, \@third_pipes,
    'combined selection log pipe separators align for track evidence too');

is_deeply(
    Plugins::BlissMixerExt::Plugin::_genreGroups(),
    [['Rock', 'Hard Rock'], ['Jazz*'], ['Ambient']],
    'genre groups are inherited from BlissMixer and trimmed without losing patterns',
);

is(Plugins::BlissMixerExt::Plugin->title(), 'BlissMixerExt',
    'plugin identity remains distinct from upstream');

my $migration_dir = tempdir(CLEANUP => 1);
my $legacy_matrix = File::Spec->catfile($migration_dir, 'blissmixer-ext-matrix.json');
my $canonical_matrix = File::Spec->catfile($migration_dir, 'learned_matrix.json');
open my $legacy_fh, '>', $legacy_matrix or die "Cannot create $legacy_matrix: $!";
print {$legacy_fh} "legacy matrix\n";
close $legacy_fh;
is(
    Plugins::BlissMixerExt::Plugin::_migrateLearningFile(
        $legacy_matrix, $canonical_matrix,
    ),
    'migrated',
    'an Ext-specific learning file is migrated to its canonical filename',
);
ok(-e $canonical_matrix, 'the migrated canonical learning file exists');
ok(!-e $legacy_matrix, 'the successfully migrated legacy file is gone');

open my $canonical_fh, '>', $canonical_matrix
    or die "Cannot replace $canonical_matrix: $!";
print {$canonical_fh} "canonical matrix\n";
close $canonical_fh;
open $legacy_fh, '>', $legacy_matrix or die "Cannot recreate $legacy_matrix: $!";
print {$legacy_fh} "other matrix\n";
close $legacy_fh;
is(
    Plugins::BlissMixerExt::Plugin::_migrateLearningFile(
        $legacy_matrix, $canonical_matrix,
    ),
    'conflict',
    'an existing canonical learning file is never overwritten',
);
ok(-e $legacy_matrix, 'a conflicting legacy file is left untouched');

done_testing();
