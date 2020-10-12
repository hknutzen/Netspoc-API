#!/usr/bin/env perl

use strict;
use warnings;
use File::Temp qw/ tempdir /;
use JSON;
use Test::More;
use Test::Differences;
use lib 't';
use Test_API qw(write_file prepare_dir run);

# Set up PATH and PERL5LIB, such that files and libraries are searched
# in $HOME/Netspoc.
my $NETSPOC_DIR = "$ENV{HOME}/Netspoc";
$ENV{PATH} = "$NETSPOC_DIR/bin:$ENV{PATH}";
{
    my $lib = "$NETSPOC_DIR/lib";
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

    # Create initial netspoc files.
    mkdir('netspoc');
    prepare_dir('netspoc', $in);

    # Make copy for later diff.
    system "cp -r netspoc unchanged";

    write_file('job', encode_json($job));

    # Apply changes.
    my ($success, $stderr) = run('bin/worker job');
    if (not $success) {
        return ($success, $stderr);
    }

    # Run Netspoc.
    ($success, $stderr) = run('netspoc -q netspoc');

    # Handle warnings as errors.
    $success = 0 if $stderr;

    # Collect and simplify diff.
    # Show diff even if Netspoc failed.
    #--- unchanged/owner       15 Apr 2019 07:56:13 -0000
    #+++ netspoc/owner       15 Apr 2019 13:27:38 -0000
    #@@ -5,7 +5,7 @@
    #
    # Remove single space in empty line.
    my $diff = `diff -u -r unchanged netspoc | sed 's/^ \$//'`;
    $diff =~ s/^diff -u -r unchanged\/[^ ]* //mg;
    $diff =~ s/--- .*\n\+\+\+ .*\n//mg;

    # Combine messages from Netspoc and diff into one message,
    # separated by "---".
    if ($stderr) {
        $diff = "$stderr---\n$diff";
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

my ($title, $in, $job, $out);

############################################################
$title = 'Invalid empty job';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
END

$job = {};

$out = <<'END';
Error: Unknown method 'null'
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Invalid job without params';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
END

$job = {
    method => 'add_to_group',
};

$out = <<'END';
Error: Can't find 'group:' in netspoc
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add to multi block group (1)';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24;
 host:h_10_1_1_4 = { ip = 10.1.1.4; }
 host:h_10_1_1_5 = { ip = 10.1.1.5; }
 host:h_10_1_1_44 = { ip = 10.1.1.44; }
}
network:n2 = { ip = 10.1.2.0/24;
 host:h_10_1_2_5 = { ip = 10.1.2.5; }
 host:h_10_1_2_6 = { ip = 10.1.2.6; }
 host:h_10_1_2_7 = { ip = 10.1.2.7; }
 host:h_10_1_2_9 = { ip = 10.1.2.9; }
}
network:n3 = { ip = 10.1.3.0/24; }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
 interface:n3 = { ip = 10.1.3.1; hardware = n3; }
 interface:n4 = { ip = 10.1.4.1; hardware = n4; }
}

network:n4 = { ip = 10.1.4.0/24; }
-- group
group:g1 =
 host:h_10_1_1_4,
 host:h_10_1_1_44,
 network:n3,
 host:h_10_1_2_6,
 host:h_10_1_2_9,
;
-- service
service:s1 = {
 user = group:g1;
 permit src = user; dst = network:n4; prt = tcp 80;
}
END

$job = {
    method => 'add_to_group',
    params => {
        name   => 'g1',
        object => 'host:h_10_1_2_7',
    }
};

$out = <<'END';
netspoc/group
@@ -1,7 +1,8 @@
 group:g1 =
+ network:n3,
  host:h_10_1_1_4,
  host:h_10_1_1_44,
- network:n3,
  host:h_10_1_2_6,
+ host:h_10_1_2_7,
  host:h_10_1_2_9,
 ;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add to multi block group (2)';
############################################################

$job = {
    method => 'add_to_group',
    params => {
        name   => 'g1',
        object => 'host:h_10_1_2_5',
    }
};

$out = <<'END';
netspoc/group
@@ -1,7 +1,8 @@
 group:g1 =
