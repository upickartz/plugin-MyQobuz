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

package Plugins::MyQobuz::MyQobuzDB;

use strict;
use utf8;
use DBI;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::OSDetect;

use File::Spec::Functions qw(catfile);
use File::Basename;
use File::Copy;

use Plugins::Qobuz::API;
use Plugins::MyQobuz::MyQobuzMigrate;

# use XML::Simple qw(:strict);
# use Slim::Utils::Prefs;



require Data::Dump;

    my $log = logger('plugin.myqobuz');

    my $instance = undef;
    my $areAlbumsRemovedByQobuz = 0;
    my $albumsRemovedByQobuz = [];  

    my $_dbh;

    my $_sth_insert_artist;
    my $_sth_insert_album;
    my $_sth_insert_track;
    my $_sth_insert_tag;
    my $_sth_change_album_genre;
    my $_sth_insert_album_tag;
    my $_sth_insert_goody;

    my $_sth_delete_artist;
    my $_sth_delete_album;
    my $_sth_cleanup_artist_album;
    my $_sth_delete_album_tracks;
    my $_sth_delete_tag;
    my $_sth_delete_album_tag;
    my $_sth_delete_artist_album;
    

    my $_sth_exist_album_with_artist;
    my $_sth_exist_artist_album_with_artist;
    my $_sth_exist_album_with_tag;
    my $_sth_all_albums_with_artist;

    my $_sth_artists;
    my $_sth_artists_with_tag;
    my $_sth_artists_with_genre;
    my $_sth_artists_with_genre_tag;
    my $_sth_insert_artist_album;

    my $_sth_genres;
    my $_sth_genres_with_tag;

    my $_sth_album;
    my $_sth_tags;
    my $_sth_tag_id; 
    my $_sth_tag_with_album;
    my $_sth_albums_with_artist;
    my $_sth_albums_with_artist_and_genre;
    my $_sth_albums_with_artist_and_tag;
    my $_sth_albums_with_artist_and_genre_and_tag;
    my $_sth_albums_with_tag;

    my $_sth_album_latest;

## working but not used      
# sub getVersion() {
#     my $prefs = preferences('server');
#     #get install version
#     my $installFile = $prefs->get('cachedir') . '/InstalledPlugins/Plugins/MyQobuz/install.xml';
#     $log->error("Hugo getVersion()" .  Data::Dump::dump($installFile));
#     my $ref = XMLin($installFile,
# 			KeyAttr    => [],
# 			ForceArray => [ ],
# 		);
#     return $ref->{version};
# }

sub exist_mig_version 
{
    my $mig_version = shift;
    my $rv = 0;

    local $@;
        eval{
            my $sth = $_dbh->prepare('SELECT version FROM mig_version where version = ?');
            $sth->execute($mig_version);
            $rv = $sth->fetchrow_array();
            $_dbh->commit();
        };
        if ($@){
            $@ && $log->error($@);
        }
        return $rv;
}



sub db_error {
        my $error = shift;
        if (
                (index($error, 'UNIQUE constraint failed') != -1) 
                # forein key constraints are not working
                #||
                #(index($error, 'FOREIGN KEY constraint failed') != -1)
            )
        {
            $log->debug("No DB error: $error \n");
            return 1;
        }else{
            $_dbh->rollback();
            die ("MyQobuz DB error: $error \n");
        }        
}

