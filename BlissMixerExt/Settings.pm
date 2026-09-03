package Plugins::BlissMixerExt::Settings;

#
# Bliss Mixer Experimental companion for Lyrion Music Server
#
# Licence: GPL v3
#

use strict;
use base qw(Slim::Web::Settings);

use File::Spec;
use Slim::Utils::Misc;
use Slim::Utils::Network;
use Slim::Utils::OSDetect;
use Slim::Utils::PluginManager;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Versions;

my $prefs = preferences('plugin.blissmixerext');
my $serverprefs = preferences('server');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('BLISSMIXEREXT');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/BlissMixerExt/settings/blissmixerext.html');
}

sub prefs {
    return ($prefs, 'learned_blend', 'triplets_backup_path');
}

sub beforeRender {
    my ($class, $paramRef) = @_;

    my $dbDir = Slim::Utils::Prefs::dir() || Slim::Utils::OSDetect::dirsFor('prefs');
    my $manifest = Slim::Utils::PluginManager->dataForPlugin('Plugins::BlissMixer::Plugin');
    my $host = $paramRef->{host}
        || (Slim::Utils::Network::serverAddr() . ':' . ($serverprefs->get('httpport') || 9000));

    $paramRef->{jsonrpc_url} = "http://${host}/jsonrpc.js";
    $paramRef->{survey_url} = '/blissmixerext/survey.html';
    $paramRef->{upstream_enabled} = $manifest ? 1 : 0;
    $paramRef->{upstream_version} = $manifest ? ($manifest->{version} || 'unknown') : '';
    $paramRef->{upstream_compatible} = $manifest
        && Slim::Utils::Versions->compareVersions($manifest->{version} || '0', '0.10.0') >= 0 ? 1 : 0;
    $paramRef->{database_exists} = -e File::Spec->catfile($dbDir, 'bliss.db') ? 1 : 0;
    $paramRef->{matrix_exists} = -e File::Spec->catfile($dbDir, 'blissmixer-ext-matrix.json') ? 1 : 0;
    $paramRef->{no_learner_binary} = !Slim::Utils::Misc::findbin('bliss-learner-ext');
    $paramRef->{restore_in_progress_text} = string('BLISSMIXEREXT_RESTORE_IN_PROGRESS');
    $paramRef->{restore_success_text} = string('BLISSMIXEREXT_RESTORE_SUCCESS');
    $paramRef->{restore_failed_text} = string('BLISSMIXEREXT_RESTORE_FAILED');
    $paramRef->{backup_now_text} = string('BLISSMIXEREXT_BACKUP_NOW');
    $paramRef->{backup_success_text} = string('BLISSMIXEREXT_BACKUP_SUCCESS');
    $paramRef->{backup_failed_text} = string('BLISSMIXEREXT_BACKUP_FAILED');
}

sub handler {
    my ($class, $client, $paramRef) = @_;
    return $class->SUPER::handler($client, $paramRef);
}

1;

__END__