+ network:n3,
  host:h_10_1_1_4,
  host:h_10_1_1_44,
- network:n3,
+ host:h_10_1_2_5,
  host:h_10_1_2_6,
  host:h_10_1_2_9,
 ;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add to multi block group (3)';
############################################################

$job = {
    method => 'add_to_group',
    params => {
        name   => 'g1',
        object => 'host:h_10_1_1_5',
    }
};

$out = <<'END';
netspoc/group
@@ -1,7 +1,8 @@
 group:g1 =
+ network:n3,
  host:h_10_1_1_4,
+ host:h_10_1_1_5,
  host:h_10_1_1_44,
- network:n3,
  host:h_10_1_2_6,
  host:h_10_1_2_9,
 ;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add name without IP to group';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
 interface:n3 = { ip = 10.1.3.1; hardware = n3; }
}

network:n3 = { ip = 10.1.3.0/24; }
-- group
group:g1 =
 interface:r1.n1,
 network:n1,
 interface:r1.n2,
;
-- service
service:s1 = {
 user = group:g1;
 permit src = user; dst = network:n3; prt = tcp 80;
}
END

$job = {
    method => 'add_to_group',
    params => {
        name   => 'g1',
        object => 'network:n2',
    }
};

$out = <<'END';
netspoc/group
@@ -1,5 +1,6 @@
 group:g1 =
- interface:r1.n1,
  network:n1,
+ network:n2,
+ interface:r1.n1,
  interface:r1.n2,
 ;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add before first element located on first line';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24;
 host:h_10_1_1_4 = { ip = 10.1.1.4; }
 host:h_10_1_1_5 = { ip = 10.1.1.5; }
}
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}
-- group
group:g1 = host:h_10_1_1_5; # Comment
-- service
service:s1 = {
 user = group:g1;
 permit src = user; dst = network:n2; prt = tcp 80;
}
END

$job = {
    method => 'add_to_group',
    params => {
        name   => 'g1',
        object => 'host:h_10_1_1_4',
    }
};

$out = <<'END';
netspoc/group
@@ -1 +1,4 @@
-group:g1 = host:h_10_1_1_5; # Comment
+group:g1 =
+ host:h_10_1_1_4,
+ host:h_10_1_1_5, # Comment
+;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Group having description ending with ";"';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
network:n2 = { ip = 10.1.2.0/24; }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
 interface:n3 = { ip = 10.1.3.1; hardware = n3; }
}

network:n3 = { ip = 10.1.3.0/24; }
-- group
group:g1 =
 description = Some text;
 network:n1,
;
-- service
service:s1 = {
 user = group:g1;
 permit src = user; dst = network:n3; prt = tcp 80;
}
END

$job = {
    method => 'add_to_group',
    params => {
        name   => 'g1',
        object => 'network:n2',
    }
};

$out = <<'END';
netspoc/group
@@ -1,4 +1,6 @@
 group:g1 =
  description = Some text;
+
  network:n1,
+ network:n2,
 ;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add to empty group';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; host:h4 = { ip = 10.1.1.4; } }

router:r1 = {
 managed;
 model = ASA;
 interface:n1 = { ip = 10.1.1.1; hardware = n1; }
 interface:n2 = { ip = 10.1.2.1; hardware = n2; }
}

network:n2 = { ip = 10.1.2.0/24; }
-- group
group:g1 = ; # IGNORED
-- service
service:s1 = {
 user = group:g1;
 permit src = user; dst = network:n2; prt = tcp 80;
}
END

$job = {
    method => 'add_to_group',
    params => {
        name   => 'g1',
        object => 'host:h4',
    }
};

$out = <<'END';
netspoc/group
@@ -1 +1,3 @@
-group:g1 = ; # IGNORED
+group:g1 =
+ host:h4,
+;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Added owner exists';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
-- owner
owner:a = {
 admins = a@example.com;
}
END

$job = {
    method => 'create_owner',
    params => {
        name    => 'a',
        admins  => [ 'a@example.com' ],
    }
};

