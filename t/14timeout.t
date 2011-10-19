#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 8;
use IO::Async::Test;
use IO::Async::Loop;

use Net::Async::HTTP;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my $http = Net::Async::HTTP->new();

$loop->add( $http );

{
   my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

   my $errcount;
   my $error;

   $http->do_request(
      uri => URI->new( "http://my.server/doc" ),
      handle => $S1,

      timeout => 1, # Really quick for testing

      on_response => sub { die "Test died early - got a response but shouldn't have" },
      on_error    => sub { $errcount++; $error = $_[0] },
   );

   wait_for { defined $error };

   like( $error, qr/^Timed out/, 'Received timeout error' );
   is( $errcount, 1, 'on_error invoked once' );
}

{
   my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

   my $errcount;
   my $error;

   $http->do_request(
      uri => URI->new( "http://my.server/redir" ),
      handle => $S1,

      timeout => 1, # Really quick for testing

      on_response => sub { die "Test died early - got a response but shouldn't have" },
      on_error    => sub { $errcount++; $error = $_[0] },
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
   is( $errcount, 1, 'on_error invoked once from redirect' );
}

{
   my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

   my $error;
   my $errcount;

   $http->do_request(
      uri => URI->new( "http://my.server/first" ),
      handle => $S1,

      timeout => 1, # Really quick for testing

      on_response => sub { die "Test died early - got a response but shouldn't have" },
      on_error    => sub { $errcount++; $error = $_[0] },
   );

   my $error2;
   my $errcount2;

   $http->do_request(
      uri => URI->new( "http://my.server/second" ),
      handle => $S1,

      timeout => 3,

      on_response => sub { die "Test died early - got a response but shouldn't have" },
      on_error    => sub { $errcount2++; $error2 = $_[0] },
   );

   wait_for { defined $error and defined $error2 };

   like( $error, qr/^Timed out/, 'Received timeout error from pipeline' );
   is( $errcount, 1, 'on_error invoked once from pipeline' );
   like( $error2, qr/^Timed out/, 'Received timeout error from pipeline(2)' );
   is( $errcount2, 1, 'on_error invoked once from pipeline(2)' );
}
