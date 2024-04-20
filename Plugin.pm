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

		$log->error("Hugo postinitPlugin 2 qobuz = $qobuz_installed .");
		$log->error("Hugo postinitPlugin 2 error $error .");
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



sub _playlistItem {
	my ($playlist, $showOwner, $isWeb) = @_;

	my $image = Plugins::Qobuz::API::Common->getPlaylistImage($playlist);

	my $owner = $showOwner ? $playlist->{owner}->{name} : undef;

	return {
		name  => $playlist->{name} . ($isWeb && $owner ? " - $owner" : ''),
		name2 => $owner,
		url   => \&QobuzPlaylistGetTracks,
		image => $image,
		passthrough => [{
			playlist_id  => $playlist->{id},
		}],
		type  => 'playlist',
	};
}

sub _trackItem {
	my ($client, $track, $isWeb) = @_;

	my $title = Plugins::Qobuz::API::Common->addVersionToTitle($track);
	my $artist = Plugins::Qobuz::API::Common->getArtistName($track, $track->{album});
	my $album  = $track->{album}->{title} || '';
	if ( $track->{album}->{title} && $prefs->get('showDiscs') ) {
		$album = Slim::Music::Info::addDiscNumberToAlbumTitle($album,$track->{media_number},$track->{album}->{media_count});
	}
	my $genre = $track->{album}->{genre};

	my $item = {
		name  => sprintf('%s %s %s %s %s', $title, cstring($client, 'BY'), $artist, cstring($client, 'FROM'), $album),
		line1 => $title,
		line2 => $artist . ($artist && $album ? ' - ' : '') . $album,
		image => Plugins::Qobuz::API::Common->getImageFromImagesHash($track->{album}->{image}),
	};

	if ( $track->{hires_streamable} && $item->{name} !~ /hi.?res|bits|khz/i && $prefs->get('labelHiResAlbums') && Plugins::Qobuz::API::Common->getStreamingFormat($track->{album}) eq 'flac' ) {
		$item->{name} .= ' (' . cstring($client, 'PLUGIN_QOBUZ_HIRES') . ')';
		$item->{line1} .= ' (' . cstring($client, 'PLUGIN_QOBUZ_HIRES') . ')';
	}

	# Enhancements to work/composer display for classical music (tags returned from Qobuz are all over the place)
	if ( $track->{album}->{isClassique} ) {
		if ( $track->{work} ) {
			$item->{work} = $track->{work};
		} else {
			# Try to set work to the title, but without composer if it's in there
			if ( $track->{composer}->{name} && $track->{title} ) {
				my @titleSplit = split /:\s*/, $track->{title};
				$item->{work} = $track->{title};
				if ( index($track->{composer}->{name}, $titleSplit[0]) != -1 ) {
					$item->{work} =~ s/\Q$titleSplit[0]\E:\s*//;
				}
			}
			# try to remove the title (ie track, movement) from the work
			my @titleSplit = split /:\s*/, $track->{title};
			my $tempTitle = @titleSplit[-1];
			$item->{work} =~ s/:\s*\Q$tempTitle\E//;
			$item->{line1} =~ s/\Q$item->{work}\E://;
		}
		$item->{displayWork} = $item->{work};
		if ( $track->{composer}->{name} ) {
			$item->{displayWork} = $track->{composer}->{name} . string('COLON') . ' ' . $item->{work};
			my $composerSurname = (split ' ', $track->{composer}->{name})[-1];
			$item->{line1} =~ s/\Q$composerSurname\E://;
		}
		$item->{line2} .= " - " . $item->{work} if $item->{work};
	}

	if ( $track->{album} ) {
		$item->{year} = $track->{album}->{year} || substr($track->{$album}->{release_date_stream},0,4) || 0;
	}

	if ( $prefs->get('parentalWarning') && $track->{parental_warning} ) {
		$item->{name} .= ' [E]';
		$item->{line1} .= ' [E]';
	}

	if (!$track->{streamable} && (!$prefs->get('playSamples') || !$track->{sampleable})) {
		$item->{items} = [{
			name => cstring($client, 'PLUGIN_QOBUZ_NOT_AVAILABLE'),
			type => 'textarea'
		}];
		$item->{name}      = '* ' . $item->{name};
		$item->{line1}     = '* ' . $item->{line1};
	}
	else {
		$item->{name}      = '* ' . $item->{name} if !$track->{streamable};
		$item->{line1}     = '* ' . $item->{line1} if !$track->{streamable};
		$item->{play}      = Plugins::Qobuz::API::Common->getUrl($client, $track);
		$item->{on_select} = 'play';
		$item->{playall}   = 1;
	}

	$item->{tracknum} = $track->{track_number};
	$item->{media_number} = $track->{media_number};
	$item->{media_count} = $track->{album}->{media_count};
	return $item;
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
	
			if ($prefs->enableDBConfig){
				push @$items, {
					name => cstring($client, 'PLUGIN_MY_QOBUZ_ALBUM', $album),
					url  => \&Plugins::MyQobuz::MyQobuzImpl::QobuzManageMyQobuz,
					passthrough => [$args],
				} if keys %$args;
			}
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

