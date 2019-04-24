#!/usr/bin/env perl

use strict;
use warnings;
use File::Temp qw/ tempfile tempdir /;
use File::Spec::Functions qw/ file_name_is_absolute splitpath catdir catfile /;
use File::Path 'make_path';
use IPC::Run3;
use JSON;
use Test::More;
use Test::Differences;

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

sub write_file {
    my($name, $data) = @_;
    my $fh;
    open($fh, '>', $name) or die "Can't open $name: $!\n";
    print($fh $data) or die "$!\n";
    close($fh);
}

sub prepare_dir {
    my($dir, $input) = @_;

    # Prepare files in input directory.
    # $input consists of one or more blocks.
    # Each block is preceeded by a single
    # starting with one or more of dashes followed by a filename.
    my $delim  = qr/^-+[ ]*(\S+)[ ]*\n/m;
    my @input = split($delim, $input);
    my $first = shift @input;

    # Input does't start with filename.
    # No further delimiters are allowed.
    if ($first) {
        BAIL_OUT("Missing filename before first input block");
        return;
    }
    while (@input) {
        my $path = shift @input;
        my $data = shift @input;
        if (file_name_is_absolute $path) {
            BAIL_OUT("Unexpected absolute path '$path'");
            return;
        }
        my (undef, $dir_part, $file) = splitpath($path);
        my $full_dir = catdir($dir, $dir_part);
        make_path($full_dir);
        my $full_path = catfile($full_dir, $file);
        write_file($full_path, $data);
    }
}

sub run {
    my ($cmd) = @_;

    my $stderr;
    run3($cmd, \undef, undef, \$stderr);

    # Child was stopped by signal.
    die if $? & 127;

    my $status = $? >> 8;
    my $success = $status == 0;
    return($success, $stderr);
}

sub test_worker {
    my ($in, $job, $other) = @_;

    # Initialize empty CVS repository.
    my $cvs_root = tempdir(CLEANUP => 1);
    $ENV{CVSROOT} = $cvs_root;
    system "cvs init";

    # Create working directory, set as home directory and as current directory.
    my $home_dir = tempdir(CLEANUP => 1);
    $ENV{HOME} = $home_dir;
    chdir $home_dir;

    # Make worker scripts available.
    symlink("$API_DIR/bin", 'bin');

    # Create initial netspoc files and put them under CVS control.
    mkdir("import");
    prepare_dir("import", $in);
    chdir 'import';
    system 'cvs -q import -m start netspoc vendor version >/dev/null 2>&1';
    chdir $home_dir;
    system "rm -r import";
    system "cvs -q checkout netspoc >/dev/null";

    # Create config file .netspoc-approve for newpolicy
    mkdir("policydb");
    mkdir("lock");
    write_file('.netspoc-approve', <<"END");
netspocdir = $home_dir/policydb
lockfiledir = $home_dir/lock
END

    # Create files for Netspoc-Approve and create compile.log file.
    system "newpolicy.pl >/dev/null 2>&1";

    write_file('job', encode_json($job));

    # Checkout files from CVS, apply changes and run Netspoc.
    my ($success, $stderr) = run("bin/cvs-worker1 job");

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
    my $diff = `cvs -q diff -u netspoc`;
    $diff =~ s/^={67}\nRCS .*\nretrieving .*\ndiff .*\n--- .*\n\+\+\+ .*\n//mg;

    # Combine warnings and diff into one message, separated by "---".
    if (not $success) {
        $stderr .= "---\n" . $diff;
        return ($success, $stderr);
    }

    # Simulate changes by other user.
    if ($other) {
        system "cvs -q checkout -d other netspoc >/dev/null 2>&1";
        prepare_dir("other", $other);
        system "cvs -q commit -m other other >/dev/null 2>&1"
    }

    # Try to check in changes.
    ($success, $stderr) = run("bin/cvs-worker2 job");

    if ($success) {
        return ($success, $diff);
    }
    else {
        return ($success, $stderr);
    }
}

sub test_run {
    my ($title, $in, $job, $expected, $other) = @_;
    my($success, $result) = test_worker($in, $job, $other);
    if (!$success) {
        diag("Unexpected failure:\n$result");
        fail($title);
        return;
    }
    eq_or_diff($result, $expected, $title);
}

