#!/usr/bin/perl -w

use strict;

use Test::More tests => 17;
use IO::Async::Test;
use IO::Async::Loop::IO_Poll;
use IO::Async::Stream;

use IO::Socket::UNIX;
use Socket qw( AF_UNIX SOCK_STREAM PF_UNSPEC );

use Net::Async::HTTP::Client;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop::IO_Poll->new();
testing_loop( $loop );

my $client = Net::Async::HTTP::Client->new(
   loop => $loop,
);

ok( defined $client, 'defined $client' );
is( ref $client, "Net::Async::HTTP::Client", 'ref $client is Net::Async::HTTP::Client' );

sub do_test_req
{
   my $name = shift;
   my %args = @_;

   ( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
      die "Cannot create socket pair - $!";

   my $response;
   my $error;

   $client->do_request_handle(
      request => $args{req},
      handle  => $S1,

      on_response => sub { $response = $_[0] },
      on_error    => sub { $error    = $_[0] },
   );

   my $request_stream = "";
   my $otherend = IO::Async::Stream->new(
      handle => $S2,

      on_read => sub {
         $request_stream = ${$_[1]};
         ${$_[1]} = "";
         return 0;
      }
   );

   $loop->add( $otherend );

   # Wait for the Client to send its request
   wait_for { $request_stream =~ m/$CRLF$CRLF/ };

   $request_stream =~ s/^(.*)$CRLF//;
   my $req_firstline = $1;

   is( $req_firstline, $args{expect_req_firstline}, "First line for $name" );

   my %req_headers = map { m/^(.*?):\s+(.*)$/g } split( m/$CRLF/, $request_stream );

   is_deeply( \%req_headers, $args{expect_req_headers}, "Request headers for $name" );

   $otherend->write( $args{response} );

   # Wait for the Client to finish its response
   wait_for { defined $response or defined $error };

   if( $args{expect_error} ) {
      ok( 1, "Expected error for $name" );
      return;
   }

   if( exists $args{expect_res_code} ) {
      is( $response->code, $args{expect_res_code}, "Result code for $name" );
   }

   if( exists $args{expect_res_content} ) {
      is( $response->content, $args{expect_res_content}, "Result content for $name" );
   }

   if( exists $args{expect_res_headers} ) {
      my %h = map { $_ => $response->header( $_ ) } $response->header_field_names;

      is_deeply( \%h, $args{expect_res_headers}, "Result headers for $name" );
   }
}

my $req;

$req = HTTP::Request->new( HEAD => "/some/path", [ Host => "myhost" ] );
$req->protocol( "HTTP/1.1");

do_test_req( "simple HEAD",
   req => $req,

   expect_req_firstline => "HEAD /some/path HTTP/1.1",
   expect_req_headers => {
      Host => "myhost",
   },

   response => "HTTP/1.1 200 OK$CRLF" . 
               "Content-Length: 13$CRLF" . 
               "Content-Type: text/plain$CRLF" .
               $CRLF,

   expect_res_code    => 200,
   expect_res_headers => {
      'Content-Length' => 13,
      'Content-Type'   => "text/plain",
   },
   expect_res_content => "",
);

$req = HTTP::Request->new( GET => "/some/path", [ Host => "myhost" ] );
$req->protocol( "HTTP/1.1" );

do_test_req( "simple GET",
   req => $req,

   expect_req_firstline => "GET /some/path HTTP/1.1",
   expect_req_headers => {
      Host => "myhost",
   },

   response => "HTTP/1.1 200 OK$CRLF" . 
               "Content-Length: 13$CRLF" . 
               "Content-Type: text/plain$CRLF" .
               $CRLF . 
               "Hello, world!",

   expect_res_code    => 200,
   expect_res_headers => {
      'Content-Length' => 13,
      'Content-Type'   => "text/plain",
   },
   expect_res_content => "Hello, world!",
);

$req = HTTP::Request->new( GET => "/somethingmissing", [ Host => "somewhere" ] );
$req->protocol( "HTTP/1.1" );

do_test_req( "GET not found",
   req => $req,

   expect_req_firstline => "GET /somethingmissing HTTP/1.1",
   expect_req_headers => {
      Host => "somewhere",
   },

   response => "HTTP/1.1 404 Not Found$CRLF" . 
               $CRLF,

   expect_res_code    => 404,
   expect_res_headers => {
   },
   expect_res_content => "",
);

