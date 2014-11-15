#!/usr/bin/env perl

use warnings;
use strict;

use Getopt::Long qw/:config no_ignore_case bundling auto_abbrev/;
use Fcntl qw/SEEK_SET/;
use IO::Poll;
use IO::Handle;
use IPC::Open3;
use POSIX qw/strftime :sys_wait_h/;
use JSON;
use LWP::UserAgent;

# ==============================================================================

use constant {
	'POLL_TIMEOUT' => 1,
};

# ==============================================================================

my (%OPTIONS, @RCFILES, $rcfile, $rcfileLine);

%OPTIONS = (
	'__HELP__' => undef,
	'apiurl' => 'https://events.pagerduty.com/generic/2010-04-15/create_event.json',
	'apikey' => '',
	'log' => '/dev/null',
	'stdout' => undef,
	'stderr' => undef,
	'timeout' => 0,
	'exitmin' => 0,
	'exitmax' => 0,
);
@RCFILES = (
	'/etc/pdwraprc',
	$ENV {'HOME'} . '/.pdwraprc',
	'./.pdwraprc',
);

foreach $rcfile (@RCFILES) {
	if (open (RCFILE, '<', $rcfile)) {
		while ($rcfileLine = <RCFILE>) {
			$rcfileLine =~ s/(\r\n|\n\r|\r|\n)//ms;
			$rcfileLine =~ s/(#|\/\/).*$//;
			$rcfileLine =~ s/^\s+//;
			$rcfileLine =~ s/\s+$//;
			if ($rcfileLine =~ /^(\S+)\s+(\S.*)$/) {
				if (exists ($OPTIONS {lc ($1)})) {
					$OPTIONS {lc ($2)} = $2;
				}
			}
		}
		close (RCFILE);
	}
}

GetOptions (
	'h|help' => \$OPTIONS {'__HELP__'},
	'u|apiurl=s' => \$OPTIONS {'apiurl'},
	'k|apikey=s' => \$OPTIONS {'apikey'},
	'l|log=s' => \$OPTIONS {'log'},
	'stdout!' => \$OPTIONS {'stdout'},
	'stderr!' => \$OPTIONS {'stderr'},
	't|timeout=i' => \$OPTIONS {'timeout'},
	'm|exitmin=i' => \$OPTIONS {'exitmin'},
	'M|exitmax=i' => \$OPTIONS {'exitmax'},
) || (
	exit (1)
);

# ==============================================================================

if (defined ($OPTIONS {'__HELP__'})) {
	$OPTIONS {'__HELP__'} = 0;

} else  {
	if ($OPTIONS {'apiurl'} !~ /^https?:\/\/[a-z0-9_.-]+(?:\/.*)?$/i) {
		printf (STDERR "Error: apiurl must be a valid HTTP/HTTPS URL\n");
		$OPTIONS {'__HELP__'} = 1;
	}
	if ($OPTIONS {'apikey'} !~ /^[a-z0-9]+$/i) {
		printf (STDERR "Error: apikey must be a valid PagerDuty API key\n");
		$OPTIONS {'__HELP__'} = 1;
	}

	if ($OPTIONS {'timeout'} < 0) {
		printf (STDERR "Error: timeout must be greater than or equal to 0\n");
		$OPTIONS {'__HELP__'} = 1;
	}

	if ($OPTIONS {'exitmin'} > $OPTIONS {'exitmax'}) {
		printf (STDERR "Error: exitmin must be less than or equal to exitmax\n");
		$OPTIONS {'__HELP__'} = 1;
	}
}

if (defined ($OPTIONS {'__HELP__'})) {
	if ($OPTIONS {'__HELP__'} == 0) {
		printf (<<'EOF', $0, join ("\n  * ", @RCFILES));
Usage: %s --apikey <KEY> [OPTIONS] -- <COMMAND> [<ARG> ...]

  Option      Type  Note
  ------------------------------------------------------------------------------
  -h --help           This help
  -u --apiurl   URL   PagerDuty API URL that you probably should leave alone
  -k --apikey   KEY   PagerDuty service API key
  -l --log      FILE  Append the output of the command to the specified log file
                      Default: /dev/null
  --stdout            Allow passthru of STDOUT from the command to this terminal
                      Default: Off
  --nostdout          Disallow passthru of STDOUT (if enabled via an RC file)
  --stderr            Allow passthru of STDERR from the command to this terminal
                      Default: Off
  --nostderr          Disallow passthru of STDERR (if enabled via an RC file)
  -t --timeout  INT   Max allowed run time for the command (0 means none)
                      Default: 0
  -m --exitmin  INT   Minimum value for a good exit code
                      Default: 0
  -M --exitmax  INT   Maximum value for a good exit code
                      Default: 0

Options are also read from the following files (in order) prior to CLI options
being applied:

  * %s

EOF
	}
	exit ($OPTIONS {'__HELP__'});
}

# ==============================================================================

sub pdEvent {
	my ($apiKey, $apiURL, $event) = @_;
	my ($useragent, $response);

	$event->{'service_key'} = $apiKey;

	$useragent = LWP::UserAgent->new ();
	$response = $useragent->post (
		$apiURL,
		'Content_Type' => 'application/json',
		'Content' => JSON->new ()->utf8 ()->encode ($event)
	);

	if (! $response->is_success ()) {
		return ($response->status_line ());
	}
	return (undef);
}

# ==============================================================================

my ($TMP) = ('');
if ($OPTIONS {'log'}) {
	if (! open (LOG, '>>', $OPTIONS {'log'})) {
		printf (STDERR "Error: Failed to open log file (%s): %s\n", $OPTIONS {'log'}, $!);
		exit (1);
	}
}
if (! open (TMP, '+>', \$TMP)) {
	printf (STDERR "Error: Failed to open temporary in-memory file: %s\n", $!);
	exit (1);
}

# ==============================================================================

#sub 

# ==============================================================================

my ($POLL, $pid, $exitStatus, $timedOut, $stdin, $stdout, $stderr, $pollHandle, $pollLine, $pollLines, $timestamp);

$stdin = IO::Handle->new ();
$stdout = IO::Handle->new ();
$stderr = IO::Handle->new ();

# Ignore SIGPIPE
$SIG {PIPE} = sub {};

if (defined ($OPTIONS {'timeout'}) && ($OPTIONS {'timeout'} > 0)) {
	alarm ($OPTIONS {'timeout'});
	$SIG {ALRM} = sub {
		$timedOut = 1;
		kill (-9, $pid);
		sleep (1);
		waitpid ($pid, WNOHANG);
	};
}

$POLL = IO::Poll->new ();
$POLL->mask (*STDIN => POLLIN);

$pid = open3 ($stdin, $stdout, $stderr, @ARGV);
if (! defined ($pid)) {
	printf (STDERR "Error: Failed to launch command: %s\n", $!);
	close (TMP);
	close (LOG);
	exit (1);
}
$POLL->mask ($stdout => POLLIN);
$POLL->mask ($stderr => POLLIN);

while (1) {
	$pollLines = 0;

	if (! $timedOut && ! defined ($exitStatus) && (waitpid ($pid, WNOHANG) != 0)) {
		$exitStatus = $? >> 8;
		alarm (0);
	}

	$POLL->poll (POLL_TIMEOUT);
	foreach $pollHandle ($POLL->handles (POLLIN)) {
		$timestamp = strftime ('%Y-%m-%d %H:%M:%S %z', localtime ());

		if ($pollHandle == \*STDIN) {
			if (defined ($pollLine = <STDIN>)) {
				$pollLines++;
				if (! $timedOut && ! defined ($exitStatus)) { # Only write to the child if it's still running even though we're sinking SIGPIPE
					print ({$stdin} $pollLine); # Cute hack so $stdin doesn't get treated as an item to be printed

					$pollLine =~ s/(\r\n|\n\r|\r|\n)//ms;
					$pollLine =~ s/\s+$//;

					if ($OPTIONS {'log'}) {
						printf (LOG "%s STDIN  %s\n", $timestamp, $pollLine);
					}
					printf (TMP "%s STDIN  %s\n", $pollLine);
				}
			}

		} elsif (($pollHandle == $stdout) || ($pollHandle == $stderr)) {
			if (defined ($pollLine = <$pollHandle>)) {
				$pollLines++;
				$pollLine =~ s/(\r\n|\n\r|\r|\n)//ms;
				$pollLine =~ s/\s+$//;

				if ($pollHandle == $stdout) {
					if ($OPTIONS {'stdout'}) {
						printf (STDOUT "%s\n", $pollLine);
					}
					if ($OPTIONS {'log'}) {
						printf (LOG "%s STDOUT %s\n", $timestamp, $pollLine);
					}
					printf (TMP "%s STDOUT %s\n", $timestamp, $pollLine);
				}
				if ($pollHandle == $stderr) {
					if ($OPTIONS {'stderr'}) {
						printf (STDERR "%s\n", $pollLine);
					}
					if ($OPTIONS {'log'}) {
						printf (LOG "%s STDERR %s\n", $timestamp, $pollLine);
					}
					printf (TMP "%s STDERR %s\n", $timestamp, $pollLine);
				}
			}
		}
	}
	
	if (($timedOut || defined ($exitStatus)) && ($pollLines == 0)) {
		last;
	}
}

close (TMP);

# ==============================================================================

my (@cmdPieces, $cmdPiece, $pdError);

foreach $cmdPiece (@ARGV) {
	if ($cmdPiece =~ /\s/) {
		push (@cmdPieces, sprintf ('"%s"', $cmdPiece));
	} else {
		push (@cmdPieces, $cmdPiece);
	}
}

$timestamp = strftime ('%Y-%m-%d %H:%M:%S %z', localtime ());

if (defined ($timedOut)) {
	printf (LOG "%s ALARM  Timed-out after %is\n", $timestamp, $OPTIONS {'timeout'});

	$pdError = pdEvent ($OPTIONS {'apikey'}, $OPTIONS {'apiurl'}, {
		'event_type' => 'trigger',
		'incident_key' => undef,
		'description' => sprintf ('Command exceeded max runtime of %is: %s', $OPTIONS {'timeout'}, join (' ', @cmdPieces)),
		'details' => $TMP,
	});

} elsif (($exitStatus < $OPTIONS {'exitmin'}) || ($exitStatus > $OPTIONS {'exitmax'})) {
	printf (LOG "%s STATUS %i\n", $timestamp, $exitStatus);

	$pdError = pdEvent ($OPTIONS {'apikey'}, $OPTIONS {'apiurl'}, {
		'event_type' => 'trigger',
		'incident_key' => undef,
		'description' => sprintf ('Command exited with unexpected code %i: %s', $exitStatus, join (' ', @cmdPieces)),
		'details' => $TMP,
	});

} else {
	close (LOG);
	exit (0);
}

$timestamp = strftime ('%Y-%m-%d %H:%M:%S %z', localtime ());
if ($pdError) {
	printf (STDERR "Notice: PagerDuty Failure: %s\n", $pdError);
	printf (LOG "%s PGRDTY %s\n", $timestamp, $pdError);

} else {
	printf (STDERR "Notice: PagerDuty Success!\n");
	printf (LOG "%s PGRDTY OKAY\n", $timestamp);
}

close (LOG);
exit ($exitStatus);
