package Plugins::MyQobuz::Settings;

use strict;
use Digest::MD5 qw(md5_hex);

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::MyQobuz::MyQobuzDB;

my $log   = logger('plugin.myqobuz');
my $prefs = preferences('plugin.myqobuz');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_MY_QOBUZ');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/MyQobuz/settings/basic.html');
}

sub prefs {
	return ($prefs, 'enableDBConfig', 'myQobuzDB');
}

sub checkMyQobuzConfig {
		my ($params) = @_;
		## check db config is enabled
		my $enableDBConfig = $prefs->enableDBConfig ;
		$log->error("Hugo checkMyQobuzConfig  old: $enableDBConfig; new: $params->{pref_enableDBConfig} .");
		if($enableDBConfig) {
			my $oldQobuzDbName = $prefs->myQobuzDB;
			my $newQobuzDbName = $params->{pref_myQobuzDB};
			$log->error("Hugo checkMyQobuzConfig  oldDB: $oldQobuzDbName ; newDB: $newQobuzDbName .");
			if ( defined $oldQobuzDbName  and ($newQobuzDbName ne $oldQobuzDbName) ) {
				# Trigger restart required message
				Plugins::Qobuz::MyQobuzDB->resetDB();
				$params = Slim::Web::Settings::Server::Plugins->getRestartMessage($params, Slim::Utils::Strings::string('CLEANUP_PLEASE_RESTART_SC'));
			}
		}
}

sub handler {
 	my ($class, $client, $params, $callback, @args) = @_;

	# keep track of the user agent for request using the web token
	$prefs->set('useragent', $params->{userAgent}) if $params->{userAgent};

	if (  $params->{saveSettings} ) {
		$params->{'pref_enableDBConfig'} ||= 0;
		$params->{'pref_myQobuzDB'} ||= "MyQobuz";

		checkMyQobuzConfig($params);
		
	}

	$class->SUPER::handler($client, $params);
	
}

1;

__END__
