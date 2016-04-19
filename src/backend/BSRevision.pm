#
# Copyright (c) 2016 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#
################################################################
#
# Source revision handling
#

package BSRevision;

use strict;

use BSConfiguration;
use BSXML;
use BSUtil;
use BSFileDB;
use BSSrcrep;
use BSDB;

my $projectsdir = "$BSConfig::bsdir/projects";
my $srcrep = "$BSConfig::bsdir/sources";
my $uploaddir = "$srcrep/:upload";

my $sourcedb = "$BSConfig::bsdir/db/source";

my $srcrevlay = [qw{rev vrev srcmd5 version time user comment requestid}];

sub getrev_deleted_srcmd5 {
  my ($projid, $packid, $srcmd5) = @_;
  return undef unless BSSrcrep::existstree($projid, $packid, $srcmd5);
  # tree exists. make sure we knew the project/package at one time in the past
  return undef unless -e "$projectsdir/$projid.pkg/$packid.mrev.del" ||
                      -e "$projectsdir/_deleted/$projid.pkg/$packid.mrev" ||
                      -e "$projectsdir/_deleted/$projid.pkg/$packid.mrev.del";
  return {'project' => $projid, 'package' => $packid, 'rev' => $srcmd5, 'srcmd5' => $srcmd5};
}

#
# get a revision object from a revision identifier, local case only
#
sub getrev_local {
  my ($projid, $packid, $rev) = @_;
  die("bad projid\n") if $projid =~ /\// || $projid =~ /^\./;
  die("bad packid\n") if $packid =~ /\// || $packid =~ /^\./;
  return undef if $packid ne '_project' && ! -e "$projectsdir/$projid.pkg/$packid.xml";
  undef $rev if $rev && ($rev eq 'latest' || $rev eq 'build');
  undef $rev if $rev && $rev eq 'upload' && ! -e "$projectsdir/$projid.pkg/$packid.upload-MD5SUMS";
  if (!defined($rev)) {
    $rev = BSFileDB::fdb_getlast("$projectsdir/$projid.pkg/$packid.rev", $srcrevlay);
    if (!$rev && ($packid eq '_project' && -e "$projectsdir/$projid.conf")) {
      addrev_meta({'user' => 'internal', 'comment' => 'initial commit'}, $projid, undef, undef, undef, undef, 'rev');
      $rev = BSFileDB::fdb_getlast("$projectsdir/$projid.pkg/$packid.rev", $srcrevlay);
    }
    $rev = {'srcmd5' => $BSSrcrep::emptysrcmd5} unless $rev;
  } elsif ($rev =~ /^[0-9a-f]{32}$/) {
    return undef unless -e "$projectsdir/$projid.pkg/$packid.rev" || -e "$projectsdir/$projid.pkg/$packid.mrev";
    $rev = {'srcmd5' => $rev, 'rev' => $rev};
  } elsif ($rev eq 'upload') {
    $rev = {'srcmd5' => 'upload', 'rev' => 'upload', 'special_meta' => "$projectsdir/$projid.pkg/$packid.upload-MD5SUMS"};
  } elsif ($rev eq 'repository') {
    $rev = {'srcmd5' => $BSSrcrep::emptysrcmd5, 'rev' => 'repository'}
  } else {
    if ($rev eq '0') {
      $rev = {'srcmd5' => $BSSrcrep::emptysrcmd5};
    } else {
      $rev = BSFileDB::fdb_getmatch("$projectsdir/$projid.pkg/$packid.rev", $srcrevlay, 'rev', $rev);
      die("no such revision\n") unless defined $rev;
    }
  }
  $rev->{'project'} = $projid;
  $rev->{'package'} = $packid;
  return $rev;
}

# find last revision that consisted of the same srcmd5
sub findlastrev {
  my ($orev) = @_;
  my $rev = BSFileDB::fdb_getmatch("$projectsdir/$orev->{'project'}.pkg/$orev->{'package'}.rev", $srcrevlay, 'srcmd5', $orev->{'srcmd5'});
  return undef unless $rev;
  $rev->{'project'} = $orev->{'project'};
  $rev->{'package'} = $orev->{'package'};
  return $rev;
}