sub test_err {
    my ($title, $in, $job, $expected, $other) = @_;
    my ($success, $stderr) = test_worker($in, $job, $other);
    if ($success) {
        diag("Unexpected success");
        diag($stderr) if $stderr;
        fail($title);
        return;
    }
    eq_or_diff($stderr, $expected, $title);
}

my ($title, $in, $job, $out, $other);

############################################################
$title = 'Add host to known network';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24; } # Comment
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
Index: netspoc/topology
@@ -1 +1,3 @@
-network:a = { ip = 10.1.1.0/24; } # Comment
+network:a = { ip = 10.1.1.0/24; # Comment
+ host:name_10_1_1_4			= { ip = 10.1.1.4; }
+}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host, same name';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24;
 host:name_10_1_1_4 = { ip = 10.1.1.4; }
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
Error: Duplicate definition of host:name_10_1_1_4
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, same IP';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24;
 host:other_10_1_1_4 = { ip = 10.1.1.4; }
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
Error: Duplicate IP for host:name_10_1_1_4 and host:other_10_1_1_4
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, same IP unsorted';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24;
 host:name_10_1_1_4 = { ip = 10.1.1.4; }
 host:name_10_1_1_3 = { ip = 10.1.1.3; }
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
Netspoc failed:
Error: Duplicate definition of host:name_10_1_1_4 in netspoc/topology
Error: Duplicate IP address for host:name_10_1_1_4 and host:name_10_1_1_4
Aborted with 2 error(s)
---
Index: netspoc/topology
@@ -1,4 +1,5 @@
 network:a = { ip = 10.1.1.0/24;
  host:name_10_1_1_4 = { ip = 10.1.1.4; }
  host:name_10_1_1_3 = { ip = 10.1.1.3; }
+ host:name_10_1_1_4			= { ip = 10.1.1.4; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Multiple networks at one line';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24; } network:b = { ip = 10.1.2.0/24; } # Comment
router:r1 = {
 interface:a;
 interface:b;
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
Netspoc failed:
Error: IP of host:name_10_1_1_4 doesn't match IP/mask of network:b
Aborted with 1 error(s)
---
Index: netspoc/topology
@@ -1,4 +1,6 @@
-network:a = { ip = 10.1.1.0/24; } network:b = { ip = 10.1.2.0/24; } # Comment
+network:a = { ip = 10.1.1.0/24; } network:b = { ip = 10.1.2.0/24; # Comment
+ host:name_10_1_1_4			= { ip = 10.1.1.4; }
+}
 router:r1 = {
  interface:a;
  interface:b;
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host with owner';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = { admins = abc@example.com; }
network:a = { ip = 10.1.0.0/21; }
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        owner   => 'DA_abc',
    }
};

$out = <<'END';
Index: netspoc/topology
@@ -1,2 +1,4 @@
 owner:DA_abc = { admins = abc@example.com; }
-network:a = { ip = 10.1.0.0/21; }
+network:a = { ip = 10.1.0.0/21;
+ host:name_10_1_1_4			= { ip = 10.1.1.4; owner = DA_abc; }
+}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host, redundant owner';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = { admins = abc@example.com; }
network:a = { ip = 10.1.0.0/21; owner = DA_abc; }
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        owner   => 'DA_abc',
    }
};

$out = <<'END';
Netspoc warnings:
Warning: Useless owner:DA_abc at host:name_10_1_1_4,
 it was already inherited from network:a
---
Index: netspoc/topology
@@ -1,2 +1,4 @@
 owner:DA_abc = { admins = abc@example.com; }
-network:a = { ip = 10.1.0.0/21; owner = DA_abc; }
+network:a = { ip = 10.1.0.0/21; owner = DA_abc;
+ host:name_10_1_1_4			= { ip = 10.1.1.4; owner = DA_abc; }
+}
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, with warning from previous checkin';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = { admins = abc@example.com; }
network:a = { ip = 10.1.0.0/21; owner = DA_abc;
 host:name_10_1_1_4			= { ip = 10.1.1.4; owner = DA_abc; }
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_3',
        ip      => '10.1.1.3',
    }
};

