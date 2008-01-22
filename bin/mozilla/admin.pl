#=====================================================================
# LX-Office ERP
# Copyright (C) 2004
# Based on SQL-Ledger Version 2.1.9
# Web http://www.lx-office.org
#
#=====================================================================
# SQL-Ledger Accounting
# Copyright (c) 2002
#
#  Author: Dieter Simader
#   Email: dsimader@sql-ledger.org
#     Web: http://www.sql-ledger.org
#
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#======================================================================
#
# setup module
# add/edit/delete users
#
#======================================================================

$menufile = "menu.ini";

use DBI;
use CGI;
use English qw(-no_match_vars);
use Fcntl;
use File::Copy;
use IO::File;
use POSIX qw(strftime);
use Sys::Hostname;

use SL::Auth;
use SL::Form;
use SL::Mailer;
use SL::User;
use SL::Common;
use SL::Inifile;
use SL::DBUpgrade2;
use SL::DBUtils;

require "bin/mozilla/common.pl";
require "bin/mozilla/admin_groups.pl";

our $cgi = new CGI('');

$form = new Form;

$locale = new Locale $language, "admin";

our $auth = SL::Auth->new();
if ($auth->session_tables_present()) {
  $auth->expire_sessions();
  $auth->restore_session();
  $auth->set_session_value('rpw', $form->{rpw});
}

# customization
if (-f "bin/mozilla/custom_$form->{script}") {
  eval { require "bin/mozilla/custom_$form->{script}"; };
  $form->error($@) if ($@);
}

$form->{stylesheet} = "lx-office-erp.css";
$form->{favicon}    = "favicon.ico";

if ($form->{action}) {
  if ($auth->authenticate_root($form->{rpw}, 0) != Auth::OK) {
    $form->{error_message} = $locale->text('Incorrect Password!');
    adminlogin();
    exit;
  }

  $auth->create_or_refresh_session() if ($auth->session_tables_present());

  call_sub($locale->findsub($form->{action}));

} elsif ($auth->authenticate_root($form->{rpw}, 0) == Auth::OK) {

  $auth->create_or_refresh_session() if ($auth->session_tables_present());

  login();

} else {
  # if there are no drivers bail out
  $form->error($locale->text('No Database Drivers available!'))
    unless (User->dbdrivers);

  adminlogin();

}

1;

# end

sub adminlogin {

  $form->{title} = qq|Lx-Office ERP $form->{version} | . $locale->text('Administration');

  $form->header();
  print $form->parse_html_template('admin/adminlogin');
}

sub login {
  check_auth_db_and_tables();
  list_users();
}

sub logout {
  $auth->destroy_session();
  adminlogin();
}

sub check_auth_db_and_tables {
  my %params;

  map { $params{"db_${_}"} = $auth->{DB_config}->{$_} } keys %{ $auth->{DB_config} };

  if (!$auth->check_database()) {
    $form->{title} = $locale->text('Authentification database creation');
    $form->header();
    print $form->parse_html_template('admin/check_auth_database', \%params);

    exit 0;
  }

  if (!$auth->check_tables()) {
    $form->{title} = $locale->text('Authentification tables creation');
    $form->header();
    print $form->parse_html_template('admin/check_auth_tables', \%params);

    exit 0;
  }

  if (-f $memberfile) {
    my $memberdir = "";

    if ($memberfile =~ m|^.*/|) {
      $memberdir = $&;
    }

    my $backupdir = "${memberdir}member-file-migration";

    $form->{title} = $locale->text('User data migration');
    $form->header();
    print $form->parse_html_template('admin/user_migration', { 'memberfile' => $memberfile,
                                                               'backupdir'  => $backupdir });

    exit 0
  }
}

sub create_auth_db {
  $auth->create_database('superuser'          => $form->{db_superuser},
                         'superuser_password' => $form->{db_superuser_password},
                         'template'           => $form->{db_template});
  login();
}

sub create_auth_tables {
  $auth->create_tables();
  $auth->set_session_value('rpw', $form->{rpw});
  $auth->create_or_refresh_session();

  login();
}

