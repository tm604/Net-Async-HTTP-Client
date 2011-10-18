#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use IO::Async::Test;
use IO::Async::Loop;

use Net::Async::HTTP;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my $http = Net::Async::HTTP->new();

$loop->add( $http );

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

my $error;

$http->do_request(
   uri => URI->new( "http://my.server/doc" ),
   handle => $S1,

   timeout => 1, # Really quick for testing

   on_response => sub { die "Test died early - got a response but shouldn't have" },
   on_error    => sub { $error = $_[0] },
);

wait_for { defined $error };

like( $error, qr/^Timed out/, 'Received timeout error' );

( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

undef $error;

$http->do_request(
   uri => URI->new( "http://my.server/redir" ),
   handle => $S1,

   timeout => 1, # Really quick for testing

   on_response => sub { die "Test died early - got a response but shouldn't have" },
   on_error    => sub { $error = $_[0] },
);

my $request_stream = "";
wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $S2 => $request_stream;

$request_stream =~ s/^(.*)$CRLF//;

$S2->syswrite( "HTTP/1.1 301 Moved Permanently$CRLF" .
               "Content-Length: 0$CRLF" .
               "Location: http://my.server/get_doc?name=doc$CRLF" .
               "$CRLF" );

wait_for { defined $error };

like( $error, qr/^Timed out/, 'Received timeout error from redirect' );
