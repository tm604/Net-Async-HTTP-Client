#!/usr/bin/perl -w

use strict;

use Test::More tests => 44;
use IO::Async::Test;
use IO::Async::Loop::IO_Poll;
use IO::Async::Stream;

use IO::Socket::UNIX;
use Socket qw( AF_UNIX SOCK_STREAM PF_UNSPEC );

use Net::Async::HTTP;

my $CRLF = "\x0d\x0a"; # because \r\n isn't portable

my $loop = IO::Async::Loop::IO_Poll->new();
testing_loop( $loop );

my $http = Net::Async::HTTP->new(
   loop => $loop,
   user_agent => "", # Don't put one in request headers
);

# Most of this function copypasted from t/01http-req.t

sub do_test_uri
{
   my $name = shift;
   my %args = @_;

   ( my $S1, my $S2 ) = IO::Socket::UNIX->socketpair( AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or
      die "Cannot create socket pair - $!";

   my $response;
   my $error;

   $http->do_request(
      uri     => $args{uri},
      method  => $args{method},
      user    => $args{user},
      pass    => $args{pass},
      content => $args{content},
      handle  => $S1,

      on_response => sub { $response = $_[0] },
      on_error    => sub { $error    = $_[0] },
   );

   my $request_stream = "";
   my $otherend = IO::Async::Stream->new(
      handle => $S2,

      on_read => sub {
         $request_stream .= ${$_[1]};
         ${$_[1]} = "";
         return 0;
      }
   );

   $loop->add( $otherend );

   # Wait for the client to send its request
   wait_for { $request_stream =~ m/$CRLF$CRLF/ };

   $request_stream =~ s/^(.*)$CRLF//;
   my $req_firstline = $1;

   is( $req_firstline, $args{expect_req_firstline}, "First line for $name" );

   $request_stream =~ s/^(.*)$CRLF$CRLF//s;
   my %req_headers = map { m/^(.*?):\s+(.*)$/g } split( m/$CRLF/, $1 );

   my $req_content;
   if( defined( my $len = $req_headers{'Content-Length'} ) ) {
      wait_for { length( $request_stream ) >= $len };

      $req_content = substr( $request_stream, 0, $len );
      substr( $request_stream, 0, $len ) = "";
   }

   is_deeply( \%req_headers, $args{expect_req_headers}, "Request headers for $name" );

   if( defined $args{expect_req_content} ) {
      is( $req_content, $args{expect_req_content}, "Request content for $name" );
   }

   $otherend->write( $args{response} );
   $otherend->close if $args{close_after_response};

   # Wait for the server to finish its response
   wait_for { defined $response or defined $error };

   if( $args{expect_error} ) {
      ok( defined $error, "Expected error for $name" );
      return;
   }
   else {
      ok( !defined $error, "Failed to error for $name" );
      if( defined $error ) {
         diag( "Got error $error" );
      }
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

do_test_uri( "simple HEAD",
   method => "HEAD",
   uri    => URI->new( "http://myhost/some/path" ),

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

do_test_uri( "simple GET",
   method => "GET",
   uri    => URI->new( "http://myhost/some/path" ),

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

do_test_uri( "GET with params",
   method => "GET",
   uri    => URI->new( "http://myhost/cgi?param=value" ),

   expect_req_firstline => "GET /cgi?param=value HTTP/1.1",
   expect_req_headers => {
      Host => "myhost",
   },

   response => "HTTP/1.1 200 OK$CRLF" . 
               "Content-Length: 11$CRLF" . 
               "Content-Type: text/plain$CRLF" .
               $CRLF . 
               "CGI content",

   expect_res_code    => 200,
   expect_res_headers => {
      'Content-Length' => 11,
      'Content-Type'   => "text/plain",
   },
   expect_res_content => "CGI content",
);

do_test_uri( "authenticated GET",
   method => "GET",
   uri    => URI->new( "http://myhost/secret" ),
   user   => "user",
   pass   => "pass",

   expect_req_firstline => "GET /secret HTTP/1.1",
   expect_req_headers => {
      Host => "myhost",
      Authorization => "Basic dXNlcjpwYXNz", # determined using 'wget'
   },

   response => "HTTP/1.1 200 OK$CRLF" . 
               "Content-Length: 18$CRLF" . 
               "Content-Type: text/plain$CRLF" .
               $CRLF . 
               "For your eyes only",

   expect_res_code    => 200,
   expect_res_headers => {
      'Content-Length' => 18,
      'Content-Type'   => "text/plain",
   },
   expect_res_content => "For your eyes only",
);

do_test_uri( "authenticated GET (URL embedded)",
   method => "GET",
   uri    => URI->new( "http://user:pass\@myhost/private" ),

   expect_req_firstline => "GET /private HTTP/1.1",
   expect_req_headers => {
      Host => "myhost",
      Authorization => "Basic dXNlcjpwYXNz", # determined using 'wget'
   },

   response => "HTTP/1.1 200 OK$CRLF" . 
               "Content-Length: 6$CRLF" . 
               "Content-Type: text/plain$CRLF" .
               $CRLF . 
               "Shhhh!",

   expect_res_code    => 200,
   expect_res_headers => {
      'Content-Length' => 6,
      'Content-Type'   => "text/plain",
   },
   expect_res_content => "Shhhh!",
);

do_test_uri( "simple POST",
   method  => "POST",
   uri     => URI->new( "http://somewhere/handler" ),
   content => "New content",

   expect_req_firstline => "POST /handler HTTP/1.1",
   expect_req_headers => {
      Host => "somewhere",
      'Content-Length' => 11,
      'Content-Type' => "application/x-www-form-urlencoded",
   },
   expect_req_content => "New content",

   response => "HTTP/1.1 201 Created$CRLF" . 
               "Content-Length: 11$CRLF" .
               "Content-Type: text/plain$CRLF" .
               $CRLF .
               "New content",

   expect_res_code    => 201,
   expect_res_headers => {
      'Content-Length' => 11,
      'Content-Type'   => "text/plain",
   },
   expect_res_content => "New content",
);

do_test_uri( "form POST",
   method  => "POST",
   uri     => URI->new( "http://somewhere/handler" ),
   content => [ param => "value", another => "value with things" ],

   expect_req_firstline => "POST /handler HTTP/1.1",
   expect_req_headers => {
      Host => "somewhere",
      'Content-Length' => 37,
      'Content-Type' => "application/x-www-form-urlencoded",
   },
   expect_req_content => "param=value&another=value+with+things",

   response => "HTTP/1.1 200 OK$CRLF" . 
               "Content-Length: 4$CRLF" .
               "Content-Type: text/plain$CRLF" .
               $CRLF .
               "Done",

   expect_res_code    => 200,
   expect_res_headers => {
      'Content-Length' => 4,
      'Content-Type'   => "text/plain",
   },
   expect_res_content => "Done",
);
