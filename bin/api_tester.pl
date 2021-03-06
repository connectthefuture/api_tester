#!/usr/bin/perl
#
# This script is meant to run a test suite against an API built on api_producer.
# It does NOT do any setup of resources. All systems (database, webserver, etc)
# must be working first. This is just the functional test of the actual API.

use strict;
use warnings;

##
## Modules
##

use File::Basename;
use Getopt::Long;
use HTTP::Request;
use JSON::DWIW;
use LWP::UserAgent;
use Test::Deep;
use Test::More;
use URI::Escape;

##
## Variables
##

Getopt::Long::Configure('bundling');

my $PROGNAME = basename($0);
my $REVISION = '1';

our $CAPTURED = '';
my $JSON;
my %OPTS;
our $TESTS;
my $TOTAL = 0;
my $UA;
our $UNIQUE = $PROGNAME . $$ . time();

our $UNIQUE_NODE = $UNIQUE;
$UNIQUE_NODE =~ s/[^a-z0-9.-]/-/g;

##
## Subroutines
##

sub capture {
# Purpose: Capture a field from the output
# Inputs: $got (from Test::Deep)
# Output: None
# Return: None
# Exits: No

	$CAPTURED = shift;

	return 1;
}

sub captured {
# Purpose: Compare against the previously captured value
# Inputs: $got (from Test::Deep)
# Output: None
# Return: None
# Exits: No

	my $got = shift;

	$TOTAL++;

	return is($got, $CAPTURED);
}

sub init {
# Purpose: Get command line opts, set things up, etc
# Inputs: None
# Output: None
# Return: None
# Exits: Possibly

	my $help;
	my $tests_file;

	my $result = GetOptions(
		'S|ignore-http-status' => \$OPTS{'ignore_http_status'},
		'c|testsfile=s' => \$tests_file,
		'h|help|?' => \$help,
	) || BAIL_OUT(usage());

	BAIL_OUT(usage()) if($help);

	if(!$tests_file) {
		BAIL_OUT(usage());
	}

	note('Unique string is ' . $UNIQUE);

	$JSON = JSON::DWIW->new();
	$UA = LWP::UserAgent->new('agent' => $UNIQUE);

	parse_tests_file($tests_file);

	return;
}

sub parse_tests_file {
# Purpose: Parse the tests file and add to $TESTS
# Inputs: Tests file
# Outputs: Error if any
# Return: None
# Exits: Yes

	my $file = shift;

	my $return = do($file);

	if($@) {
		BAIL_OUT('Unable to parse ' . $file . ': ' . $@);
	}

	if(!defined($return)) {
		BAIL_OUT('Unable to parse ' . $file . ': ' . $!);
	}

	if(!$return) {
		BAIL_OUT('Unable to parse ' . $file);
	}
}

sub usage {
# Purpose: Print a usage statement
# Inputs: None
# Output: None
# Return: usage statement
# Exits: No

	my $usage = 'Usage: ' . $PROGNAME . ' [OPTIONS]' . "\n";
	$usage .= <<USAGE;

Options:
 -S		Ignore HTTP status code.
 -c file	The test spec file.
 -h		This help statement.
 -v		Increase verbosity. May be used multiple times.
USAGE

	return $usage;
}

##
## Main
##

init();

TEST: foreach my $test (@{$TESTS}) {
	my $requests = scalar(@{$test->{'requests'}});
	my $responses = scalar(@{$test->{'responses'}});

	$TOTAL++;

	next unless(is($requests, $responses,
		$test->{'description'} . ': requests != responses'));

	$TOTAL += $requests * 4;

	my $cur = 0;
	foreach my $request (@{$test->{'requests'}}) {
		my $err;
		my $expected = $test->{'responses'}->[$cur];
		my $got;
		my $json;
		my $req;
		my $response;
		my $uri = $test->{'uri'};

		if(defined($request->{'uri'})) {
			$uri = $request->{'uri'};
		}

		$uri .= '?outputFormat=json';

		if($request->{'get'}) {
			my @g_params = ();
			while(my($key, $val) = each(%{$request->{'get'}})) {
				if(ref($val) eq 'ARRAY') {
					foreach my $v (@{$val}) {
						push(@g_params, $key . '[]=' .
							uri_escape($v));
					}
				} else {
					push(@g_params,
						$key . '=' . uri_escape($val));
				}
			}

			$uri .= '&' . join('&', @g_params);
		}

		if($request->{'json'}) {
			while(my ($jkey, $jval) = each(%{$request->{'json'}})) {
				if($jval eq '_CAPTURED_') {
					$request->{'json'}->{$jkey} = $CAPTURED;
				}
			}

			($json, $err)  = $JSON->to_json($request->{'json'});
			unless(ok(!defined($err), $test->{'description'} .
					': request -> JSON')) {
				diag($err);
				$cur++;
				next TEST;
			}

			$req = HTTP::Request->new('POST' => $uri);
			$req->header('Content-Type' => 'application/json');
			$req->content($json);
		} else {
			$req = HTTP::Request->new('GET' => $uri);
			$TOTAL--;
		}

		$response = $UA->request($req);
		if(defined($OPTS{'ignore_http_status'})) {
			pass($test->{'description'} . ': HTTP 2xx');
			$cur++;
		} else {
			unless(ok(($response->is_success()),
					$test->{'description'} . ': HTTP 2xx')) {
				diag($response->status_line());
				$cur++;
				next TEST;
			}
		}

		($got, $err) = $JSON->from_json($response->decoded_content());
		unless(ok(!defined($err), $test->{'description'} .
				': JSON response -> perl')) {
			diag($err);
			diag($response->decoded_content());
			$cur++;
			next TEST;
		}

		unless(cmp_deeply($got, $expected->{'body'},
				$test->{'description'} . ': body')) {
			diag(explain($got));
			$cur++;
			next TEST;
		}

		$cur++;
	}
}

done_testing($TOTAL);
