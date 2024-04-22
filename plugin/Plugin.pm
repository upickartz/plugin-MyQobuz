package Plugins::MyQobuz::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);

use JSON::XS::VersionOneAndTwo;
use Tie::RegexpHash;
use POSIX qw(strftime);

use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);
use Scalar::Util qw(looks_like_number);


my $prefs = preferences('plugin.myqobuz');
my $qobuz_installed = 0;


$prefs->init({
	enableFavoriteImport => 1,
	deleteFavoriteAfterImport => 1,
	enableDBConfig => 0,
	myQobuzDB => "MyQobuz.db",
});

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.myqobuz',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_MY_QOBUZ',
	logGroups    => 'SCANNER',
} );

use constant PLUGIN_TAG => 'myqobuz';
use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);


sub initPlugin {
	my $class = shift;
	#DEBUG
 	my $dbConfig = $prefs->enableDBConfig;
	$log->error("Hugo initPlugin  dbConfig: $dbConfig ");
	# "Local Artwork" requires LMS 7.8+, as it's using its imageproxy.
	if (CAN_IMAGEPROXY) {
		require Slim::Web::ImageProxy;
		Slim::Web::ImageProxy->registerHandler(
			match => qr/static\.qobuz\.com/,
			func  => \&_imgProxy,
		);
	}

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => PLUGIN_TAG,
		menu   => 'radios',
		is_app => 1,
		weight => 1,
	);
}

sub postinitPlugin {
	my $class = shift;
	eval {
		require Plugins::MyQobuz::MyQobuzImpl;
  		Plugins::MyQobuz::MyQobuzImpl->import();
		$qobuz_installed = 1;
		$log->error("Hugo postinitPlugin 1 qobuz = $qobuz_installed.");
		if (main::WEBUI) {
			require Plugins::MyQobuz::Settings;
			Plugins::MyQobuz::Settings->new();
		}
		# Track Info item
		Slim::Menu::TrackInfo->registerInfoProvider( myQobuzTrackInfo => (
			func  => \&trackInfoMenu,
		) );
     	1;  # always return true to indicate success
	}
	or do {
		$qobuz_installed = 0;
		my $error = $@ || 'Unknown failure';
		$log->error("postinitPlugin: qobuz not installed.");
		1;  # return true to indicate success
	};
}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	if ( !$qobuz_installed ) {
		return $cb->({
			items => [{
				name => cstring($client, 'PLUGIN_MY_QOBUZ_QOBUZ_MISSING'),
				type => 'textarea',
			}]
		});
	}

	my $params = $args->{params};

	$log->info("Plugins::MyQobuz::MyQobuzImpl MyQobuz  called.");
	my $items = [
		{
			name => cstring($client, 'PLUGIN_MY_QOBUZ_GENRE'),
			url  => \&Plugins::MyQobuz::MyQobuzImpl::MyQobuzGenres
		},
		{
			name => cstring($client, 'PLUGIN_MY_QOBUZ_ARTIST'),
			url  => \&Plugins::MyQobuz::MyQobuzImpl::MyQobuzArtists
		},
		{
				name  => cstring($client, 'PLUGIN_MY_QOBUZ_SELECT_TAG'),
				url  => \&Plugins::MyQobuz::MyQobuzImpl::MyQobuzSelectTag,
		},
		{
			name => cstring($client, 'PLUGIN_MY_QOBUZ_LATEST_ALBUM'),
			url  => \&Plugins::MyQobuz::MyQobuzImpl::MyLatestAlbums,
		},
	];

	my $instance = Plugins::MyQobuz::MyQobuzDB->getInstance(); 
	if ($instance->areAlbumsRemovedByQobuz() == 1 ) {
		push @{$items} , {			
			name  => cstring($client, 'PLUGIN_MY_QOBUZ_DELETED_ALBUMS'),
			url  => \&MyQobuzDeletedAlbums
		}
	}
	
	$cb->({ items => $items });
}
sub trackInfoMenu {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	my $album  = $track->remote ? $remoteMeta->{album}  : ( $track->album ? $track->album->name : undef );

	$log->error("Hugo trackInfoMenu album.");
	$log->error(Data::Dump::dump($album));
	my $items;

	if ( my ($trackId) = Plugins::Qobuz::ProtocolHandler->crackUrl($url) ) {
		my $albumId = $remoteMeta ? $remoteMeta->{albumId} : undef;

		$log->error("Hugo trackInfoMenu albumId:  $albumId  ");
		
		if ( $albumId) {
			my $args = {};
	

			if ($albumId && $album) {
				$args->{albumId} = $albumId;
				$args->{album}   = $album;
			}

			$items ||= [];
				push @$items, {
					name => cstring($client, 'PLUGIN_MY_QOBUZ_ALBUM', $album),
					url  => \&Plugins::MyQobuz::MyQobuzImpl::QobuzManageMyQobuz,
					passthrough => [$args],
				} if keys %$args;
			}

	};

	my $menu;
	if ( scalar @$items == 1) {
			$menu = $items->[0];
			$menu->{name} = cstring($client, 'PLUGIN_ON_MY_QOBUZ');
	}

	return $menu if $menu;
}



sub _imgProxy { if (CAN_IMAGEPROXY) {
	my ($url, $spec) = @_;

	#main::DEBUGLOG && $log->debug("Artwork for $url, $spec");

	# https://github.com/Qobuz/api-documentation#album-cover-sizes
	my $size = Slim::Web::ImageProxy->getRightSize($spec, {
		50 => 50,
		160 => 160,
		300 => 300,
		600 => 600
	}) || 'max';

	$url =~ s/(\d{13}_)[\dmax]+(\.jpg)/$1$size$2/ if $size;

	#main::DEBUGLOG && $log->debug("Artwork file url is '$url'");

	return $url;
} }