sub createDB {
        $log->info("Create new DB");
        $_dbh->do('CREATE TABLE artist (id INTEGER PRIMARY KEY,name TEXT,image TEXT);');
        my $albumCreate = q/
        CREATE TABLE album (
        id TEXT PRIMARY KEY,
        insertTS DATETIME DEFAULT CURRENT_TIMESTAMP,
        name  TEXT,
        image TEXT,
        genre TEXT, 
        qobuzGenre TEXT,                
        artist INTEGER,
        year INTEGER DEFAULT NULL,
        label TEXT DEFAULT NULL);
        /;
        $_dbh->do($albumCreate);
        $_dbh->do('CREATE INDEX index_genre ON album (genre);');
        $_dbh->do('CREATE INDEX index_artist ON album (artist);');
        $_dbh->do('CREATE INDEX index_year ON album (year);');
        $_dbh->do('CREATE INDEX index_label ON album (label);');
        
        my $trackCreate = q/
        CREATE TABLE track (
        id TEXT PRIMARY KEY,
        no INTEGER,
        exclude INTEGER,
        name  TEXT,
        duration INTEGER,
        url TEXT,
        performers TEXT,             
        album TEXT);
        /;
        $_dbh->do($trackCreate);
        $_dbh->do('CREATE INDEX index_album ON track (album);');
        my $tagCreate = q/
        CREATE TABLE tag ( id INTEGER PRIMARY KEY,
                            name TEXT NOT NULL, 
                            group_name TEXT DEFAULT '\#no_group\#' NOT NULL,
                            UNIQUE(name,group_name));
        /;
        $_dbh->do($tagCreate);
        $_dbh->do('CREATE TABLE album_tag (album TEXT,tag INTEGER,PRIMARY KEY (album,tag));');
        $_dbh->do('CREATE INDEX index_album_tag ON album_tag (album);');
        $_dbh->do('CREATE INDEX index_tag_album ON album_tag (tag);');
        # to store album artist relation
        $_dbh->do('CREATE TABLE artist_album (artist TEXT,album TEXT,role TEXT,PRIMARY KEY (artist,album));');
        $_dbh->do('CREATE INDEX index_artist_album_artist ON artist_album (artist);');
        $_dbh->do('CREATE INDEX index_artist_album_album ON artist_album (album);');
        # to store goodies from qobuz
        my $goodyTable = q/
        CREATE TABLE goody (id INTEGER PRIMARY KEY AUTOINCREMENT,
                                        album TEXT,
                                        description TEXT,
                                        file_format_id INTEGER,
                                        name TEXT,
                                        original_url TEXT,
                                        url TEXT);
        /;
        $_dbh->do($goodyTable);
        $_dbh->do('CREATE INDEX index_goody_album ON goody (album);');
        #version table
        $_dbh->do('CREATE TABLE mig_version (version TEXT,PRIMARY KEY (version));');
        $_dbh->commit();
        Plugins::MyQobuz::MyQobuzMigrate::insert_mig_version($_dbh,"1.3.0");

}

sub getDbPath {
    # create default for no or wrong entry
    my $prefs_dir =  Slim::Utils::OSDetect::dirsFor('prefs');
    my $dbPath = catfile($prefs_dir,'MyQobuz.db');
    $log->info("MyQobuzDB::getDbPath prefs_dir: $prefs_dir");
    $log->info("MyQobuzDB::getDbPath init dbPath $dbPath ");
    #check user defined entry
    my $prefs = preferences('plugin.myqobuz');
    my $userPath = $prefs->myQobuzDB;
    if (-d $userPath) {
        # only directory provided => take dafault name for DB
        $dbPath =  catfile( $userPath,'MyQobuz.db'); 
        $log->info("MyQobuzDB::getDbPath user path is existing directory");
    }elsif (-e $userPath) {
         # DB is provided with directory and filename
         $log->info("MyQobuzDB::getDbPath user path is existing file");
         $dbPath = $userPath; 
    }else {
        my $basename = basename($userPath);
        my $dirname  = dirname($userPath);  
        if (index($basename, '.db') != -1) {
            if (-d $dirname and (length($dirname) > 1) ){
                # case dir exisits and DB with basename has to be created
                $dbPath = $userPath; 
                
            }else{
                if (length($dirname) > 1){
                    # directory does not exist => error
                    $log->error("wrong file specification for MyQobuz.db; take default");
                }else{
                    # case dirname empty ony basename with *.db 
                    # => create in prefs directory
                    $dbPath = catfile($prefs_dir,$basename);
                }
            } 
        }else{
            $log->error("wrong file specification for MyQobuz.db; take default");
        }
    }

    $log->info("dbPath:  $dbPath");
    return $dbPath;
 
}


