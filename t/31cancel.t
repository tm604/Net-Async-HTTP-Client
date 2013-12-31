#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use IO::Async::Test;
use IO::Async::Loop;

use Net::Async::HTTP;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

my $http = Net::Async::HTTP->new(
   user_agent => "", # Don't put one in request headers
);

$loop->add( $http );

my $peersock;
no warnings 'redefine';
local *IO::Async::Handle::connect = sub {
   my $self = shift;
   my %args = @_;

   ( my $selfsock, $peersock ) = IO::Async::OS->socketpair() or die "Cannot create socket pair - $!";
   $self->set_handle( $selfsock );
   $peersock->blocking(0);

   return Future->new->done( $self );
};

# Cancellation
{
   undef $peersock;
   my $f1 = $http->do_request(
      method  => "GET",
      uri     => URI->new( "http://host1/some/path" ),
   );

   wait_for { $peersock };

   $f1->cancel;

   wait_for { my $ret = sysread($peersock, my $buffer, 1); defined $ret and $ret == 0 };
   ok( 1, '$peersock closed' );

   # Retry after cancel should establish another connection

   undef $peersock;
   my $f2 = $http->do_request(
      method  => "GET",
      uri     => URI->new( "http://host1/some/path" ),
   );

   wait_for { $peersock };

   # Wait for the client to send its request
   my $request_stream = "";
   wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $peersock => $request_stream;

   $peersock->syswrite( join( $CRLF,
      "HTTP/1.1 200 OK",
      "Content-Type: text/plain",
      "Content-Length: 12",
      "" ) . $CRLF .
      "Hello world!"
   );

   wait_for { $f2->is_ready };
   $f2->get;
}

done_testing;