$out = <<'END';
Index: netspoc/topology
@@ -1,4 +1,5 @@
 owner:DA_abc = { admins = abc@example.com; }
 network:a = { ip = 10.1.0.0/21; owner = DA_abc;
+ host:name_10_1_1_3			= { ip = 10.1.1.3; }
  host:name_10_1_1_4			= { ip = 10.1.1.4; owner = DA_abc; }
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host, with old and new warning';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = { admins = abc@example.com; }
network:a = { ip = 10.1.0.0/21; owner = DA_abc;
 host:name_10_1_1_4			= { ip = 10.1.1.4; owner = DA_abc; }
}
END

$job = {
    method => 'CreateHost',
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
 it was already inherited from network:a
Warning: Useless owner:DA_abc at host:name_10_1_1_4,
 it was already inherited from network:a
---
Index: netspoc/topology
@@ -1,4 +1,5 @@
 owner:DA_abc = { admins = abc@example.com; }
 network:a = { ip = 10.1.0.0/21; owner = DA_abc;
+ host:name_10_1_1_3			= { ip = 10.1.1.3; owner = DA_abc; }
  host:name_10_1_1_4			= { ip = 10.1.1.4; owner = DA_abc; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, unknown owner';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.0.0/21; }
END

$job = {
    method => 'CreateHost',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        owner   => 'DA_abc',
    }
};

$out = <<'END';
Netspoc failed:
Error: Can't resolve reference to 'DA_abc' in attribute 'owner' of host:name_10_1_1_4
Aborted with 1 error(s)
---
Index: netspoc/topology
@@ -1 +1,3 @@
-network:a = { ip = 10.1.0.0/21; }
+network:a = { ip = 10.1.0.0/21;
+ host:name_10_1_1_4			= { ip = 10.1.1.4; owner = DA_abc; }
+}
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host [auto]';
############################################################

$in = <<'END';
-- topology
#network:c
# ip = 10.1.0.0/21;
network:a = {
 # Comment
#network:b
 ip = 10.1.0.0/21;
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Index: netspoc/topology
@@ -4,4 +4,5 @@
  # Comment
 #network:b
  ip = 10.1.0.0/21;
+ host:name_10_1_1_4			= { ip = 10.1.1.4; }
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host, can\'t find [auto] network';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.0.0/24; }
END

$job = {
    method => 'CreateHost',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Error: Can't find network with 'ip = 10.1.0.0/21' in netspoc/
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, can\'t find network for found [auto] IP';
############################################################

$in = <<'END';
-- topology
network:a = {
#
 ip = 10.1.0.0/21; }
END

my $many_comments = "#\n" x 50;
$in =~ s/#/$many_comments/;

$job = {
    method => 'CreateHost',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Error: Can't find network definition for 'ip = 10.1.0.0/21' in netspoc/topology
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, multiple [auto] networks in one file';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.0.0/21; nat:a = { hidden; } }
network:b = { ip = 10.1.0.0/21; nat:b = { hidden; } }

router:r1 = {
 interface:a = { bind_nat = b; }
 interface:b = { bind_nat = a; }
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Error: Found multiple networks with 'ip = 10.1.0.0/21' in netspoc/topology: network:a network:b
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, multiple [auto] networks in multiple files';
############################################################

$in = <<'END';
-- topo1
network:a = { ip = 10.1.0.0/21; nat:a = { hidden; } }
-- topo2
network:b = { ip = 10.1.0.0/21; nat:b = { hidden; } }
-- topo3
network:c = { ip = 10.1.0.0/21; nat:c = { hidden; } }

router:r1 = {
 interface:a = { bind_nat = b, c; }
 interface:b = { bind_nat = a, c; }
 interface:c = { bind_nat = a, b; }
}
END

$job = {
    method => 'CreateHost',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Error: Found multiple occurrences of 'ip = 10.1.0.0/21' in: netspoc/topo3 netspoc/topo1 netspoc/topo2
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
    method => 'CreateHost',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Index: netspoc/topology
@@ -1,2 +1,4 @@
-network:a = { ip = 10.1.0.0/21; }
+network:a = { ip = 10.1.0.0/21;
+ host:name_10_1_1_4			= { ip = 10.1.1.4; }
+}
 #
END

test_run($title, $in, $job, $out, $other);

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
    method => 'CreateHost',
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

test_err($title, $in, $job, $out, $other);

############################################################
done_testing;