sub init {
        my $class = shift;
        $log->info("MyQobuz init DB");
        ## get db file
		my $db_path = getDbPath();
					
        if ( not -e $db_path) {
            #create and connect to database
            $_dbh = DBI->connect("dbi:SQLite:dbname=$db_path","","",{sqlite_unicode => 1,AutoCommit=>0,RaiseError=>1,HandleError=>\&db_error });    
            createDB();
            $_dbh->commit();
        }else{
            # make backup db 
            my $backup_path = $db_path . ".backup";
            copy($db_path,$backup_path) or $log->error("Backup failed with db_path:  $db_path");
            if (-e $backup_path) {
                $log->info("MyQobuzDB::initBackup created:  $backup_path");
            }
            #only connect to database
            $_dbh = DBI->connect("dbi:SQLite:dbname=$db_path","","",{sqlite_unicode => 1,AutoCommit=>0,RaiseError=>1,HandleError=>\&db_error });    
            if ( ! exist_mig_version("1.3.0") ) {
            $log->info("init: mig ro 1.3.0 required");
            Plugins::MyQobuz::MyQobuzMigrate::migrate_1_3_0($_dbh);
            }  
            #$_dbh->do("PRAGMA foreign_keys = ON");
        }

        # prepare insert statements
        #artist
        $_sth_insert_artist = $_dbh->prepare("INSERT INTO artist (id,name,image) VALUES (?, ?, ?);");
        #album
        $_sth_insert_album = $_dbh->prepare("INSERT INTO album (id,name,genre, qobuzGenre, image, artist, year, label) VALUES (?, ?, ?, ?, ?, ?, ?, ?);");
        #album
        $_sth_insert_track = $_dbh->prepare("INSERT INTO track (id,no,name,duration,url,album, exclude) VALUES (?, ?, ?, ?, ?, ?, 0);");
        #tag
        $_sth_insert_tag = $_dbh->prepare("INSERT INTO tag (name) VALUES (?);");
        #tag
        $_sth_insert_album_tag = $_dbh->prepare("INSERT INTO album_tag (album,tag) VALUES (?,?);");
        #artist_album
        $_sth_insert_artist_album = $_dbh->prepare("INSERT INTO artist_album (artist,album,role) VALUES (?,?,?);");
        #genre
        $_sth_change_album_genre = $_dbh->prepare("UPDATE album SET genre = ? WHERE id = ?;");
        #goody
        my $goody_sql = q/
            INSERT INTO goody (album,description,file_format_id,name,original_url,url) 
            VALUES (?,?,?,?,?,?);
        /;
        $_sth_insert_goody = $_dbh->prepare($goody_sql);
        
        # prepare delete statements
        #artist
        $_sth_delete_artist = $_dbh->prepare("DELETE FROM artist WHERE id = ?;");
         my $cleanup_sql = q/
            DELETE FROM artist WHERE artist.id IN 
                (SELECT  a.id FROM artist as a 
                    LEFT JOIN artist_album as aa ON a.id = aa.artist 
                    WHERE aa.album IS NULL);
        /;
        $_sth_cleanup_artist_album =  $_dbh->prepare($cleanup_sql);
        
        #album
        $_sth_delete_album = $_dbh->prepare("DELETE FROM album WHERE id = ?;");
        $_sth_delete_artist_album = $_dbh->prepare("DELETE FROM artist_album WHERE album = ?;");
        #tracks
        $_sth_delete_album_tracks = $_dbh->prepare("DELETE FROM track WHERE album = ?;");
        #tag
        $_sth_delete_tag =  $_dbh->prepare("DELETE FROM tag WHERE id = ?;");
        #album_tag
        $_sth_delete_album_tag = $_dbh->prepare("DELETE FROM album_tag WHERE album = ? AND tag = ?;");

        # prepare exist query statements (foreign key constraints are not working)
        $_sth_exist_album_with_artist = $_dbh->prepare("SELECT count(*) FROM album WHERE artist = ?;");
        $_sth_exist_artist_album_with_artist = $_dbh->prepare("SELECT count(*) FROM artist_album WHERE artist = ?;");
        $_sth_exist_album_with_tag =  $_dbh->prepare("SELECT count(*) FROM album_tag WHERE tag = ?;");
        

        #prepare fetches
        $_sth_albums_with_artist    = $_dbh->prepare("SELECT id FROM album WHERE artist = ?;");
        $_sth_tag_id                = $_dbh->prepare("SELECT id FROM tag WHERE name = ?;");
        $_sth_artists               = $_dbh->prepare("SELECT id,name FROM artist ORDER BY name;");
        $_sth_tags                  = $_dbh->prepare("SELECT id,name FROM tag;");
        $_sth_genres                = $_dbh->prepare("SELECT DISTINCT genre FROM album;");
        $_sth_album                 = $_dbh->prepare("SELECT id,name,artist FROM album WHERE id = ?;");
        $_sth_albums_with_tag       = $_dbh->prepare("SELECT album FROM album_tag WHERE tag = ?;");

        my $albumLatest = q/
        SELECT 
            album.id , 
            album.name, 
            artist.id,
            artist.name
        FROM album 
        INNER JOIN artist
        ON album.artist = artist.id
        ORDER BY insertTS DESC LIMIT 10 
        /;
        $_sth_album_latest = $_dbh->prepare($albumLatest);
    
        my $artistWithGenreSql = q/
        SELECT DISTINCT
            artist.id,
            artist.name
        FROM
            album
            INNER JOIN artist ON artist.id = album.artist
        WHERE
           album.genre = ? ;
        /;
        $_sth_artists_with_genre = $_dbh->prepare($artistWithGenreSql);

        $_sth_albums_with_artist_and_genre = $_dbh->prepare("SELECT id FROM album WHERE artist = ? AND genre = ?;");

        my $tagWithAlbumSql= q/
        SELECT
            tag,
            tag.name as tag_name 
        FROM
            album_tag
            INNER JOIN tag ON album_tag.tag=tag.id
        WHERE
            album = ?; 
        /;
        $_sth_tag_with_album = $_dbh->prepare($tagWithAlbumSql);

        my $albumWithArtistAndTagSql = q/
        SELECT
            id,
            artist,
            album_tag.tag as album_tag 
        FROM
            album
            INNER JOIN album_tag ON album_tag.album=album.id
        WHERE
            artist = ? AND
            album_tag = ? ;
        /;
        $_sth_albums_with_artist_and_tag = $_dbh->prepare($albumWithArtistAndTagSql);

        my $albumWithArtistAndGenreAndTagSql = q/
        SELECT
            id,
            artist,
            genre,
            album_tag.tag as album_tag 
        FROM
            album
            INNER JOIN album_tag ON album_tag.album=album.id
        WHERE
            artist = ? AND
            genre = ? AND
            album_tag = ?;
        /;
        $_sth_albums_with_artist_and_genre_and_tag = $_dbh->prepare($albumWithArtistAndGenreAndTagSql);

        my $allAlbumWithArtist = q/
        SELECT
            album.id,
            album.name,
            artist.name as artist_name,
            artist.id as   artist_id
        FROM
            album
            INNER JOIN artist ON artist.id=album.artist;
        /;

        $_sth_all_albums_with_artist = $_dbh->prepare($allAlbumWithArtist );
       
        my $genreWithTagSql = q/
        SELECT DISTINCT 
        album.genre
        FROM album 
        INNER JOIN album_tag ON album.id = album_tag.album 
        WHERE album_tag.tag = ? ;
        /;
        $_sth_genres_with_tag = $_dbh->prepare($genreWithTagSql);

        my $artistWithTagSql = q/
        SELECT DISTINCT 
        artist.id,
        artist.name  
        FROM album 
        INNER JOIN album_tag ON album.id = album_tag.album 
        INNER JOIN artist ON album.artist = artist.id 
        WHERE album_tag.tag = ? 
        ORDER BY artist.name;
        /;
        $_sth_artists_with_tag = $_dbh->prepare($artistWithTagSql);
        
        my $artistWithGenreTagSql = q/
        SELECT DISTINCT 
        artist.id,
        artist.name  
        FROM album 
        INNER JOIN album_tag ON album.id = album_tag.album 
        INNER JOIN artist ON album.artist = artist.id 
        WHERE album.genre = ? AND album_tag.tag = ?
        ORDER BY artist.name;
        /;    
        $_sth_artists_with_genre_tag = $_dbh->prepare($artistWithGenreTagSql);
        1;
}

