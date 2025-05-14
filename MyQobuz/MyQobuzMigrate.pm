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

package Plugins::MyQobuz::MyQobuzMigrate;

use strict;
use Slim::Utils::Log;
use DBI;

my $log = logger('plugin.myqobuz');

sub insert_mig_version 
{
    my $_dbh = shift;
    my $mig_version = shift;
    local $@;
    eval{
        my $sth = $_dbh->prepare('INSERT INTO mig_version (version) VALUES(?);');
        $sth->execute($mig_version);
        $_dbh->commit();
    };    
    if ($@){
        $@ && $log->error($@);
    }
}

sub migrate_1_3_0 {
    my $_dbh = shift;

    local $@;
    eval{
        # change  unique constraint tag
        my $newTgaTable = q/
        CREATE TABLE tag_copy ( id INTEGER PRIMARY KEY,
                            name TEXT NOT NULL, 
                            group_name TEXT DEFAULT '\#no_group\#' NOT NULL,
                            UNIQUE(name,group_name));
        /;
        $_dbh->do($newTgaTable);
        $_dbh->do("INSERT INTO tag_copy SELECT * FROM tag;");
        $_dbh->do("DROP TABLE tag;");
        $_dbh->do("ALTER TABLE tag_copy RENAME TO tag;");
        $_dbh->commit();
        # change album
        $_dbh->do("ALTER TABLE album add column  year INTEGER DEFAULT NULL ;");
        $_dbh->do("ALTER TABLE album add column  label TEXT DEFAULT NULL ;");
        $_dbh->do("CREATE INDEX index_year ON album (year);");
        $_dbh->do("CREATE INDEX index_label ON album (label);");
        $_dbh->commit();
        #change track 
        $_dbh->do("ALTER TABLE track add column  performers TEXT DEFAULT NULL ;");
        # to store album artist relation
        $_dbh->do("CREATE TABLE IF NOT EXISTS artist_album (artist TEXT,album TEXT,role TEXT,PRIMARY KEY (artist,album));");
        $_dbh->do("CREATE INDEX index_artist_album_artist ON artist_album (artist);");
        $_dbh->do("CREATE INDEX index_artist_album_album ON artist_album (album);");
        $_dbh->commit();
        # to store goodies from qobuz
        my $newGoodyTable = q/
        CREATE TABLE IF NOT EXISTS goody (id INTEGER PRIMARY KEY AUTOINCREMENT,
                                        album TEXT,
                                        description TEXT,
                                        file_format_id INTEGER,
                                        name TEXT,
                                        original_url TEXT,
                                        url TEXT);
        /;
        $_dbh->do($newGoodyTable);
        $_dbh->do("CREATE INDEX IF NOT EXISTS index_goody_album ON goody (album);");
        $_dbh->commit();
        #create version table
        $_dbh->do("CREATE TABLE IF NOT EXISTS mig_version (version TEXT,PRIMARY KEY (version));");
        $_dbh->commit();
        #insert new verion
        insert_mig_version($_dbh,"1.3.0");
        $_dbh->commit();
    };
    if ($@){
        $@ && $log->error($@);
    }
}

1;
