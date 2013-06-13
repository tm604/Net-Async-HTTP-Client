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
local *Net::Async::HTTP::Protocol::connect = sub {
   my $self = shift;
   my %args = @_;

   ( my $selfsock, $peersock ) = IO::Async::OS->socketpair() or die "Cannot create socket pair - $!";

   $self->IO::Async::Protocol::connect(
      transport => IO::Async::Stream->new( handle => $selfsock )
   );
};

# fail_on_error false
{
   $http->configure( fail_on_error => 0 );

   my $request = HTTP::Request->new(
      GET => "/some/path",
      [ Host => "myhost" ]
   );

   my $future = $http->do_request(
      method => "GET",
      uri    => URI->new( "http://host0/some/path" ),
   );

   ok( defined $future, '$future defined for request' );

   wait_for { $peersock };

   # Wait for the client to send its request
   my $request_stream = "";
   wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $peersock => $request_stream;

   $peersock->syswrite( join( $CRLF,
      "HTTP/1.1 404 Not Found",
      "Content-Type: text/plain",
      "Content-Length: 9",
      "" ) . $CRLF .
      "Not Found"
   );

   wait_for { $future->is_ready };

   my $response = $future->get;
   isa_ok( $response, "HTTP::Response", '$future->get for fail_on_error false' );

   is( $response->code, 404, '$response->code for fail_on_error false' );
}

# fail_on_error true
{
   $http->configure( fail_on_error => 1 );

   my $request = HTTP::Request->new(
      GET => "/some/path",
      [ Host => "myhost" ]
   );

   my ( $response_c, $request_c );
   my $future = $http->do_request(
      method => "GET",
      uri    => URI->new( "http://host0/some/path" ),
      on_error => sub {
         ( my $message, $response_c, $request_c ) = @_;
         is( $message, "404 Not Found", '$message to on_error' );
      },
   );

   ok( defined $future, '$future defined for request' );

   wait_for { $peersock };

   # Wait for the client to send its request
   my $request_stream = "";
   wait_for_stream { $request_stream =~ m/$CRLF$CRLF/ } $peersock => $request_stream;

   $peersock->syswrite( join( $CRLF,
      "HTTP/1.1 404 Not Found",
      "Content-Type: text/plain",
      "Content-Length: 9",
      "" ) . $CRLF .
      "Not Found"
   );

   wait_for { $future->is_ready };

   is( scalar $future->failure, "404 Not Found", '$future->failure for fail_on_error true' );
   my ( undef, $response_f, $request_f ) = $future->failure;

   is( $response_f->code, 404, '$response_f->code for fail_on_error true' );
   is( $response_c->code, 404, '$response_c->code for fail_on_error true' );

   is( $request_f->uri, "http://host0/some/path", '$request_f->uri for fail_on_error true' );
   is( $request_c->uri, "http://host0/some/path", '$request_f->uri for fail_on_error true' );
}

done_testing;