sub areAlbumsRemovedByQobuz {
    return  $areAlbumsRemovedByQobuz;
}

sub albumsRemovedByQobuz {
    return $albumsRemovedByQobuz;
}

sub albumRemovedCleanUp {
    my $class = shift;
    my $albumId = shift;
    my $index = 0;
    foreach (@{$albumsRemovedByQobuz}) {
        if ($_->{album_id} eq $albumId) {
            splice(@{$albumsRemovedByQobuz}, $index, 1);
            last;
        }
        $index++
    }
}

sub checkAlbumRemovedByQobuz {
    if (not $areAlbumsRemovedByQobuz){
        $areAlbumsRemovedByQobuz = -1;
        my $albums = getInstance()->getAllAlbums();
        my $items = [];
        my $api = Plugins::Qobuz::Plugin::getAPIHandler();
        foreach my $albumref (@{$albums}){
            $api->getAlbum( 
                sub {
                    my $album = shift;
                    if (not $album->{title}){
                        $areAlbumsRemovedByQobuz = 1;
                        my $album = { 
                            album_id => $albumref->[0],
                            album_name => $albumref->[1],
                            artist_name => $albumref->[2],
                            artist_id => $albumref->[3]
                        }; 
                        push (@{$albumsRemovedByQobuz}, $album);
                    }
                },
                $albumref->[0],
                sub {
                    my $error = shift;
                    if ( $error =~ /^404/){
                        # album with id is removed from Qobuz
                        $areAlbumsRemovedByQobuz = 1;
                        my $album = { 
                            album_id => $albumref->[0],
                            album_name => $albumref->[1],
                            artist_name => $albumref->[2],
                            artist_id => $albumref->[3]
                        }; 
                        push (@{$albumsRemovedByQobuz}, $album);
                    }
                });
        }
    }
    
}