$out = <<'END';
Error: Duplicate definition of owner:a in netspoc/owner
Aborted with 1 error(s)
---
netspoc/owner
@@ -1,3 +1,7 @@
 owner:a = {
  admins = a@example.com;
 }
+
+owner:a = {
+ admins = a@example.com;
+}
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Added owner exists, ok';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
-- owner
owner:a = {
 admins = a@example.com;
}
END

$job = {
    method => 'create_owner',
    params => {
        name    => 'a',
        admins  => [ 'a@example.com' ],
        'ok_if_exists' => 1,
    },
};

$out = <<'END';
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Added owner exists, but not found';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
-- owner
owner:a
= {
 admins = a@example.com;
}
END

$job = {
    method => 'create_owner',
    params => {
        name    => 'a',
        admins  => [ 'a@example.com' ],
        'ok_if_exists' => 1,
    }
};

$out = <<'END';
Error: Duplicate definition of owner:a in netspoc/owner
Aborted with 1 error(s)
---
netspoc/owner
@@ -1,4 +1,7 @@
-owner:a
-= {
+owner:a = {
+ admins = a@example.com;
+}
+
+owner:a = {
  admins = a@example.com;
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Delete still referenced owner';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
-- owner
owner:a = {
 admins = a@example.com; #}
} # end
# next line
END

$job = {
    method => 'delete_owner',
    params => {
        name => 'a',
    }
};

$out = <<'END';
Warning: Ignoring undefined owner:a of network:n1
---
netspoc/owner
@@ -1,4 +1 @@
-owner:a = {
- admins = a@example.com; #}
-} # end
 # next line
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Modify owner: change admins, add watchers';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
owner:a = {
 admins = a@example.com; } # Comment
END

$job = {
    method => 'modify_owner',
    params => {
        name => 'a',
        admins => [ 'b@example.com', 'a@example.com' ],
        watchers => [ 'c@example.com', 'd@example.com' ]
    }
};

$out = <<'END';
netspoc/topology
@@ -1,3 +1,11 @@
 network:n1 = { ip = 10.1.1.0/24; owner = a; }
 owner:a = {
- admins = a@example.com; } # Comment
+ admins =
+	a@example.com,
+	b@example.com,
+	;
+ watchers =
+	c@example.com,
+	d@example.com,
+	;
+} # Comment
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Modify owner with swapped admins and watchers';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
owner:a = {
 watchers = b@example.com;
 admins   = a@example.com; }
END

$job = {
    method => 'modify_owner',
    params => {
        name => 'a',
        admins => [ 'b@example.com' ],
        watchers => [ 'c@example.com' ]
    }
};

$out = <<'END';
netspoc/topology
@@ -1,4 +1,9 @@
 network:n1 = { ip = 10.1.1.0/24; owner = a; }
 owner:a = {
- watchers = b@example.com;
- admins   = a@example.com; }
+ admins =
+	b@example.com,
+	;
+ watchers =
+	c@example.com,
+	;
+}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Modify owner: leave admins untouched, remove watchers';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
owner:a = {
 watchers = b@example.com;
 admins   = a@example.com;
}
END

$job = {
    method => 'modify_owner',
    params => {
        name => 'a',
        watchers => []
    }
};

$out = <<'END';
netspoc/topology
@@ -1,5 +1,4 @@
 network:n1 = { ip = 10.1.1.0/24; owner = a; }
 owner:a = {
- watchers = b@example.com;
  admins   = a@example.com;
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Modify owner, defined in one line';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
owner:a = { admins = a@example.com; }
END

$job = {
    method => 'modify_owner',
    params => {
        name => 'a',
        admins => [ 'c@example.com' ]
    }
};

$out = <<'END';
netspoc/topology
@@ -1,2 +1,6 @@
 network:n1 = { ip = 10.1.1.0/24; owner = a; }
-owner:a = { admins = a@example.com; }
+owner:a = {
+ admins =
+	c@example.com,
+	;
+}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Modify owner: multiple attributes in one line';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; owner = a; }
owner:a = {
 admins = a@example.com; watchers = b@example.com;
}
END

$job = {
    method => 'modify_owner',
    params => {
        name => 'a',
        admins => [ 'c@example.com' ]
    }
};

$out = <<'END';
netspoc/topology
@@ -1,4 +1,7 @@
 network:n1 = { ip = 10.1.1.0/24; owner = a; }
 owner:a = {
- admins = a@example.com; watchers = b@example.com;
+ admins =
+	c@example.com,
+	;
+ watchers = b@example.com;
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host to known network';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24; }
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    },
};

