#!/usr/local/bin/perl

=head1 NAME

api.psgi - Accept jobs for Netspoc-API

=head1 COPYRIGHT AND DISCLAIMER

(C) 2019 by Heinz Knutzen <heinz.knutzen@gmail.com>

https://github.com/hknutzen/Netspoc-Web

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.
You should have received a copy of the GNU General Public License
along with this program. If not, see <http://www.gnu.org/licenses/>.

=cut

use strict;
use warnings;
use JSON;
use Plack::Util;
use Plack::Request;
use Plack::Response;
use IPC::Run3;

# JSON file with
# either
# - ldap_uri = URL
# or
# - user = USERNAME
# - pass = PASSWORD
my $conf_file = 'config';
my $config;

my %path2sub =
(
  'add-job' => \&add_job,
  'job-status'  => \&job_status,
);

# Parameter is HTTP error message, optionally preceeded by status code.
# Use 500 as default.
sub abort {
    my ($msg) = @_;
    die "$msg\n";
}

sub load_config {
    my $result;
    open( my $fh, '<', $conf_file ) or abort("Can't open '$conf_file': $!");
    local $/ = undef;
    return from_json(  <$fh>, { relaxed  => 1 } );
}

sub add_job {
    my ($job) = @_;
    my ($id, $stderr);
    my $json = encode_json($job);
    run3('bin/add-job', \$json, \$id, \$stderr);
    $? and abort($stderr);
    return(encode_json({id => $id}));
}

sub job_status {
    my ($job) = @_;
    my ($id, $user) = @{$job}{qw(id user)};
    my ($result, $stderr);
    run3("bin/job-status $id $user", \undef, \$result, \$stderr);
    $? and abort($stderr);
    return $result;
}

sub authenticate {
    my ($json) = @_;
    my $user = $json->{user} or abort "400 Missing 'user'";

    # Delete password from request, must not be stored in queue.
    my $pass = delete $json->{pass} or abort "400 Missing 'pass'";

    my $user_conf = $config->{user}->{$user} or abort('400 Unknown user');
    if (my $user_pass = $user_conf->{pass}) {
        $pass eq  $user_pass or abort('400 Local authentication failed');
    }
    elsif ($user_conf->{ldap}) {
        my $ldap_uri = $config->{ldap_uri};
        my $ldap = Net::LDAP->new($ldap_uri, onerror => 'undef') or
            abort "LDAP connect failed: $@";
        $ldap->bind($user, password => $pass) or
            abort('400 LDAP authentication failed');
    }
    else {
        abort('No authentication method configured');
    }
}

sub handle_request {
    my ($env) = @_;
    my $res = Plack::Response->new(200);
    # Catch errors.
    eval {
        my $req = Plack::Request->new($env);
        my $path = $req->path_info();
        $path =~ s:^/::;
        my $handler = $path2sub{$path} or abort "400 Unknown path '$path'";
        my $job = decode_json($req->content());
        authenticate($job);
        my $result = $handler->($job);
        $res->content_type('application/json');
        $res->body($result);
    };
    if ($@) {
        my $msg = $@;
        $msg =~ s/(\d\d\d) *//;
        $res->status($1 || 500);
        $res->content_type('text/plain; charset=utf-8');
        $res->body($msg);
    }
    return $res->finalize;
}

chdir $ENV{HOME};
$config = load_config();
my $app = \&handle_request;
