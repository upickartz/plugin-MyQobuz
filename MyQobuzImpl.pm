package Plugins::MyQobuz::MyQobuzImpl;
use strict;
use utf8;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::MyQobuz::MyQobuzDB;

 
my $log = logger('plugin.myqobuz');

# copy from Plugins::Qobuz::Plugin.pm 
sub _stripHTML {
	my $html = shift;
	$html =~ s/<(?:[^>'”]*|([‘”]).*?\1)*>//ig;
	return $html;
}

sub MyQobuz {
	my ($client, $cb, $params, $args) = @_;
	$log->info("Plugins::MyQobuz::MyQobuzImpl MyQobuz  called.");
	my $items = [
		{
			name => cstring($client, 'PLUGIN_MY_QOBUZ_GENRE'),
			url  => \&MyQobuzGenres
		},
		{
			name => cstring($client, 'PLUGIN_MY_QOBUZ_ARTIST'),
			url  => \&MyQobuzArtists
		},
		{
				name  => cstring($client, 'PLUGIN_MY_QOBUZ_SELECT_TAG'),
				url  => \&MyQobuzSelectTag,
		},
		{
			name => cstring($client, 'PLUGIN_MY_QOBUZ_LATEST_ALBUM'),
			url  => \&MyLatestAlbums,
		},
	];

	my $instance = Plugins::MyQobuz::MyQobuzDB->getInstance(); 
	if ($instance->areAlbumsRemovedByQobuz() == 1 ) {
		push @{$items} , {			
			name  => cstring($client, 'PLUGIN_MY_QOBUZ_DELETED_ALBUMS'),
			url  => \&MyQobuzDeletedAlbums
		}
	}
	
	$cb->({
		items => $items
	})
	
}

sub MyQobuzGenres {
	my ($client, $cb, $params, $args) = @_;

	my $tagId = $args->{tagId};

	$log->info("MyQobuzImpl::MyQobuzGenres  called with tagId:  $tagId .");
	my $myGenres = Plugins::MyQobuz::MyQobuzDB->getInstance()->getMyGenres($tagId);

	my $items = [];
	foreach (@{$myGenres})
	{
		my $item = {
				name => $_->[0],
				url  => \&MyQobuzGenre,
				passthrough => [{
					genre => $_->[0],
					tagId => $tagId
				}]
			};
		push @$items, $item;
	};	
	$cb->({
		items => $items
	});

}

sub MyLatestAlbums {
	my ($client, $cb, $params, $args) = @_;

	my $myLatestAlbums = Plugins::MyQobuz::MyQobuzDB->getInstance()->getLatestAlbums();
	my @myArtists;
	my @data;
	my $item;
	foreach my $album (@{$myLatestAlbums})
	{
		undef $item;
		# check if artist already in array
		foreach (@data){
			if ($_->{artist_id} == $album->{artist_id}){
				$item = $_;
			}
		}
		# push new artist or expand filter
		if( defined($item) ) {
			push (@{$item->{album_filter}},$album->{id});
		} else {
			$item = {
				artist_id => $album->{artist_id},
				artist_name => $album->{artist_name},
				album_filter => [],
			};
			push (@{$item->{album_filter}},$album->{id});
			push (@data, $item);
		}
	}
	foreach (@data){
		push @myArtists, _myArtistItem($client, $_->{artist_id}, $_->{artist_name}, $_->{album_filter});
	}
	$cb->({
			items => \@myArtists
		});
}

sub MyQobuzArtist {
	my ($client, $cb, $params, $args) = @_;

	my $artistId = $args->{artistId};
	$log->debug("MyQobuzArtist called with $artistId .");
	my $myQobuzAlbumFilter = $args->{myQobuzAlbumFilter};
	my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);
	$api->getArtist( sub {
		my $artist = shift;

		if ($artist->{status} && $artist->{status} =~ /error/i) {
			$cb->();
			return;
		}

		my $items = [{
			name  => cstring($client, 'ALBUMS'),
			# sub itemes will be defined below
			image => 'html/images/albums.png',
		}];

		if ($artist->{biography}) {
			my $images = $artist->{image} || {};
			push @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_BIOGRAPHY'),
				# don#t use API because this should already be done
				image => Plugins::Qobuz::API::Common->getImageFromImagesHash($images) || 'html/images/artists.png',
				items => [{
					name => _stripHTML($artist->{biography}->{content}),
					type => 'textarea',
				}],
			}
		};
		my @albums;
		foreach (@{$myQobuzAlbumFilter}){
					$api->getAlbum(sub {
						my $album = shift;
						push @albums, Plugins::Qobuz::Plugin->_albumItem($album);	
					},$_);
		};
		if (@albums) {
				$items->[0]->{items} = \@albums;
		}
		$cb->( {
			items => $items
		} );

	}, $artistId);
}
	
