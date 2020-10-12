#!/usr/bin/env perl

use strict;
use warnings;
use File::Temp qw/ tempdir /;
use JSON;
use Test::More;
use Test::Differences;
use lib 't';
use Test_API qw(write_file prepare_dir setup_netspoc run);

# Set up PATH and PERL5LIB, such that files and libraries are searched
# in $HOME/Netspoc, $HOME/Netspoc-Approve
my $NETSPOC_DIR = "$ENV{HOME}/Netspoc";
my $APPROVE_DIR = "$ENV{HOME}/Netspoc-Approve";
$ENV{PATH} = "$NETSPOC_DIR/bin:$APPROVE_DIR/bin:$ENV{PATH}";
{
    my $lib = "$NETSPOC_DIR/lib:$APPROVE_DIR/lib";
    if (my $old = $ENV{PERL5LIB}) {
        $lib .= ":$old";
    }
    $ENV{PERL5LIB} = $lib;
}

my $API_DIR = "$ENV{HOME}/Netspoc-API";

sub test_worker {
    my ($in, $job, %named) = @_;

    # Create working directory, set as home directory and as current directory.
    my $home_dir = tempdir(CLEANUP => 1);
    $ENV{HOME} = $home_dir;
    chdir $home_dir;

    # Make worker scripts available.
    symlink("$API_DIR/backend", 'bin');

    setup_netspoc($home_dir, $in);

    ref $job eq 'ARRAY' or $job = [$job];
    my $i = 1;
    for my $j (@$job) {
        write_file($i, encode_json($j));
        $i++;
    }

    # Checkout files from CVS, apply changes and run Netspoc.
    my ($success, $stderr) = run('bin/cvs-worker1 [0-9]*');

    if (not $success and (not $stderr or $stderr !~ /^Netspoc/)) {
        return ($success, $stderr);
    }

    # Collect and simplify diff before check in.
    # Show diff even if Netspoc failed.
    #Index: netspoc/owner
    #===================================================================
    #RCS file: /home/diamonds/cvsroot/netspoc/owner,v
    #retrieving revision 1.1468
    #diff -u -u -r1.1468 owner
    #--- netspoc/owner       15 Apr 2019 07:56:13 -0000      1.1468
    #+++ netspoc/owner       15 Apr 2019 13:27:38 -0000
    #@@ -5,7 +5,7 @@
    my $diff = `cvs -Q diff -u netspoc`;
    $diff =~ s/^Index: //mg;
    $diff =~ s/^={67}\nRCS .*\nretrieving .*\ndiff .*\n--- .*\n\+\+\+ .*\n//mg;
    $diff =~ s/^ $//m;

    # Combine warnings and diff into one message, separated by "---".
    if (not $success) {
        $stderr .= "---\n$diff";
        return ($success, $stderr);
    }

    # Simulate changes by other user.
    if (my $other = $named{other}) {
        system 'cvs -Q checkout -d other netspoc';
        prepare_dir('other', $other);
        system 'cvs -Q commit -m other other';
    }

    # Try to check in changes.
    ($success, $stderr) = run('bin/cvs-worker2 [0-9]*');
    $success or $diff = $stderr;

    if (my $file = $named{cvs_log}) {
        my $log =
            `cvs -q log netspoc/$file|tail -n +15|egrep -v '^date'|head -n -8`;
        $diff .= "---\n$log";
    }
    return ($success, $diff);
}

sub test_run {
    my ($title, $in, $job, $expected, %named) = @_;
    my($success, $result) = test_worker($in, $job, %named);
    if (!$success) {
        diag("Unexpected failure:\n$result");
        fail($title);
        return;
    }
    eq_or_diff($result, $expected, $title);
}

sub test_err {
    my ($title, $in, $job, $expected, %named) = @_;
    my ($success, $stderr) = test_worker($in, $job, %named);
    if ($success) {
        diag('Unexpected success');
        diag($stderr) if $stderr;
        fail($title);
        return;
    }
    eq_or_diff($stderr, $expected, $title);
}

my ($title, $in, $job, $out, $other);

############################################################
$title = 'Add host, ignore warning from previous checkin';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = { admins = abc@example.com; }
network:a = { ip = 10.1.0.0/21; owner = DA_abc;
 host:name_10_1_1_4 = { ip = 10.1.1.4; owner = DA_abc; }
}
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_3',
        ip      => '10.1.1.3',
    }
};

$out = <<'END';
netspoc/topology
@@ -1,4 +1,10 @@
-owner:DA_abc = { admins = abc@example.com; }
-network:a = { ip = 10.1.0.0/21; owner = DA_abc;
+owner:DA_abc = {
+ admins = abc@example.com;
+}
+
+network:a = {
+ ip = 10.1.0.0/21;
+ owner = DA_abc;
+ host:name_10_1_1_3 = { ip = 10.1.1.3; }
  host:name_10_1_1_4 = { ip = 10.1.1.4; owner = DA_abc; }
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host, with old warning and new warning';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = {
 admins = abc@example.com;
}

any:a = {
 link = network:a;
 owner = DA_abc;
}

network:a = {
 ip = 10.1.0.0/21;
 host:name_10_1_1_4 = { ip = 10.1.1.4; owner = DA_abc; }
}
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_3',
        ip      => '10.1.1.3',
        owner   => 'DA_abc',
    }
};