sub getrev_meta {
  my ($projid, $packid, $revid, $deleted) = @_;
  my $revfile = defined($packid) ? "$projectsdir/$projid.pkg/$packid.mrev" : "$projectsdir/$projid.pkg/_project.mrev";
  if ($deleted) {
    $revfile = defined($packid) ? "$projectsdir/$projid.pkg/$packid.mrev.del" : "$projectsdir/_deleted/$projid.pkg/_project.mrev";
    if (defined($packid) && ! -e $revfile && ! -e "$projectsdir/$projid.xml" && -e "$projectsdir/_deleted/$projid.pkg") {
      $revfile = "$projectsdir/_deleted/$projid.pkg/$packid.mrev";
    }
  }
  my $rev;
  if (!defined($revid) || $revid eq 'latest') {
    $rev = BSFileDB::fdb_getlast($revfile, $srcrevlay);
    $rev = { 'srcmd5' => $BSSrcrep::emptysrcmd5 } unless $rev;
  } elsif ($revid =~ /^[0-9a-f]{32}$/) {
    $rev = { 'srcmd5' => $revid };
  } else {
    $rev = BSFileDB::fdb_getmatch($revfile, $srcrevlay, 'rev', $revid);
  }
  if (!$rev) {
    die("404 revision '$revid' does not exist\n") if $revid;
    die("404 no revision\n");
  }
  $rev->{'project'} = $projid;
  $rev->{'package'} = defined($packid) ? $packid : '_project';
  return $rev;
}

sub retrofit_old_prjsource {
  my ($projid) = @_;
  my $files = {};
  my $packid = '_project';
  if (-e "$projectsdir/$projid.conf") {
    BSUtil::cp("$projectsdir/$projid.conf", "$uploaddir/addrev_meta$$");
    $files->{'_config'} = BSSrcrep::addfile($projid, $packid, "$uploaddir/addrev_meta$$", '_config');
  }
  return $files;
}

sub retrofit_old_meta {
  my ($projid, $packid) = @_;
  my $files = {};
  if (defined($packid) && $packid ne '_project') {
    if (-e "$projectsdir/$projid.pkg/$packid.xml") {
      BSUtil::cp("$projectsdir/$projid.pkg/$packid.xml", "$uploaddir/addrev_meta$$");
      $files->{'_meta'} = BSSrcrep::addfile($projid, $packid, "$uploaddir/addrev_meta$$", '_meta');
    }
  } else {
    $packid = '_project';
    if (-e "$projectsdir/$projid.xml") {
      BSUtil::cp("$projectsdir/$projid.xml", "$uploaddir/addrev_meta$$");
      $files->{'_meta'} = BSSrcrep::addfile($projid, $packid, "$uploaddir/addrev_meta$$", '_meta');
    }
    if (-e "$projectsdir/$projid.pkg/_sslcert") {
      # FIXME: this is only needed for the test suite. But as long we do not have a signing
      #        stub there we need this to inject keys.
      BSUtil::cp("$projectsdir/$projid.pkg/_sslcert", "$uploaddir/addrev_meta$$");
      $files->{'_sslcert'} = BSSrcrep::addfile($projid, $packid, "$uploaddir/addrev_meta$$", '_sslcert');
    }
    if (-e "$projectsdir/$projid.pkg/_pubkey") {
      BSUtil::cp("$projectsdir/$projid.pkg/_pubkey", "$uploaddir/addrev_meta$$");
      $files->{'_pubkey'} = BSSrcrep::addfile($projid, $packid, "$uploaddir/addrev_meta$$", '_pubkey');
    }
    if (-e "$projectsdir/$projid.pkg/_signkey") {
      BSUtil::cp("$projectsdir/$projid.pkg/_signkey", "$uploaddir/addrev_meta$$");
      chmod(0600, "$uploaddir/addrev_meta$$");
      $files->{'_signkey'} = BSSrcrep::addfile($projid, $packid, "$uploaddir/addrev_meta$$", '_signkey');
    }
  }
  return $files;
}

sub extract_old_prjsource {
  my ($projid, $rev) = @_;
  my $files = BSSrcrep::lsrev($rev);
  my $config;
  $config = BSSrcrep::repreadstr($rev, '_config', $files->{'_config'}, 1) if $files->{'_config'};
  writestr("$uploaddir/$$.2", "$projectsdir/$projid.conf", $config) if $config;
}