sub getInstance {
            if (not defined $instance){
                $instance = bless {}, shift ;
                $instance->init();
                $instance->checkAlbumRemovedByQobuz();
            }
            return $instance;
}

sub resetDB {
    if (defined $instance) {
        my $rc = $_dbh->disconnect  || warn $_dbh->errstr;
        $_dbh = undef;
        $instance = undef;
    }
}


sub getMyAlbum {
     my $class = shift;
     my $albumId = shift;
        local $@;
        my $album = undef;
        eval {
                $_sth_album->execute($albumId);
                my $albums = $_sth_album->fetchall_arrayref();  
                if  ( @{$albums} == 1) {
                    my $albumref = $albums->[0];
                    $album = {
                        id => $albumref->[0],
                        name => $albumref->[1],
                        artist => $albumref->[2]
                    }
                }     
        };
        if ($@){
            $@ && $log->error($@);
        }
        return $album;

}

sub _existAlbumWithArtist {
        my $class = shift;
        my $artist = shift;
        $_sth_exist_album_with_artist->execute($artist);
        my $count1 = $_sth_exist_album_with_artist->fetchrow_array();
        $_sth_exist_artist_album_with_artist->execute($artist);
        my $count2 = $_sth_exist_artist_album_with_artist->fetchrow_array();
        return $count1 + $count2;
}

sub _existAlbumWithTag {
         my $class = shift;
         my $tag = shift;
         $_sth_exist_album_with_tag->execute($tag);
         my ($count) = $_sth_exist_album_with_tag->fetchrow_array();
         return $count;
}

sub insertAlbum {
        my $class = shift;
        my $album = shift;
        local $@;
        eval {
            # insert artist
            my $artistId = $album->{artist}->{id};
            my $image =  Plugins::Qobuz::API->getArtistPicture($artistId) || 'html/images/artists.png';
            $_sth_insert_artist->execute($artistId,$album->{artist}->{name},$image);
            # insert album     
            my $year = substr($album->{release_date_stream},0,4) + 0;  
            $_sth_insert_album->execute($album->{id},
                $album->{title},
                $album->{genre},
                $album->{genre},
                $album->{image},
                $album->{artist}->{id},
                $year,
                $album->{label}->{name}
                );
            #insert artist album relation
            my $artists = $album->{artists};
            foreach my $item (@{$artists}){
                $image =  Plugins::Qobuz::API->getArtistPicture($item->{id}) || 'html/images/artists.png';
                $_sth_insert_artist->execute($item->{id},$item->{name},$image);
                my $roles = $item->{roles}; 
                foreach my $role (@{$roles}){
                    $_sth_insert_artist_album->execute($item->{id},$album->{id},$role);
                }
            }
            # insert goodies
            my $goodies = $album->{goodies};
            foreach my $goody (@{$goodies}){
                $_sth_insert_goody->execute(
                $album->{id},
                $goody->{description},
                $goody->{file_format_id},
                $goody->{name},
                $goody->{original_url},
                $goody->{url}
                );
            }
            # insert tracks
            foreach my $track (@{$album->{tracks}->{items}}) {
                # (id,no,name,duration,url,album)
			    #$totalDuration += $track->{duration};
			    #my $formattedTrack = _trackItem($client, $track);
                my $url = Plugins::Qobuz::API::Common->getUrl(undef,$track);
                $_sth_insert_track->execute($track->{id},$track->{track_number},$track->{title},$track->{duration},$url,$album->{id});
            }
            # commit
            $_dbh->commit();
        };
        if ($@){
            $@ && $log->error($@);
        }
}