$out = <<'END';
Netspoc warnings:
Warning: Useless owner:DA_abc at host:name_10_1_1_3,
 it was already inherited from any:a
Warning: Useless owner:DA_abc at host:name_10_1_1_4,
 it was already inherited from any:a
---
netspoc/topology
@@ -9,5 +9,6 @@

 network:a = {
  ip = 10.1.0.0/21;
+ host:name_10_1_1_3 = { ip = 10.1.1.3; owner = DA_abc; }
  host:name_10_1_1_4 = { ip = 10.1.1.4; owner = DA_abc; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, need cvs update';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.0.0/21; }
#
END

$other = <<'END';
-- topology
network:a = { ip = 10.1.0.0/21; }
#
network:b = { ip = 10.8.0.0/21; }
END

$job = {
    method => 'create_host',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
netspoc/topology
@@ -1,2 +1,5 @@
-network:a = { ip = 10.1.0.0/21; }
+network:a = {
+ ip = 10.1.0.0/21;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
+}
 #
END

test_run($title, $in, $job, $out, other => $other);

############################################################
$title = 'Add host, merge conflict';
############################################################

$in = <<'END';
-- topology
network:a = {
 ip = 10.1.0.0/21;
}
END

$other = <<'END';
-- topology
network:a = { ip = 10.1.0.0/21;
 host:name_10_1_1_5			= { ip = 10.1.1.5; }
}
END

$job = {
    method => 'create_host',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Merge conflict during cvs update:
rcsmerge: warning: conflicts during merge
cvs update: conflicts found in netspoc/topology
END

test_err($title, $in, $job, $out, other => $other);

############################################################
$title = 'multi_job: add host and owner';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
-- owner
# Add owners below.
END

$job = {
    method => 'multi_job',
    crq => 'CRQ00001234',
    params => {
        jobs => [
            {
                method => 'create_owner',
                params => {
                    name     => 'a',
                    admins   => [ 'a@example.com', 'b@example.com' ],
                    watchers => [ 'c@example.com', 'd@example.com' ],
                }
            },
            {
                method => 'create_host',
                params => {
                    network => 'n1',
                    name    => 'name_10_1_1_4',
                    ip      => '10.1.1.4',
                    owner   => 'a',
                }
            }
        ],
    }
};

$out = <<'END';
netspoc/owner
@@ -1 +1,9 @@
+owner:a = {
+ admins = a@example.com,
+          b@example.com,
+          ;
+ watchers = c@example.com,
+            d@example.com,
+            ;
+}
 # Add owners below.
netspoc/topology
@@ -1 +1,4 @@
-network:n1 = { ip = 10.1.1.0/24; }
+network:n1 = {
+ ip = 10.1.1.0/24;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; owner = a; }
+}
---
revision 1.2
API job: 1
CRQ00001234
END

test_run($title, $in, $job, $out, cvs_log => 'owner');

############################################################
$title = 'Process multiple jobs at once, handle CRQs';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
-- owner
# Add owners below.
END

$job =
    [
     {
         method => 'create_host',
         crq => 'CRQ00001236',
         params => {
             network => 'n1',
             name    => 'name_10_1_1_6',
             ip      => '10.1.1.6',
         },

     },
     {
         method => 'multi_job',
         crq => 'CRQ00001236',
         params => {
             jobs =>
                 [
                  {
                      method => 'create_owner',
                      params => {
                          name     => 'a',
                          admins   => [ 'a@example.com' ],
                      },
                  },
                  {
                      method => 'create_host',
                      params => {
                          network => 'n1',
                          name    => 'name_10_1_1_4',
                          ip      => '10.1.1.4',
                          owner   => 'a',
                      },
                  },
                 ],
         }
     },
     {
         method => 'create_host',
         # Without CRQ
         params => {
             network => 'n1',
             name    => 'name_10_1_1_5',
             ip      => '10.1.1.5',
         },

     },
     {
         method => 'create_host',
         params => {
             network => 'n1',
             name    => 'name_10_1_1_7',
             ip      => '10.1.1.7',
         },
         crq => 'CRQ00001237',

     }
    ];

$out = <<'END';
netspoc/owner
@@ -1 +1,4 @@
+owner:a = {
+ admins = a@example.com;
+}
 # Add owners below.
netspoc/topology
@@ -1 +1,7 @@
-network:n1 = { ip = 10.1.1.0/24; }
+network:n1 = {
+ ip = 10.1.1.0/24;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; owner = a; }
+ host:name_10_1_1_5 = { ip = 10.1.1.5; }
+ host:name_10_1_1_6 = { ip = 10.1.1.6; }
+ host:name_10_1_1_7 = { ip = 10.1.1.7; }
+}
---
revision 1.2
API jobs: 4 3 2 1
CRQ00001236 CRQ00001237
END

test_run($title, $in, $job, $out, cvs_log => 'owner');

############################################################
done_testing;