sub MyQobuzArtists {
	my ($client, $cb, $params, $args) = @_;

	my $tagId = $args->{tagId};
	$log->info("MyQobuzImpl::MyQobuzArtists  called with tagId:  $tagId .");
	my $artists = Plugins::MyQobuz::MyQobuzDB->getInstance()->getArtists($tagId);
	my @myArtists;
	foreach my $artist ( sort {
			Slim::Utils::Text::ignoreCaseArticles($a->{name}) cmp Slim::Utils::Text::ignoreCaseArticles($b->{name})
		}
		@$artists) {
		my $artistId = $artist->{id};
		my $artistName = $artist->{name};
		my $albumFilter = Plugins::MyQobuz::MyQobuzDB->getInstance()->getAlbums($artistId,undef,$tagId);
		push @myArtists, _myArtistItem($client, $artistId, $artistName, $albumFilter);
	};
	$cb->({
			items => \@myArtists
		});
}


sub MyQobuzGenre {
	my ($client, $cb, $params, $args) = @_;

	my @myArtists;
	my $genre = $args->{genre} || '';
	my $tagId = $args->{tagId};
	$log->info("MyQobuzImpl::MyQobuzGenre  called with tagId:  $tagId and genre:  $genre .");
	my $artists = Plugins::MyQobuz::MyQobuzDB->getInstance()->getArtistsWithGenre($genre,$tagId);
	foreach my $artist (sort {
			Slim::Utils::Text::ignoreCaseArticles($a->{name}) cmp Slim::Utils::Text::ignoreCaseArticles($b->{name})
		} @$artists) {
		my $artistId = $artist->{id};
		my $artistName = $artist->{name};
		my $albumFilter = Plugins::MyQobuz::MyQobuzDB->getInstance()->getAlbums($artistId,$genre,$tagId);
		push @myArtists, _myArtistItem($client, $artistId, $artistName, $albumFilter);
	};	
	$cb->({
			items => \@myArtists
		});
}


sub MyQobuzWithTag {
	my ($client, $cb, $params, $args) = @_;

	my $tagId = $args->{tagId};
	# if tag instead tagId get it from MyQobuzDB
	if (not defined  $tagId){
		my $tag = $params->{search};
		$tagId = Plugins::MyQobuz::MyQobuzDB->getInstance()->getTagId($tag);
	}
	
	if (not defined $tagId){
		$tagId = -1;
	}
	my $items = [
		{
			name => cstring($client, 'PLUGIN_MY_QOBUZ_GENRE'),
			url  => \&MyQobuzGenres,
			passthrough => [{
					tagId => $tagId
			}],
		},
		{
			name => cstring($client, 'PLUGIN_MY_QOBUZ_ARTIST'),
			url  => \&MyQobuzArtists,
			passthrough => [{
					tagId => $tagId
			}],
		}
	];
	$cb->({
		items => $items
	})

}


sub MyQobuzSelectTag {
	my ($client, $cb, $params, $args) = @_;
	my $tags = Plugins::MyQobuz::MyQobuzDB->getInstance()->getTags();

	my $items = [];
	foreach (@{$tags}){
		push @{$items} , {
			name => $_->[1],
			url  => \&MyQobuzWithTag,
			passthrough => [{
					tagId => $_->[0]
				}],
		}
	};
	$cb->({
		items => $items
	})
}

sub MyQobuzHandleDeletedAlbum {
	my ($client, $cb, $params, $args) = @_;

	my $items = [
		{
			name => cstring($client,'PLUGIN_QOBUZ_SEARCH', $args->{album_name} ),
			url  => \&Plugins::Qobuz::Plugin::QobuzSearch,
			passthrough => [{
					q  => $args->{album_name},
					type     => 'albums',
				}]
		},
		{
			name => cstring($client,'PLUGIN_QOBUZ_SEARCH', $args->{artist_name} ),
			url  => \&Plugins::Qobuz::Plugin::QobuzArtist,
			passthrough => [{
					artistId => $args->{artist_id},
				}]
		},
		{
			name => cstring($client,'PLUGIN_QOBUZ_REMOVE_FROM_MY_QOBUZ', $args->{album_name} ),
			url  => \&QobuzRemoveAlbumFromMyQobuz,
			passthrough => [{
					album_id  => $args->{album_id},
					artist_id => $args->{artist_id},
					remove_from_qobuzremoved => 1,
				}],
			nextWindow => 'grandparent'
		}
	];

	$cb->({
		items => $items
	})
}

sub MyQobuzDeletedAlbums {
	my ($client, $cb, $params, $args) = @_;
	my $albums =  Plugins::MyQobuz::MyQobuzDB->getInstance()->albumsRemovedByQobuz();
	my $items = [];
	foreach my $albumref (@{$albums}){
		my $albumTxt = $albumref->{artist_name} . ": " . $albumref->{album_name};
		push @$items, {
				name => cstring($client,'PLUGIN_MY_QOBUZ_ALBUM', $albumTxt ),
				url  => \&MyQobuzHandleDeletedAlbum,
				passthrough => [{
					album_id    => $albumref->{album_id},
					album_name  => $albumref->{album_name},
					artist_name => $albumref->{artist_name},
					artist_id   => $albumref->{artist_id},
				}]
			};
	}

	$cb->({
		items => $items
	})
	
}

