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
    my @job_files;
    for my $j (@$job) {
        write_file($i, encode_json($j));
        push @job_files, $i;
        $i++;
    }

    my $verbose = $named{verbose} ? "-v" : "";
    # Checkout files from Git, apply changes and run Netspoc.
    my ($success, $stderr) = run("bin/cvs-worker1 $verbose @job_files");

    if (not $success and not $stderr) {
        return ($success, $stderr);
    }
    $stderr =~ s/\Q$home_dir\E/~/g;

    # Collect and simplify diff before check in.
    # Show diff even if Netspoc failed.
    #diff -x .git -ruN orig/netspoc/rule/S netspoc/rule/S
    #--- orig/netspoc/rule/S 1970-01-01 01:00:00.000000000 +0100
    #+++ netspoc/rule/S      2022-08-19 14:46:29.026666333 +0200
    #@@ -0,0 +1,6 @@
    my $diff = `diff -x .git -ruN orig/netspoc netspoc/`;
    $diff =~ s/^\+\+\+ (.*?)\t.*/$1/mg;
    $diff =~ s/^diff -x .*\n//mg;
    $diff =~ s/^--- .*\n//mg;
    $diff =~ s/^ $//m;

    # Combine warnings and diff into one message, separated by "---".
    if (not $success) {
        $stderr .= "---\n$diff";
        return ($success, $stderr);
    }

    # Simulate changes by other user.
    if (my $other = $named{other}) {
        system "git clone --quiet --depth 1 $ENV{NETSPOC_GIT} other";
        prepare_dir('other', $other);
        system 'cd other; git add --all; git commit -q -m other; git push -q';
    }

    # Try to check in changes.
    ($success, $stderr) = run("bin/cvs-worker2 $verbose [0-9]*");
    if (!$success) {
        $stderr =~ s/( not apply )[0-9a-f]{7}[.]{3}/$1COMMIT.../g;
        $diff = $stderr;
    }

    if (my $file = $named{cvs_log}) {
        my $log = `cd netspoc; git log -1 --format=format:%B $file`;
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
$title = 'Add service to new file';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = IOS;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
END

$job = {
    method => 'add',
    params => {
        path => 'service:s1',
        value => {
            user => "network:n1",
            rules => [
                {
                    action => 'permit',
                    src => 'user',
                    dst => 'network:n2',
                    prt => 'tcp 80'
                }]
        }
    }
};

$out = <<'END';
netspoc/rule/S
@@ -0,0 +1,6 @@
+service:s1 = {
+ user = network:n1;
+ permit src = user;
+        dst = network:n2;
+        prt = tcp 80;
+}
END

test_run($title, $in, $job, $out, verbose => 1);

############################################################
$title = 'Add host, ignore warning from previous checkin';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = { admins = abc@example.com; }
network:a = { ip = 10.1.0.0/21; owner = DA_abc;
 host:name_10_1_1_4 = { ip = 10.1.1.4; owner = DA_abc; }
}
-- empty
# comment
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
Checking out files to ~/netspoc
Applying changes and compiling files
Checking original files for errors or warnings
Netspoc shows warnings:
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

test_err($title, $in, $job, $out, verbose => 1);

############################################################
$title = 'Add host, Netspoc failure';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.0.0/21; host:name_10_1_1_4 = { ip = 10.1.1.4; } }
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
Netspoc shows errors:
Error: Duplicate definition of host:name_10_1_1_4 in netspoc/topology
Aborted with 1 error(s)
---
netspoc/topology
@@ -1 +1,5 @@
-network:a = { ip = 10.1.0.0/21; host:name_10_1_1_4 = { ip = 10.1.1.4; } }
+network:a = {
+ ip = 10.1.0.0/21;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
+}
END

test_err($title, $in, $job, $out, other => $other);

############################################################
$title = 'Add host, API failure';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.2.0.0/21; }
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
Can't modify Netspoc files:
Error: Can't find network with 'ip = 10.1.0.0/21'
---
END

test_err($title, $in, $job, $out, other => $other);

############################################################
$title = 'Add host, need git pull';
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
Error during git pull:
error: could not apply COMMIT... API job: 1
hint: Resolve all conflicts manually, mark them as resolved with
hint: "git add/rm <conflicted_files>", then run "git rebase --continue".
hint: You can instead skip this commit: run "git rebase --skip".
hint: To abort and get back to the state before "git rebase", run "git rebase --abort".
Could not apply COMMIT... API job: 1
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
API jobs: 4 3 2 1
CRQ00001236 CRQ00001237
END

test_run($title, $in, $job, $out, cvs_log => 'owner');

############################################################
done_testing;