sub migrate_users {
  $lxdebug->enter_sub();

  my $memberdir = "";

  if ($memberfile =~ m|^.*/|) {
    $memberdir = $&;
  }

  my $backupdir = "${memberdir}member-file-migration";

  if (! -d $backupdir && !mkdir $backupdir, 0700) {
    $form->error(sprintf($locale->text('The directory "%s" could not be created:\n%s'), $backupdir, $!));
  }

  copy $memberfile, "users/member-file-migration/members";

  my $in = IO::File->new($memberfile, "r");

  $form->error($locale->text('Could not open the old memberfile.')) if (!$in);

  my (%members, $login);

  while (<$in>) {
    chomp;

    next if (m/^\s*\#/);

    if (m/^\[.*\]/) {
      $login = $_;
      $login =~ s/(\[|\])//g;
      $login =~ s/^\s*//;
      $login =~ s/\s*$//;

      $members{$login} = { "login" => $login };
      next;
    }

    if ($login && m/=/) {
      my ($key, $value) = split m/\s*=\s*/, $_, 2;
      $key   =~ s|^\s*||;
      $value =~ s|\s*$||;

      $value =~ s|\\r||g;
      $value =~ s|\\n|\n|g;

      $members{$login}->{$key} = $value;
    }
  }

  $in->close();

  delete $members{"root login"};

  map { $_->{dbpasswd} = unpack 'u', $_->{dbpasswd} } values %members;

  while (my ($login, $params) = each %members) {
    $auth->save_user($login, %{ $params });
    $auth->change_password($login, $params->{password}, 1);

    my $conf_file = "${memberdir}${login}.conf";

    if (-f $conf_file) {
      copy   $conf_file, "${backupdir}/${login}.conf";
      unlink $conf_file;
    }
  }

  unlink $memberfile;

  my @member_list = sort { lc $a->{login} cmp lc $b->{login} } values %members;

  $form->{title} = $locale->text('User data migration');
  $form->header();
  print $form->parse_html_template('admin/user_migration_done', { 'MEMBERS' => \@member_list });

  $lxdebug->leave_sub();
}

sub create_standard_group_ask {
  $form->{title} = $locale->text('Create a standard group');

  $form->header();
  print $form->parse_html_template("admin/create_standard_group_ask");
}

sub create_standard_group {
  my %members = $auth->read_all_users();

  my $groups = $auth->read_groups();

  foreach my $group (values %{$groups}) {
    if (($form->{group_id} != $group->{id})
        && ($form->{name} eq $group->{name})) {
      $form->show_generic_error($locale->text("A group with that name does already exist."));
    }
  }

  my $group = {
    'name'        => $locale->text('Full Access'),
    'description' => $locale->text('Full access to all functions'),
    'rights'      => { map { $_ => 1 } SL::Auth::all_rights() },
    'members'     => [ map { $_->{id} } values %members ],
  };

  $auth->save_group($group);

  user_migration_complete(1);
}

sub dont_create_standard_group {
  user_migration_complete(0);
}

sub user_migration_complete {
  my $standard_group_created = shift;

  $form->{title} = $locale->text('User migration complete');
  $form->header();

  print $form->parse_html_template('admin/user_migration_complete', { 'standard_group_created' => $standard_group_created });
}

sub list_users {
  my %members = $auth->read_all_users();

  delete $members{"root login"};

  map { $_->{templates} =~ s|.*/||; } values %members;

  $form->{title}   = "Lx-Office ERP " . $locale->text('Administration');
  $form->{LOCKED}  = -e "$userspath/nologin";
  $form->{MEMBERS} = [ @members{sort { lc $a cmp lc $b } keys %members} ];

  $form->header();
  print $form->parse_html_template("admin/list_users");
}

sub add_user {

  $form->{title} =
      "Lx-Office ERP "
    . $locale->text('Administration') . " / "
    . $locale->text('Add User');

  my $myconfig = {
    "vclimit"      => 200,
    "countrycode"  => "de",
    "numberformat" => "1.000,00",
    "dateformat"   => "dd.mm.yy",
    "stylesheet"   => "lx-office-erp.css",
    "menustyle"    => "v3",
  };

  edit_user_form($myconfig);
}

sub edit_user {

  $form->{title} =
      "Lx-Office ERP "
    . $locale->text('Administration') . " / "
    . $locale->text('Edit User');
  $form->{edit} = 1;

  $form->isblank("login", $locale->text("The login is missing."));

  # get user
  my $myconfig = new User($form->{login});

  # strip basedir from templates directory
  $myconfig->{templates} =~ s|.*/||;

  edit_user_form($myconfig);
}

sub edit_user_form {
  my ($myconfig) = @_;

  my @valid_dateformats = qw(mm-dd-yy mm/dd/yy dd-mm-yy dd/mm/yy dd.mm.yy yyyy-mm-dd);
  $form->{ALL_DATEFORMATS} = [ map { { "format" => $_, "selected" => $_ eq $myconfig->{dateformat} } } @valid_dateformats ];

  my @valid_numberformats = qw(1,000.00 1000.00 1.000,00 1000,00);
  $form->{ALL_NUMBERFORMATS} = [ map { { "format" => $_, "selected" => $_ eq $myconfig->{numberformat} } } @valid_numberformats ];

  %countrycodes = User->country_codes;
  $form->{ALL_COUNTRYCODES} = [];
  foreach $countrycode (sort { $countrycodes{$a} cmp $countrycodes{$b} } keys %countrycodes) {
    push @{ $form->{ALL_COUNTRYCODES} }, { "value"    => $countrycode,
                                           "name"     => $countrycodes{$countrycode},
                                           "selected" => $countrycode eq $myconfig->{countrycode} };
  }

  # is there a templates basedir
  if (!-d "$templates") {
    $form->error(sprintf($locale->text("The directory %s does not exist."), $templates));
  }

  opendir TEMPLATEDIR, "$templates/." or $form->error("$templates : $ERRNO");
  my @all     = readdir(TEMPLATEDIR);
  my @alldir  = sort grep { -d "$templates/$_" && !/^\.\.?$/ } @all;
  my @allhtml = sort grep { -f "$templates/$_" && /\.html$/ } @all;
  closedir TEMPLATEDIR;

  @alldir = grep !/\.(html|tex|sty|odt|xml|txb)$/, @alldir;
  @alldir = grep !/^(webpages|\.svn)$/, @alldir;

  @allhtml = reverse grep !/Default/, @allhtml;
  push @allhtml, 'Default';
  @allhtml = reverse @allhtml;

  $form->{ALL_TEMPLATES} = [ map { { "name", => $_, "selected" => $_ eq $myconfig->{templates} } } @alldir ];

  $lastitem = $allhtml[0];
  $lastitem =~ s/-.*//g;
  $form->{ALL_MASTER_TEMPLATES} = [ { "name" => $lastitem, "selected" => $lastitem eq "German" } ];
  foreach $item (@allhtml) {
    $item =~ s/-.*//g;
    next if ($item eq $lastitem);

    push @{ $form->{ALL_MASTER_TEMPLATES} }, { "name" => $item, "selected" => $item eq "German" };
    $lastitem = $item;
  }

  # css dir has styles that are not intended as general layouts.
  # reverting to hardcoded list
  $form->{ALL_STYLESHEETS} = [ map { { "name" => $_, "selected" => $_ eq $myconfig->{stylesheet} } } qw(lx-office-erp.css Win2000.css) ];

  $form->{"menustyle_" . $myconfig->{menustyle} } = 1;

  map { $form->{"myc_${_}"} = $myconfig->{$_} } keys %{ $myconfig };

  my $groups = [];

  if ($form->{edit}) {
    my $user_id    = $auth->get_user_id($form->{login});
    my $all_groups = $auth->read_groups();

    foreach my $group (values %{ $all_groups }) {
      push @{ $groups }, $group if (grep { $user_id == $_ } @{ $group->{members} });
    }

    $groups = [ sort { lc $a->{name} cmp lc $b->{name} } @{ $groups } ];
  }

  $form->{CAN_CHANGE_PASSWORD} = $auth->can_change_password();

  $form->header();
  print $form->parse_html_template("admin/edit_user", { 'GROUPS' => $groups });
}

sub save_user {
  $form->{dbdriver} = 'Pg';

  # no spaces allowed in login name
  $form->{login} =~ s|\s||g;
  $form->isblank("login", $locale->text('Login name missing!'));

  # check for duplicates
  if (!$form->{edit}) {
    my %members = $auth->read_all_users();

    if ($members{$form->{login}}) {
      $form->error("$form->{login} " . $locale->text('is already a member!'));
    }
  }

  # no spaces allowed in directories
  ($form->{newtemplates}) = split / /, $form->{newtemplates};

  if ($form->{newtemplates}) {
    $form->{templates} = $form->{newtemplates};
  } else {
    $form->{templates} =
      ($form->{usetemplates}) ? $form->{usetemplates} : $form->{login};
  }

  # is there a basedir
  if (!-d "$templates") {
    $form->error(sprintf($locale->text("The directory %s does not exist."), $templates));
  }

  # add base directory to $form->{templates}
  $form->{templates} =~ s|.*/||;
  $form->{templates} =  "$templates/$form->{templates}";

  $myconfig = new User($form->{login});

  $form->isblank("dbname", $locale->text('Dataset missing!'));
  $form->isblank("dbuser", $locale->text('Database User missing!'));

  foreach $item (keys %{$form}) {
    $myconfig->{$item} = $form->{$item};
  }

  delete $myconfig->{stylesheet};
  if ($form->{userstylesheet}) {
    $myconfig->{stylesheet} = $form->{userstylesheet};
  }

  $myconfig->save_member();

  if ($auth->can_change_password()
      && defined $form->{new_password}
      && ($form->{new_password} ne '********')) {
    $auth->change_password($form->{login}, $form->{new_password});
  }

  if ($webdav) {
    @webdavdirs =
      qw(angebote bestellungen rechnungen anfragen lieferantenbestellungen einkaufsrechnungen);
    foreach $directory (@webdavdirs) {
      $file = "webdav/" . $directory . "/webdav-user";
      if ($form->{$directory}) {
        if (open(HTACCESS, "$file")) {
          while (<HTACCESS>) {
            ($login, $password) = split(/:/, $_);
            if ($login ne $form->{login}) {
              $newfile .= $_;
            }
          }
          close(HTACCESS);
        }
        open(HTACCESS, "> $file") or die "cannot open $file $ERRNO\n";
        $newfile .= $myconfig->{login} . ":" . $myconfig->{password} . "\n";
        print(HTACCESS $newfile);
        close(HTACCESS);
      } else {
        $form->{$directory} = 0;
        if (open(HTACCESS, "$file")) {
          while (<HTACCESS>) {
            ($login, $password) = split(/:/, $_);
            if ($login ne $form->{login}) {
              $newfile .= $_;
            }
          }
          close(HTACCESS);
        }
        open(HTACCESS, "> $file") or die "cannot open $file $ERRNO\n";
        print(HTACCESS $newfile);
        close(HTACCESS);
      }
    }
  }

  $form->{templates}       =~ s|.*/||;
  $form->{templates}       =  "${templates}/$form->{templates}";
  $form->{mastertemplates} =~ s|.*/||;

  # create user template directory and copy master files
  if (!-d "$form->{templates}") {
    umask(002);

    if (mkdir "$form->{templates}", oct("771")) {

      umask(007);

      # copy templates to the directory
      opendir TEMPLATEDIR, "$templates/." or $form - error("$templates : $ERRNO");
      @templates = grep /$form->{mastertemplates}.*?\.(html|tex|sty|xml|txb)$/,
        readdir TEMPLATEDIR;
      closedir TEMPLATEDIR;

      foreach $file (@templates) {
        open(TEMP, "$templates/$file")
          or $form->error("$templates/$file : $ERRNO");

        $file =~ s/\Q$form->{mastertemplates}\E-//;
        open(NEW, ">$form->{templates}/$file")
          or $form->error("$form->{templates}/$file : $ERRNO");

        while ($line = <TEMP>) {
          print NEW $line;
        }
        close(TEMP);
        close(NEW);
      }
    } else {
      $form->error("$ERRNO: $form->{templates}");
    }
  }

  $form->redirect($locale->text('User saved!'));

}

sub delete_user {
  my %members   = $auth->read_all_users();
  my $templates = $members{$form->{login}}->{templates};

  $auth->delete_user($form->{login});

  if ($templates) {
    my $templates_in_use = 0;

    foreach $login (keys %members) {
      next if $form->{login} eq $login;
      next if $members{$login}->{templates} ne $templates;
      $templates_in_use = 1;
      last;
    }

    if (!$templates_in_use && -d $templates) {
      unlink <$templates/*>;
      rmdir $templates;
    }
  }

  $form->redirect($locale->text('User deleted!'));

}

sub login_name {
  my $login = shift;

  $login =~ s/\[\]//g;
  return ($login) ? $login : undef;

}

sub get_value {
  my $line = shift;

  my ($null, $value) = split(/=/, $line, 2);

  # remove comments
  $value =~ s/\s#.*//g;

  # remove any trailing whitespace
  $value =~ s/^\s*(.*?)\s*$/$1/;

  $value;
}

sub pg_database_administration {

  $form->{dbdriver} = 'Pg';
  dbselect_source();

}

sub dbselect_source {
  $form->{dbport}    = '5432';
  $form->{dbuser}    = 'postgres';
  $form->{dbdefault} = 'template1';
  $form->{dbhost}    = 'localhost';

  $form->{title}     = "Lx-Office ERP / " . $locale->text('Database Administration');

  # Intentionnaly disabled unless fixed to work with the authentication DB.
  $form->{ALLOW_DBBACKUP} = 0; # "$pg_dump_exe" ne "DISABLED";

  $form->header();
  print $form->parse_html_template("admin/dbadmin");
}

sub continue {
  call_sub($form->{"nextsub"});
}

sub back {
  call_sub($form->{"back_nextsub"});
}

sub update_dataset {
  $form->{title} =
      "Lx-Office ERP "
    . $locale->text('Database Administration') . " / "
    . $locale->text('Update Dataset');

  my @need_updates      = User->dbneedsupdate($form);
  $form->{NEED_UPDATES} = \@need_updates;
  $form->{ALL_UPDATED}  = !scalar @need_updates;

  $form->header();
  print $form->parse_html_template("admin/update_dataset");
}

sub dbupdate {
  $form->{stylesheet} = "lx-office-erp.css";
  $form->{title}      = $locale->text("Dataset upgrade");
  $form->header();

  my $rowcount           = $form->{rowcount} * 1;
  my @update_rows        = grep { $form->{"update_$_"} } (1 .. $rowcount);
  $form->{NOTHING_TO_DO} = !scalar @update_rows;
  my $saved_form         = save_form();

  $| = 1;

  print $form->parse_html_template("admin/dbupgrade_all_header");

  foreach my $i (@update_rows) {
    restore_form($saved_form);

    map { $form->{$_} = $form->{"${_}_${i}"} } qw(dbname dbdriver dbhost dbport dbuser dbpasswd);

    my $controls = parse_dbupdate_controls($form, $form->{dbdriver});

    print $form->parse_html_template("admin/dbupgrade_header");

    $form->{dbupdate}        = $form->{dbname};
    $form->{$form->{dbname}} = 1;

    User->dbupdate($form);
    User->dbupdate2($form, $controls);

    print $form->parse_html_template("admin/dbupgrade_footer");
  }

  print $form->parse_html_template("admin/dbupgrade_all_done");
}

sub create_dataset {
  $form->{dbsources} = join " ", map { "[${_}]" } sort User->dbsources(\%$form);

  $form->{CHARTS} = [];

  opendir SQLDIR, "sql/." or $form - error($ERRNO);
  foreach $item (sort grep /-chart\.sql\z/, readdir SQLDIR) {
    next if ($item eq 'Default-chart.sql');
    $item =~ s/-chart\.sql//;
    push @{ $form->{CHARTS} }, { "name"     => $item,
                                 "selected" => $item eq "Germany-DATEV-SKR03EU" };
  }
  closedir SQLDIR;

  my $default_charset = $dbcharset;
  $default_charset ||= Common::DEFAULT_CHARSET;

  $form->{DBENCODINGS} = [];

  foreach my $encoding (@Common::db_encodings) {
    push @{ $form->{DBENCODINGS} }, { "dbencoding" => $encoding->{dbencoding},
                                      "label"      => $encoding->{label},
                                      "selected"   => $encoding->{charset} eq $default_charset };
  }

  $form->{title} =
      "Lx-Office ERP "
    . $locale->text('Database Administration') . " / "
    . $locale->text('Create Dataset');

  $form->header();
  print $form->parse_html_template("admin/create_dataset");
}

sub dbcreate {
  $form->isblank("db", $locale->text('Dataset missing!'));

  User->dbcreate(\%$form);

  $form->{title} =
      "Lx-Office ERP "
    . $locale->text('Database Administration') . " / "
    . $locale->text('Create Dataset');

  $form->header();
  print $form->parse_html_template("admin/dbcreate");
}

sub delete_dataset {
  @dbsources = User->dbsources_unused($form);
  $form->error($locale->text('Nothing to delete!')) unless @dbsources;

  $form->{title} =
      "Lx-Office ERP "
    . $locale->text('Database Administration') . " / "
    . $locale->text('Delete Dataset');
  $form->{DBSOURCES} = [ map { { "name", $_ } } sort @dbsources ];

  $form->header();
  print $form->parse_html_template("admin/delete_dataset");
}

sub dbdelete {

  if (!$form->{db}) {
    $form->error($locale->text('No Dataset selected!'));
  }

  User->dbdelete(\%$form);

  $form->{title} =
      "Lx-Office ERP "
    . $locale->text('Database Administration') . " / "
    . $locale->text('Delete Dataset');
  $form->header();
  print $form->parse_html_template("admin/dbdelete");
}

sub backup_dataset {
  $form->{title} =
      "Lx-Office ERP "
    . $locale->text('Database Administration') . " / "
    . $locale->text('Backup Dataset');

  if ("$pg_dump_exe" eq "DISABLED") {
    $form->error($locale->text('Database backups and restorations are disabled in lx-erp.conf.'));
  }

  my @dbsources         = sort User->dbsources($form);
  $form->{DATABASES}    = [ map { { "dbname" => $_ } } @dbsources ];
  $form->{NO_DATABASES} = !scalar @dbsources;

  my $username  = getpwuid $UID || "unknown-user";
  my $hostname  = hostname() || "unknown-host";
  $form->{from} = "Lx-Office Admin <${username}\@${hostname}>";

  $form->header();
  print $form->parse_html_template("admin/backup_dataset");
}

sub backup_dataset_start {
  $form->{title} =
      "Lx-Office ERP "
    . $locale->text('Database Administration') . " / "
    . $locale->text('Backup Dataset');

  $pg_dump_exe ||= "pg_dump";

  if ("$pg_dump_exe" eq "DISABLED") {
    $form->error($locale->text('Database backups and restorations are disabled in lx-erp.conf.'));
  }

  $form->isblank("dbname", $locale->text('The dataset name is missing.'));
  $form->isblank("to", $locale->text('The email address is missing.')) if $form->{destination} eq "email";

  my $tmpdir = "/tmp/lx_office_backup_" . Common->unique_id();
  mkdir $tmpdir, 0700 || $form->error($locale->text('A temporary directory could not be created:') . " $ERRNO");

  my $pgpass = IO::File->new("${tmpdir}/.pgpass", O_WRONLY | O_CREAT, 0600);

  if (!$pgpass) {
    unlink $tmpdir;
    $form->error($locale->text('A temporary file could not be created:') . " $ERRNO");
  }

  print $pgpass "$form->{dbhost}:$form->{dbport}:$form->{dbname}:$form->{dbuser}:$form->{dbpasswd}\n";
  $pgpass->close();

  $ENV{HOME} = $tmpdir;

  my @args = ("-Ft", "-c", "-o", "-h", $form->{dbhost}, "-U", $form->{dbuser});
  push @args, ("-p", $form->{dbport}) if ($form->{dbport});
  push @args, $form->{dbname};

  my $cmd  = "${pg_dump_exe} " . join(" ", map { s/\\/\\\\/g; s/\"/\\\"/g; $_ } @args);
  my $name = "dataset_backup_$form->{dbname}_" . strftime("%Y%m%d", localtime()) . ".tar";

  if ($form->{destination} ne "email") {
    my $in = IO::File->new("$cmd |");

    if (!$in) {
      unlink "${tmpdir}/.pgpass";
      rmdir $tmpdir;

      $form->error($locale->text('The pg_dump process could not be started.'));
    }

    print "content-type: application/x-tar\n";
    print "content-disposition: attachment; filename=\"${name}\"\n\n";

    while (my $line = <$in>) {
      print $line;
    }

    $in->close();

    unlink "${tmpdir}/.pgpass";
    rmdir $tmpdir;

  } else {
    my $tmp = $tmpdir . "/dump_" . Common::unique_id();

    if (system("$cmd > $tmp") != 0) {
      unlink "${tmpdir}/.pgpass", $tmp;
      rmdir $tmpdir;

      $form->error($locale->text('The pg_dump process could not be started.'));
    }

    my $mail = new Mailer;

    map { $mail->{$_} = $form->{$_} } qw(from to cc subject message);

    $mail->{charset}     = $dbcharset ? $dbcharset : Common::DEFAULT_CHARSET;
    $mail->{attachments} = [ { "filename" => $tmp, "name" => $name } ];
    $mail->send();

    unlink "${tmpdir}/.pgpass", $tmp;
    rmdir $tmpdir;

    $form->{title} =
        "Lx-Office ERP "
      . $locale->text('Database Administration') . " / "
      . $locale->text('Backup Dataset');

    $form->header();
    print $form->parse_html_template("admin/backup_dataset_email_done");
  }
}

sub restore_dataset {
  $form->{title} =
      "Lx-Office ERP "
    . $locale->text('Database Administration') . " / "
    . $locale->text('Restore Dataset');

  if ("$pg_restore_exe" eq "DISABLED") {
    $form->error($locale->text('Database backups and restorations are disabled in lx-erp.conf.'));
  }

  my $default_charset   = $dbcharset;
  $default_charset    ||= Common::DEFAULT_CHARSET;

  $form->{DBENCODINGS}  = [];

  foreach my $encoding (@Common::db_encodings) {
    push @{ $form->{DBENCODINGS} }, { "dbencoding" => $encoding->{dbencoding},
                                      "label"      => $encoding->{label},
                                      "selected"   => $encoding->{charset} eq $default_charset };
  }

  $form->header();
  print $form->parse_html_template("admin/restore_dataset");
}

sub restore_dataset_start {
  $form->{title} =
      "Lx-Office ERP "
    . $locale->text('Database Administration') . " / "
    . $locale->text('Restore Dataset');

  $pg_restore_exe ||= "pg_restore";

  if ("$pg_restore_exe" eq "DISABLED") {
    $form->error($locale->text('Database backups and restorations are disabled in lx-erp.conf.'));
  }

  $form->isblank("new_dbname", $locale->text('The dataset name is missing.'));
  $form->isblank("content", $locale->text('No backup file has been uploaded.'));

  # Create temporary directories. Write the backup file contents to a temporary
  # file. Create a .pgpass file with the username and password for the pg_restore
  # utility.

  my $tmpdir = "/tmp/lx_office_backup_" . Common->unique_id();
  mkdir $tmpdir, 0700 || $form->error($locale->text('A temporary directory could not be created:') . " $ERRNO");

  my $pgpass = IO::File->new("${tmpdir}/.pgpass", O_WRONLY | O_CREAT, 0600);

  if (!$pgpass) {
    unlink $tmpdir;
    $form->error($locale->text('A temporary file could not be created:') . " $ERRNO");
  }

  print $pgpass "$form->{dbhost}:$form->{dbport}:$form->{new_dbname}:$form->{dbuser}:$form->{dbpasswd}\n";
  $pgpass->close();

  $ENV{HOME} = $tmpdir;

  my $tmp = $tmpdir . "/dump_" . Common::unique_id();
  my $tmpfile;

  if (substr($form->{content}, 0, 2) eq "\037\213") {
    $tmpfile = IO::File->new("| gzip -d > $tmp");
    $tmpfile->binary();

  } else {
    $tmpfile = IO::File->new($tmp, O_WRONLY | O_CREAT | O_BINARY, 0600);
  }

  if (!$tmpfile) {
    unlink "${tmpdir}/.pgpass";
    rmdir $tmpdir;

    $form->error($locale->text('A temporary file could not be created:') . " $ERRNO");
  }

  print $tmpfile $form->{content};
  $tmpfile->close();

  delete $form->{content};

  # Try to connect to the database. Find out if a database with the same name exists.
  # If yes, then drop the existing database. Create a new one with the name and encoding
  # given by the user.

  User::dbconnect_vars($form, "template1");

  my %myconfig = map { $_ => $form->{$_} } grep /^db/, keys %{ $form };
  my $dbh      = $form->dbconnect(\%myconfig) || $form->dberror();

  my ($query, $sth);

  $form->{new_dbname} =~ s|[^a-zA-Z0-9_\-]||g;

  $query = qq|SELECT COUNT(*) FROM pg_database WHERE datname = ?|;
  my ($count) = selectrow_query($form, $dbh, $query, $form->{new_dbname});
  if ($count) {
    do_query($form, $dbh, qq|DROP DATABASE $form->{new_dbname}|);
  }

  my $found = 0;
  foreach my $item (@Common::db_encodings) {
    if ($item->{dbencoding} eq $form->{dbencoding}) {
      $found = 1;
      last;
    }
  }
  $form->{dbencoding} = "LATIN9" unless $form->{dbencoding};

  do_query($form, $dbh, qq|CREATE DATABASE $form->{new_dbname} ENCODING ? TEMPLATE template0|, $form->{dbencoding});

  $dbh->disconnect();

  # Spawn pg_restore on the temporary file.

  my @args = ("-h", $form->{dbhost}, "-U", $form->{dbuser}, "-d", $form->{new_dbname});
  push @args, ("-p", $form->{dbport}) if ($form->{dbport});
  push @args, $tmp;

  my $cmd = "${pg_restore_exe} " . join(" ", map { s/\\/\\\\/g; s/\"/\\\"/g; $_ } @args);

  my $in = IO::File->new("$cmd 2>&1 |");

  if (!$in) {
    unlink "${tmpdir}/.pgpass", $tmp;
    rmdir $tmpdir;

    $form->error($locale->text('The pg_restore process could not be started.'));
  }

  $AUTOFLUSH = 1;

  $form->header();
  print $form->parse_html_template("admin/restore_dataset_start_header");

  while (my $line = <$in>) {
    print $line;
  }
  $in->close();

  $form->{retval} = $CHILD_ERROR >> 8;
  print $form->parse_html_template("admin/restore_dataset_start_footer");

  unlink "${tmpdir}/.pgpass", $tmp;
  rmdir $tmpdir;
}

sub unlock_system {

  unlink "$userspath/nologin";

  $form->{callback} = "admin.pl?action=list_users";

  $form->redirect($locale->text('Lockfile removed!'));

}

sub lock_system {

  open(FH, ">$userspath/nologin")
    or $form->error($locale->text('Cannot create Lock!'));
  close(FH);

  $form->{callback} = "admin.pl?action=list_users";

  $form->redirect($locale->text('Lockfile created!'));

}

sub yes {
  call_sub($form->{yes_nextsub});
}

sub no {
  call_sub($form->{no_nextsub});
}

sub add {
  call_sub($form->{add_nextsub});
}

sub edit {
  $form->{edit_nextsub} ||= 'edit_user';

  call_sub($form->{edit_nextsub});
}

sub delete {
  $form->{delete_nextsub} ||= 'delete_user';

  call_sub($form->{delete_nextsub});
}

sub save {
  $form->{save_nextsub} ||= 'save_user';

  call_sub($form->{save_nextsub});
}

sub back {
  call_sub($form->{back_nextsub});
}

sub dispatcher {
  foreach my $action (qw(create_standard_group dont_create_standard_group)) {
    if ($form->{"action_${action}"}) {
      call_sub($action);
      return;
    }
  }

  call_sub($form->{default_action}) if ($form->{default_action});

  $form->error($locale->text('No action defined.'));
}

1;