sub getTagId {
        my $class = shift;
        my $tag   = shift;

        # remove leading and trailing ws    
        $tag =~ s/^\s+//;
        $tag =~ s/\s+$//;

         my $tag_id;
        local $@;
        eval{
            $_sth_tag_id->execute($tag);
            $tag_id = $_sth_tag_id->fetchrow_array();
        };
        if ($@){
            $@ && $log->error($@);
        }
        return $tag_id;
}

sub changeGenre {
        my $class = shift;
        my $albumId = shift;
        my $genre   = shift;
        # remove leading and trailing ws
        
        $genre =~ s/^\s+//;
        $genre =~ s/\s+$//;
        local $@;
        eval {
            # change album genre
            $_sth_change_album_genre->execute($genre,$albumId);
            # commit
            $_dbh->commit();
        };
        if ($@){
            $@ && $log->error($@);
        }
}

sub insertTag {
        my $class = shift;
        my $album = shift;
        my $tag   = shift;
        # remove leading and trailing ws
        
        $tag =~ s/^\s+//;
        $tag =~ s/\s+$//;
        local $@;
        eval {
            # check for tag exists
            my $id = $class->getTagId($tag);
            if (not defined $id){
                # insert tag    
                $_sth_insert_tag->execute($tag);
                $id = $class->getTagId($tag);
            }
            # insert album_tag
            $_sth_insert_album_tag->execute($album,$id);
            # commit
            $_dbh->commit();
        };
        if ($@){
            $@ && $log->error($@);
        }
}

sub removeTag {
        my $class = shift;
        my $album_id = shift;
        my $tag_id = shift;

        local $@;
        eval {
            # remove tag from album
            $_sth_delete_album_tag->execute($album_id,$tag_id);
            # remove tag if last     
            if (not $class->_existAlbumWithTag($tag_id)){
                # remove tag
                $_sth_delete_tag->execute($tag_id);
            }
            # commit
            $_dbh->commit();
        };
        if ($@){
            $@ && $log->error($@);
        }

}


sub removeAlbum {
        my $class = shift;
        my $albumId = shift;
        my $artistId = shift;
        
        local $@;
        eval {
            # remove album
            $_sth_delete_album->execute($albumId);
            $_sth_delete_album_tracks->execute($albumId);
            
            # remove tags
            my $tagMap = $class->getTagsWithAlbum($albumId);
            foreach my $key (keys %{ $tagMap }) {
                #delete album_tag
                $class->removeTag($albumId,$key);
            }
            #remove artist_album relation
            $_sth_delete_artist_album->execute($albumId);
            #clean up artist if required
            if (not $class->_existAlbumWithArtist($artistId)){
                # remove artist
                $_sth_delete_artist->execute($artistId);
            }
            # clean up artists by artist_album table
            $_sth_cleanup_artist_album->execute();
            # commit
            $_dbh->commit();
        };
        if ($@){
            $@ && $log->error($@);
        }
}

sub getLatestAlbums {
    my $class = shift;
    local $@;

    my @myAlbums;
    eval {
                my $myAlbum ;
                $_sth_album_latest->execute();
                my $albums = $_sth_album_latest->fetchall_arrayref();  
                foreach (@{$albums}) {
                    my $myAlbum = {
                       id => $_->[0],
                       name => $_->[1],
                       artist_id => $_->[2],
                       artist_name => $_->[3],
                    };
                    push(@myAlbums,$myAlbum)   
                }     
        };
    if ($@){
            $@ && $log->error($@);
    }

    return \@myAlbums;
}

sub getAlbums {
        my $class = shift;
        my $artistId = shift;
        my $genreId = shift;
        my $tag = shift;
        local $@;
        
        my $albumIds = [];
        my $listOfList;
        eval {
            if (defined $tag){
                if ( defined $genreId ){
                   $_sth_albums_with_artist_and_genre_and_tag->execute($artistId,$genreId,$tag);
                   $listOfList = $_sth_albums_with_artist_and_genre_and_tag->fetchall_arrayref();
                } else{
                    $_sth_albums_with_artist_and_tag->execute($artistId,$tag);
                    $listOfList = $_sth_albums_with_artist_and_tag->fetchall_arrayref();
                };
            }else{
                # no tag defined
                if ( defined $genreId ){
                    $_sth_albums_with_artist_and_genre->execute($artistId,$genreId);
                    $listOfList = $_sth_albums_with_artist_and_genre->fetchall_arrayref();
                } else{
                    $_sth_albums_with_artist->execute($artistId);
                    $listOfList = $_sth_albums_with_artist->fetchall_arrayref();
                };
            };
           
            foreach (@{$listOfList}) { push(@{$albumIds}, $_->[0]) };            
        };
        if ($@){
            $@ && $log->error($@);
        }
        return $albumIds;
}

