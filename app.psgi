use utf8;
use strict;
use warnings;

use constant RUNTIME_DENY => [ qw/ fs net proc db perl / ];

use JSON::PP qw( decode_json encode_json );
use Digest::SHA qw( sha1_hex );
use File::Path qw( make_path );
use Fcntl qw( :flock );
use Plack::Builder;
use Plack::Request;
use Plack::Response;
use Plack::App::File;
use Plack::Middleware::SizeLimit;

use FindBin;
use lib "$FindBin::Bin/../../lib";

use Scalar::Util qw( blessed );

use Zuzu;
use Zuzu::Lexer;
use Zuzu::Parser::_Impl;
use Zuzu::Runtime;
use Zuzu::Util;

my $STATIC_ROOT = "$FindBin::Bin/public";
my $COOKIE_NAME = 'zuzu_webconsole_sid';
my $SESSION_TTL = 60 * 60 * 8;
my $SESSION_DIR = $ENV{ZUZU_WEB_CONSOLE_SESSION_DIR}
	// '/tmp/zuzu-webconsole-sessions';
my $EVAL_TIMEOUT_SECONDS
	= defined $ENV{ZUZU_WEB_CONSOLE_EVAL_TIMEOUT}
	? 0 + $ENV{ZUZU_WEB_CONSOLE_EVAL_TIMEOUT}
	: 3;
my $MAX_UNSHARED_KB
	= defined $ENV{ZUZU_WEB_CONSOLE_MAX_UNSHARED_KB}
	? 0 + $ENV{ZUZU_WEB_CONSOLE_MAX_UNSHARED_KB}
	: 256 * 1024;
my $MIN_SHARED_KB
	= defined $ENV{ZUZU_WEB_CONSOLE_MIN_SHARED_KB}
	? 0 + $ENV{ZUZU_WEB_CONSOLE_MIN_SHARED_KB}
	: 0;

sub _capture_runtime_streams {
	my ( $code ) = @_;

	my $stdout = '';
	my $stderr = '';
	my $ok = 0;
	my $result;
	my $error;

	{
		local *STDOUT;
		local *STDERR;
		open STDOUT, '>', \$stdout
			or die "Failed to capture STDOUT: $!";
		open STDERR, '>', \$stderr
			or die "Failed to capture STDERR: $!";

		$ok = eval {
			$result = $code->();
			1;
		};
		$error = $@ if not $ok;
	}

	return ( $ok, $result, $error, $stdout, $stderr );
}

sub _evaluate_repl_with_timeout {
	my ( $session, $effective_source ) = @_;

	my ( $ok_eval, $result, $err_eval, $stdout, $stderr )
		= _capture_runtime_streams( sub {
		local $SIG{ALRM} = sub {
			die "__ZUZU_EVAL_TIMEOUT__\n";
		};

		my $eval_result;
		my $inner_ok = eval {
			alarm $EVAL_TIMEOUT_SECONDS;
			my $ast = _parse_repl_source( $session->{runtime}, $effective_source );
			$eval_result = $session->{runtime}->evaluate($ast);
			1;
		};
		alarm 0;
		die $@ if not $inner_ok;
		return $eval_result;
	} );

	if ( ! $ok_eval and defined $err_eval and $err_eval =~ /__ZUZU_EVAL_TIMEOUT__/ ) {
		$err_eval = "Execution timed out after ${EVAL_TIMEOUT_SECONDS}s";
	}

	return ( $ok_eval, $result, $err_eval, $stdout, $stderr );
}

sub _json_response {
	my ( $status, $payload ) = @_;

	my $res = Plack::Response->new( $status );
	$res->content_type('application/json; charset=utf-8');
	$res->body( encode_json( $payload ) );
	return $res;
}