sub extract_old_meta {
  my ($projid, $packid, $rev) = @_;
  $rev->{'keepsignkey'} = 1;
  my $files = BSSrcrep::lsrev($rev);
  delete $rev->{'keepsignkey'};
  if (!defined($packid) || $packid eq '_project') {
    $packid = '_project';
    my $pubkey;
    $pubkey = BSSrcrep::repreadstr($rev, '_pubkey', $files->{'_pubkey'}, 1) if $files->{'_pubkey'};
    writestr("$uploaddir/$$.2", "$projectsdir/$projid.pkg/_pubkey", $pubkey) if $pubkey;
    my $signkey;
    $signkey = BSSrcrep::repreadstr($rev, '_signkey', $files->{'_signkey'}, 1) if $files->{'_signkey'};
    if ($signkey) {
      writestr("$uploaddir/$$.2", undef, $signkey);
      chmod(0600, "$uploaddir/$$.2");
      rename("$uploaddir/$$.2", "$projectsdir/$projid.pkg/_signkey") || die("rename $uploaddir/$$.2 $projectsdir/$projid.pkg/_signkey: $!\n");
    }
    my $meta;
    $meta = BSSrcrep::repreadstr($rev, '_meta', $files->{'_meta'}, 1) if $files->{'_meta'};
    writestr("$uploaddir/$$.2", "$projectsdir/$projid.xml", $meta) if $meta;
  } else {
    my $meta;
    $meta = BSSrcrep::repreadstr($rev, '_meta', $files->{'_meta'}, 1) if $files->{'_meta'};
    writestr("$uploaddir/$$.2", "$projectsdir/$projid.pkg/$packid.xml", $meta) if $meta;
  }
}

sub addrev_meta_multiple {
  my ($cgi, $projid, $packid, $suf, @todo) = @_;

  $suf ||= 'mrev';
  undef $packid if $packid && $packid eq '_project';
  my $rpackid = defined($packid) ? $packid : '_project';

  # first commit content into internal repository
  my %rfilemd5;
  for my $todo (@todo) {
    my ($tmpfile, $file, $rfile) = @$todo;
    next unless defined($tmpfile);
    mkdir_p($uploaddir);
    unlink("$uploaddir/addrev_meta$$");
    BSUtil::cp($tmpfile, "$uploaddir/addrev_meta$$");
    chmod(0600, "$uploaddir/addrev_meta$$") if !defined($packid) && $suf eq 'mrev' && $rfile eq '_signkey';
    $rfilemd5{$rfile} = BSSrcrep::addfile($projid, $rpackid, "$uploaddir/addrev_meta$$", $rfile);
  }

  mkdir_p("$projectsdir/$projid.pkg");
  my $revfile = "$projectsdir/$projid.pkg/$rpackid.$suf";
  local *FF;
  BSUtil::lockopen(\*FF, '+>>', $revfile);
  my $rev = BSFileDB::fdb_getlast($revfile, $srcrevlay);
  my $files;
  if ($rev) {
    $rev->{'project'} = $projid;
    $rev->{'package'} = $rpackid;
    $rev->{'keepsignkey'} = 1;
    $files = BSSrcrep::lsrev($rev);
    delete $rev->{'keepsignkey'};
  } else {
    $files = {};
    if ((defined($packid) && -e "$projectsdir/$projid.pkg/$packid.xml") || (!defined($packid) && -e "$projectsdir/$projid.xml")) {
      if ($suf eq 'mrev') {
        $files = retrofit_old_meta($projid, $packid);
      } elsif (!defined($packid)) {
        $files = retrofit_old_prjsource($projid);
      }
    }
  }

  for my $todo (@todo) {
    my ($tmpfile, $file, $rfile) = @$todo;
    if (defined($tmpfile)) {
      $files->{$rfile} = $rfilemd5{$rfile};
    } else {
      delete $files->{$rfile};
    }
  }

  my $srcmd5 = BSSrcrep::addmeta($projid, $rpackid, $files);
  my $user = defined($cgi->{'user'}) ? str2utf8xml($cgi->{'user'}) : 'unknown';
  my $comment = defined($cgi->{'comment'}) ? str2utf8xml($cgi->{'comment'}) : '';
  my $nrev = { 'srcmd5' => $srcmd5, 'time' => time(), 'user' => $user, 'comment' => $comment, 'requestid' => $cgi->{'requestid'} };
  # copy version/vref in initial commit case
  if (!@todo && defined($packid) && $suf ne 'mrev' && $rev) {
    $nrev->{'version'} = $rev->{'version'} if defined $rev->{'version'};
    $nrev->{'vrev'} = $rev->{'vrev'} if defined $rev->{'vrev'};
  }
  BSFileDB::fdb_add_i(\*FF, $srcrevlay, $nrev);

  for my $todo (@todo) {
    my ($tmpfile, $file, $rfile) = @$todo;
    if (defined($file)) {
      if (defined($tmpfile)) {
        rename($tmpfile, $file) || die("rename $tmpfile $file: $!\n");
      } else {
        unlink($file);
      }
    } elsif (defined($tmpfile)) {
      unlink($tmpfile);
    }
  }
  close FF;	# free lock
  $nrev->{'project'} = $projid;
  $nrev->{'package'} = $rpackid;
  return $nrev;
}