sub _myArtistItem {
	my ($client, $artistId, $artistName, $myQobuzAlbumFilter) = @_;
	my $item = {
		name  => $artistName,
		url   => \&MyQobuzArtist,
		passthrough => [{
			artistId  => $artistId,
			myQobuzAlbumFilter => $myQobuzAlbumFilter,
		}],
	};
	my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);
	$item->{image} = $api->getArtistPicture($artistId) || 'html/images/artists.png';

	return $item;
}

sub QobuzManageMyQobuz {
	my ($client, $cb, $params, $args) = @_;
	my $items = [];
	if ( (my $album = $args->{album}) && (my $albumId = $args->{albumId}) ) {
		my $myAlbum = Plugins::MyQobuz::MyQobuzDB->getInstance()->getMyAlbum($albumId);
		if ($myAlbum) {		
			push @$items, {
				name => cstring($client,'PLUGIN_QOBUZ_REMOVE_FROM_MY_QOBUZ', $album),
				url  => \&QobuzRemoveAlbumFromMyQobuz,
				passthrough => [{
					album_id => $albumId,
					artist_id => $myAlbum->{artist},
					remove_from_qobuzremoved => 0,
				}],
			};
			# change  genre
			push @$items, {
				name  => cstring($client, 'PLUGIN_MY_QOBUZ_CHANGE_GENRE'),
				type => 'search',
				url  => sub {
					my ($client, $cb, $params) = @_;
					my $genre = $params->{search};
					if (defined($genre)){
						Plugins::MyQobuz::MyQobuzDB->getInstance()->changeGenre($albumId,$genre);
						$cb->({items => [{
								type        => 'text',
								name        => cstring($client, 'PLUGIN_MY_QOBUZ_CHANGED_GENRE',$genre),
							}]});

					}
				},
			};
			# add tag
			push @$items, {
				name  => cstring($client, 'PLUGIN_MY_QOBUZ_ADD_TAG'),
				type => 'search',
				url  => sub {
					my ($client, $cb, $params) = @_;
					my $tag = $params->{search};
					if (defined $tag){
						Plugins::MyQobuz::MyQobuzDB->getInstance()->insertTag($albumId,$tag);
						$cb->({items => [{
								type        => 'text',
								name        => cstring($client, 'PLUGIN_MY_QOBUZ_TAG_ADDED',$tag),
							}]});

					}

				},
			};
			#remove tags
			my $tagMap = Plugins::MyQobuz::MyQobuzDB->getInstance()->getTagsWithAlbum($albumId);
			# sometimes the wrong tag was deleted: It seems that the sort helps ??
			foreach my $key (sort keys %{ $tagMap }) {
				push @$items, {
					name => cstring($client,'PLUGIN_QOBUZ_REMOVE_TAG_FROM_MY_QOBUZ', $tagMap->{$key}, $args->{album}),
					url  => \&QobuzRemoveTagFromMyQobuz,
					passthrough => [{
						albumId => $albumId,
						tagId => $key,
						tagName => $tagMap->{$key}
					}],
				};	
			}
		}else{
			push @$items, {
				name => cstring($client,'PLUGIN_QOBUZ_ADD_TO_MY_QOBUZ', $album),
				url  => \&QobuzAddAlbumToMyQobuz,
				passthrough => [{
					album_id => $albumId
				}],
			};
		};
	}
	$cb->( {
			items => $items
		} );

}

sub QobuzAddAlbumToMyQobuz {
	my ($client, $cb, $params, $args) = @_;
	my $albumId=$args->{album_id};
	my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);
	$api->getAlbum(sub {
		my $album = shift;
		Plugins::MyQobuz::MyQobuzDB->getInstance()->insertAlbum($album);
		$cb->({items => [{
			type        => 'text',
			name        => cstring($client, 'PLUGIN_QOBUZ_ADDED_TO_MY_QOBUZ',$album->{title}),
		}] });
	},$albumId);
}

sub QobuzRemoveAlbumFromMyQobuz {
	my ($client, $cb, $params, $args) = @_;
	my $albumId=$args->{album_id};
	my $artistId=$args->{artist_id};
	if ($args->{remove_from_qobuzremoved}){
		Plugins::MyQobuz::MyQobuzDB->getInstance()->albumRemovedCleanUp($albumId);
	}
	my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);
	$api->getAlbum(sub {
		my $album = shift;
		Plugins::MyQobuz::MyQobuzDB->getInstance()->removeAlbum($albumId,$artistId); 
		$cb->({items => [{
			type        => 'text',
			name        => cstring($client, 'PLUGIN_QOBUZ_REMOVED_FROM_MY_QOBUZ',$album->{title}),
		}]});
	}, $albumId);
}

sub QobuzRemoveTagFromMyQobuz {
	my ($client, $cb, $params, $args) = @_;

	my $albumId = $args->{albumId};
	my $tagId = $args->{tagId};
	my $tagName = $args->{tagName};

	Plugins::MyQobuz::MyQobuzDB->getInstance()->removeTag($albumId,$tagId);
	$cb->({items => [{
			type        => 'text',
			name        => cstring($client, 'PLUGIN_QOBUZ_REMOVED_TAG_FROM_MY_QOBUZ',$tagName),
		}]});
}


1;