sub _new_session {
	my $seed = join ':', $$, time, rand(), ( $ENV{REMOTE_ADDR} // '' );
	my $sid = sha1_hex($seed);
	my $session = {
		history => [],
		buffer => [],
		expecting_more => 0,
		touched => time,
	};
	_save_session( $sid, $session );
	return $sid;
}

sub _session_file_for_sid {
	my ( $sid ) = @_;
	return undef if ! defined $sid;
	return undef if $sid !~ /\A[a-f0-9]{40}\z/;
	return "$SESSION_DIR/$sid.json";
}

sub _load_session {
	my ( $sid ) = @_;

	my $path = _session_file_for_sid($sid);
	return undef if ! defined $path;
	return undef if ! -e $path;

	open my $fh, '<', $path
		or return undef;
	flock( $fh, LOCK_SH )
		or return undef;
	local $/;
	my $json = <$fh>;
	close $fh;
	return undef if ! defined $json;

	my $session = eval {
		decode_json($json);
	};
	return undef if $@;
	return undef if ref($session) ne 'HASH';

	$session->{history} = [] if ref( $session->{history} ) ne 'ARRAY';
	$session->{buffer} = [] if ref( $session->{buffer} ) ne 'ARRAY';
	$session->{expecting_more} = $session->{expecting_more} ? 1 : 0;
	$session->{touched} = 0 + ( $session->{touched} // 0 );

	return $session;
}

sub _save_session {
	my ( $sid, $session ) = @_;

	make_path($SESSION_DIR) if ! -d $SESSION_DIR;
	my $path = _session_file_for_sid($sid)
		or die "Invalid session id";

	open my $fh, '>', $path
		or die "Failed to write session file '$path': $!";
	flock( $fh, LOCK_EX )
		or die "Failed to lock session file '$path': $!";
	print {$fh} encode_json($session);
	close $fh
		or die "Failed to close session file '$path': $!";
	return;
}

sub _prune_sessions {
	my $now = time;
	make_path($SESSION_DIR) if ! -d $SESSION_DIR;

	opendir my $dh, $SESSION_DIR
		or return;
	while ( my $entry = readdir $dh ) {
		next if $entry !~ /\A([a-f0-9]{40})\.json\z/;
		my $sid = $1;
		my $session = _load_session($sid);
		if ( ! defined $session ) {
			unlink "$SESSION_DIR/$entry";
			next;
		}
		next if ( $session->{touched} // 0 ) >= $now - $SESSION_TTL;
		unlink "$SESSION_DIR/$entry";
	}
	closedir $dh;
	return;
}

sub _session_for_request {
	my ( $req, $requested_sid ) = @_;

	_prune_sessions();

	if ( defined $requested_sid ) {
		my $session = _load_session($requested_sid);
		if ( defined $session ) {
			$session->{touched} = time;
			_save_session( $requested_sid, $session );
			return ( $requested_sid, $session, 0 );
		}
	}

	my $sid = $req->cookies->{$COOKIE_NAME};
	if ( defined $sid ) {
		my $session = _load_session($sid);
		if ( defined $session ) {
			$session->{touched} = time;
			_save_session( $sid, $session );
			return ( $sid, $session, 0 );
		}
	}

	$sid = _new_session();
	my $session = _load_session($sid);
	return ( $sid, $session, 1 );
}

sub _runtime_from_history {
	my ( $history ) = @_;

	my $runtime = Zuzu::Runtime->new(
		lib  => [ @Zuzu::Runtime::DEFAULT_LIB ],
		deny => RUNTIME_DENY,
	);

	for my $source ( @{ $history // [] } ) {
		my $ast = _parse_repl_source( $runtime, $source );
		$runtime->evaluate($ast);
	}

	return $runtime;
}

sub _repl_render_value {
	my ( $runtime, $value ) = @_;

	return 'Null' if ! defined $value;
	return "$value" if ! ref($value);
	if ( blessed($value) and $value->isa('Zuzu::Value::Boolean') ) {
		return $value ? "true" : "false";
	}

	return $runtime->_type_name($value);
}

sub _is_probably_incomplete_parse_error {
	my ( $error, $source ) = @_;

	return 0 if ! blessed($error);
	return 0 if ! $error->isa('Zuzu::Error::Compile');
	return 1 if ( $error->message // '' ) =~ /\AUnterminated\b/;

	my $line_count = () = $source =~ /\n/g;
	$line_count++;
	return 0 if ! defined $error->line;
	return 0 if $error->line < $line_count;

	return 1 if ( $error->message // '' ) =~ /\AExpected\b/;

	return 0;
}

sub _repl_structural_depth {
	my ( $source ) = @_;

	my $depth = 0;
	my $in_single = 0;
	my $in_double = 0;
	my $escaped = 0;

	for my $ch ( split //, $source ) {
		if ($escaped) {
			$escaped = 0;
			next;
		}
		if ($in_single) {
			if ( $ch eq '\\' ) {
				$escaped = 1;
				next;
			}
			if ( $ch eq "'" ) {
				$in_single = 0;
			}
			next;
		}
		if ($in_double) {
			if ( $ch eq '\\' ) {
				$escaped = 1;
				next;
			}
			if ( $ch eq '"' ) {
				$in_double = 0;
			}
			next;
		}
		if ( $ch eq "'" ) {
			$in_single = 1;
			next;
		}
		if ( $ch eq '"' ) {
			$in_double = 1;
			next;
		}
		if ( $ch eq '{' or $ch eq '(' or $ch eq '[' ) {
			$depth++;
			next;
		}
		if ( $ch eq '}' or $ch eq ')' or $ch eq ']' ) {
			$depth--;
		}
	}

	return $depth;
}

sub _repl_prelude_for_runtime {
	my ( $runtime ) = @_;

	my %reserved = map { $_ => 1 } qw(
		Exception
		AssertionException
		TypeException
		CancelledException
		TimeoutException
		ChannelClosedException
		Array
		Dict
		PairList
		Set
		Bag
		Pair
		String
		BinaryString
		Task
		say
		print
		warn
		typeof
		to_binary
		to_string
		__system__
		__global__
	);
	my @decls;
	for my $name ( sort keys %{ $runtime->{_global}{slots} // {} } ) {
		next if $reserved{$name};
		next if $name !~ /\A[_A-Za-z][_A-Za-z0-9]*\z/;
		next if Zuzu::Util::is_keyword($name);
		push @decls, "let $name := null;";
	}

	return @decls;
}

sub _parse_repl_source {
	my ( $runtime, $source ) = @_;

	my @prelude = _repl_prelude_for_runtime($runtime);
	my $combined = @prelude
		? join( "\n", @prelude, $source )
		: $source;

	my $lexer = Zuzu::Lexer->new(
		src => $combined,
		filename => '<repl>',
	);
	my $impl = Zuzu::Parser::_Impl->new(
		lexer => $lexer,
		filename => '<repl>',
	);

	my $ast = $impl->parse_program;
	if (@prelude) {
		my @stmts = @{ $ast->statements };
		splice @stmts, 0, scalar @prelude;
		$ast->statements( \@stmts );
	}

	return $ast;
}

sub _try_parse_with_optional_semicolon {
	my ( $runtime, $source ) = @_;

	my $parse_ok = eval {
		_parse_repl_source( $runtime, $source );
		1;
	};
	if ($parse_ok) {
		return ( 1, undef, $source );
	}
	my $first_error = $@;

	my $trimmed = $source;
	$trimmed =~ s/\s+\z//;
	if ( $trimmed !~ /[;{}]\z/ and $trimmed =~ /\S/ ) {
		my $with_semicolon = $trimmed . ';';
		my $semicolon_ok = eval {
			_parse_repl_source( $runtime, $with_semicolon );
			1;
		};
		if ($semicolon_ok) {
			return ( 1, undef, $with_semicolon );
		}
	}

	return ( 0, $first_error, $source );
}

my $api_app = sub {
	my ( $env ) = @_;
	my $req = Plack::Request->new($env);

	return _json_response( 405, { error => 'Method not allowed' } )->finalize
		if $req->method ne 'POST';

	my $payload = eval {
		decode_json( $req->content // '{}' );
	};
	if ($@) {
		return _json_response( 400, { error => 'Invalid JSON request body' } )->finalize;
	}

	my ( $sid, $session, $is_new )
		= _session_for_request( $req, $payload->{sid} );
	$session = {
		history => [],
		buffer => [],
		expecting_more => 0,
		touched => time,
	} if ! defined $session;

	if ( $payload->{reset} ) {
		$session->{history} = [];
		$session->{buffer} = [];
		$session->{expecting_more} = 0;
		$session->{touched} = time;
		_save_session( $sid, $session );
	}

	my $line = defined $payload->{line}
		? $payload->{line}
		: '';
	$line =~ s/\r\n?/\n/g;
	$line =~ s/\n\z//;

	if ( ! @{ $session->{buffer} } and $line =~ /\A\s*\z/ ) {
		my $res = _json_response( 200, {
			status => 'blank',
			sid => $sid,
			expecting_more => JSON::PP::false,
		} );
		$res->cookies->{$COOKIE_NAME} = {
			value => $sid,
			path => '/',
			httponly => 1,
			samesite => 'Lax',
		};
		$session->{touched} = time;
		_save_session( $sid, $session );
		return $res->finalize;
	}

	push @{ $session->{buffer} }, split /\n/, $line, -1;
	my $source = join "\n", @{ $session->{buffer} };

	if ( _repl_structural_depth($source) > 0 ) {
		$session->{expecting_more} = 1;
		my $res = _json_response( 200, {
			status => 'continue',
			sid => $sid,
			expecting_more => JSON::PP::true,
		} );
		$res->cookies->{$COOKIE_NAME} = {
			value => $sid,
			path => '/',
			httponly => 1,
			samesite => 'Lax',
		};
		$session->{touched} = time;
		_save_session( $sid, $session );
		return $res->finalize;
	}

	my $runtime = eval {
		_runtime_from_history( $session->{history} );
	};
	if ($@) {
		$session->{history} = [];
		$session->{buffer} = [];
		$session->{expecting_more} = 0;
		$session->{touched} = time;
		_save_session( $sid, $session );

		my $res = _json_response( 200, {
			status => 'error',
			sid => $sid,
			expecting_more => JSON::PP::false,
			error => "Session state could not be restored: $@",
		} );
		$res->cookies->{$COOKIE_NAME} = {
			value => $sid,
			path => '/',
			httponly => 1,
			samesite => 'Lax',
		};
		return $res->finalize;
	}

	my ( $ok, $err, $effective_source )
		= _try_parse_with_optional_semicolon( $runtime, $source );
	if ( ! $ok ) {
		if ( _is_probably_incomplete_parse_error( $err, $source ) ) {
			$session->{expecting_more} = 1;
			my $res = _json_response( 200, {
				status => 'continue',
				sid => $sid,
				expecting_more => JSON::PP::true,
			} );
			$res->cookies->{$COOKIE_NAME} = {
				value => $sid,
				path => '/',
				httponly => 1,
				samesite => 'Lax',
			};
			$session->{touched} = time;
			_save_session( $sid, $session );
			return $res->finalize;
		}

		$session->{buffer} = [];
		$session->{expecting_more} = 0;
		my $res = _json_response( 200, {
			status => 'error',
			sid => $sid,
			expecting_more => JSON::PP::false,
			error => "$err",
		} );
		$res->cookies->{$COOKIE_NAME} = {
			value => $sid,
			path => '/',
			httponly => 1,
			samesite => 'Lax',
		};
		$session->{touched} = time;
		_save_session( $sid, $session );
		return $res->finalize;
	}

	my $response;
	my ( $ok_eval, $result, $err_eval, $stdout, $stderr )
		= _evaluate_repl_with_timeout( {
			runtime => $runtime,
		}, $effective_source );

	if ($ok_eval) {
		push @{ $session->{history} }, $effective_source;
		$response = {
			status => 'ok',
			sid => $sid,
			expecting_more => JSON::PP::false,
			output => _repl_render_value( $runtime, $result ),
			stdout => $stdout,
			stderr => $stderr,
		};
	}
	else {
		my $message;
		if ( ref($err_eval) eq 'HASH' and $err_eval->{_zuzu_throw} ) {
			my $value = defined $err_eval->{value} ? $err_eval->{value} : '';
			$message = "$value";
		}
		else {
			$message = "$err_eval";
		}
		$response = {
			status => 'error',
			sid => $sid,
			expecting_more => JSON::PP::false,
			error => $message,
			stdout => $stdout,
			stderr => $stderr,
		};
	}

	$session->{buffer} = [];
	$session->{expecting_more} = 0;
	$session->{touched} = time;
	_save_session( $sid, $session );

	my $res = _json_response( 200, $response );
	$res->cookies->{$COOKIE_NAME} = {
		value => $sid,
		path => '/',
		httponly => 1,
		samesite => 'Lax',
	};
	return $res->finalize;
};


my $static = Plack::App::File->new( root => $STATIC_ROOT )->to_app;

builder {
	enable 'SizeLimit',
		max_unshared_size => $MAX_UNSHARED_KB,
		min_shared_size => $MIN_SHARED_KB;
	mount '/api/eval' => $api_app;
	mount '/' => sub {
		my ( $env ) = @_;
		$env->{PATH_INFO} = '/index.html' if $env->{PATH_INFO} eq '/';
		return $static->($env);
	};
};
