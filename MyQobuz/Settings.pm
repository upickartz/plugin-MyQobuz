# Copyright (c) 2024  Ulrich Pickartz
#
# plugin-MyQobuz is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# plugin-MyQobuz is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

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
	return ($prefs,'enableDBConfig', 'enableFavoriteImport','deleteFavoriteAfterImport', 'myQobuzDB');
}

sub checkMyQobuzConfig {
		my ($params) = @_;
		## check db config is enabled
		my $enableDBConfig = $prefs->enableDBConfig ;
		if($enableDBConfig) {
			my $oldQobuzDbName = $prefs->myQobuzDB;
			my $newQobuzDbName = $params->{pref_myQobuzDB};
			$log->info("checkMyQobuzConfig  oldDB: $oldQobuzDbName ; newDB: $newQobuzDbName .");
			if ( defined $oldQobuzDbName  and ($newQobuzDbName ne $oldQobuzDbName) ) {
				# Trigger restart required message
				Plugins::MyQobuz::MyQobuzDB->resetDB();
				$params = Slim::Web::Settings::Server::Plugins->getRestartMessage($params, Slim::Utils::Strings::string('CLEANUP_PLEASE_RESTART_SC'));
			}
		}
}

sub handler {
 	my ($class, $client, $params, $callback, @args) = @_;

	# keep track of the user agent for request using the web token
	$prefs->set('useragent', $params->{userAgent}) if $params->{userAgent};

	if (  $params->{saveSettings} ) {
		my $enableDBConfig = $prefs->enableDBConfig ;
		$params->{'pref_enableFavoriteImport'} ||= 0;
		$params->{'pref_deleteFavoriteAfterImport'} ||= 0;
		$params->{'pref_enableDBConfig'} = $enableDBConfig;
		$params->{'pref_myQobuzDB'} ||= 'MyQobuz.db';
		checkMyQobuzConfig($params);		
	}

	$class->SUPER::handler($client, $params);
	
}

1;

__END__
