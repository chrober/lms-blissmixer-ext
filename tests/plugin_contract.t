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
