#!/usr/bin/perl

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


use strict;

use Data::Dumper;
 
use XML::Simple qw(:strict);
use Archive::Zip::SimpleZip qw($SimpleZipError) ;
use Crypt::Digest::SHA1 qw(  sha1_file_hex);


sub check_version {
    # get repo version
    my $repoFile = './repo/myqobuz.xml';
    my $ref = XMLin($repoFile,
			KeyAttr    => [],
			ForceArray => [  'creator', 'sha', 'email', 'desc', 'link','url', 'title' , 'plugin', 'plugins'],
		);
    my $repo_version = $ref->{plugins}->[0]->{plugin}->[0]->{version};
    print "repo_version: $repo_version \n";
    #get install version
    my $installFile = './MyQobuz/install.xml';
    my $ref2 = XMLin($installFile,
			KeyAttr    => [],
			ForceArray => [ ],
		);
    # print Dumper($ref2);
    my $install_version = $ref2->{version};
    print "install_version: $install_version \n";
    if  ($install_version gt $repo_version){
        return $install_version;
    }else{
        return 0;
    }  
}

sub create_zip { 
    my $zipa = new Archive::Zip::SimpleZip("repo/MyQobuz.zip") 
        or die "Cannot create zip file: $SimpleZipError\n" ;
    $zipa->add("MyQobuz/install.xml");
    $zipa->add("MyQobuz/MyQobuzImpl.pm");
    $zipa->add("MyQobuz/Plugin.pm");
    $zipa->add("MyQobuz/MyQobuzDB.pm");
    $zipa->add("MyQobuz/Settings.pm");
    $zipa->add("MyQobuz/strings.txt");
    $zipa->add("MyQobuz/HTML/EN/plugins/MyQobuz/html/images/icon.png");
    $zipa->add("MyQobuz/HTML/EN/plugins/MyQobuz/html/images/qobuz.png");
    $zipa->add("MyQobuz/HTML/EN/plugins/MyQobuz/html/images/tag.png");
    $zipa->add("MyQobuz/HTML/EN/plugins/MyQobuz/settings/basic.html");
    $zipa->close();
}

sub update_repo {
    my $version = shift;
    my $sha1 = shift;
    print "Update version to $version\n";
    print "Update sha to $sha1\n";
    my $repoFile = './repo/myqobuz.xml';
    # parse XML
    my $ref = XMLin($repoFile,
			KeyAttr    => [],
			ForceArray => [  'creator', 'sha', 'email', 'desc', 'link','url', 'title' , 'plugin', 'plugins'],
		);
    # update sha1 and version
    $ref->{plugins}->[0]->{plugin}->[0]->{version} = $version;
    $ref->{plugins}->[0]->{plugin}->[0]->{sha}->[0] = $sha1;
    # write out
    XMLout($ref,
        RootName   => 'extensions',
        KeyAttr => {},
        OutputFile =>  $repoFile,
    );
}

####################################################################
#
#   main 
#
 my $new_version = check_version();
 if ( $new_version ) {
    print "Ok: versions consistent\n";
    #create new zip
    create_zip();
    #calculate sha1
    my $sha1  = sha1_file_hex('./repo/MyQobuz.zip');
    print "sha1: $sha1 \n";
    # update repo 
    update_repo($new_version ,$sha1);
 }else{
    print "Error: versions not consistent\n";
 }

1;



 