$out = <<'END';
netspoc/topology
@@ -1 +1,4 @@
-network:a = { ip = 10.1.1.0/24; }
+network:a = {
+ ip = 10.1.1.0/24;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
+}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host, insert sorted';
############################################################

$in = <<'END';
-- topology
network:a = {
 ip = 10.1.1.0/24;
 # Comment1
 host:name_10_1_1_2 = { ip = 10.1.1.2; }
 # Comment2
 # Comment3
 host:name_10_1_1_5 = { ip = 10.1.1.5; }
 host:name_10_1_1_6 = { ip = 10.1.1.6; }
}
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
netspoc/topology
@@ -2,6 +2,7 @@
  ip = 10.1.1.0/24;
  # Comment1
  host:name_10_1_1_2 = { ip = 10.1.1.2; }
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
  # Comment2
  # Comment3
  host:name_10_1_1_5 = { ip = 10.1.1.5; }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host, same name';
############################################################

$in = <<'END';
-- topology
network:a = {
 ip = 10.1.1.0/24;
 host:name_10_1_1_4 = { ip = 10.1.1.4; }
}
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
Error: Duplicate definition of host:name_10_1_1_4 in netspoc/topology
Aborted with 1 error(s)
---
netspoc/topology
@@ -1,4 +1,5 @@
 network:a = {
  ip = 10.1.1.0/24;
  host:name_10_1_1_4 = { ip = 10.1.1.4; }
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, same IP';
############################################################

$in = <<'END';
-- topology
network:a = {
 ip = 10.1.1.0/24;
 host:other_10_1_1_4 = { ip = 10.1.1.4; }
}
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
Error: Duplicate IP address for host:other_10_1_1_4 and host:name_10_1_1_4
Aborted with 1 error(s)
---
netspoc/topology
@@ -1,4 +1,5 @@
 network:a = {
  ip = 10.1.1.0/24;
  host:other_10_1_1_4 = { ip = 10.1.1.4; }
+ host:name_10_1_1_4  = { ip = 10.1.1.4; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, same IP unsorted';
############################################################

$in = <<'END';
-- topology
network:a = {
 ip = 10.1.1.0/24;
 host:name_10_1_1_5 = { ip = 10.1.1.5; }
 host:name_10_1_1_4 = { ip = 10.1.1.4; }
}
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
Error: Duplicate definition of host:name_10_1_1_4 in netspoc/topology
Aborted with 1 error(s)
---
netspoc/topology
@@ -1,5 +1,6 @@
 network:a = {
  ip = 10.1.1.0/24;
- host:name_10_1_1_5 = { ip = 10.1.1.5; }
  host:name_10_1_1_4 = { ip = 10.1.1.4; }
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
+ host:name_10_1_1_5 = { ip = 10.1.1.5; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Multiple networks at one line';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24; } network:b = { ip = 10.1.2.0/24; }
router:r1 = {
 interface:a;
 interface:b;
}
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
    }
};

$out = <<'END';
netspoc/topology
@@ -1,4 +1,10 @@
-network:a = { ip = 10.1.1.0/24; } network:b = { ip = 10.1.2.0/24; }
+network:a = {
+ ip = 10.1.1.0/24;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
+}
+
+network:b = { ip = 10.1.2.0/24; }
+
 router:r1 = {
  interface:a;
  interface:b;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host with owner';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = {
 admins = abc@example.com;
}

network:a = { ip = 10.1.0.0/21; }
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        owner   => 'DA_abc',
    }
};

$out = <<'END';
netspoc/topology
@@ -2,4 +2,7 @@
  admins = abc@example.com;
 }