sub getAlbumsWithTag {
        my $class = shift;
        my $tag = shift;
        local $@;
        my $albumIds = [];
        my $listOfList;
        eval {
            if (defined $tag){
                   $_sth_albums_with_tag->execute($tag);
                   $listOfList = $_sth_albums_with_tag->fetchall_arrayref();
                   foreach (@{$listOfList}) { push(@{$albumIds}, $_->[0]) };            
            };
        };
        if ($@){
            $@ && $log->error($@);
        }
        return $albumIds;
}


sub getTags {
        my $class = shift;
        local $@;
        my $tags = [];
        eval {
                $_sth_tags->execute();
                $tags = $_sth_tags->fetchall_arrayref();       
        };
        if ($@){
            $@ && $log->error($@);
        }
        return $tags;
}

sub getAllAlbums {
    my $class = shift;
        local $@;
        my $albums = [];
        eval {
                $_sth_all_albums_with_artist->execute();
                $albums = $_sth_all_albums_with_artist->fetchall_arrayref();       
        };
        if ($@){
            $@ && $log->error($@);
        }
        return $albums;
}

sub getMyGenres {
        my $class = shift;
        my $tagId = shift;
        my $_sth;
        local $@;
        my $genres;
        eval {
            if (defined $tagId){
                $_sth_genres_with_tag->execute($tagId);
                $genres = $_sth_genres_with_tag->fetchall_arrayref();
            } else{
                $_sth_genres->execute();
                $genres = $_sth_genres->fetchall_arrayref();
            }
   
        };
        if ($@){
            $@ && $log->error($@);
        }
        return $genres;
}

# returns list of artist hashes with id and name
sub getArtists {
        my $class = shift;
        my $tagId = shift;
       
        local $@;
        my $artists = [];
        eval {
            my $listOfArtists;
            if (defined $tagId){
                $_sth_artists_with_tag->execute($tagId);
                $listOfArtists = $_sth_artists_with_tag->fetchall_arrayref();
            }else{
                $_sth_artists->execute();
                $listOfArtists = $_sth_artists->fetchall_arrayref();
            }

            foreach (@{$listOfArtists}) { 
                my $hash = { id => $_->[0] , name =>  $_->[1] }; 
                push ( @{$artists} , $hash); 
            };
                 
        };
        if ($@){
            $@ && $log->error($@);
        }
        return $artists;
}

# returns list of artist hashes with id and name
sub getArtistsWithGenre {
        my $class = shift;
        my $genre = shift;
        my $tagId = shift;
       
        local $@;
        my $artists = [];
        eval {
            my $listOfArtists ;
            if (defined $tagId){
                $_sth_artists_with_genre_tag->execute($genre,$tagId);
                $listOfArtists = $_sth_artists_with_genre_tag->fetchall_arrayref();
            }else{
                $_sth_artists_with_genre->execute($genre);
                $listOfArtists = $_sth_artists_with_genre->fetchall_arrayref();
            }
           
            foreach (@{$listOfArtists}) {  
                my $hash = { id => $_->[0] , name =>  $_->[1] }; 
                push(@{$artists}, $hash ) 
            };
        };
        if ($@){
            $@ && $log->error($@);
        }
        return $artists;
}

#returns tag map with key == tag.id and value == tag.mame
sub getTagsWithAlbum {
        my $class = shift;
        my $albumId = shift;
       
        local $@;
        my $tagMap = {};
        eval {
            $_sth_tag_with_album->execute($albumId);
            my $listOfTags = $_sth_tag_with_album->fetchall_arrayref();
            foreach (@{$listOfTags}) {  
                $tagMap->{$_->[0]} = $_->[1];
            };
        };
        if ($@){
            $@ && $log->error($@);
        }
        return $tagMap;
}
   

1;