sub addrev_meta {
  my ($cgi, $projid, $packid, $tmpfile, $file, $rfile, $suf) = @_;
  if (defined($rfile)) {
    return addrev_meta_multiple($cgi, $projid, $packid, $suf,  [ $tmpfile, $file, $rfile ]);
  } else {
    return addrev_meta_multiple($cgi, $projid, $packid, $suf);
  }
}

sub updatelinkinfodb {
  my ($projid, $packid, $rev, $files) = @_;

  mkdir_p($sourcedb) unless -d $sourcedb;
  my $linkdb = BSDB::opendb($sourcedb, 'linkinfo');
  my $linkinfo;
  if ($files && $files->{'_link'}) {
    my $l = BSSrcrep::repreadxml($rev, '_link', $files->{'_link'}, $BSXML::link, 1);
    if ($l) {
      $linkinfo = {};
      $linkinfo->{'project'} = defined $l->{'project'} ? $l->{'project'} : $projid;
      $linkinfo->{'package'} = defined $l->{'package'} ? $l->{'package'} : $packid;
      $linkinfo->{'rev'} = $l->{'rev'} if defined $l->{'rev'};
    }
  }
  $linkdb->store("$projid/$packid", $linkinfo);
}

sub movelinkinfos {
  my ($projid, $oprojid) = @_;
  return if $projid eq $oprojid;
  return unless -d $sourcedb;
  my $linkdb = BSDB::opendb($sourcedb, 'linkinfo');
  return unless $linkdb;
  my @packids = grep {s/\Q$oprojid\E\///} $linkdb->keys();
  for my $packid (@packids) {
    next unless -e "$projectsdir/$projid.pkg/$packid.xml";
    eval {
      my $rev = getrev_local($projid, $packid);
      updatelinkinfodb($projid, $packid, $rev, BSSrcrep::lsrev($rev)) if $rev;
    };
    warn($@) if $@;
    updatelinkinfodb($oprojid, $packid);
  }
}

sub addrev_local {
  my ($cgi, $projid, $packid, $rev, $files) = @_;
  mkdir_p("$projectsdir/$projid.pkg");
  if ($packid eq '_project') {
    $rev = BSFileDB::fdb_add_i("$projectsdir/$projid.pkg/$packid.rev", $srcrevlay, $rev);
    $rev->{'project'} = $projid;
    $rev->{'package'} = $packid;
    extract_old_prjsource($projid, $rev);
    # kill upload revision as we did a real commit
    unlink("$projectsdir/$projid.pkg/$packid.upload-MD5SUMS");
    return $rev;
  }
  if (defined($rev->{'version'}) && !defined($cgi->{'vrev'})) {
    $rev = BSFileDB::fdb_add_i2("$projectsdir/$projid.pkg/$packid.rev", $srcrevlay, $rev, 'vrev', 'version', $rev->{'version'});
  } else {
    $rev = BSFileDB::fdb_add_i("$projectsdir/$projid.pkg/$packid.rev", $srcrevlay, $rev);
  }
  # add missing data to complete the revision object
  $rev->{'project'} = $projid;
  $rev->{'package'} = $packid;
  # update linked package database
  updatelinkinfodb($projid, $packid, $rev, $files) if $files;
  # kill upload revision as we did a real commit
  unlink("$projectsdir/$projid.pkg/$packid.upload-MD5SUMS");
  # kill obsolete _pattern file
  unlink("$projectsdir/$projid.pkg/pattern-MD5SUMS") if $packid eq '_pattern';
  return $rev;
}

sub undelete_rev {
  my ($cgi, $projid, $packid, $revfilefrom, $revfileto) = @_;
  my @rev = BSFileDB::fdb_getall($revfilefrom, $srcrevlay);
  die("$revfilefrom: no entries\n") unless @rev;
  # XXX add way to specify which block to restore
  for my $rev (reverse splice @rev) {
    unshift @rev, $rev;
    last if $rev->{'rev'} == 1;
  }
  my $rev = $rev[-1];
  my $user = defined($cgi->{'user'}) ? str2utf8xml($cgi->{'user'}) : 'unknown';
  my $comment = defined($cgi->{'comment'}) ? str2utf8xml($cgi->{'comment'}) : '';
  my $nrev = { 'srcmd5' => $rev->{'srcmd5'}, 'time' => time(), 'user' => $user, 'comment' => $comment, 'requestid' => $cgi->{'requestid'} };
  $nrev->{'version'} = $rev->{'version'} if $rev && defined $rev->{'version'};
  $nrev->{'vrev'} = $rev->{'vrev'} if $rev && defined $rev->{'vrev'};
  $nrev->{'rev'} = $rev->{'rev'} + 1;
  if ($cgi->{'time'}) {
    if ($cgi->{'time'} == 1) {
      $nrev->{'time'} = $rev->{'time'} if $rev && $rev->{'time'};
    } else {
      die("specified time is less than time in last commit\n") if $rev && $rev->{'time'} > $cgi->{'time'};
      $nrev->{'time'} = $cgi->{'time'};
    }
  }
  push @rev, $nrev;
  BSFileDB::fdb_add_multiple($revfileto, $srcrevlay, @rev);
  $nrev->{'project'} = $projid;
  $nrev->{'package'} = $packid;
  # extract legacy files, update linkinfo db
  if ($revfileto =~ /\.rev$/) {
    if ($packid eq '_project') {
      extract_old_prjsource($projid, $nrev);
    } else {
      updatelinkinfodb($projid, $packid, $rev, BSSrcrep::lsrev($nrev));
    }
  } elsif ($revfileto =~ /\.mrev$/) {
    BSRevision::extract_old_meta($projid, $packid, $nrev);
  }
  return $nrev;
}

sub delete_rev {
  my ($cgi, $projid, $packid, $revfilefrom, $revfileto, $wipe) = @_;

  if ($revfilefrom =~ /\.mrev$/) {
    if ($packid eq '_project') {
      unlink("$projectsdir/$projid.pkg/_pubkey");
      unlink("$projectsdir/$projid.pkg/_signkey");
      unlink("$projectsdir/$projid.xml");
    } else {
      unlink("$projectsdir/$projid.pkg/$packid.xml");
    }
  } elsif ($revfilefrom =~ /\.rev$/) {
    if ($packid eq '_project') {
      unlink("$projectsdir/$projid.conf");
    }
  }
  my $oldrev = readstr($revfilefrom, 1);
  if (defined($oldrev) && $oldrev ne '' && not $wipe) {
    BSUtil::lockopen(\*F, '+>>', $revfileto);
    if ($revfilefrom =~ /\.mrev$/) {
      BSUtil::appendstr("$projectsdir/$projid.pkg/$packid.mrev.del", $oldrev);
    } else {
      BSUtil::appendstr("$projectsdir/$projid.pkg/$packid.rev.del", $oldrev);
    }
    close F;
    if ($packid ne '_project' && $revfilefrom =~ /\.rev$/) {
      BSRevision::updatelinkinfodb($projid, $packid);
    }
  }
  unlink($revfilefrom);
}

sub delete_deleted {
  my ($cgi, $projid) = @_;
  for my $f (ls("$projectsdir/_deleted/$projid.pkg")) {
    next unless  $f =~ /\.m?rev$/;
    my $oldrev = readstr("$projectsdir/_deleted/$projid.pkg/$f", 1);
    if (defined($oldrev) && $oldrev ne '') {
      BSUtil::lockopen(\*F, '+>>', "$projectsdir/_deleted/$projid.pkg/$f.del");
      BSUtil::appendstr("$projectsdir/_deleted/$projid.pkg/$f.del", $oldrev);
      # XXX: add comment
      close F;
    }
    unlink("$projectsdir/_deleted/$projid.pkg/$f");
  }
}

sub lsprojects_local {
  my ($deleted) = @_;
  if ($deleted) {
    my @projids = grep {s/\.pkg$//} ls("$projectsdir/_deleted");
    @projids = grep {! -e "$projectsdir/$_.xml"} @projids;
    return sort @projids;
  }
  local *D;
  return () unless opendir(D, $projectsdir);
  my @projids = grep {s/\.xml$//} readdir(D);
  closedir(D);
  return sort @projids;
}

sub lspackages_local {
  my ($projid, $deleted) = @_;

  if ($deleted) {
    my @packids;
    if (! -e "$projectsdir/$projid.xml" && -d "$projectsdir/_deleted/$projid.pkg") {
      @packids = grep {$_ ne '_meta' && $_ ne '_project'} grep {s/\.mrev$//} ls("$projectsdir/_deleted/$projid.pkg");
    } else {
      @packids = grep {s/\.mrev\.del$//} ls("$projectsdir/$projid.pkg");
      @packids = grep {! -e "$projectsdir/$projid.pkg/$_.xml"} @packids;
    }
    return sort @packids;
  }
  local *D;
  return () unless opendir(D, "$projectsdir/$projid.pkg");
  my @packids = grep {s/\.xml$//} readdir(D);
  closedir(D);
  return sort @packids;
}

1;