-network:a = { ip = 10.1.0.0/21; }
+network:a = {
+ ip = 10.1.0.0/21;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; owner = DA_abc; }
+}
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host, redundant owner';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = {
 admins = abc@example.com;
}

network:a = {
 ip = 10.1.0.0/21;
 owner = DA_abc;
}
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        owner   => 'DA_abc',
    }
};

$out = <<'END';
netspoc/topology
@@ -5,4 +5,5 @@
 network:a = {
  ip = 10.1.0.0/21;
  owner = DA_abc;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Add host, with warning from previous checkin';
############################################################

$in = <<'END';
-- topology
owner:DA_abc = {
 admins = abc@example.com;
}

network:a = {
 ip = 10.1.0.0/21;
 owner = DA_abc;
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
Warning: Useless owner:DA_abc at host:name_10_1_1_4,
 it was already inherited from network:a
---
netspoc/topology
@@ -5,5 +5,6 @@
 network:a = {
  ip = 10.1.0.0/21;
  owner = DA_abc;
+ host:name_10_1_1_3 = { ip = 10.1.1.3; }
  host:name_10_1_1_4 = { ip = 10.1.1.4; owner = DA_abc; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, with old and new warning';
############################################################

$in = <<'END';
-- topology
network:a = {
 ip = 10.1.0.0/21;
 host:name_10_1_1_4 = { ip = 10.1.1.4; }
}

router:r = {
 interface:a;
 interface:b;
}

network:b = {
 ip = 10.1.1.0/24;
 subnet_of = network:a;
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
Warning: IP of host:name_10_1_1_3 overlaps with subnet network:b
Warning: IP of host:name_10_1_1_4 overlaps with subnet network:b
---
netspoc/topology
@@ -1,5 +1,6 @@
 network:a = {
  ip = 10.1.0.0/21;
+ host:name_10_1_1_3 = { ip = 10.1.1.3; }
  host:name_10_1_1_4 = { ip = 10.1.1.4; }
 }

END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, unknown owner';
############################################################

$in = <<'END';
-- topology
network:a = {
 ip = 10.1.0.0/21;
}
END

$job = {
    method => 'create_host',
    params => {
        network => 'a',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        owner   => 'DA_abc',
    }
};

$out = <<'END';
Warning: Ignoring undefined owner:DA_abc of host:name_10_1_1_4
---
netspoc/topology
@@ -1,3 +1,4 @@
 network:a = {
  ip = 10.1.0.0/21;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; owner = DA_abc; }
 }
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, no IP address found';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.0.0/21; }
END

$job = {
    method => 'create_host',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.0.*',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Error: IP address expected: '10.1.0.*'
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, invalid IP address';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.0.0/21; }
END

$job = {
    method => 'create_host',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.0.444',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Error: Invalid IP address: '10.1.0.444'
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, invalid IP mask';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.0.0/21; }
END

$job = {
    method => 'create_host',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.0.4',
        mask    => '123.255.248.0',
    }
};

$out = <<'END';
Error: Invalid IP mask: '123.255.248.0'
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host [auto]';
############################################################

$in = <<'END';
-- topology
network:d = { ip = 10.2.0.0/21; }

network:a = {
 ip = 10.1.0.0/21;
}

router:r = {
 interface:a;
 interface:d;
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
netspoc/topology
@@ -2,6 +2,7 @@

 network:a = {
  ip = 10.1.0.0/21;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; }
 }

 router:r = {
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
    method => 'create_host',
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

my $many_comments = "#\n" x 50;
$in = <<"END";
-- topology
network:a = {
$many_comments
 ip = 10.1.0.0/21; }
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
    method => 'create_host',
    params => {
        network => '[auto]',
        name    => 'name_10_1_1_4',
        ip      => '10.1.1.4',
        mask    => '255.255.248.0',
    }
};

$out = <<'END';
Error: Found multiple networks with 'ip = 10.1.0.0/21' in: netspoc/topology
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Add host, find NAT IP from [auto]';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.0.0/21; nat:a = { hidden; } }
network:b = { ip = 10.2.0.0/21; nat:b = { ip = 10.1.0.0/21; } }
network:c = { ip = 10.3.0.0/21; }

router:r1 = {
 interface:a;
 interface:b = { bind_nat = a; }
 interface:c = { bind_nat = a, b; }
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
Error: Found multiple networks with 'ip = 10.1.0.0/21' in: netspoc/topology
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
    method => 'create_host',
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
$title = 'multi_job without jobs';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
-- owner
# Add owners below.
END

$job = {
    method => 'multi_job',
};

$out = <<'END';
END

test_run($title, $in, $job, $out);

############################################################
$title = 'multi_job: add host and owner';
############################################################

$in = <<'END';
-- topology
network:n1 = {
 ip = 10.1.1.0/24;
}
-- owner
# Add owners below.
END

$job = {
    method => 'multi_job',
    params => {
        jobs => [
            {
                method => 'create_owner',
                params => {
                    name     => 'a',
                    admins   => [ 'b@example.com', 'a@example.com' ],
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
@@ -1,3 +1,4 @@
 network:n1 = {
  ip = 10.1.1.0/24;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; owner = a; }
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'multi_job: add owner that exists and add host';
############################################################

$in = <<'END';
-- topology
network:n1 = {
 ip = 10.1.1.0/24;
 host:name_10_1_1_5 = { ip = 10.1.1.5; owner = a; }
}
-- owner
owner:a = {
 admins = a@example.com;
}
END

$job = {
    method => 'multi_job',
    params => {
        jobs => [
            {
                method => 'create_owner',
                params => {
                    name     => 'a',
                    admins   => [ 'b@example.com' ],
                    ok_if_exists => 1,
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
netspoc/topology
@@ -1,4 +1,5 @@
 network:n1 = {
  ip = 10.1.1.0/24;
+ host:name_10_1_1_4 = { ip = 10.1.1.4; owner = a; }
  host:name_10_1_1_5 = { ip = 10.1.1.5; owner = a; }
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'multi_job: second job fails';
############################################################

$in = <<'END';
-- topology
network:n1 = { ip = 10.1.1.0/24; }
END

$job = {
    method => 'multi_job',
    params => {
        jobs => [
            {
                method => 'create_host',
                params => {
                    network => 'n1',
                    name    => 'name_10_1_1_4',
                    ip      => '10.1.1.4',
                }
            },
            {
                method => 'create_host',
                params => {
                    network => 'n2',
                    name    => 'name_10_1_2_4',
                    ip      => '10.1.2.4',
                }
            }
        ],
    }
};

$out = <<'END';
Error: Can't find 'network:n2' in netspoc
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Change owner of host, add and delete owner';
############################################################

$in = <<'END';
-- topology
network:n1 = {
 ip = 10.1.1.0/24;
 host:h1 = {
  ip = 10.1.1.1;
  owner = o1;
 } host:h2 = { ip = 10.1.1.2; owner = o1; }
}
-- owner
owner:o1 = { admins = a1@example.com; }
END

$job = {
    method => 'multi_job',
    params => {
        jobs => [
            {
                method => 'create_owner',
                params => {
                    name     => 'o2',
                    admins   => [ 'a2@example.com' ],
                }
            },
            {
                method => 'delete_owner',
                params => {
                    name     => 'o1',
                }
            },
            {
                method => 'modify_host',
                params => {
                    name    => 'h1',
                    owner   => 'o2',
                }
            },
            {
                method => 'modify_host',
                params => {
                    name    => 'h2',
                    owner   => 'o2',
                }
            }
        ],
    }
};

$out = <<'END';
netspoc/owner
@@ -1 +1,3 @@
-owner:o1 = { admins = a1@example.com; }
+owner:o2 = {
+ admins = a2@example.com;
+}
netspoc/topology
@@ -2,6 +2,7 @@
  ip = 10.1.1.0/24;
  host:h1 = {
   ip = 10.1.1.1;
-  owner = o1;
- } host:h2 = { ip = 10.1.1.2; owner = o1; }
+  owner = o2;
+ }
+ host:h2 = { ip = 10.1.1.2; owner = o2; }
 }
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Change owner at second of multiple ID-hosts';
############################################################

$in = <<'END';
-- topology
network:n1 = {
 ip = 10.1.1.0/24;
 host:id:a1@example.com = { ip = 10.1.1.1; owner = DA_TOKEN_o1; }
 host:id:a2@example.com = { ip = 10.1.1.2; owner = DA_TOKEN_o1; }
}
network:n2 = {
 ip = 10.1.2.0/24;
 host:id:a1@example.com = { ip = 10.1.2.1; owner = DA_TOKEN_o1; }
 host:id:a2@example.com = { ip = 10.1.2.2; owner = DA_TOKEN_o2; }
}
router:r1 = {
 interface:n1;
 interface:n2;
}
-- owner-token
owner:DA_TOKEN_o1 = {
 admins = a1@example.com;
}
owner:DA_TOKEN_o2 = { admins = a2@example.com; }
END


$job = {
    method => 'multi_job',
    params => {
        jobs => [
            {
                method => 'modify_host',
                params => {
                    name  => 'id:a2@example.com.n2',
                    owner => 'DA_TOKEN_o3',
                }
            },
            {
                method => 'create_owner',
                params => {
                    name   => 'DA_TOKEN_o3',
                    admins => [ 'a3@example.com' ],
                }
            },
            {
                method => 'delete_owner',
                params => {
                    name => 'DA_TOKEN_o2',
                }
            },
        ]
    }
};

$out = <<'END';
netspoc/owner-token
@@ -1,4 +1,7 @@
 owner:DA_TOKEN_o1 = {
  admins = a1@example.com;
 }
-owner:DA_TOKEN_o2 = { admins = a2@example.com; }
+
+owner:DA_TOKEN_o3 = {
+ admins = a3@example.com;
+}
netspoc/topology
@@ -6,7 +6,7 @@
 network:n2 = {
  ip = 10.1.2.0/24;
  host:id:a1@example.com = { ip = 10.1.2.1; owner = DA_TOKEN_o1; }
- host:id:a2@example.com = { ip = 10.1.2.2; owner = DA_TOKEN_o2; }
+ host:id:a2@example.com = { ip = 10.1.2.2; owner = DA_TOKEN_o3; }
 }
 router:r1 = {
  interface:n1;
END

test_run($title, $in, $job, $out);

############################################################
$title = 'Must not change wrong ID-host';
############################################################

$in = <<'END';
-- topology
network:n1 = {
 ip = 10.1.1.0/24;
 host:id:a1@example.com
 = { ip = 10.1.1.1; owner = o1; }
}
network:n2 = {
 ip = 10.1.2.0/24;
 host:id:a1@example.com = { ip = 10.1.2.1; owner = DA_TOKEN_o1; }
}
router:r1 = {
 interface:n1;
 interface:n2;
}
-- owner-token
owner:DA_TOKEN_o1 = { admins = a1@example.com; }
owner:DA_TOKEN_o2 = { admins = a2@example.com; }
END

$job = {
    method => 'modify_host',
    params => {
        name    => 'id:a1@example.com.n1',
        owner   => 'o1',
    }
};

$out = <<'END';
Error: Can't find host:id:a1@example.com
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Job with malicous network name';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24; } # Comment
END

$job = {
    method => 'create_host',
    params => {
        network => "a'; exit; '",
    }
};

$out = <<'END';
Error: Can't find 'network:a'; exit; '' in netspoc
END

test_err($title, $in, $job, $out);

############################################################
$title = 'Job with whitespace in email address';
############################################################

$in = <<'END';
-- topology
network:a = { ip = 10.1.1.0/24; }
-- owner
owner:a = { admins = a@example.com; }
END

$job = {
    method => 'modify_owner',
    params => {
        admins => ['b example.com'],
        name => 'a'
    }
};

$out = <<'END';
Syntax error: Expected ';' at line 3 of netspoc/owner, near "b --HERE-->example.com"
---
netspoc/owner
@@ -1 +1,5 @@
-owner:a = { admins = a@example.com; }
+owner:a = {
+ admins =
+	b example.com,
+	;
+}
END

test_err($title, $in, $job, $out);

############################################################
done_testing;
